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

## Keep model coordinates and runtime state separate

Evolution needs a declared fixed design, not arbitrary struct fields:

- `pack_params`, `unpack_params`, and `paramdim` define model coordinates;
- `snapshot_state` and `load_state!` preserve transient runtime state for reset or replay.

Do not place activations, learned within-rollout weights, spike buffers, or RNG position in
the model coordinates. Do not place searchable design values only in a runtime snapshot.

The public evolution operation supports any registered node whose `NodeSpec` declares a
reviewed `Evolution.NodeDesignSpec`. The built-in fixed designs are:

- `FalandaysParams`, used by `:falandays` and its registered variants;
- `StructuredCompartmental`, registered as `:compartmental_structured`;
- `DenseCompartmental`, registered as `:compartmental_dense`.

Each `NodeDesignSpec` fixes the model type, coordinate schema, and reconstruction contract.
The Falandays design searches seven bounded coordinates and reconstructs candidates with
online plasticity enabled. `learn_on` is not a model coordinate.

Setting `genome_type` on another `NodeSpec` does not admit that node to the public
`EvolutionPlan` path. A new design needs a reviewed typed design contract, portable model
serialisation, and record tests. A search changes coordinates within that design. It does
not change topology, node count, body components, receptor ports, or effector ports.

Continue to register ordinary node parameters for composition and sweep work. For example:

```julia
ParameterSpec(
    :leak,
    0.25;
    sweep=(0.1, 0.25, 0.5),
)
```

`ParameterSpec.owner` distinguishes local node parameters from reservoir construction
parameters. A `SweepPlan` searches declared parameter cells. It does not create a portable
evolved model.

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

Use an `EvolutionPlan` only when the registered node declares a reviewed fixed design
contract. Embed `BrainlessLab.Evolution.RunConfig` to declare the strategy, iteration
budget, search seed, measure, direction, seeded normal initialisation, and strategy options.

All public strategies resolve through one typed registry. The current keys are `:sepcma`,
`:nsga2`, and `:cmame`. SepCMA writes the model role `selected`. NSGA-II and CMA-ME write
ordered sets and do not choose an implicit champion.

Use `Evolution.model_reference` to attach one named model to a later `EvaluationTarget`.
Evaluate that target with a `BenchmarkPlan`. A direct low-level optimiser call is suitable
for implementation tests, not for a published protocol.

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
- Hidden design discovery: use a reviewed `NodeDesignSpec`; do not search struct fields.
- Mixed model and state: keep design coordinates separate from runtime variables.
- Incomplete wrappers: Julia dispatch does not forward through `getproperty`.
- Incorrect reset: restore initial weights and all stochastic positions required by the
  declared reset policy.
- Implicit initialisation: declare a seeded normal distribution in `Evolution.RunConfig`.

The project keeps the term `Reservoir` for the runtime node population. Do not rename it
to `Network` in the public interface.

See the [node and reservoir guide](https://brainless-lab.pages.dev/handbook/nodes-reservoirs/), the
[extension guide](https://brainless-lab.pages.dev/handbook/extending/), `cli-tools.md`, and
`designing-environments-and-tasks.md`.
