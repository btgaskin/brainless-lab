# BrainlessLab.jl

<p align="center"><img src="brainless-lab.png" alt="BrainlessLab" width="760"></p>

<p align="center">
  <em>Behaviour from collectives of simple neuron-like nodes &mdash; brainless cognition.</em><br>
  <a href="https://brainless-lab.pages.dev"><strong>Documentation &amp; outputs</strong></a> &middot;
  a <a href="https://disi.org">Diverse Intelligences Summer Institute</a> 2026 (Geneva NY) project<br>
  Polyphony Bruna &middot; Benjamin Gaskin &middot; Ian Jackson &middot; William O'Hearn
</p>

An extensible Julia lab for **"brainless" cognition** -- behaviour that emerges from
collectives of simple neuron-like nodes with no homunculus and no hand-wired control.
Reservoirs, composed embodiments, tasks, physical worlds, recorders, metrics, and Makie
visualisations are wired through lightweight **registries** and Julia interfaces, so participants
can swap node families or add their own parts without forking the framework. The core concept is
*neurons as nodes within a collective* -- the same abstraction at every scale.

The project is a summer-institute testbed: a clean framework for other people to run
experiments around a settled Falandays baseline. Use a project-local Julia environment
(`pkg> activate .` or `julia --project=.`) when running examples and tooling. Validation
means numerical trajectory parity with the tested local reference implementations
(`../v0`, `../v0.2`) within their declared tolerances, where those reference paths exist.
The 2021 authors-faithful baseline is `:falandays_base` with the original constants; v0.2
also contains documented experimental departures, so numpy fidelity should not be read as
paper fidelity for every platform component.

**Documentation:** the full docs live in the Astro/Starlight site under [`site/`](site/),
published at <https://brainless-lab.pages.dev> (run locally with `cd site && bun run dev`). Key pages:
[getting started](https://brainless-lab.pages.dev/getting-started/),
[introduction](https://brainless-lab.pages.dev/introduction/),
[research workflow](https://brainless-lab.pages.dev/research-workflow/),
[agentic workflow](https://brainless-lab.pages.dev/agentic-workflow/),
[nodes & variants](https://brainless-lab.pages.dev/nodes/overview/),
[environments & tasks](https://brainless-lab.pages.dev/environments-tasks/),
[the collective](https://brainless-lab.pages.dev/collective/),
[embodiment](https://brainless-lab.pages.dev/receptors-effectors/),
[analysis](https://brainless-lab.pages.dev/analysis/),
[evolution](https://brainless-lab.pages.dev/evolution/),
[contracts](https://brainless-lab.pages.dev/contracts/),
[platform limits](https://brainless-lab.pages.dev/platform-limits/),
[reference](https://brainless-lab.pages.dev/reference/).

---

## Stable baseline vs Experimental

**Stable baseline:** `:falandays_base` (also accepted as `:falandays`) is the settled,
validated, authors-faithful baseline: the published Falandays homeostatic spiking reservoir with
its exact constants, run on the 2024 case-study task suite implemented here. This is the
reference participants can rely on when they need the known model rather than a new
experiment.

**Experimental platform:** everything around that baseline is for experiments and is still
in flux: the compartmental/CTRNN nodes, the evolution and embodiment layers, collective and
ecological worlds, and
the SORN reference node, the Falandays variants beyond base (`:falandays_noisy`,
`:falandays_extended`, `:falandays_ablated`, `:falandays_hemispheric`, `:falandays_oosawa`,
`:falandays_spatial`, `:falandays_delayed`, `:falandays_dendritic`). These pieces are useful testbed surfaces,
but they should not be described as the published paper model.

---

## Quickstart

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. examples/quickstart.jl
```

This runs the fixture-validated baseline headlessly and prints its wall-task score. The
compute core does **not** depend on Makie. Plot methods load automatically as a package
extension in an environment that provides a Makie backend (`CairoMakie` for static figures,
`GLMakie` for interactive windows). See
[Getting started](https://brainless-lab.pages.dev/getting-started/) for browser,
agent-assisted, and manual paths without modifying the root environment.

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
| `:falandays_base` | **stable baseline** | Base Falandays homeostatic spiking reservoir, authors-faithful to the tested 2024 publication reference construction. `:falandays` is an alias. |
| `:falandays_noisy` | experimental | Base reservoir wrapped with sensory input noise (`Uniform(+/-0.1)`, clip >= 0 -- the v0.2 body formula). |
| `:falandays_extended` | experimental | The paper's **extended** architecture (validated against the v0.2 numpy reference, not the authors' bit-parity fixtures): base + sensory noise + Watts--Strogatz small-world recurrent wiring + Dale's law (excitatory/inhibitory). Same neuron update as base; a richer substrate -- the documented `base` vs `extended` contrast. |
| `:falandays_ablated` | experimental | Target homeostasis frozen (`lrate_targ=0`): target pinned at 1.0, threshold fixed at 2.0; weights still learn. |
| `:falandays_hemispheric` | experimental | Two half-size reservoirs, contralateral wiring (right sensors -> left effectors, left -> right). |
| `:falandays_oosawa` | experimental | Oosawa endogenous membrane drive (firing-threshold-gap-modulated noise; stays active when blind). |
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

Every registered task resolves to a `TaskSpec` whose setup returns
`TaskSetup(environment, bodies)`; a task may set `score_key=nothing` when it has no scalar
objective. Existing single-agent vector tasks use direct `Embodiment`s and task-specific
2-effector decoders. The established situated adapter builds ordinary embodiments from
`SituatedSensorLayout`, `SituatedEncoder`, `SituatedActuator`, and `KinematicMotor`.
Its default `:torus` contract pads 62 bearing rays to **64 receptor inputs** and uses
**3 effectors** for heading and forward acceleration. `:forage` adds a second 64-wide source
bank for **128 receptors**, scored by bounded `forage_score` and source-arrival metrics.
`tasks()` lists all registered task symbols.

See [Environments & Tasks](https://brainless-lab.pages.dev/environments-tasks/) and
[Contracts](https://brainless-lab.pages.dev/contracts/) before comparing
results across tasks, because effectors and scores are intentionally non-uniform.

## Embodiment and physical worlds

`AbstractBody` is the public dispatch boundary; `Embodiment` is the one generic concrete body.
It composes geometry, sensors, encoders, actuators, dynamics, physiology, traits, and runtime
state. Component IDs are stable, and receptor/effector port IDs are namespaced from them.
Biological and robotic organisms use the same type with different component values.
`traits` are optional direct-Julia metadata; embodiment TOML does not currently represent
them, and preset materialization or physics does not depend on them.

Strict TOML presets live in [`examples/embodiments/`](examples/embodiments/):

```julia
config = read_embodiment_config("examples/embodiments/bilateral_insect.toml")
body = materialize_embodiment(config)

component_slots(body)
portspec(body)
```

For the tested physical loop, run
`include("examples/embodiments/object_world_quickstart.jl")` followed by
`run_object_world_quickstart(ticks=25, seed=7)`.

For the same physical composition through the high-level result surface, run
`include("examples/embodiments/object_world_task.jl")` followed by
`run_object_world_task(ticks=25, seed=11)`. The direct quickstart exposes its
`Ensemble` and `Recorder`; wrapping a setup callable in `TaskSpec` adds standardized
`SimResult`, recording, and scoring semantics.

The component catalog exposes required/optional parameter-name metadata and evidence-scoped
readiness:

```julia
components()
component_info(:sensor, :spectral_camera)
readiness()
```

This metadata lists accepted names; it is not a typed schema of defaults or constraints.

`ObjectWorld` closes the generic physical loop for toroidal or walled 2-D arenas, fixed
agent populations, static circular objects, named analytic fields, spectral appearances,
mounted field probes, typed effects, and one actuator/dynamics command pair per body.
`SituatedEnvironment` remains the adapter for established collective, foraging, and
signalling tasks.

`RegulatedPhysiology` can hold arbitrary named `RegulatedVariable`s. Each owns drift, bounds,
setpoint/deficit rule, response curve, feedback mode, gain, emission and reservoir-link
probabilities, plus optional failure. Worlds emit typed `Exposure`s; physiology decides how
they change internal state.

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
checkpoint. These artifacts support a traceable rerun in the declared environment;
bit-for-bit guarantees apply only where explicit fixture or replay tests establish them.
`run_sweep` does cartesian parameter sweeps with an index. `replay(rundir)` can load a saved
run directory with `recorder.jld2` back into a `SimResult` for `visualize`/`animate`.

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

Named, discoverable presets use registries; direct Julia composition and multiple dispatch
are equally public. Register a part when configuration by symbol is useful. **Extending a
node means adding methods to the package generics, so `import` them**—otherwise `simulate`
will not see your `step!`.

```julia
using BrainlessLab: Reservoir, register_node!, simulate
import BrainlessLab: step!, effectors, reset!, n_nodes, n_receptors, n_effectors

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
reset!(r::MyNode) = (fill!(r.spikes, 0.0); r)
n_nodes(r::MyNode) = length(r.spikes)
n_receptors(r::MyNode) = r.n_receptors
n_effectors(r::MyNode) = r.n_effectors

register_node!(:mynode, MyNode)
simulate(:wall; node=:mynode, ticks=100)
```

The same `register_*!` pattern applies to tasks (`register_task!` + a `TaskSpec`), drives
(`<: Drive` + `apply_drive!`), bodies, physical components (`register_component!`), metrics,
ablations/interventions, views, and optimizers (`<: AbstractEvolutionStrategy` with
`ask`/`tell!`/`result`). See
[Contracts](https://brainless-lab.pages.dev/contracts/) for the node/extension contract and the
`pack_params`/`snapshot_state` split.

## Examples & notebooks

`examples/quickstart.jl` is the headless first run. `variant_tour.jl`, `dyad.jl`, and
`drift.jl` are figure-producing examples for an environment with CairoMakie and save PNGs
to `examples/output/`; `examples/embodiments/` contains three strict component presets;
`examples/pluto/quickstart.jl` is a reactive Pluto notebook.

## Tests

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

The test suite covers node families, environments, homogeneous and heterogeneous ensembles,
embodiment composition/configuration/development, physical components, homeostasis, ablations,
the CMA runner, run artifacts, and Makie extension loading against Float64 scientific fixtures
where applicable.

## Layout

```
src/core/    interfaces, traits, registries, params, Recorder
src/nodes/   Falandays baseline/variants + compartmental (cell, reservoir, wiring, interventions)
src/world/   ports, embodiment/physiology, physical components, worlds, ensembles, metrics
src/envs/    WallBox + the four environments + cartpole variants
src/drivers/ rollout, SepCMA + EvolveRunner, Fixed/Plastic, threaded harness
src/run/     TOML config, profiles, manifest, artifacts, sweeps
src/api/     simulate / explore / visualize / replay
ext/         BrainlessLabMakieExt  (viz -- never on the compute path)
bench/       cross-node comparison tool
profile/     single-node characterization tool
sweep/       parameter and ablation sweep runner   ·   calibration/  score-anchor report
configs/     sweep/experiment TOML configs
examples/    runnable examples, embodiment presets, and templates   ·   test/
site/        Astro/Starlight docs + outputs site (the docs live here)
skills/      agent guidance for Julia and BrainlessLab
```

## Acknowledgements & prior art

The stable baseline (`:falandays_base`) is an independent, authors-faithful reimplementation of
the homeostatic spiking reservoir from:

> J. Benjamin Falandays, Jeffrey Yoshimi, William H. Warren, and Michael J. Spivey.
> "A potential mechanism for Gibsonian resonance: behavioral entrainment emerges from local
> homeostasis in an unsupervised reservoir network." *Cognitive Neurodynamics* **18**(4),
> 1811–1834 (2024). [doi:10.1007/s11571-023-09988-2](https://doi.org/10.1007/s11571-023-09988-2)

BrainlessLab is not affiliated with or endorsed by the original authors. "Authors-faithful" means
numerical parity of the tested reservoir state trajectories with a local authors-derived
reference construction, within the declared `1e-9` tolerance (guarded by the
`test/fixtures/authors_*.jld2` fixtures). It does **not** mean paper fidelity for every
component—the experimental variants and platform layers are our own construction. See
[`CITATION.cff`](CITATION.cff) to cite this software.

## License

[MIT](LICENSE) © 2026 the BrainlessLab authors.
