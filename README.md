# BrainlessLab.jl

[![CI](https://github.com/btgaskin/brainless-lab/actions/workflows/CI.yml/badge.svg)](https://github.com/btgaskin/brainless-lab/actions/workflows/CI.yml)

<p align="center"><img src="brainless-lab.png" alt="BrainlessLab" width="760"></p>

<p align="center">
  <em>Behaviour from collectives of simple neuron-like nodes &mdash; brainless cognition.</em><br>
  <a href="https://brainless-lab.pages.dev"><strong>Documentation &amp; outputs</strong></a> &middot;
  a <a href="https://disi.org">Diverse Intelligences Summer Institute</a> 2026 (Geneva NY) project<br>
  Polyphony Bruna &middot; Benjamin Gaskin &middot; Ian Jackson &middot; William O'Hearn
</p>

An extensible Julia lab for **"brainless" cognition** -- behaviour that emerges from
collectives of simple neuron-like nodes with no homunculus and no hand-wired control.
Reservoirs, bodies, tasks, swarm environments, recorders, metrics, and Makie visualisations are
all wired through lightweight **registries**, so participants can swap node families or add
their own parts without forking the framework. The core concept is *neurons as nodes within
a collective* -- the same abstraction at every scale.

The project is a summer-institute testbed: a clean framework for other people to run
experiments around a settled Falandays baseline. Use a project-local Julia environment
(`pkg> activate .` or `julia --project=.`) when running examples and tooling. Validation means bit-fidelity to the local
numpy reference implementations (`../v0`, `../v0.2`) where those reference paths exist.
The 2021 authors-faithful baseline is `:falandays_base` with the original constants; v0.2
also contains documented experimental departures, so numpy fidelity should not be read as
paper fidelity for every platform component.

**Documentation:** the full docs live in the Astro/Starlight site under [`site/`](site/),
published at <https://brainless-lab.pages.dev> (run locally with `cd site && bun run dev`). Key pages:
[introduction](https://brainless-lab.pages.dev/introduction/),
[nodes & variants](https://brainless-lab.pages.dev/nodes/overview/),
[environments & tasks](https://brainless-lab.pages.dev/environments-tasks/),
[the collective](https://brainless-lab.pages.dev/collective/),
[receptors & effectors](https://brainless-lab.pages.dev/receptors-effectors/),
[analysis](https://brainless-lab.pages.dev/analysis/),
[evolution](https://brainless-lab.pages.dev/evolution/),
[contracts](https://brainless-lab.pages.dev/contracts/),
[reference](https://brainless-lab.pages.dev/reference/).

---

## Stable baseline vs Experimental

**Stable baseline:** `:falandays_base` (also accepted as `:falandays`) is the settled,
validated, authors-faithful baseline: the 2021 Falandays homeostatic spiking reservoir with
its exact constants, run on the 2024 case-study task suite implemented here. This is the
reference participants can rely on when they need the known model rather than a new
experiment.

**Experimental platform:** everything around that baseline is for experiments and is still
in flux: the compartmental/CTRNN nodes, the evolution layer, the swarm/VEN extensions, and
the SORN reference node, the Falandays variants beyond base (`:falandays_noisy`,
`:falandays_extended`, `:falandays_ablated`, `:falandays_hemispheric`, `:falandays_oosawa`,
`:falandays_spatial`, `:falandays_delayed`, `:falandays_dendritic`). These pieces are useful testbed surfaces,
but they should not be described as the 2021 paper model.

---

## Quickstart

**Requirements:** Julia 1.10 or newer on macOS, Linux, or Windows (CI-verified).

```julia
pkg> activate .         # or run scripts with julia --project=.
pkg> dev .              # from the brainless-lab/ directory
pkg> add CairoMakie     # a Makie backend, for plotting

julia> using BrainlessLab, CairoMakie

julia> sim = simulate(:wall; node=:falandays_base, ticks=300)  # authors-faithful baseline
julia> visualize(sim)                                          # spike raster + rate + trajectory
```

The compute core does **not** depend on Makie -- `simulate` runs headless. Plot methods load
automatically (a package extension) once you load a Makie backend (`CairoMakie` for static
figures, `GLMakie` for interactive windows). See the
[Introduction](https://brainless-lab.pages.dev/introduction/) for the root package and
tooling-project setup split.

`explore(...)` opens a live GLMakie display. On SSH/headless machines, use saved static
outputs instead (`visualize`/`animate` with CairoMakie, or the CLI `--save` paths where
available).

---

## Tooling run directories

The command-line tools write timestamped run directories with the same primary
shape: `manifest.toml`, resolved settings, CSV outputs, house-palette figures,
behaviour GIFs where relevant, and a short run README.

- `bench/` compares a roster of nodes across tasks. It writes `summary.csv`,
  `results_raw.csv`, baseline-relative statistics, comparison figures,
  per-cell GIFs, and a ranking README.
- `profile/` characterizes one node in depth. It writes `metrics.csv`,
  per-task analytic figures, one representative GIF per task, and a signature
  README. HTML is off by default and available only as an opt-in stub.
- `sweep/run.jl` perturbs parameter axes and writes `results.csv`, per-cell
  metrics/GIFs, figures, manifest, and callouts.
- `sweep/run.jl ablate NODE TASK` runs the same sweep-shaped output over
  registered ablations.

Quick commands:

```bash
(cd bench && julia --project=. run.jl --neurons falandays_base,compartmental_structured --tasks wall,pong)
(cd profile && julia --project=. run.jl falandays_base)
julia --project=. sweep/run.jl configs/sweep_falandays_wall.toml
julia --project=. sweep/run.jl ablate falandays_base wall
```

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
| `:falandays_base` | **stable baseline** | Base Falandays homeostatic spiking reservoir, authors-faithful to the 2021 model. `:falandays` is an alias. |
| `:falandays_noisy` | experimental | Base reservoir wrapped with sensory input noise (`Uniform(+/-0.1)`, clip >= 0 -- the v0.2 body formula). |
| `:falandays_extended` | experimental | The paper's **extended** architecture (validated against the v0.2 numpy reference, not the authors' bit-parity fixtures): base + sensory noise + Watts--Strogatz small-world recurrent wiring + Dale's law (excitatory/inhibitory). Same neuron update as base; a richer substrate -- the documented `base` vs `extended` contrast. |
| `:falandays_ablated` | experimental | Target homeostasis frozen (`lrate_targ=0`): target pinned at 1.0, threshold fixed at 2.0; weights still learn. |
| `:falandays_hemispheric` | experimental | Two half-size reservoirs, contralateral wiring (right sensors -> left effectors, left -> right). |
| `:falandays_oosawa` | experimental | Oosawa endogenous membrane drive (pure target-modulated, stays active when blind). |
| `:falandays_spatial` | experimental | Falandays reservoir with spatial embedding and distance-dependent wiring. |
| `:falandays_delayed` | experimental | Falandays reservoir with heterogeneous recurrent transmission delays. |
| `:falandays_dendritic` | experimental | Base reservoir plus a parallel dendritic pathway: recurrent synapses are split across `n_dendrites` compartments, each firing a local dendritic spike that sets an eligibility tag, so the homeostatic weight update gates on presynaptic-spike **or** dendrite-tag (learning without a somatic spike); the soma still receives the full recurrent sum. |
| `:sorn` | experimental | Self-organizing recurrent network reference with STDP, intrinsic plasticity, and synaptic normalization. |
| `:compartmental_dense` | experimental | Dense compartmental cell (dendrite -> soma -> hillock CTRNN, emergent weights, no plasticity). |
| `:compartmental_structured` | experimental | Structured compartmental cell (single-port dendrite/soma routing, emergent threshold). |

`variants()` lists the registered symbols, including the `:falandays` alias.

## Tasks

The registered tasks are `:wall`, `:tracking`, `:pong`, `:pong_hitrate`, `:cartpole`,
`:cartpole_hard`, `:cartpole_swingup`, `:cartpole_long`, `:torus`, and `:forage`.

Single-agent tasks use task-specific 2-effector decoders. The swarm task (`:torus`) uses
`VENBody`: 62 bearing-vision sensors are padded to **64 receptor inputs**, and the motor
decode consumes **3 effectors** for heading and forward acceleration. `:forage` uses the same
3-effector VEN decode with **128 receptors**: 64 conspecific-vision inputs plus 64 source-vision
inputs, scored by bounded `forage_score` and source-arrival metrics. `tasks()` lists them all.

See [Environments & Tasks](https://brainless-lab.pages.dev/environments-tasks/) and
[Contracts](https://brainless-lab.pages.dev/contracts/) before comparing
results across tasks, because effectors and scores are intentionally non-uniform.

---

## Evolution

```julia
result = evolve(model_sym=:compartmental_structured, train_tasks=(:wall,),
                generations=30, popsize=32, k_trials=8, N=200)
```

Selection uses a hand-rolled diagonal **sep-CMA-ES** (validated against pycma to ~1e-6),
with thread-parallel rollouts (`Threads.@threads`, deterministic regardless of thread count)
and the multi-task `:min`/`:mean` aggregation of the numpy line. `FixedRunner` (baseline
eval) and `PlasticRunner` (online-learning runs) share the same `rollout` substrate.

Evolution is part of the experimental platform. Evolving the 7 Falandays control parameters is
an optional experimental perturbation of the baseline; evolving compartmental/CTRNN genomes is
required before those non-plastic nodes are a meaningful test.

## Reproducible runs

`run_experiment(read_config("configs/evolve_falandays_wall.toml"))` resolves a TOML config
(with `:teaching` / `:oracle` / `:evolution` profiles), runs the runner, and writes a run
directory under `runs/` containing a `manifest.toml` (git SHA, Julia + package versions,
timestamps, full seed scheme), the resolved config, CSV/JSONL logs, and a JLD2 genome
checkpoint. A run reproduces **bit-for-bit** from its own artifacts. `run_sweep` does
cartesian parameter sweeps with an index. `replay(rundir)` can load a saved run directory with
`recorder.jld2` back into a `SimResult` for `visualize`/`animate`.

## Performance

Compiled + thread-parallel over independent rollouts. On an Apple M5 (4 P + 6 E cores), a
256-rollout generation (compartmental-structured, wall, N=200, 300 ticks) takes **2.5 s with
`-t 10`** vs **28 s for the serial numpy oracle -- approximately 11x**, at Float64.
Per-rollout it is ~2.5x faster compiled, and it keeps scaling with cores (run with
`julia -t auto` or `-t <n>`; Julia's `auto` uses the performance cores). The structured
reservoir is the fast path; the dense all-to-all kernel is a known optimisation target.

All run harnesses (sweep, bench, profile, evolve) parallelise their independent rollouts
across Julia threads via the central `parallel_map`/`init_parallelism!` helpers
(`src/core/Parallel.jl`): results stay in seed order, so threaded and serial runs produce
identical CSVs, and BLAS is pinned to one thread under multi-threaded runs to avoid
oversubscription. The entry scripts re-launch themselves with `-t auto` when started
single-threaded; opt out with `BRAINLESSLAB_AUTOTHREADS=0` or an explicit
`JULIA_NUM_THREADS`/`-t` setting (sweeps also accept `sweep.threaded = false` in the TOML).
Expensive per-tick diagnostics are strided: recording `:spectral_radius` recomputes the
eigendecomposition every K ticks (`simulate(...; spectral_every=K)`; sweeps use K=10) and
holds the last value in between, keeping the recorded series tick-aligned.

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
[Contracts](https://brainless-lab.pages.dev/contracts/) for the node/extension contract and the
`pack_params`/`snapshot_state` split.

## Examples & notebooks

`examples/{quickstart,variant_tour,dyad,drift}.jl` are runnable scripts (save PNGs to
`examples/output/`); `examples/pluto/quickstart.jl` is a reactive Pluto notebook.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The test suite covers node families, envs, ensembles, ablations, the CMA runner, run
artifacts, and Makie extension loading against Float64 numpy fixtures where applicable.

## Layout

```
src/core/    interfaces, traits, registries, params, Recorder
src/nodes/   Falandays baseline/variants + compartmental (cell, reservoir, wiring, interventions)
src/world/   Body, Torus, Environments, Ensemble, Metrics  (single-agent task = ensemble of one)
src/envs/    WallBox + the four environments + cartpole variants
src/drivers/ rollout, SepCMA + EvolveRunner, Fixed/Plastic, threaded harness
src/run/     TOML config, profiles, manifest, artifacts, sweeps
src/api/     simulate / explore / visualize / replay
ext/         BrainlessLabMakieExt  (viz -- never on the compute path)
bench/       cross-node comparison tool
profile/     single-node characterization tool
sweep/       parameter and ablation sweep runner   ·   calibration/  score-anchor report
configs/     sweep/experiment TOML configs
examples/    runnable examples and templates   ·   test/
site/        Astro/Starlight docs + outputs site (the docs live here)
skills/      Claude Code skills (julia, brainless-lab)
```

## Acknowledgements & prior art

The stable baseline (`:falandays_base`) is an independent, authors-faithful reimplementation of
the homeostatic spiking reservoir from:

> J. Benjamin Falandays, Jeffrey Yoshimi, William H. Warren, and Michael J. Spivey.
> "A potential mechanism for Gibsonian resonance: behavioral entrainment emerges from local
> homeostasis in an unsupervised reservoir network." *Cognitive Neurodynamics* **18**(4),
> 1811–1834 (2024). [doi:10.1007/s11571-023-09988-2](https://doi.org/10.1007/s11571-023-09988-2)

BrainlessLab is not affiliated with or endorsed by the original authors. "Authors-faithful" means
bit-fidelity to a reconstruction of the authors' code (guarded by the `test/fixtures/authors_*.jld2`
fixtures), **not** paper-fidelity for every component — the experimental variants and platform layers
are our own construction. See [`CITATION.cff`](CITATION.cff) to cite this software.

## License

[MIT](LICENSE) © 2026 the BrainlessLab authors.
