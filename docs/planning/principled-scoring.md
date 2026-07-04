# Principled scoring & normalization — implementation plan

**Branch:** `feat-scoring` (worktree). **Scope of THIS run:** Phase 1 only — the
principled scoring/normalization foundation, recalibration of the existing
single-agent tasks, and re-anchoring the foraging/swarm scoring. The two new
rhythmic tasks (sine-sync, respiratory entrainment) are **Phase 2 and OUT OF
SCOPE here** — they are specced at the end for context only; do not implement
them.

Primary consumer is the **static analytics sweep** (`src/run/Sweep.jl`), not the
evolution loop. The sweep compares *absolute* normalized scores across parameter
cells, regimes, and ablations and auto-writes regime-flip callouts, so a
miscalibrated anchor manufactures fake conclusions. Making anchors principled is
a precondition for trusting the sweep's `score` column and its callouts.

---

## 0. The problem (why this work exists)

Normalization is one formula — `normalized_score(task, raw) =
clamp((raw − floor)/(ceiling − floor), 0, 1)` (`src/tasks/Tasks.jl:108`) — fed by
hand-typed anchors (`Tasks.jl:39`). Several of those anchors are undocumented
magic numbers, several floors are wrong (set to 0 where the real chance level is
well above 0), and the swarm/forage path bypasses the anchor scheme entirely.

**Three distinct kinds of number are currently conflated. Treat them separately:**

- **(a) Normalization anchors** — `score_floor`, `score_ceiling`, forage's
  `max_dist`. Must never be a literal typed by hand; always the measured or
  analytic score of a *named agent* (see §2).
- **(b) Task-definition thresholds** — liveness gates, `targ_min`,
  `capture_radius`, (Phase 2: sync `amp_floor`, entrain `band`). Legitimate
  constants that define what the task *is*. Keep them, but declare them as task
  definition and make them relative/dimensionless where possible.
- **(c) Hidden objective weights** — wall `lam=1.0`, which folds a collision
  penalty into the wall score. Stop pre-collapsing; surface as separate channels
  and let downstream analysis combine explicitly.

## 1. The one idea

**A floor or ceiling is never a number someone typed — it is the measured (or
analytic) score of a named reference agent.**

- **Floor = a model-agnostic null policy** that ignores input and emits
  uniform-random effectors each tick (seeded). Model-agnostic is the crux: the
  sweep varies node type (falandays / compartmental / SORN), and a
  model-specific null ("a dead Falandays") would make "0" mean something
  different per neuron and destroy cross-neuron comparability. A random-output
  null fixes "0 = no better than acting randomly" identically for every model.
- **Ceiling = analytic maximum** where a true max exists (tracking, cartpole,
  and Phase-2 sync/entrain — perfect performance is well-defined = 1.0), else a
  **named best-known reference agent**, recorded with provenance (wall, pong).
- **One normalization semantics everywhere:** the score is the *fraction of the
  null→reference gap closed*. 0 = the null policy, 1 = the reference.

Comparability caveat to preserve honestly: scores are only mutually comparable
*within a ceiling kind*. Analytic-ceiling tasks share "1 = true optimum";
reference-ceiling tasks are comparable only relative to their reference agent.
Emit the ceiling kind so downstream analysis never cross-compares illegitimately.

## 2. Core types & API (new)

Add to `src/tasks/` (new file `Scoring.jl`, included from `BrainlessLab.jl`
before `Tasks.jl`; or top of `Tasks.jl` — your call).

```julia
@enum AnchorKind ANALYTIC NULL_MEASURED REFERENCE_MEASURED

struct ScoreAnchor
    value::Float64
    kind::AnchorKind
    provenance::String   # e.g. "random-null, seeds 0:7, git 8f5c193, 2026-07-04"
end

# convenience
analytic(v; note="")            = ScoreAnchor(Float64(v), ANALYTIC, note)
null_anchor(v, prov)            = ScoreAnchor(Float64(v), NULL_MEASURED, prov)
reference_anchor(v, prov)       = ScoreAnchor(Float64(v), REFERENCE_MEASURED, prov)
```

`TaskSpec` (`Tasks.jl:3`): replace the two `Float64` fields `score_floor`,
`score_ceiling` with `floor::ScoreAnchor`, `ceiling::ScoreAnchor`. Provide
accessor helpers `score_floor(t::TaskSpec) = t.floor.value` and
`score_ceiling(t::TaskSpec) = t.ceiling.value` for any external readers, and
grep the whole repo for `.score_floor` / `.score_ceiling` field access and route
them through the accessors or `.floor.value`. Keep the `TaskSpec(name, env; ...)`
kwarg constructor working: accept `floor`/`ceiling` as either a `ScoreAnchor` or
a bare `Real` (wrap a bare real as `ANALYTIC` with provenance
`"legacy literal (uncalibrated)"` and emit a `@warn` once), so no call site
breaks and un-migrated literals are loud, not silent.

`normalized_score` (`Tasks.jl:108`): keep the formula exactly; read `.value` from
the anchors; keep the `ceiling.value > floor.value` guard.

## 3. The null policy (new, model-agnostic)

Implement a minimal `Reservoir` that satisfies the node interface and emits
uniform-random effectors in `[0,1]`, independent of input, driven by a seeded
RNG. Register it (`register_node!`) as `:null_random` so it flows through the
existing `rollout(task, model, seed; model_sym=:null_random, ...)` /
`simulate` paths unchanged. It must:
- ignore its input `R`,
- return a spike vector of the reservoir width (zeros are fine; liveness will
  read it as dead, which is correct — the null is *not* alive),
- produce an `effectors` readout of uniform-random values so
  `decode_effectors` yields a random motor command every tick.

Determinism: same seed ⇒ same trajectory (needed for reproducible calibration).

## 4. Calibration (new)

`calibrate_task(task; null=:null_random, reference=nothing, seeds=0:7, kw...)`:
- Run the null policy through `rollout` over `seeds`, take the raw score via the
  task's `score_key`, average → floor value; build `null_anchor(mean, prov)`
  with a provenance string containing the git short-sha (shell out to
  `git rev-parse --short HEAD` or reuse `run/Manifest.jl` if it already exposes
  one), the date (`Dates.today()`), the null name, and the seed range.
- Ceiling: if the task declares an analytic max, return `analytic(max)`. Else, if
  a `reference` agent/genome is supplied, run it the same way →
  `reference_anchor(mean, prov)`. If no reference genome artifact is available,
  keep the current ceiling value but re-tag it `REFERENCE_MEASURED` with
  provenance `"legacy observed best, pending reference-genome calibration"` and
  leave a `# TODO(reference-genome)` note.
- Return `(floor, ceiling)`. Also provide a thin CLI/entry (e.g.
  `calibration/run_calibration.jl` or a function `write_calibration_report`) that
  prints/writes the freshly measured anchors so a developer can regenerate them.

**Do not** load anchors from a file at module import — keep anchor values as
`ScoreAnchor` literals in `Tasks.jl` (deterministic, no import-time IO). The
calibration routine *regenerates* those literals; a test guards drift (§7).

## 5. Recalibrate the existing anchors

Run `calibrate_task` to obtain real numbers, then write them into the `Tasks.jl`
literals as `ScoreAnchor`s with provenance. Target treatment per task:

| task | score_key | floor | ceiling | ceiling kind | notes |
|---|---|---|---|---|---|
| tracking | track_score | `analytic(0.0, "E[cos]=0 chance")` | `analytic(1.0)` | ANALYTIC | already principled; just document |
| cartpole / _hard / _long | score | `analytic(0.0)` | `analytic(1.0)` | ANALYTIC | already principled |
| cartpole_swingup | mean_uprightness | `null_anchor(measured≈0.02)` | `analytic(1.0)` | ANALYTIC | measure the hanging null |
| pong | mean_align | `null_anchor(measured≈0.33)` | `reference_anchor(≈0.972, prov)` | REFERENCE | ceiling currently undocumented |
| pong_hitrate | hit_rate | `null_anchor(measured≈0.30)` | `reference_anchor(≈0.52, prov)` | REFERENCE | 0.22-wide band, hypersensitive — recompute carefully |
| wall | **:distance_window** (see §6) | `null_anchor(random-walker distance)` | `reference_anchor(best-known, prov)` | REFERENCE | floor was wrongly 0; ceiling 77.3 undocumented |

Where a reference genome is unavailable, follow the fallback in §4 (retag +
TODO), do **not** invent a number.

## 6. Wall `lam` — surface it, stop folding it (class c)

- Change `WALL_TASK.score_key` from `:score` to `:distance_window` so the scored
  quantity is pure distance (anchored by a random-walker null), **not** the
  lam-blended value.
- Keep `collisions_window` visible. Add an optional field to `TaskSpec`:
  `descriptor_keys::Vector{Symbol} = Symbol[]` — metric channels to carry into
  the sweep's per-cell row as extra columns. Set wall's to `[:collisions_window]`.
- In `_run_seed_metrics` (`Sweep.jl:740`), copy each `descriptor_keys` channel
  from `sim.metrics` into the row dict (finite-guarded). `_csv_header`
  (`Sweep.jl:819`) already promotes non-fixed keys to "extras", so these appear
  as columns automatically.
- Leave the `lam` param and the blended `:score` channel in place for anyone who
  wants the combined metric; only the *scored* key changes.

This `descriptor_keys` mechanism is reused in §7 to demote swarm order params.

## 7. Foraging / swarm re-anchor (the worst offender)

`forage_score = clamp(1 − mean_distance/max_dist(torus), 0, 1)`
(`src/world/Metrics.jl:345`) is normalized against the **geometric** max
distance, so a random/dead swarm (mean distance ≈ 0.3–0.35·L) scores
**forage ≈ 0.5**, and `_sim_score` (`Sweep.jl:693`) reports that 0.5 straight
into results.csv as competence. Fix:

- Keep `forage_score`'s geometric value as a **raw channel** (don't change
  `Metrics.jl`'s formula).
- Introduce forage anchors: `floor = null_anchor(random-walk forage_score ≈0.5,
  measured via calibrate_task with the :null_random policy on the forage/torus
  env)`, `ceiling = analytic(1.0, "agents on source")`.
- Generalize `_sim_score` (`Sweep.jl:686`): for swarm tasks, if the metrics
  expose a `:forage_score` (or a generic `:score`) channel, normalize it through
  the forage anchors instead of returning it raw. Prefer reading a generic
  `:score` channel so future non-swarm-metric environments work too.
- **Demote `polarization`/`milling` from competence to descriptors.** An order
  parameter of headings has chance ≈ 1/√N (≈0.35 at N=8) and no task-competence
  meaning. `_sim_score` must **not** return raw `polarization` as "score". For a
  bare `torus` task that has no objective, return `NaN` score (or skip scoring)
  and record polarization/milling as descriptor columns via the existing
  `regime` measure path (`Sweep.jl:796`), which already captures them. Add a
  one-line `@warn`/note where the old raw-polarization-as-score fallback used to
  be, so any sweep relying on it is told to move to a descriptor read. Do not
  silently delete behavior that existing swarm sweeps may depend on — warn and
  redirect.

## 8. Chance-floor reasoning (sanity checks for the measured floors)

The measured null floors should land near these analytic expectations; if they
don't, something is wrong with the null wiring:
- pong `mean_align` ≈ 0.33 (centered paddle chance), `hit_rate` ≈ 0.30.
- forage ≈ 0.5 (random walk vs geometric-max normalizer).
- polarization ≈ 1/√N (descriptor, not scored).
Measuring the null is the *single* mechanism that makes all of these honest —
do not hand-derive per-metric chance constants.

## 9. Tests

- `test/scoring_anchors.jl`: `ScoreAnchor` construction, `normalized_score` reads
  `.value`, the guard, and the legacy-literal wrapping + warning.
- `test/scoring_calibration.jl`: run `calibrate_task` on 1–2 fast tasks (pong,
  wall) with a small seed range and assert the committed floor literal ≈ freshly
  measured null within a tolerance (a **drift guard**), plus assert the analytic
  expectations in §8 hold to within tolerance.
- Ensure the **existing** test suite still passes. Run it and report results.

## 10. Constraints

- **No new package dependencies** (Phase 1 uses only existing infra; the FFT/DSP
  needs belong to Phase 2). Do not touch `Project.toml`.
- Preserve public behavior except the deliberate score-value shifts (wall, pong,
  pong_hitrate, forage) — those *will* move; that's the point. Note them.
- Commit incrementally with clear messages, one commit per numbered section where
  practical. End commit messages with:
  `Co-Authored-By: Codex <noreply@openai.com>`
- Run the Julia test suite (`julia --project=. -e 'using Pkg; Pkg.test()'` or the
  repo's runner) before finishing and report pass/fail with output.
- Work only within this worktree.

## 11. Out of scope (Phase 2 — context only, DO NOT implement)

Two rhythmic tasks will be built on this scheme later, as the template for
principled tasks (analytic ceiling 1.0, incoherent/independent-oscillator
null floors, dimensionless gates):
- **`SyncEnv <: TaskWorld`** — single agent phase-locks to an external sinusoid;
  fitness = amplitude-gate × PLV; needs FFT/quadrature phase extraction.
- **`EntrainEnvironment <: Environment`** — N≥4 coupled static oscillators
  (distinct wiring seeds) entrain; fitness = ⟨Kuramoto r⟩ × liveliness × in-band,
  with mandatory null-subtraction (E[r]≈0.63 at N=2 is the reason for N≥4).

These have open design forks (in-phase vs detuned target; N) and a new
dependency, so they are a separate run. Leave hooks obvious but write no code.
