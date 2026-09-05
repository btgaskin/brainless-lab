# Shared CTRNN evolution readiness

This development review covers Structured and Dense CTRNN construction, integration,
wiring, evaluation, search objectives, model artifacts, checkpoints, and benchmark reuse.
The two families are alternatives with 220 and 404 coordinates. Every candidate supplies
one genome to all four tasks in direct-control v2; there are no task-specific specialists.

## Supported pipeline

- Typed compositions expose integration, state-initialisation, and wiring parameters.
  Exact connection counts and output fanout are applied and validated.
- Kernels cache static coefficients, reuse scratch arrays, avoid substep output copies,
  compute each Dense dendrite sigmoid once per update, and use sparse effector source lists.
- Evaluation resolves invariant compositions once and retains compact candidate trial and
  seed rows. Resource reports include edges, dynamic internal states, and integration updates
  per neural frame. Task-declared diagnostics remain in a JSON column, including recall
  decisions and exact ties. Resource counts are not a cross-model compute-equivalence claim.
- Maximising NSGA-II uses separate native task coordinates through `measure=:benchmark_profile`.
  Tracking error is negated; rally, balanced steps, and recall accuracy retain their sign.
- Complete generation data is written atomically with checksums. Resume validates those
  shards and also reads older flat-table records. Final records retain the standard CSV surface.
- Expected non-finite CTRNN dynamics invalidate a candidate evaluation with an explicit
  reason. Other errors fail the operation. Wall-time stops preserve resumable checkpoints.
- `ModelProfileSpec` can carry an `Evolution.ModelReference` into every generated target.

The fixed model kernel must remain unchanged during stepping. Replace the complete genome
through `reservoir.genome = model` to refresh it. Direct mutation of its nested coefficient
arrays is unsupported. Scratch arrays are per-reservoir and are not persistent neural state.

## Runtime measurements and conformance

`development/kernel-costs.csv` contains warmed local Julia 1.12.6 measurements. At 200 nodes,
both families allocate 1,664 bytes per `step!` and 80 bytes for two effectors. The pre-change
diagnostic allocated 123,904 and 3,408 bytes respectively. Dense median stepping fell from
approximately 4.77 ms to 1.39 ms; Structured remained approximately 0.69 ms. These are local
diagnostics, not controlled hardware benchmarks or end-to-end search speedups.

The immutable Dense and Structured reference trajectories and intervention fixtures pass.
Maximum observed state deviations were below 8e-15. This is numerical conformance for those
fixtures; it does not inherit or extend the canonical Falandays scientific boundary.

## Initialisation diagnostic

For each family and scale (0.25, 0.5, 1, 2), 24 models received paired zero and unit receptor
inputs for 120 frames at 200 nodes. Model and topology seeds were held fixed within a pair.
After 20 frames, any effector difference above 1e-12 counted as input sensitivity.
Selection maximises the finite sensitive fraction and breaks ties with the smaller scale.

Structured selected scale 1 with 2/24 sensitive models. Dense selected scale 0.25 with 1/24.
The complete table retains silence, equal-output, firing-rate, and finiteness diagnostics.
These are synthetic input probes, not task performance measurements. They reveal a sparse
initial search signal and justify a bounded pilot before any larger campaign.

## Bounded pilot protocol

```bash
julia --project=. tools/profile_ctrnn.jl
julia --project=. tools/run_shared_ctrnn_pilot.jl
```

The first command replaces local development diagnostic tables. The second runs ordinary
`EvolutionPlan` records under `records/shared-ctrnn-pilot`. Each family receives three search
seeds (971001–971003), two generations, four candidates, and two blocks per task. Both use
200 nodes, `dt=1`, five substeps, `link_p=0.1`, `rho=0.2`, random initial state with scale
0.05, and input gain 1 on every task. Task horizons and warm-up match direct-control v2.

Training roots are 962000, 963000, 964000, and 965000 in versioned task order. Fixed
Falandays and SORN baselines use these same worlds and their frozen profile gains.
The search seed varies proposals; it does not vary the paired training worlds.

One nominee per family maximises its minimum development margin against the stronger
fixed profile on each task. Each oriented difference is divided by the larger of the
baseline magnitude and 1. Ties use mean margin, search seed, generation, then candidate ID.
This explicit nomination rule does not turn the four objectives into a general competence score.

The nominee is saved as a portable model artifact and that exact reference is evaluated
on eight fresh development blocks per task, with roots 982000–985000. No v2 confirmation
root is used. The combined pilot budget is two hours, checked between episodes; one active
episode may overrun it. Interrupted searches retain their last complete generation.

`development/` holds plans, baseline trials, candidate scores, trials and seeds, nominated
models, and later selection tables. Full standard records remain in the local records root.
For the initial pilot records, `tools/replay_ctrnn_cue_diagnostics.jl` writes a linked recall
diagnostic table and checks each outcome against its original trial. Replayed blocks are
not additional observations. New searches retain these task diagnostics directly.
The search histories and selection results are development evidence. Confirmation,
robustness, and human acceptance remain separate work.

## Pilot results and readiness

All six searches completed within the combined budget: 48 candidate evaluations, each
with four task coordinates and two blocks per task. Every candidate remained finite.
The run, baselines, nominations, and fresh selection took 2,250 seconds (37.5 minutes).
The Structured nominee came from search seed 971003, generation 2, candidate 7; Dense
came from seed 971002, generation 1, candidate 3. Each saved model was used unchanged
across all four fresh task evaluations.

| Fresh development coordinate, 8 blocks per task | Structured220 | Dense404 |
| --- | ---: | ---: |
| Tracking mean heading error, degrees, lower is better | 89.713 | 89.754 |
| Pong mean longest rally, returns | 1.375 | 1.000 |
| Plank CartPole Easy mean balanced steps | 9.500 | 11.250 |
| Delayed-cue recall accuracy | 3/8 (0.375) | 6/8 (0.750) |

These native search coordinates accompany the task-declared outcomes below. Values are
means across the same eight independent blocks; normalisation occurs within each block.
Tracking and Pong use different fields for their declared outcome and search coordinate.

| Task outcome key | Structured raw / normalised | Dense raw / normalised |
| --- | ---: | ---: |
| Tracking `track_score` | 0.003842 / 0.006120 | 0.003347 / 0.009240 |
| Pong `hit_rate` | 0.180141 / 0.003240 | 0.233485 / 0.026987 |
| CartPole `fitness` | 9.500000 / 0.000633 | 11.250000 / 0.000750 |
| Recall `recall_accuracy` | 0.375000 / 0.375000 | 0.750000 / 0.750000 |

The CSV tables retain individual blocks and Student-t 95% intervals. With eight binary
recall observations, these descriptive intervals can extend outside [0, 1]; they are not
calibrated binomial intervals. No reliable recall advantage follows from Dense's 6/8 result.
Neither nominee improved on the stronger fixed training profile on the three control tasks.
The fresh blocks evaluate the nominees alone, so they do not provide a fresh paired
comparison with Falandays or SORN.

The diagnostic replay reproduced all 96 candidate recall trials exactly. Structured tied
its response effectors on 32/48 trials; Dense tied on 43/48. A tie selects the declared left
response and is not successful cue use. The two training worlds balanced cue identity but
sampled only delays 8 and 32; the 128-frame delay was absent from training. Together with
the synthetic input probe, this points to weak input sensitivity and limited development
coverage as immediate search concerns.

The pipeline is ready for further bounded development searches: construction, cached
stepping, multi-task objectives, compact records, checkpoint resume, saved models, and
benchmark reuse have executable coverage. The current initialisation and tiny search budget
have not produced a competitive shared design. Before a larger campaign, test whether
development-only input coupling and initialisation changes increase cue-sensitive responses,
use blocks covering every declared delay, and include blind-input or shuffled-cue controls
for any memory claim. Freeze any revised protocol before drawing new confirmation blocks.

## Verification

The complete Julia package gate passed 8,689 checks, including immutable CTRNN and
Falandays fixture checks. Focused checks also exercised allocation limits with bounds
checking enabled, saved-model benchmark reuse, corrupt journal rejection, invalid-candidate
resume, and the wall-time stop path. Export and dispatch-ambiguity checks passed.

The site passed 13 browser-runtime and component tests, display-seed consistency checks,
and a 45-page production build. These automated checks do not establish visual or click
acceptance in a browser. Reproduce the package and site gates with:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
cd site
bun test
bun run demo:check
bun run build
```
