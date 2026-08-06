# Changelog

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
