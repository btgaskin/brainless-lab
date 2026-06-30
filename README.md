# BrainlessLab.jl

An extensible Julia lab for **"brainless" cognition** -- behaviour that emerges from
collectives of simple neuron-like nodes with no homunculus and no hand-wired control.
Reservoirs, bodies, tasks, swarm media, recorders, metrics, and Makie visualisations are
all wired through lightweight **registries**, so participants can swap node families or add
their own parts without forking the framework. The core concept is *neurons as nodes within
a collective* -- the same abstraction at every scale.

The project is a summer-institute testbed: a clean framework for other people to run
experiments around a settled Falandays baseline. Validation means bit-fidelity to the local
numpy reference implementations (`../v0`, `../v0.2`) where those reference paths exist.
The 2021 paper-faithful baseline is `:falandays_base` with the original constants; v0.2
also contains documented experimental departures, so numpy fidelity should not be read as
paper fidelity for every platform component.

**Documentation:** see [`docs/`](docs/README.md) -- [onboarding](docs/onboarding.md),
[nodes & variants](docs/nodes.md), [tasks & I/O mappings](docs/tasks.md),
[contracts](docs/contracts.md), [receptors & effectors](docs/receptors-effectors.md),
[the collective](docs/collective.md), [evolution](docs/evolution.md).

---

## Stable baseline vs Experimental

**Stable baseline:** `:falandays_base` (also accepted as `:falandays`) is the settled,
validated, paper-faithful baseline: the 2021 Falandays homeostatic spiking reservoir with
its exact constants, run on the 2024 case-study task suite implemented here. This is the
reference participants can rely on when they need the known model rather than a new
experiment.

**Experimental platform:** everything around that baseline is for experiments and is still
in flux: the compartmental/CTRNN nodes, the evolution layer, the swarm/VEN extensions, and
the Falandays variants beyond base (`:falandays_noisy`, `:falandays_ablated`,
`:falandays_hemispheric`, `:falandays_oosawa`). These pieces are useful testbed surfaces,
but they should not be described as the 2021 paper model.

---

## Quickstart

```julia
pkg> dev .              # from the brainless-lab/ directory
pkg> add CairoMakie     # a Makie backend, for plotting

julia> using BrainlessLab, CairoMakie

julia> sim = simulate(:wall; node=:falandays_base, ticks=300)  # paper-faithful baseline
julia> visualize(sim)                                          # spike raster + rate + trajectory
```

The compute core does **not** depend on Makie -- `simulate` runs headless. Plot methods load
automatically (a package extension) once you load a Makie backend (`CairoMakie` for static
figures, `GLMakie` for interactive windows). See [docs/onboarding.md](docs/onboarding.md)
for the root, `demo/`, and `bench/` setup split.

---

## Demo (with visualisation)

A turnkey runner for showing the standard Falandays models on the standard tasks lives in
[`demo/`](demo/).

**Setup (once):**

```bash
cd brainless-lab/demo
julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add(["CairoMakie","TOML"]); Pkg.instantiate()'
# for the live interactive window, also:
julia --project=. -e 'using Pkg; Pkg.add("GLMakie")'
```

**Run it:**

```bash
julia --project=. run.jl --list                       # list tasks and node variants
julia --project=. run.jl wall                         # interactive window (Play / Step / speed)
julia --project=. run.jl wall --save                  # archive a run dir (figure + GIF + config)
julia --project=. run.jl pong --node falandays_oosawa --save
julia --project=. run.jl torus --n-agents 6 --save    # multi-agent swarm
julia --project=. run.jl cartpole_swingup --save
```

- **`--save`** -> archives a **timestamped run directory** under `demo/runs/<task>/fixed/<UTC>_<git>_<id>/`
  containing `config.resolved.toml`, `manifest.toml` (git SHA, Julia + package versions, seeds),
  `metrics.toml`, `figure.png` (static panels), and `activity.gif` (the rollout animation). Headless,
  any task. Add `--no-gif` to skip the slower animation.
- **no flag** -> opens a **live GLMakie window** with Play / Step / speed controls (needs
  `GLMakie` and a display).

Flags: `--node <name>` · `--ticks <n>` · `--seed <n>` · `--n-agents <n>` · `--no-gif` · `--out <runs-root>`.

The figure is a spike raster + firing-rate trace + trajectory/swarm; the GIF (`activity.gif`)
plays the **actual task behaviour** -- every task animates: tracking shows the eye chasing the
stimulus, pong the ball + paddle, cartpole the cart + pole, wall/torus the agent moving -- with
a marker sweeping the firing-rate timeline.

---

## Visualisation

Visualisation is a **clean optional layer** -- the engine never imports Makie; a tiny
`Recorder` (channel-gated, downsampling) is the only coupling, and a package extension
(`BrainlessLabMakieExt`) provides the plots when a Makie backend is present.

| Call | What it gives you |
| --- | --- |
| `visualize(sim; panels=[...])` | a static `CairoMakie` figure assembling chosen panels |
| `animate(sim; path="...gif")` | a **GIF/MP4** of the actual task behaviour: tracking (eye chasing the stimulus), pong (ball + paddle), cartpole (cart + pole), wall/torus (agent moving) -- with a synced firing-rate marker |
| `explore(task; node=..., ...)` | a live **GLMakie** window: Play / Step / speed slider |
| `replay(sim)` / `replay(rundir)` | re-render an in-memory `SimResult`, or **load a saved run directory** (`recorder.jld2`) back into a `SimResult` and re-render it with `visualize`/`animate` |
| `rasterplot` / `rateplot` / `trajectoryplot` / `swarmplot` / `networkplot` / `driftplot` / `fitnessplot` | individual recipes |

`driftplot` shows the spike-pattern autocorrelation over time -- the representational-drift
signature (behaviour persisting with no stable recurring codes).

---

## Node variants

The registered high-level variants are:

| Symbol | Status | Description |
| --- | --- | --- |
| `:falandays_base` | **stable baseline** | Base Falandays homeostatic spiking reservoir, paper-faithful to the 2021 model. `:falandays` is an alias. |
| `:falandays_noisy` | experimental | Base reservoir wrapped with sensory input noise (`Uniform(+/-0.1)`, clip >= 0 -- the v0.2 body formula). |
| `:falandays_ablated` | experimental | Target homeostasis frozen (`lrate_targ=0`): target pinned at 1.0, threshold fixed at 2.0; weights still learn. |
| `:falandays_hemispheric` | experimental | Two half-size reservoirs, contralateral wiring (right sensors -> left effectors, left -> right). |
| `:falandays_oosawa` | experimental | Oosawa endogenous membrane drive (pure target-modulated, stays active when blind). |
| `:compartmental_dense` | experimental | Dense compartmental cell (dendrite -> soma -> hillock CTRNN, emergent weights, no plasticity). |
| `:compartmental_structured` | experimental | Structured compartmental cell (single-port dendrite/soma routing, emergent threshold). |

`variants()` lists the registered symbols, including the `:falandays` alias.

## Tasks

The registered tasks are `:wall`, `:tracking`, `:pong`, `:pong_hitrate`, `:cartpole`,
`:cartpole_hard`, `:cartpole_swingup`, `:cartpole_long`, and `:torus`.

Single-agent tasks use task-specific 2-effector decoders. The swarm task (`:torus`) uses
`VENBody`: 62 bearing-vision sensors are padded to **64 receptor inputs**, and the motor
decode consumes **3 effectors** for heading and forward acceleration. `tasks()` lists them all.

See [docs/tasks.md](docs/tasks.md) and [docs/contracts.md](docs/contracts.md) before comparing
results across tasks, because effectors and scores are intentionally non-uniform.

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

Evolution is part of the experimental platform. Evolving the 7 Falandays control parameters is
an optional experimental perturbation of the baseline; evolving compartmental/CTRNN genomes is
required before those non-plastic nodes are a meaningful test.

## Reproducible runs

`run_experiment(read_config("configs/evolve_falandays_wall.toml"))` resolves a TOML config
(with `:teaching` / `:oracle` / `:evolution` profiles), runs the driver, and writes a run
directory under `runs/` containing a `manifest.toml` (git SHA, Julia + package versions,
timestamps, full seed scheme), the resolved config, CSV/JSONL logs, and a JLD2 genome
checkpoint. A run reproduces **bit-for-bit** from its own artifacts. `run_sweep` does
cartesian parameter sweeps with an index. Loading a saved run directory back into `replay`
is not implemented yet.

## Performance

Compiled + thread-parallel over independent rollouts. On an Apple M5 (4 P + 6 E cores), a
256-rollout generation (compartmental-structured, wall, N=200, 300 ticks) takes **2.5 s with
`-t 10`** vs **28 s for the serial numpy oracle -- approximately 11x**, at Float64.
Per-rollout it is ~2.5x faster compiled, and it keeps scaling with cores (run with
`julia -t auto` or `-t <n>`; Julia's `auto` uses the performance cores). The structured
reservoir is the fast path; the dense all-to-all kernel is a known optimisation target.

---

## Extending it

Every surface has a registry: register a part under a symbol, then reference that symbol from
high-level code. **Extending a node means adding methods to the package generics, so
`import` them** -- otherwise `simulate` will not see your `step!`.

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
optimizers (`<: AbstractEvolutionStrategy` with `ask`/`tell!`/`result`). See
[docs/contracts.md](docs/contracts.md) for the node/extension contract and the
`pack_params`/`snapshot_state` split.

## Examples & notebooks

`examples/{quickstart,variant_tour,dyad,drift}.jl` are runnable scripts (save PNGs to
`examples/output/`); `examples/pluto/quickstart.jl` is a reactive Pluto notebook.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The test suite covers node families, envs, collectives, ablations, the CMA driver, run
artifacts, and Makie extension loading against Float64 numpy fixtures where applicable.

## Layout

```
src/core/    interfaces, traits, registries, params, Recorder
src/nodes/   Falandays baseline/variants + compartmental (cell, reservoir, wiring, interventions)
src/world/   Body, Torus, Mediums, Collective, Metrics  (single-agent task = collective of one)
src/envs/    WallBox + the four environments + cartpole variants
src/drivers/ rollout, SepCMA + EvolveDriver, Fixed/Plastic, threaded harness
src/run/     TOML config, profiles, manifest, artifacts, sweeps
src/api/     simulate / explore / visualize / replay
ext/         BrainlessLabMakieExt  (viz -- never on the compute path)
demo/        run.jl demo runner   ·   examples/   ·   test/
```
