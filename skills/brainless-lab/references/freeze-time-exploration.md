# Skill-operated freeze-time exploration

The user describes the question; the skill edits authoring arguments, executes ordinary
operations and returns a single-page report with a shareable archive. Do not introduce
another settings schema or require the user to edit code. Hypotheses and sealed evaluation
are optional later choices. Exploration needs explicit settings and retained results.

Use `tools/capacity_probes/freeze_curves.jl` for native capacity-probe timing curves.
`capacity_freeze_programme` accepts cells, scales, blocks, episodes per block, seed root,
input gain, cutoff fractions, explicit per-cell cutoffs, mechanisms and version. The default
is one cell from each of seven families, scale 0.1, ten independent blocks and sixteen
episodes per wiring block. Reversal uses one complete session per block. These are editable
exploration settings, not a universal sample-size rule or a calibrated optimum.
`cells=capacity_probe_presets()` includes all 64 difficulty cells; describe the expanded
budget before execution. A request for all capacity families need not imply all difficulties.

Author to a fresh directory under `experiments/`, validate with `check-experiment`, then
run selected branches with `run_experiment` or `run-experiment`. Keep failed runs and prior
curves. Full resets mean each episode starts afresh even when wiring is shared within a
block. Episodes improve block estimates; only wiring blocks count as independent samples.

`n` means completed adaptive ticks. Schedule freezing at `n+1`; `n=0` freezes before the
first tick. Use weight-only and complete freezing as distinct mechanisms. Target adaptation
affects emitted thresholds even when weights are fixed. Always-on has no intervention;
it is a horizontal reference, not a finite cutoff or derivative endpoint.

Six binary probes score their common final response and require warmup zero. Their generic
window argument does not select a different late outcome. The reversal branch fixes reversal
at round 48, marks this variation in its description, uses round-aligned cuts and retains
the native first-16-post-reversal-round score. This is within-episode timing, not learning
across episodes. Decoder accuracy is separate; the current decoder excludes reversal.

Make the curve primary. `report_freeze.py` computes adjacent slopes from paired block means,
dividing by actual tick spacing. It retains signs and tied maxima of absolute slope. Show
standard errors and sample counts. A flat curve has no non-zero steepest interval; a noisy
or chance-level curve does not establish a useful knee. Do not impose an acceptable-loss
threshold or binary-search monotonicity when the user wants exploratory curves.

For refinement, inspect the suggested midpoint of the steepest observed interval, add it
to the complete prior cutoff grid and author a linked follow-up with all prior points retained.
The report suggests cutoffs; it does not execute an adaptive search. Keep the source curve,
decision and revised settings together. Different seed batches remain separate. For a
same-seed curve extension, declare reuse explicitly and do not count replays as new evidence.

Generate the local report and ZIP with the isolated plotting dependency:

```bash
uv run tools/capacity_probes/report_freeze.py RUNS_DIRECTORY NEW_REPORT_DIRECTORY
```

The source directory contains ordinary experiment-run directories. The output contains
raw curves, paired slopes, selected-interval descriptions, normalised tables, complete
operation records, executed protocols, the analysis script, environment versions and
checksums. Verify desktop/mobile layout and offline links. Sharing means preparing this
portable output; sending or publishing it requires an authorised destination.

The tool currently reports native capacity curves. Canonical Tracking and Pong use distinct
task settings; choose a common post-cutoff scoring interval for continued-performance
questions. Their first raw-start initialisation sweeps do not measure freeze timing.
