# Changelog

## 0.4.0 — release candidate

BrainlessLab 0.4.0 replaces the maintained Julia implementation with a Python and
Quadrants package. This is a breaking release with a narrower capability scope.
Earlier protocols and research records retain their original source revisions.

### Models and tasks

- Implement Falandays and SORN reservoirs with independent equation checks,
  deterministic streams, complete trial reset and owned snapshots.
- Advance neural and task state with Quadrants in bounded CPU or Metal batches.
  Use ordered destination-owned sums and fixed array ranks. CPU float64 is the
  reference arithmetic policy; Metal requires explicit float32 numerics.
- Support Tracking, Pong, CartPole, delayed cue and six additional experimental
  capacity-probe families. Retain 64 difficulty cells across the seven probe families.
- Preserve per-frame numerical-failure masks and task-specific raw outcomes.
  Weight freeze, full-plasticity freeze, blind input and shuffled input remain
  distinct controls.

### Plans, records and analysis

- Use one version-four `Plan` format for profiles, sweeps, ablations, benchmarks
  and calibration. Keep scientific identity separate from `ExecutionSpec` settings.
- Add `brainlesslab check`, `run` and `inspect` commands with machine-readable
  JSON output. Runtime logs go to standard error.
- Write portable records containing the request, resolved settings, stream
  identities, trial outcomes, summaries, calibration and exact package sources.
  Preserve failed trials and reject overwriting existing records.
- Retain signed null-adjusted outcomes. Empirical task calibration uses exactly
  1,024 independent trajectories and matching task, timing and numerical signatures.
- Add offline sparse-event decoding with fixed wiring per block, whole-trial
  splits, fit-only scaling and validation-only tuning. Diagnostic labels never
  enter the online controller.
- Add repeatable backend profiling with separate startup, warmed evaluation,
  recording and cache phases. No general CPU/GPU speedup is claimed.

### Documentation and packaging

- Ship version 0.4.0 as a Python wheel and source distribution with a locked
  Python 3.12 environment and Quadrants 1.3.3.
- Replace the website's live numerical engine with task illustrations and
  generated development recordings. Simplify the first-run and comparison guides.
- Organise the guide around getting started, tasks and models, study workflows,
  system concepts, reference, development, evidence and history. Expose all ten
  task families while preserving existing page URLs.
- Lead the landing page with the research workflow, identify microscopy and
  scripted diagrams beside their visuals, and place the first-run route before
  the task illustration on the start page.
- Consolidate extension guidance, expand specification and CLI reference tables,
  label historical search results and show when the accepted-run catalogue is empty.
- Align desktop search with the reading column and enlarge its phone touch target.
- Complete generated redirect HTML before search indexing, preserving old links
  without Pagefind's missing-document warnings.
- Add the project contributors and acknowledgements for the Diverse Intelligences
  Summer Institute and John Templeton Foundation.
- Make the installed-wheel test use the native virtual-environment interpreter
  path on Windows and POSIX systems.
- Make profiling tests declare their synthetic POSIX telemetry and preserve
  unsupported memory telemetry on platforms without the `resource` module.

### Evidence and remaining limits

Local macOS arm64 CPU and Metal qualification receipts are retained under
`docs/python/qualification/`. They cover declared software checks and short backend
conformance trajectories. Configured Linux and Windows jobs still require actual
passing CI receipts. Development runs and website recordings do not establish
learning, cognition, biological fidelity or external validity.

General body composition, heterogeneous populations, broad registries, evolution,
autodiff, durable checkpoint/resume and distributed execution are not implemented
in this release. Use `ARCHIVE.md` and the version-history guide to locate the
earlier implementation. Historical fixtures, benchmark tables and research bundles
remain unchanged.

## Earlier Julia changes — unreleased

- Add SORN as a stable core-registry node with causal STDP, synaptic normalisation,
  intrinsic plasticity, deterministic reset/replay, and explicit provenance limits.
- Add a frozen direct-control benchmark for fixed 200-node Falandays and SORN profiles on
  Tracking, Pong, and Plank CartPole Easy. Development may select only the external input
  gain. Selection and confirmation report mean heading error, mean longest rally, and mean
  balanced steps separately, while retaining each task's formal raw and normalised outcome.
- Correct `VotingReadout` to choose the largest cumulative effector activity across the
  interaction cycle. Silent frames no longer become first-index votes. This changes the
  public readout's previous frame-winner behaviour and matches the pinned Plank CartPole
  task interface.

## 0.3.0 — 2026-08-01

BrainlessLab 0.3.0 strips the platform back to a library. It ships the canonical node, the
core task protocols, and the machinery to extend both. It ships no experimental results and
no benchmark record.

This release is breaking. Scores computed with 0.2.0 do not carry over.

### Scoring windows

- Score the whole run by default. `simulate` and the composition path previously used
  `min(ticks, default_window)`, silently discarding the rest of a longer run: a
  2,000-tick tracking simulation scored its final 200 ticks, where the between-seed spread
  is four times the mean. The typed evaluation path already scored the full post-warmup
  interval, so the two paths disagreed.
- Add `minimum_scored_ticks` to `TaskSpec`, declaring how many scored ticks a task needs
  before its value means anything: Pong 6,000 (it emits roughly one ball event per 305
  ticks), Tracking 2,000, Wall 200. An evaluation below the minimum is now rejected
  instead of scored. Pass an explicit `window` to acknowledge a short diagnostic run.
- Reject at registration any task whose `default_ticks` is below its own
  `minimum_scored_ticks`.
- Record the effective scoring window on every outcome and in every record.
- `TrackingEnv` `default_ticks` is now 2,000, so the default tracking simulation produces a
  meaningful score rather than near-noise.
- `default_window(env)` is unchanged; it remains the fallback for direct `metrics(env)`
  calls.

### Anchors

- No anchor value changed. Anchor provenance now records `scored_ticks`, because
  calibration rate-matches the reference firing rate over the scoring window: an anchor
  measured over a different window is a different anchor. Measured over 32 seeds, Wall's
  floor moves 0.81609 to 0.77244 between window 200 and window 1,000.

### Evolution records

- Evolution checkpoints no longer grow quadratically. Each generation previously wrote the
  entire candidate archive to date, so a 60-generation run produced 3.0 GB of checkpoints
  beside 3.6 MB of results. Checkpoints now carry strategy state only, retain the newest
  two, and reconstruct the candidate archive from the record's own CSV tables. Per-
  checkpoint size is constant in generation count.
- Records are self-sufficient for custom measures. `candidates.csv` is written
  incrementally, and per-trial measure values are persisted as `measure_value`. Previously
  those values existed only inside checkpoints.

### Surface

- `:falandays` is the only name for the canonical node; the `:falandays_base` alias is
  removed.
- Nine Falandays variants are removed: `ablated`, `delayed`, `dendritic`, `extended`,
  `hemispheric`, `noisy`, `oosawa`, `spatial`, `swarm_legacy`. Registered nodes are
  `:falandays`, `:null_random`, `:sorn`, `:compartmental_dense`,
  `:compartmental_structured`, and `:homeostatic_flow_v2`. The `Dale`, `UnsignedAxis` and
  `OosawaDrive` mechanisms remain on the base reservoir, which is what the sealed parity
  fixtures exercise.
- The `bench` cross-node comparison tool is removed. It was the only evaluation path that
  produced no record, and its default protocol scored Pong over a single ball event.
  Cross-node comparison is a `BenchmarkPlan`; parameter exploration is a `SweepPlan`.
- The Falandays core benchmark version 1 is retired. Its committed record's normalised
  column no longer reproduced after the anchors were recalibrated, and it predated the Pong
  window fix. Version 2 is the single core protocol, and it ships as a declared protocol
  with no record.
- Pre-pipeline contribution support is now generic rather than hardcoded to one record,
  with path-containment and record-bundle validation.
- Top-level layout flattened from 28 tracked entries to 25: `archive/` removed,
  `calibration/`, `configs/` and `sweep/` folded into `tools/`.

### Tests

- `Pkg.test()` runs every suite. It previously defaulted to `core`, 14 files of 72, and
  reported success. Opt into a single tier with `BRAINLESSLAB_TEST_SUITE=core`.

### Packaging

- `Manifest.toml` is no longer tracked. A dependency's manifest is ignored by a downstream
  resolver, which reads only `Project.toml` and `[compat]`, so a committed manifest pinned
  this repository's own CI to one resolution out of the range the package claims to
  support. All eight dependencies and every test extra carry compat bounds, and CI already
  deleted the manifest and re-resolved on every run.
- Each record now stores its resolved dependency graph as
  `environment/Manifest.toml`. The record inventory and checksums seal that file with the
  other artifacts. A single tracked Manifest would drift with the branch, while the
  per-record copy preserves the resolution that produced that result.

## 0.2.0 — 2026-07-22

BrainlessLab 0.2.0 is an experimental research preview and the first typed research-platform release.

- Add typed node, task, composition, evaluation, operation, and experiment contracts.
- Add one version-one TOML plan schema for profile, sweep, ablate, evolve, and benchmark.
- Add portable research records with raw CSV data, seed ledgers, checksums, statistics,
  resolved provenance, and generated HTML reports.
- Add four experimental Plank CartPole profiles while keeping Tracking and Pong as the
  core qualification benchmark.
- Add checked-in operation plans, a unified CLI, and an external-project template.
- Align package and citation metadata on version 0.2.0.
- Add reproducible package, compatibility-floor, tool-smoke, and documentation CI.
- Add package-quality checks without weakening numerical conformance or calibration tests.
- Clarify repository installation and the pre-1.0 stability boundary.

## 0.1.0 — 2026-07-04

The public tag named `v0.1.0` was created from code whose `Project.toml` still reported
version `0.0.1`. That historical tag remains immutable; 0.2.0 is the first release in
which the package and citation versions are aligned.
