# Scientific Ecosystem: Computational Neuroscience and Artificial Life

This file is domain-specific, unlike the rest of this skill. Read it when the task is actually
agent-based, dynamical-systems, or neural-simulation work; for general Julia questions, the rest
of this skill applies unchanged and this file isn't needed.

The throughline across all three packages below is the same thing that makes Julia worth using for
this kind of work in the first place: they compose with each other and with the rest of the
language through ordinary multiple dispatch and the shared `AbstractArray` interface, rather than
through a bespoke framework boundary. A `ComponentArray` state vector works as an ODE solver's
state *and* as a plain array for plotting *and* as an optimizer's parameter vector, with no
adapter code, because all three expect "something that behaves like an array," and dispatch makes
that work for any type that satisfies the interface.

## Agent-based / artificial-life modeling: `Agents.jl`

`Agents.jl` is the standard general-purpose ABM framework in Julia (grids, graphs, continuous
space, and OpenStreetMap-based spaces; both discrete-time step-based and continuous-time
event-queue-based simulation).

```julia
using Agents

@agent struct Boid(ContinuousAgent{2,Float64})
    speed::Float64
    vision::Float64
end

function agent_step!(boid, model)
    neighbors = nearby_agents(boid, model, boid.vision)
    # ... compute heading from neighbors ...
    move_agent!(boid, model, boid.speed)
end

space = ContinuousSpace((100, 100))
model = StandardABM(Boid, space; agent_step! = agent_step!)
data, _ = run!(model, 100; adata = [:pos])   # returns a DataFrame
```

A few design points worth understanding rather than just copying:

- **`nearby_agents` is space-agnostic by dispatch.** The same call works whether `space` is a grid,
  a graph, or continuous space, because `Agents.jl` dispatches the neighbor-finding logic on the
  *space type*, not on a config flag you have to remember to set correctly. This is the multiple
  dispatch payoff from `dispatch-and-design.md` showing up directly in API design — if you ever
  want a custom space (e.g. a non-Euclidean or structured environment for an ALife model), you
  extend a small number of generic functions rather than forking the package.
- **Use `@agent` to define agent types, and `@multiagent` (preferred over a plain `Union` of agent
  types) when a model has more than one kind of agent** — e.g. predator and prey, or organism and
  resource. `@multiagent` is usually faster than a `Union`-typed population and is the documented
  default for multi-species models.
- **Performance applies identically to agent step functions as anywhere else** — `agent_step!`
  runs once per agent per tick, so the type-stability and allocation guidance in this skill applies
  directly to it. A type-unstable or allocating `agent_step!` is exactly the kind of hot-loop
  function the rest of this skill is about; don't treat ABM code as a separate category.
- `run!` collects requested fields into a `DataFrame` automatically (`adata` for agent-level data,
  `mdata` for model-level data) — prefer this over hand-rolled accumulation arrays unless you have
  a specific reason not to.

## Continuous dynamics / neuron models: `DifferentialEquations.jl` (SciML)

For anything expressed as an ODE/SDE/DDE/DAE — single-neuron biophysical models (Hodgkin-Huxley,
FitzHugh-Nagumo, Izhikevich in its continuous form), population-rate models, or the continuous part
of a hybrid agent/dynamics model — `DifferentialEquations.jl` (and its smaller, dependency-lighter
sibling `OrdinaryDiffEq.jl`, if you only need ODEs) is the standard tool.

```julia
function fitzhugh_nagumo!(du, u, p, t)
    v, w = u
    a, b, τ, I = p
    du[1] = v - v^3/3 - w + I
    du[2] = (v + a - b*w) / τ
    return nothing
end

u0 = [0.0, 0.0]
prob = ODEProblem(fitzhugh_nagumo!, u0, (0.0, 100.0), (0.7, 0.8, 12.5, 0.5))
sol = solve(prob, Tsit5())
```

Performance-critical specifics for this domain:

- **Always write the in-place (`!`) form for anything beyond a toy system.** This is the same
  mutating-API point from `memory-and-allocations.md`, but it matters especially here: the solver
  calls your right-hand-side function every internal step (often many more than the number of
  points you actually save), so an out-of-place form that allocates a fresh array every call adds
  up fast over a long simulation.
- **For small systems (roughly under 20 state variables — a single neuron's gating variables, for
  instance), use the out-of-place form with `StaticArrays.jl` instead**, which can be *faster* than
  the in-place mutating form at that size, because the whole state fits in registers/stack with no
  GC involvement at all:

  ```julia
  using StaticArrays
  fhn_static(u, p, t) = SA[u[1] - u[1]^3/3 - u[2] + p[4], (u[1] + p[1] - p[2]*u[2]) / p[3]]
  prob = ODEProblem(fhn_static, SA[0.0, 0.0], (0.0, 100.0), (0.7, 0.8, 12.5, 0.5))
  ```
  This crossover (in-place mutating for large systems, out-of-place `StaticArrays` for small ones)
  is specific advice from the SciML documentation, not a general Julia rule — the right choice
  depends on system size.
- **Solver choice matters and has real defaults to start from:** `Tsit5()` for general non-stiff
  problems; `Rosenbrock23()`/`Rodas5()` for stiff systems under ~50 state variables (a common
  situation in conductance-based neuron models, where fast spike dynamics and slow adaptation
  variables coexist at very different timescales — a classic stiffness signature); `TRBDF2`/`KenCarp4`
  for stiff systems up to a couple thousand variables (e.g. a moderately sized coupled-neuron
  network); `QNDF` for larger still. If a solve is diverging (`dt <= dtmin`, `NaN dt`, "Instability
  detected"), the overwhelming majority of the time the cause is a bug in the model's right-hand
  side, not the solver — check the model before reaching for solver tolerance tweaks.
- **Use `ComponentArrays.jl` for any model with more than two or three named state variables**
  (firing rates of several populations; voltage and several gating/adaptation variables together)
  instead of indexing a bare vector by position — see `memory-and-allocations.md`. It stays
  solver-compatible while making the right-hand-side function actually readable
  (`D.v = ...; D.w = ...` instead of `du[1] = ...; du[2] = ...`).
- For coupling many neuron-like ODE units together into a network (rather than one ODE per neuron
  simulated separately), the same `ODEProblem`/`u!` machinery scales to one large coupled system —
  the state vector just holds every unit's variables, often via a `ComponentArray` or a
  `StaticArray`-of-`StaticArray`s for cache-friendly per-unit access.

## Nonlinear dynamics / chaos analysis: `DynamicalSystems.jl`

Once a model (continuous or discrete, hand-written or built via `DifferentialEquations.jl`) is
defined, `DynamicalSystems.jl` provides the analysis layer relevant to both fields here: Lyapunov
exponents and other chaos measures, attractor/basin identification, bifurcation and continuation
analysis, recurrence quantification, and nonlinear time-series analysis (delay embeddings,
complexity measures) for working from recorded/simulated time series back toward the dynamics that
produced them. This is the natural tool for questions like "is this network dynamics regime
chaotic," "where's the bifurcation as I sweep this parameter," or "what's the effective dimension
of this population's collective activity" — questions that come up on both the comp-neuro side
(neural dynamics, criticality) and the ALife side (emergent collective behavior, regime shifts in
an evolving population).

`DynamicalSystems.jl` is built to interoperate with `DifferentialEquations.jl`-defined systems
directly (it uses the same solver machinery underneath for continuous systems), so a model you've
already written for simulation doesn't need to be reimplemented to also analyze.

## Spiking neural networks specifically

This is a genuine gap relative to the Python ecosystem (`Brian2`, `NEST`): there is no single
dominant, mature, widely-used SNN simulator package in Julia comparable to those. A few
special-purpose packages exist (e.g. `SpikingNN.jl`) but are less battle-tested and less actively
maintained than the rest of this ecosystem — evaluate current activity before depending on one for
a project with any longevity. Two more reliable paths in practice: model spiking dynamics directly
as a (possibly hybrid/discontinuous) system on top of `DifferentialEquations.jl`, handling spikes
as solver callbacks/events (`DifferentialEquations.jl` has first-class support for this kind of
discontinuity-at-a-condition), or hand-roll the network update as a tight, type-stable, in-place
loop over plain (or `StaticArrays`-backed) arrays — which, given everything above about type
stability and allocations, is often both fast and not actually much code once you're applying the
rest of this skill. Don't assume a dedicated package is required; for many SNN use cases, plain
Julia plus the techniques in this skill outperforms reaching for an immature dependency.
