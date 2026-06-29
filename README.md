# BrainlessLab.jl

An extensible Julia lab for **"brainless" cognition** — behaviour that emerges from
collectives of simple neuron-like nodes with no homunculus and no hand-wired control.
Reservoirs, bodies, tasks, swarm media, recorders, metrics, and Makie visualisations are
all wired through lightweight **registries**, so you can swap node families or add your own
parts without forking the framework. The core concept is *neurons as nodes within a
collective* — the same abstraction at every scale.

Every node family, environment, collective, ablation, and the evolutionary optimiser is
**validated to Float64 against the original numpy implementation** (`../v0`, `../v0.2`) as
the oracle. The compute core is pure and fast; visualisation is an optional layer.

---

## Quickstart

```julia
pkg> dev .            # from the brainless-lab/ directory (or: dev /path/to/brainless-lab)
pkg> add CairoMakie   # a Makie backend, for plotting

julia> using BrainlessLab, CairoMakie

julia> sim = simulate(:wall; node=:falandays, ticks=300)   # run a Falandays reservoir on wall-avoidance
julia> visualize(sim)                                       # spike raster + firing rate + trajectory
```

The compute core does **not** depend on Makie — `simulate` runs headless. Plot methods load
automatically (a package extension) once you load a Makie backend (`CairoMakie` for static
figures, `GLMakie` for interactive windows).

---

## Demo (with visualisation)

A turnkey runner for showing the standard Falandays models on the standard tasks lives in
[`demo/`](demo/).

**Setup (once):**

```bash
cd brainless-lab/demo
julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add("CairoMakie"); Pkg.instantiate()'
# for the live interactive window, also:
julia --project=. -e 'using Pkg; Pkg.add("GLMakie")'
```

**Run it:**

```bash
julia --project=. run.jl --list                       # list tasks and node variants
julia --project=. run.jl wall                         # interactive window (Play / Step / speed)
julia --project=. run.jl wall --save                  # save a static figure to demo/output/
julia --project=. run.jl pong --node falandays_oosawa --save
julia --project=. run.jl torus --n-agents 6 --save    # multi-agent swarm
julia --project=. run.jl cartpole_swingup --save
```

- **`--save`** → renders static panels (spike raster + firing rate + trajectory/swarm) to a
  PNG in `demo/output/`. Works headless, anywhere, on any task.
- **no flag** → opens a **live GLMakie window** with Play / Step / speed controls (needs
  `GLMakie` and a display).

Flags: `--node <name>` · `--ticks <n>` · `--seed <n>` · `--n-agents <n>` · `--out <dir>`.

A `wall` figure looks like: a spike raster over time, the population firing-rate trace, and
the agent's 2-D path through the box.

---

## Visualisation

Visualisation is a **clean optional layer** — the engine never imports Makie; a tiny
`Recorder` (channel-gated, downsampling) is the only coupling, and a package extension
(`BrainlessLabMakieExt`) provides the plots when a Makie backend is present.

| Call | What it gives you |
| --- | --- |
| `visualize(sim; panels=[...])` | a static `CairoMakie` figure assembling chosen panels |
| `explore(task; node=..., ...)` | a live **GLMakie** window: Play / Step / speed slider |
| `replay(rundir)` | reconstruct views from a saved run's artifacts |
| `rasterplot` / `rateplot` / `trajectoryplot` / `swarmplot` / `networkplot` / `driftplot` / `fitnessplot` | individual recipes |

`driftplot` shows the spike-pattern autocorrelation over time — the representational-drift
signature (behaviour persisting with no stable recurring codes).

---

## Node variants

| Symbol | Description |
| --- | --- |
| `:falandays` | Base Falandays homeostatic spiking reservoir (the default). |
| `:falandays_oosawa` | + Oosawa endogenous membrane drive (stays active when blind). |
| `:falandays_dale` | + Dale's-law signed weights, Watts–Strogatz wiring, Oosawa drive. |
| `:compartmental_dense` | Dense compartmental cell (dendrite→soma→hillock CTRNN, emergent weights, no plasticity). |
| `:compartmental_structured` | Structured compartmental cell (single-port dendrite/soma routing, emergent threshold). |

`variants()` lists what's registered.

## Tasks

Single-agent: `:wall` · `:tracking` · `:pong` · `:cartpole`.
CartPole variants: `:cartpole_hard` · `:cartpole_swingup` (pole starts down; score = mean
uprightness) · `:cartpole_long`. Also `:pong_hitrate`, and `:torus` for swarms
(`simulate(:torus; node=:falandays, n_agents=5)`). `tasks()` lists them all.

---

## Evolution

```julia
result = evolve(model_sym=:compartmental_structured, train_tasks=(:wall,),
                generations=30, popsize=32, k_trials=8, N=200)
```

Selection uses a hand-rolled diagonal **sep-CMA-ES** (validated against pycma to ~1e-6),
with thread-parallel rollouts (`Threads.@threads`, deterministic regardless of thread count)
and the multi-task `:min`/`:mean` aggregation of the numpy line. `FixedDriver` (baseline
eval) and `PlasticDriver` (online-learning runs) share the same `rollout` substrate.

## Reproducible runs

`run_experiment(read_config("configs/evolve_falandays_wall.toml"))` resolves a TOML config
(with `:teaching` / `:oracle` / `:evolution` profiles), runs the driver, and writes a run
directory under `runs/` containing a `manifest.toml` (git SHA, Julia + package versions,
timestamps, full seed scheme), the resolved config, CSV/JSONL logs, and a JLD2 genome
checkpoint. A run reproduces **bit-for-bit** from its own artifacts. `run_sweep` does
cartesian parameter sweeps with an index.

## Performance

Compiled + thread-parallel over independent rollouts. On an Apple M5 (4 P + 6 E cores), a
256-rollout generation (compartmental-structured, wall, N=200, 300 ticks) takes **2.5 s with
`-t 10`** vs **28 s for the serial numpy oracle — ≈ 11×**, at Float64. Per-rollout it's
~2.5× faster compiled, and it keeps scaling with cores (run with `julia -t auto` or
`-t <n>`; Julia's `auto` uses the performance cores). The structured reservoir is the
fast path; the dense all-to-all kernel is a known optimisation target.

---

## Extending it

Every surface has a registry: register a part under a symbol, then reference that symbol from
high-level code. **Extending a node means adding *methods* to the package generics, so
`import` them** — otherwise `simulate` won't see your `step!`.

```julia
import BrainlessLab: step!, effectors, n_receptors, n_effectors

struct MyNode <: Reservoir
    n_receptors::Int; n_effectors::Int; spikes::Vector{Float64}
end
MyNode(n_nodes, n_receptors, n_effectors; seed=0) =
    MyNode(n_receptors, n_effectors, zeros(Float64, n_nodes))

function step!(r::MyNode, receptors)
    r.spikes .= maximum(Float64.(receptors)) > 0.5
    return copy(r.spikes)
end
effectors(r::MyNode, spikes) = fill(sum(spikes) / length(spikes), r.n_effectors)
n_receptors(r::MyNode) = r.n_receptors
n_effectors(r::MyNode) = r.n_effectors

register_node!(:mynode, MyNode)
simulate(:wall; node=:mynode, ticks=100)
```

The same `register_*!` pattern applies to tasks (`register_task!` + a `TaskSpec`), drives
(`<: Drive` + `apply_drive!`), bodies, metrics, ablations/interventions, views, and
optimizers (`<: AbstractEvolutionStrategy` with `ask`/`tell!`/`result`).

## Examples & notebooks

`examples/{quickstart,variant_tour,dyad,drift}.jl` are runnable scripts (save PNGs to
`examples/output/`); `examples/pluto/quickstart.jl` is a reactive Pluto notebook.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

~5,800 assertions across 22 testsets, all green — every node family / env / collective /
ablation / the CMA driver validated to Float64 against the numpy oracle via injected-wiring
NPZ fixtures, with spikes checked exactly where the pre-threshold margin is safely non-zero.

## Layout

```
src/core/    interfaces, traits, registries, params, Recorder
src/nodes/   Falandays family (drives/axes) + compartmental (cell, reservoir, wiring, interventions)
src/world/   Body, Torus, Mediums, Collective, Metrics  (single-agent task = collective of one)
src/envs/    WallBox + the four environments + cartpole variants
src/drivers/ rollout, SepCMA + EvolveDriver, Fixed/Plastic, threaded harness
src/run/     TOML config, profiles, manifest, artifacts, sweeps
src/api/     simulate / explore / visualize / replay
ext/         BrainlessLabMakieExt  (viz — never on the compute path)
demo/        run.jl demo runner   ·   examples/   ·   test/
```
