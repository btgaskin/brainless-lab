# Designing Nodes

A **node** is a neuron model that fills a reservoir. BrainlessLab is built so that the same
node runs *any* task: the framework hands it dimensions and drives it through a fixed
contract, and the node knows nothing about walls, paddles, or poles. Adding a node is not
about wiring it to a task — it is about deciding *where adaptation lives* and then honoring
the contract cleanly enough that `simulate`, `bench`, and `evolve` can size and drive it
without a single `if node == :yours` branch anywhere in the framework.

This file is design guidance. For the task side, see `designing-environments-and-tasks.md`;
for measures over a run, `designing-analyses.md`; for the CLI/evolution flow,
`cli-tools.md` and `usage-and-workflows.md`. The canonical web references are
<https://brainless-lab.pages.dev/extending/> and <https://brainless-lab.pages.dev/contracts/>.

## The contract is a design contract

A node is a `struct MyNode <: Reservoir` plus a small set of **methods** on BrainlessLab's
generics:

```julia
step!(r, R)          -> spikes    # advance one tick; return the spike/rate vector
effectors(r, spikes) -> E         # map spikes to an E-vector of length n_effectors(r)
reset!(r)                         # zero the runtime state, restore initial weights
n_nodes(r)                       # node population width, including inactive ticks
n_receptors(r)                    # R-width this node was built for
n_effectors(r)                    # E-width this node was built for
```

The single most common mistake is scoping these wrong. In Julia a function is a name and a
method is one implementation of it; you are *adding methods* to the framework's existing
generics, so you must **import the names you extend**:

```julia
import BrainlessLab: step!, effectors, reset!, n_nodes, n_receptors, n_effectors
import BrainlessLab: NodeModel, Reservoir, register_node!
```

`using BrainlessLab` brings the names into scope for *calling* but not for *extending* —
define `step!(r::MyNode, R)` under `using` alone and you have quietly created a **new**
local `step!` that shadows the generic, so `simulate` dispatches to the framework's method
and never sees yours. If your node "doesn't run" with no error, this is almost always why.
(This is the general Julia function-vs-method rule — see the `julia` skill's
`dispatch-and-design.md`.)

## A node is task-agnostic

The framework constructs every node the same way and matches it to the task's shape:

```julia
MyNode(n_nodes, n_receptors, n_effectors; seed=0, kwargs...)
```

`n_nodes` is your population size; `n_receptors`/`n_effectors` are dictated by the task, not
chosen by you. Honor them exactly: `step!` receives an `R`-vector of length `n_receptors(r)`
and `effectors` must return an `E`-vector of length `n_effectors(r)`. A node that assumes a
particular task — hard-codes 2 effectors, expects a Pong-shaped input — has broken the
abstraction and will `DimensionMismatch` the moment it meets another task. Keep `seed`
threaded through every stochastic choice (wiring, weight init, noise) so a run is
reproducible.

Implement `n_nodes(r)` from stable reservoir state, for example `length(r.spikes)`. The
generic ensemble uses it to emit a correctly sized zero vector when a dead or inactive body
keeps its stable slot without advancing neural state.

The smoke test for "am I task-agnostic" is that `simulate(:wall; node=:mynode)` and
`simulate(:cartpole; node=:mynode)` both build and run without you touching the node.

If the constructor accepts a body-specific vector of receptor connection probabilities,
declare the keyword as a capability:

```julia
register_node!(
    :mynode,
    MyNode;
    genome_type=MyNodeParams,
    receptor_profile_keyword=:input_link_p,
)
```

This is how regulated-variable `link_p` reaches a compatible reservoir without a symbol check.
For mutable stochastic node inputs, high-level multi-agent builds give each agent an owned source.
`RngNoise(seed)` derives seeds `seed`, `seed + 1`, and so on; use `AgentNoiseFactory` or extend
`agent_noise_source` when a custom source needs a different split rule.

## Three families — and what each decides about *how you test it*

The families in `src/nodes/` differ on one design axis: **does adaptation live in plastic
weights, or in the fixed-weight dynamics of an evolved system?** That axis decides whether an
*untrained* node is a fair test — get it wrong and every comparison you draw is unfair.

- **Falandays** (`src/nodes/Falandays.jl`, the reference node) — homeostatic LIF that learns
  **online**: recurrent weights and per-node targets adapt every tick inside `step!`. Because
  it self-organizes during the rollout, an untrained instance is already meaningful. It
  declares `plasticity(::FalandaysReservoir) = OnlinePlasticity()`, and `bench` preps it
  **untrained**. SORN (`SORN.jl`, STDP + intrinsic plasticity + synaptic normalization) is a
  mechanistically different route to the same "fair untrained" status.
- **Compartmental / CTRNN** (`CompartmentalReservoir.jl`) — dendrite→soma→hillock cells with
  **fixed weights and no online plasticity**; adaptation is in the *dynamics*, not the
  synapses. It declares `NoPlasticity()`. An untrained one is random noise — it **must be
  evolved** before it means anything, and `bench` flags an untrained compartmental run as
  not-comparable.

Declare the trait honestly:

```julia
plasticity(::MyNode) = OnlinePlasticity()   # only if step! actually adapts weights/targets
```

The default is `NoPlasticity()`. If your node has no learning in `step!`, do not claim
`OnlinePlasticity()` to dodge the evolve step — you will publish an unfair untrained baseline.

## Compose before you subtype

Most "new nodes" are not new update rules — they are the Falandays rule with a different
knob. Those belong as **kwargs**, not new structs. The registered variants are exactly this:
preset kwarg bundles over one constructor.

```julia
simulate(:wall; node=:falandays_base, sign=:dale,
         topology=:watts_strogatz, drive=OosawaDrive(...))
```

`sign`, `topology`, and `drive` are composed axes (`src/nodes/Axes.jl`, `Wiring.jl`,
`Drives.jl`); `:falandays_oosawa`, `:falandays_dendritic`, `:falandays_spatial` are named
presets. **Reserve a fresh `<: Reservoir` for a genuinely new update rule** — a different
integrator, a different plasticity law, a different cell model. If the change is parametric,
add a kwarg or a preset and you inherit the whole family's wiring, drives, and tests for
free. This is composition-over-inheritance applied to neuron models.

## Evolvable nodes: genome vs state

Two orthogonal splits, and conflating them is the second-most-common mistake:

- **`pack_params` / `unpack_params` / `paramdim`** — the *genome*: the evolvable scalars an
  optimizer stores, mutates, and reloads. Attach these to a `MyNodeParams <: NodeModel`
  bundle. `paramdim` sizes the search space; `pack`/`unpack` are inverses (Falandays maps
  through `softplus`/`sigmoid` so the genome lives in unconstrained ℝⁿ while the params stay
  bounded — a good pattern).
- **`snapshot_state` / `load_state!`** — transient *runtime state*: activations, learned
  weights, spike buffers, noise index. For replay and reset, never for the search space.

A reservoir wrapper must forward the whole public behavioral contract, not merely fields:
widths, traits/window timing, recording, `network_snapshot`, readout, interventions, and
state snapshot/load. `getproperty` does not forward Julia dispatch. Include wrapper-owned
RNG or lag state in the snapshot and test next-step continuation after loading it.

Do not hide evolvable numbers in `snapshot_state`, and do not let `pack_params` leak dynamic
state — an optimizer that mutates a "parameter" that is really an activation will corrupt the
rollout. Then register with the genome type so `bench`/`evolve` can size it from the public
contract instead of branching on your symbol:

```julia
register_node!(:my_node, MyNode; genome_type=MyNodeParams)
```

A non-evolvable node (a null control like `NullRandomReservoir`) registers with no
`genome_type`; `bench` will only run it untrained.

## Register and smoke-test before you benchmark

```julia
register_node!(:my_node, MyNode; genome_type=MyNodeParams)
simulate(:wall; node=:my_node)      # does it build and run for a real task?
```

Get a clean `simulate` on at least two tasks before touching `bench`/`evolve` — a
benchmark that dies on tick 1 wastes a sweep. The copy-to-start scaffold lives at
`examples/templates/new_project/my_node.jl` (a self-contained homeostatic reservoir with all
methods, the genome/state split, and registration) plus its `README.md`.

**Naming:** this project deliberately keeps **"Reservoir"** (these are untrained /
self-organizing populations, not trained "networks"). Do not rename `<: Reservoir` to
`Network` or propose it — the term is load-bearing.

## Pitfalls

- **Type-unstable node struct.** `step!` is a hot loop run millions of times. Give every
  field a concrete type (`Vector{Float64}`, `Matrix{Float64}`, `BitMatrix`, `Int`) — never
  an abstract or untyped field. Parameterize on drive/sign type (`FalandaysModel{D<:Drive,S}`)
  rather than storing `::Any`. See the `julia` skill's `type-stability.md`.
- **Allocating in `step!`.** Preallocate `acts`, `spikes`, `errors`, `prev_spikes` as struct
  fields and mutate in place with `@inbounds` loops; `copyto!(prev, spikes)` instead of
  rebinding. Return `copy(r.spikes)` so callers can't alias your internal buffer, but do the
  work allocation-free.
- **Mismatched effector counts.** `effectors` must always return `length == n_effectors(r)`,
  even when the mapping is sparse — pad with zeros, don't return a short vector.
- **Assuming the node knows its task.** No task IDs, no per-task branches inside the node.
  If behavior must differ, that difference belongs in the task/body decode
  (`designing-environments-and-tasks.md`) or in a composed kwarg axis — not baked into `step!`.
