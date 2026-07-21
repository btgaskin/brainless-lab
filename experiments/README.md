# experiments/

The multi-run protocol surface. It complements one-run simulation, task calibration,
profiling, sweeps, ablations, benchmarks, and evolution; see the site's Tooling page for the
capability map. `experiments/run.jl` uses the **root project**.

It holds composed, reproducible experiment protocols that are **not part of the
core library** — core stays lean (the settled Falandays baseline, the validated
per-run measures). This is for studies that combine those parts in a specific way
we want to run *regularly and replicably*, without promoting each one into core.

> Note: `run_experiment` is a **core** name (`src/run/Artifacts.jl` — run one
> `RunConfig` and write reproducible artifacts). This tool deliberately does not
> reuse it; experiments are invoked as `experiments/run.jl <name>`.

Rule of thumb: a question answered by **one measure over one run** belongs in the
analysis registry. A **protocol over many runs** (sweep a schedule, contrast
conditions, detect a knee) that isn't general enough to be a core CLI tool belongs
here.

## Run by name

Experiments are registered by symbol — the same pattern core uses for
nodes/tasks/analyses — but the registry lives here, not in core. One entrypoint:

```bash
julia --project=. experiments/run.jl --list                 # discover
julia --project=. experiments/run.jl freeze_onset           # run with defaults
julia --project=. experiments/run.jl freeze_onset seeds=0:9 tasks=tracking,pong window=600
julia -t 4 --project=. experiments/run.jl shoal_vision_sweep # 44-run exploratory pilot
julia -t 4 --project=. experiments/run.jl shoal_sensitivity_screen # 70-run OFAT screen
```

`key=val` values parse as Int (`600`), Float (`0.5`), range (`0:9`), comma-list
(`tracking,pong` → Symbols; `1,2,4,8` → Ints), else a Symbol. Each run writes
`experiments/runs/<name>/<UTCstamp>_<gitsha>/` with `results.json` + `manifest.txt`
(node, tasks, ticks, seeds, git SHA, timestamp). That is a traceable exploratory run, not
an exact-reproduction or promoted-evidence guarantee.

## Layout

```
experiments/
  run.jl          # CLI entrypoint: registers all experiments, dispatches by name
  registry.jl     # ExpRegistry — register/resolve/list experiments by symbol
  harness.jl      # ExpHarness — reusable building blocks (public-API only)
  freeze_onset.jl                   # experiment (:freeze_onset)
  tracking_param_sweep.jl           # experiment (:tracking_param_sweep)
  tracking_leak_lrate_factorial.jl  # experiment (:tracking_leak_lrate_factorial)
  shoal_vision_sweep.jl             # experiment (:shoal_vision_sweep)
  shoal_vision_sweep/protocol.toml  # full, pilot, and operating-point sensitivity profiles
  figures/        # CairoMakie figure scripts (own env; read a run's results.json)
  runs/           # scratch/exploratory outputs (git-ignored)
  results/        # curated evidence bundles, committed & traceable to a study/figure
```

**Data retention.** Exploratory runs land in the git-ignored `runs/`. Committing a directory
under `results/` makes it reviewable; it does not by itself promote the scientific result.
Large raw data may live in an external archive, but the immutable URI and checksum belong in
the committed bundle.

## Evidence states and promotion

Every study page declares `exploratory`, `tuned`, `frozen`, `confirmed`, `promoted`, or
`retired`. `frozen` is a fixed protocol whose sealed outcomes remain unopened; `confirmed`
means the frozen protocol has been executed on those blocks.
Development outputs, selected winners, and representative runs remain exploratory unless a
frozen protocol is evaluated on untouched randomized blocks.

A promoted bundle requires:

- frozen protocol and analysis plan;
- resolved config and selected parameters;
- full git SHA plus dirty-worktree status;
- Julia version and Project/Manifest hashes;
- named seed ledger with disjoint-stage and overlap checks;
- per-block results and declared paired contrasts;
- inferential unit, exclusions, and dead/failed-run policy;
- analysis-code version or hash;
- schema-versioned summary JSON;
- figure inputs and representative-selection rule;
- checksums for every promoted artifact;
- immutable external-archive URI and hash when raw data is not committed.

Do not hardcode numerical prose from a scratch run. Site figures and claims should read from
the promoted summary. Opening sealed data and then changing a parameter, endpoint, exclusion,
or analysis restarts the evidence cycle.

`harness.jl` composes only the **public** `BrainlessLab` API (`simulate`,
`task_outcome`, …), so experiments survive core refactors:

- `freeze_sweep(task; freeze_ticks, window, seeds, verb)` — normalized score + rate
  vs. the tick an intervention is applied, with a matched full-learning control.
- `onset_tick(freeze_ticks, fz_mean)` — the knee of a score-vs-tick curve (a
  sweep-level readout, deliberately *not* a `register_analysis!`, which is per-run).
- `run_dir` / `write_text` / `git_sha` / `stamp` — a traceable run directory.

## Adding an experiment

1. Write `experiments/<name>.jl` that defines `run_<name>(; kwargs...)::String`
   (does the work, writes a run dir via `run_dir`, returns its path) and registers
   it: `register_experiment!(:<name>, run_<name>; description="…")`.
2. Add `include(joinpath(@__DIR__, "<name>.jl"))` to `run.jl`.

Keep it public-API-only; reaching into `BrainlessLab` internals is a signal the
piece wants to be a registered analysis or a core feature instead.

Before adding a protocol, follow the site's Research workflow: calibrate the task, choose
controls that match the claim, separate development and confirmation seeds, name the
independent block, and plan power prospectively from a fresh variance pilot.

Natural next studies on this seam:
- **What sets the onset tick** — sweep `freeze_tick × lrate_targ|threshold_mult`
  and read `onset_tick` as a function of the homeostatic rate.
- **Which plasticity carries the load** — `freeze_sweep(...; verb=:clamp_target)`
  (targets only) vs `:freeze_plasticity` (weights + targets).

## Physical composition

New ecological experiments that need independently composed physical cameras,
field probes, actuators, dynamics, and physiology should start from the public
`ObjectWorld` surface. The copy-ready examples under `examples/embodiments/`
show both levels: `object_world_quickstart.jl` exposes the live `Ensemble` and
`Recorder`, while `object_world_task.jl` adds a `TaskSpec` and returns the
standardized `SimResult`.
