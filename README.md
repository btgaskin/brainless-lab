# BrainlessLab.jl

BrainlessLab.jl is a small Julia lab for tinkering with brainless cognition: reservoirs, bodies, tasks, swarm media, recorders, metrics, and Makie visualizations are all wired through lightweight registries so researchers can swap node families and add their own parts without forking the framework. The current port is oracle-validated against the numpy v0/v0.2 implementation in Float64, while keeping the Julia API pleasant enough for examples, notebooks, and quick experiments.

## Quickstart

From the Julia package prompt:

```julia
pkg> dev /Users/bengaskin/dev/neural-cognition/brainless-lab
pkg> add CairoMakie
```

Then run a task and plot it:

```julia
using BrainlessLab, CairoMakie

sim = simulate(:wall; node=:falandays, ticks=300)
visualize(sim)
```

The compute core does not depend on Makie. Plotting methods are loaded by the package extension after a Makie backend such as CairoMakie or GLMakie is loaded.

## Node Variants

| Symbol | Description |
| --- | --- |
| `:falandays` | Base Falandays adaptive spiking reservoir with native random wiring. |
| `:falandays_oosawa` | Falandays plus Oosawa endogenous drive, default `membrane_noise=1.0`, `noise_gain=0.5`. |
| `:falandays_dale` | Dale-signed Falandays with Watts-Strogatz recurrent wiring, negative activations, and Oosawa drive. |
| `:compartmental_dense` | Dense compartmental reservoir with random native wiring and a teaching-size default. |
| `:compartmental_structured` | Structured compartmental reservoir with native structured dendrite/soma routing. |

List the currently registered variants:

```julia
variants()
```

## Tasks

Single-agent tasks:

- `:wall`
- `:tracking`
- `:pong`
- `:cartpole`

CartPole variants (greenfield):

- `:cartpole_hard` — tighter bounds / weaker actuation
- `:cartpole_swingup` — pole starts hanging down; score is mean uprightness
- `:cartpole_long` — double pole length (harder dynamics)

Additional registered task entries:

- `:pong_hitrate`
- `:torus` for swarm runs, for example `simulate(:torus; node=:falandays, n_agents=5)`

List the currently registered tasks:

```julia
tasks()
```

## Examples

Run scripts from the package root:

```julia
julia --project=. examples/quickstart.jl
julia --project=. examples/variant_tour.jl
julia --project=. examples/dyad.jl
julia --project=. examples/drift.jl
```

Each script saves PNGs under `examples/output/`.

Open the Pluto quickstart notebook with:

```julia
using Pluto
Pluto.run(notebook="examples/pluto/quickstart.jl")
```

## Extending It

Every major surface has a registry. Register a part under a symbol, then use that symbol from high-level code.

Add a node. (Extending a node means adding *methods* to the package generics, so `import` them — otherwise `simulate` won't see your `step!`.)

```julia
import BrainlessLab: step!, effectors, n_receptors, n_effectors

struct MyNode <: Reservoir
    n_receptors::Int
    n_effectors::Int
    spikes::Vector{Float64}
end

MyNode(n_nodes, n_receptors, n_effectors; seed=0) =
    MyNode(n_receptors, n_effectors, zeros(Float64, n_nodes))

function step!(r::MyNode, receptors)
    value = maximum(Float64.(receptors))
    r.spikes .= value > 0.5
    return copy(r.spikes)
end

effectors(r::MyNode, spikes) = fill(sum(spikes) / length(spikes), r.n_effectors)
n_receptors(r::MyNode) = r.n_receptors
n_effectors(r::MyNode) = r.n_effectors

register_node!(:mynode, MyNode)
simulate(:wall; node=:mynode, ticks=100)
```

Add a task:

```julia
MY_WALL = TaskSpec(:my_wall, WallEnv; default_ticks=250, default_window=100)
register_task!(:my_wall, MY_WALL)

sim = simulate(:my_wall; node=:falandays)
```

Add a drive:

```julia
struct MyDrive <: Drive
    gain::Float64
end

function apply_drive!(d::MyDrive, acts, targets, params, noise)
    acts .+= d.gain
    return acts
end

register_drive!(:mydrive, MyDrive)
```

Add a view:

```julia
myview(sim; kwargs...) = rasterplot(sim; kwargs...)
register_view!(:myview, myview)

resolve_view(:myview)(sim)
```

The same pattern is available for bodies, metrics, optimizers, and ablations.
