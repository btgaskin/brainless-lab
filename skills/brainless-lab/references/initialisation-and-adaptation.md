# Initialisation and adaptation studies

Use this workflow to ask whether plasticity establishes a useful operating regime,
whether continued adaptation helps, or whether a frozen network performs well at a
different initialisation scale. Task performance and operating-regime diagnostics answer
different questions; report both without treating one as proof of the other.

## Check what changes

Inspect `src/nodes/Falandays.jl`, `src/nodes/Axes.jl`, `src/nodes/Interventions.jl`,
`src/core/Catalog.jl`, and the resolved composition before selecting axes.

- `weight_init_std` scales the zero-centred normal weights only under `legacy_normal`
  with the unsigned axis. The excitatory, Pong mixed, and Dale initialisers do not use it.
- Canonical Tracking uses the excitatory initialiser. Its recurrent mean depends on
  `input_weight`, which also sets sensory input amplitude. Sweeping that parameter does
  not isolate recurrent initialisation scale.
- `freeze_plasticity` sets `learn_on=false`, stopping both weight and target adaptation.
- `lrate_wmat=0.0` with `learn_on=true` freezes weights from construction while allowing
  target adaptation. `clamp_target` stops target adaptation. There is currently no
  registered live weight-only freeze intervention.

Do not switch to `legacy_normal` merely to obtain a working scale axis when the question
concerns the canonical initialiser. A new scale control must preserve the existing default
distribution, mask, signs and random draws. Verify its effect on realised initial weights
before collecting results. Preserve the declared reference trajectories.

## Compose the smallest study

1. State the task, initialisation distribution, meaning of frozen, outcome, scored interval,
   and development budget. Obtain external replication settings when exact replication
   matters; an internal exploratory study can proceed with explicit assumptions.
2. Use `ExperimentSpec` for named conditions and operations. Start from
   `plans/examples/sweep_tracking.toml`, `plans/examples/ablate_tracking.toml`, and
   `experiments/tracking-plasticity-branching-v1/` for current syntax and diagnostics.
   The last bundle is a planned freeze-timing study, not evidence for this question.
3. Use `SweepPlan` for supported parameter axes. Pair topology and world seeds across
   conditions and cells. Keep network size, connectivity, body and sensory gain fixed
   when testing recurrent scale. Verify that paired constructions differ as intended.
4. Use `ProfilePlan` on a small declared set of cells to inspect activity, target error
   and task behaviour. `tracking_plasticity_diagnostics` provides windowed Tracking
   diagnostics. Compute expensive channels sparsely; inspect analysis failures.
5. Compare continuous adaptation with freezing from the start. For delayed freezing,
   use `ScheduledIntervention` on the target. Score a common post-intervention interval
   when asking whether continued adaptation helps; whole-run scores also include the
   shared adaptation period. Verify paired trajectories agree before intervention.
6. Keep weight-only and complete freezing distinct. Add a missing live intervention
   through the existing interface with focused contract tests if the question needs it.

## Validate, run and read

The minimum validation command for an existing bundle is:

```bash
julia --project=. bin/brainlesslab.jl check-experiment experiments/tracking-plasticity-branching-v1
```

This checks the existing protocol without simulation. It does not create a scale sweep.
For a new study, write ordinary plans through `write_experiment`, validate the resulting
bundle, then run only the authorised operation using the CLI reference. Estimate runtime
from a small diagnostic before choosing a larger budget.

Expect standard records with resolved configuration, seeds, trial tables, summaries and
an HTML report. Check realised axis effects, paired seeds, failures and scoring windows.
Report the task outcome key, raw and normalised scores together. Use independent blocks
for uncertainty; ticks do not increase the sample size.

A frozen network winning a development cell does not establish that plasticity is useless.
Delayed freezing tests continued adaptation under the declared task and timescale. Fresh
worlds or changed conditions are needed for transfer or adaptation-to-change claims.
Select cells on development seeds, then follow the research-workflow reference for a
variance pilot and frozen confirmation protocol. Do not launch those later stages by
default.
