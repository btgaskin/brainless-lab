# experiments/

A fifth CLI tool, a peer to `bench`/`profile`/`sweep`/`calibration`: a top-level
directory with a `run.jl` entrypoint, run against the **root project** (like
`sweep`/`calibration`; `bench`/`profile` only carry their own `Project.toml`
because they pull in viz/stats deps that experiments don't need).

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
```

`key=val` values parse as Int (`600`), Float (`0.5`), range (`0:9`), comma-list
(`tracking,pong` → Symbols; `1,2,4,8` → Ints), else a Symbol. Each run writes
`experiments/runs/<name>/<UTCstamp>_<gitsha>/` with `results.json` + `manifest.txt`
(node, tasks, ticks, seeds, git SHA, timestamp) — enough to reproduce exactly.

## Layout

```
experiments/
  run.jl          # CLI entrypoint: registers all experiments, dispatches by name
  registry.jl     # ExpRegistry — register/resolve/list experiments by symbol
  harness.jl      # ExpHarness — reusable building blocks (public-API only)
  freeze_onset.jl # an experiment (registered as :freeze_onset)
  runs/           # self-describing outputs (git-ignored)
```

`harness.jl` composes only the **public** `BrainlessLab` API (`simulate`,
`sim.metrics.score`, `normalized_score`, …), so experiments survive core refactors:

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

Natural next studies on this seam:
- **What sets the onset tick** — sweep `freeze_tick × lrate_targ|threshold_mult`
  and read `onset_tick` as a function of the homeostatic rate.
- **Which plasticity carries the load** — `freeze_sweep(...; verb=:clamp_target)`
  (targets only) vs `:freeze_plasticity` (weights + targets).
