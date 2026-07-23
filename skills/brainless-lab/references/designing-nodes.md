# Designing nodes

A node type defines the local neural dynamics used throughout a reservoir. It must not know
the task name, body type, or experimental condition.

Use a new `Reservoir` subtype only for a genuinely different update rule, integrator, cell
model, or state organisation. Use parameters or a registered preset for a different value
of an existing rule.

## Implement the reservoir methods

A reservoir implements methods on BrainlessLab generics:

```julia
step!(reservoir, receptors)          # advance one neural frame
effectors(reservoir, spikes)         # return the declared effector width
reset!(reservoir)                    # restore initial runtime state
n_nodes(reservoir)
n_receptors(reservoir)
n_effectors(reservoir)
```

Import every generic that receives a new method:

```julia
import BrainlessLab: step!, effectors, reset!
import BrainlessLab: n_nodes, n_receptors, n_effectors
import BrainlessLab: Reservoir, NodeBuildContext, NodeSpec, ParameterSpec, register!
```

`using BrainlessLab` makes names available for calls. It does not authorise unqualified
method extension. A local `step!` created without `import` will not extend the framework
function.

## Build from `NodeBuildContext`

A registered node builder receives the resolved context and parameter values:

```julia
function build_my_node(context::NodeBuildContext, values)
    MyReservoir(
        context.n_nodes,
        n_receptors(context.ports),
        n_effectors(context.ports);
        seed=Int(mod(context.seeds.topology, UInt64(typemax(Int)))),
        params=values,
    )
end
```

The composition owns node count. The body ports own receptor and effector widths. Honour
these values exactly. Thread the supplied seeds through topology, weight initialisation,
noise, and any other stochastic construction.

Implement `n_nodes` from stable reservoir state. Inactive bodies retain stable entity
slots, so the runtime may need the correct width without advancing the node.

If a node accepts body-specific receptor connection probabilities, read
`context.receptor_profile` and declare the capability:

```julia
NodeSpec(
    :my_node,
    build_my_node;
    genome_type=MyNodeParams,
    capabilities=(:receptor_profile,),
)
```

Mutable stochastic inputs need one owned source per agent. Use `AgentNoiseFactory` or
extend `agent_noise_source` when a custom source needs its own stream derivation.

## Declare where adaptation occurs

State the plasticity trait honestly:

```julia
plasticity(::MyReservoir) = OnlinePlasticity()
```

Use `OnlinePlasticity()` only when `step!` changes weights, targets, or another persistent
adaptive variable during the rollout. The default is `NoPlasticity()`.

The trait affects fair evaluation:

- an online-plastic reservoir can adapt during each evaluation rollout;
- a fixed-weight reservoir may require prior evolution or another declared selection
  procedure;
- the selected parameters or weights must be held fixed for held-out evaluation.

Do not label a fixed system online-plastic to avoid preparation. Do not describe local
online plasticity as “nothing is trained”. State that there is no external task loss,
teacher, or fitted readout when that narrower claim is correct.

## Keep genome and runtime state separate

Evolution needs declared parameters, not arbitrary struct fields:

- `pack_params`, `unpack_params`, and `paramdim` define the optimisation genome;
- `snapshot_state` and `load_state!` preserve transient runtime state for reset or replay.

Do not place activations, learned within-rollout weights, spike buffers, or RNG position in
the genome. Do not place evolvable design parameters only in a runtime snapshot.

Register the parameter set explicitly:

```julia
spec = NodeSpec(
    :my_node,
    build_my_node;
    genome_type=MyNodeParams,
    parameters=(
        ParameterSpec(
            :leak,
            0.25;
            sweep=(0.1, 0.25, 0.5),
            evolve=(lower=0.0, upper=0.95),
        ),
        ParameterSpec(
            :link_p,
            0.1;
            owner=:reservoir,
            evolve=(lower=0.01, upper=0.8),
        ),
    ),
    parameter_sets=Dict(
        :sweep => (:leak,),
        :evolve => (:leak,),
        :connectivity => (:link_p,),
    ),
)
```

`ParameterSpec.owner` distinguishes local node parameters from reservoir construction
parameters. A non-evolvable node declares no `:evolve` parameter set. A `SweepPlan` or
`EvolutionPlan` resolves only the registered set.

Reservoir wrappers must forward methods, not only fields. Forward widths, traits,
recording, `network_snapshot`, readout, interventions, and state snapshot methods. Include
wrapper-owned RNG or lag state in the snapshot. Test continuation after loading it.

## Register and test the node

```julia
register!(DEFAULT_REGISTRY, spec)

composition = CompositionSpec(
    :my_tracking,
    :my_node,
    :tracking;
    n_nodes=200,
)

simulate(composition; ticks=300, seed=11)
```

Resolve and run explicit `CompositionSpec` values on at least two port-compatible tasks.
The node implementation must not change between them.

Use an `EvolutionPlan` when the node requires parameter selection. The plan separates
optimiser randomness, training evaluation, and held-out targets. A direct low-level
optimiser call is appropriate for implementation tests, not for a published protocol.

Use an `AblationPlan` to test a registered mechanism. Declare the required node
capabilities in `AblationSpec`. Typed plan validation rejects an inapplicable intervention
and execution rejects an unchanged composition.

The copy-ready node scaffold is
`examples/templates/new_project/my_node.jl`.

## Julia performance requirements

`step!` runs in the hot loop. Apply the Julia skill's inference and allocation checks:

- give hot-path fields concrete or parametric types;
- preallocate state and work buffers;
- mutate buffers instead of rebinding arrays;
- use function barriers around heterogeneous setup;
- measure allocations after warming the call;
- add threading only after the single-threaded kernel is correct and efficient.

Return a copy only when callers must not alias an internal buffer. Measure that choice
against the runtime contract.

## Common errors

- Hardcoded task widths: derive dimensions from `context.ports`.
- Task-name branches: move task behaviour into the body, task, or composition.
- Hidden parameter discovery: register sweep and evolution parameters explicitly.
- Mixed genotype and state: keep design values separate from runtime variables.
- Incomplete wrappers: Julia dispatch does not forward through `getproperty`.
- Incorrect reset: restore initial weights and all stochastic positions required by the
  declared reset policy.
- Unbounded parameters: give each evolved parameter an explicit transform or bound.

The project keeps the term `Reservoir` for the runtime node population. Do not rename it
to `Network` in the public interface.

See the [reservoir guide](https://brainless-lab.pages.dev/core/reservoirs/), the
[extension guide](https://brainless-lab.pages.dev/core/extend/), `cli-tools.md`, and
`designing-environments-and-tasks.md`.
