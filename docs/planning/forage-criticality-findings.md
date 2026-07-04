# Forage × Criticality — situation, methods, findings, caveats

A working reference for the forage-criticality investigation on `falandays_base`.
All quantitative results below are from the **frozen HEAD `30b1af2`** unless a
row is explicitly marked as older/incomparable (see §4).

---

## 1. The question

Hypothesis chain (optimal-information-transmission-at-criticality lens):

1. **Collective dynamics improve foraging.** Agents that couple (see/signal each
   other) should forage better than agents acting individually.
2. **That gain corresponds to criticality of the *ensemble*.** The collective
   improvement should show up as ensemble-scale criticality (susceptibility,
   correlated motion) that is *genuine* — i.e. survives a null test, not just
   common-drive structure.
3. **Ensemble criticality ↔ network criticality.** The reservoir (network) scale
   and the swarm (ensemble) scale should share associated dimensions, so that a
   collective coupling change is "equivalent" to a network coupling change.
4. **Degrading network criticality degrades both scales and hurts performance.**

Cross-scale framing: find *associated dimensions* between vision/coupling
(ensemble) and connectivity/size (network), and ask whether the same criticality
signature appears at both.

## 2. The system

- **brainless-lab**, node `falandays_base`: a reservoir-in-a-body agent with
  **online homeostatic plasticity** (the connectome self-organises during the
  rollout — no evolution/pretraining). Body `:ven` (128 receptors incl. a source
  bank + conspecific bank; 3 effectors).
- **Task `:forage`**: `n_agents` agents on a **15×15 torus**, an amber source at
  ~(10,11), `capture_radius=1`. Agents sense the source (`source_gain`) and,
  when `conspecific_vision=true`, each other (`vision_range`).
- **Controlled knobs**: `task.N` (reservoir nodes), `env.n_agents`,
  `env.conspecific_vision` (visual coupling), `env.vision_range`,
  `env.source_gain`, `env.sensory_noise`, `env.capture_radius`.
- **Held fixed** here: `n_agents=6`, `ticks=1200`, `source_gain=1`,
  `vision_range=6`, `link_p` = node default (per direction: vary population, not
  wiring density).

## 3. The measures (code references)

Network (reservoir) scale:
- **Branching ratio m** (MR, subsampling-robust) — `src/analysis/Branching.jl`
  (`branching_ratio_mr`). *Pinned near 1* by homeostasis → poor discriminator.
- **Susceptibility χ_node = N·var(synchrony)** — `src/analysis/SecondOrder.jl`.
- **Spectral radius ρ(W)** — `src/analysis/Spectral.jl` (now strided per
  `spectral_every`).

Ensemble (swarm) scale:
- **Susceptibility χ_agent = n_agents·var(polarization)** — `SecondOrder.jl`.
  The main ensemble-criticality read.
- **Agent branching** (event observables turn/speed/align/graded at a quantile
  threshold) — `Branching.jl` + `src/analysis/ActivityLevels.jl`. *Fails the null
  test* (measures autocorrelation, not cascade); kept as a **negative control**.
- **Correlation length** (Cavagna 2010) — `src/analysis/SwarmAnalysis.jl`.
  Unreliable so far (collapses to 0 in many cells).
- **Contact-graph clusters** — `SwarmAnalysis.jl` (new; relational).

Validation:
- **Circular-shift null test** — `src/analysis/NullTest.jl` (`crossshift_null`):
  independently time-shift each agent's series, recompute the measure on the
  surrogate. Real ≫ null ⇒ genuine cross-agent structure. The trust gate. Report
  the **collective − individual difference-in-differences** to separate coupling
  from common source drive (the shift removes both).

**Two forage scores — keep them straight:**
- **Raw metric** `sim.metrics.forage_score = clamp(1 − mean_dist/max_d)` —
  `src/world/Metrics.jl`. Unchanged by scoring work.
- **Anchored score** `score_mean` in sweep `results.csv` — the ScoreAnchor
  calibrated score (`src/tasks/Scoring.jl`). Amplifies the high-N penalty.
  Both peak at N≈100; magnitudes differ (see §5).

## 4. Data-integrity note (why some early numbers are void)

The codebase changed **during** the sweep campaign: `feat(scoring): ScoreAnchor`
(`d420563`, re-anchored forage) and `perf(runs)` (`30b1af2`, thread-parallelism +
strided spectral radius) landed mid-run. Identical configs gave different results
across the boundary (e.g. base N=100 anchored score 0.72 *before* vs 0.48
*after*). **Only frozen-HEAD (`30b1af2`) sweeps are comparable.** The pooled
`sweeps/ALL_RESULTS.csv` mixes calibrations — treat it as an index, not a
result. Trustworthy sweeps: `forage_ncurve`, `forage_peak`, `forage_collective`,
`forage_equivalence` (all frozen HEAD).

## 5. Findings (frozen HEAD)

### 5a. Foraging vs network size N — inverted-U, peak N≈100
`forage_ncurve` / `forage_peak` (base, n_agents=6, vision on), anchored score:

| N | 40 | 60 | 80 | 100 | 120 | 150 | 200 | 400 | 700 | 1000 |
|---|---|---|---|---|---|---|---|---|---|---|
| forage | .23 | .24 | .31 | **.48** | .47 | .43 | .37 | .06 | .10 | .02 |
| raw dist | | 4.4 | 4.0 | 3.0 | 3.1 | 3.3 | 3.7 | 5.5 | 5.2 | 5.7 |
| susc_node | .3 | .6 | 1.3 | 2.5 | 3.1 | 5.2 | 7.2 | 9.1 | 11.9 | 6.2 |

Clean inverted-U, peak N≈100–120. `susc_node` and spectral radius climb straight
through the peak → the descending side is the reservoir going **supercritical /
over-excited**, which kills the task. Foraging is best at *moderate* criticality,
not maximal. Branching m_node is pinned 0.91–0.98 and doesn't mark the peak.

### 5b. Collective vs individual — coupling helps most at the optimum
`forage_collective` (base, n_agents=6), anchored score:

| N | collective (vision on) | individual (vision off) | ratio |
|---|---|---|---|
| 60 | 0.241 | 0.184 | 1.3× |
| **100** | **0.482** | **0.148** | **3.3×** |
| 200 | 0.366 | 0.190 | 1.9× |
| 500 | 0.148 | 0.123 | 1.2× |

Raw metric agrees in direction (N=100: 0.71 vs 0.53; N=500: 0.54 vs 0.53). The
collective advantage is **largest at the N=100 optimum and nearly gone at N=500**
— coupling only pays off when the network is in its functional regime.
Individual-at-N=100 ≈ collective-at-N=500 → over-excitation wipes out the entire
collective bonus.

Images (`scratchpad/imgs/`): N=100 collective = tight cluster on the source;
N=100 individual = scattered across the torus; N=500 (either) = partial cohesion,
several agents strayed.

### 5c. Cross-scale coupling — vision raises BOTH susceptibilities
At N=100, vision on vs off: χ_agent 0.081 vs 0.003 (~27×) **and** χ_node 2.46 vs
0.49 (~5×). An ensemble/embodiment change reaches into the network's own
criticality. `forage_equivalence`: χ_node and χ_agent correlate **r = +0.84**
across cells — the two scales' criticality co-vary (the associated-dimension
signature). Caveat: χ = N·var grows with N / n_agents *mechanically* — normalise
(χ/N) before any population→criticality claim.

### 5d. The null test REFUTES the ensemble-criticality reading (powered)
Powered test at N=100 (8 seeds × 60 shifts; χ_agent real vs circular-shift null):

| condition | mean real χ_agent | mean gap (real − null) | t (n=8) |
|---|---|---|---|
| collective (vision on) | 0.094 | **−0.007 ± 0.036** | −0.53 (n.s.) |
| individual (vision off) | 0.002 | −0.0004 ± 0.001 | −1.09 (n.s.) |

**DiD (collective gap − individual gap) = −0.006 ≈ 0.** So the elevated
susceptibility under coupling is **fully accounted for by the surrogate**: the
circular-shift null (which preserves each agent's own source-driven dynamics but
scrambles inter-agent timing) reproduces the same susceptibility. The gain is
**common-source-driven correlated motion, not genuine agent-to-agent critical
dynamics** — exactly the common-input confound flagged at the outset, now
confirmed with power. **Hypothesis step 2 is not supported for χ_agent at N=100.**
The collective foraging advantage is real (behaviour, §5b) but is a
coordination/coverage effect, *not* an ensemble-criticality effect by this
measure. (Scope: susceptibility, N=100; other measures/N untested and
correlation_length is unreliable, but the collective measures broadly sat near
their nulls.)

### 5e. Behaviour is *approach*, not *capture*
`frac_within_capture ≈ 0` throughout — even at the optimum the swarm clusters
*around* the source (mean dist ~3 on a 15-unit torus) but rarely sits on the
1-unit capture point. "Foraging" here = collective approach/aggregation.

## 6. Caveats & confounds (read before citing any number)

- **Scoring anchor**: raw vs anchored scores diverge; *direction and pattern*
  (inverted-U, coupling helps, peak N≈100) are robust, *magnitudes* are not.
- **Susceptibility prefactor**: χ = N·var → grows with N/n_agents by construction.
- **Null test power**: the sweep runs it on one representative seed — underpowered.
- **agent-branching fails the null** — negative control, not a collective measure.
- **Signalling (acoustic) is not a sweep axis** — `env.signalling` is rejected by
  the harness (known axes exclude it). Collective coupling studied via
  `conspecific_vision` only until it's wired in.
- **correlation_length** unreliable (collapses to 0) — needs binning/scale review.

## 7. What you can read (files)

- **Consolidated index**: `sweeps/ALL_RESULTS.csv` (mixed calibrations — index only).
- **Per sweep**: `sweeps/<id>/results.csv`; captured cells:
  `cells/cell_NNN/{metrics.csv, criticality_timeseries.csv, null_test.csv}`.
  Frozen-HEAD sweeps: `forage_ncurve`, `forage_peak`, `forage_collective`,
  `forage_equivalence`.
- **Configs**: `configs/sweep_forage_*.toml`.
- **Images**: `scratchpad/imgs/*.png` (swarm snapshots), `forage_N100.gif`
  (motion at the peak).
- **Measure code**: `src/analysis/{Branching,SecondOrder,SwarmAnalysis,NullTest,
  ActivityLevels}.jl`; scoring `src/tasks/Scoring.jl`, `src/world/Metrics.jl`.

## 8. Open questions / next steps

1. ~~Powered null test~~ **DONE (§5d): refuted** — coupling's susceptibility gain
   does not survive the null (common-drive, not ensemble criticality). Follow-up:
   does *node-level* χ (or a different ensemble measure) survive its own null?
2. **Normalise susceptibility** (χ/N) and re-read the population trends.
3. **Wire `env.signalling`** so acoustic signalling (not just vision) can be swept
   — needed to complete the "signalling affects both scales" equivalence.
4. **Separate approach from capture** (§5e) — maybe a larger capture radius or a
   capture-based score, so "foraging" means arrival.
5. **Degrade-criticality arm**: directly push the reservoir supercritical (large N,
   or a drive) and confirm both scales' criticality and performance drop together.
6. **Associated-dimension collapse**: rescale χ_node(N) onto χ_agent(n_agents) and
   test whether the two criticality-vs-coupling curves overlay.
