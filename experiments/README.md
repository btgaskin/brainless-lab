# Versioned experiments

This directory contains reusable scientific protocols written as `ExperimentSpec` bundles.
An experiment gives a stable identity and version to:

- the research question;
- named `EvaluationTarget` conditions;
- one or more ordinary operation plans;
- the current evidence state;
- known limitations and descriptive metadata.

`ExperimentSpec` is not a second execution path. Each contained profile, sweep, ablation,
evolution, or benchmark plan uses the same validator, executor, and record writer as a
standalone plan.

The [capacity-probe proposals](capacity-probes/README.md) provide calibration, native
comparison and block-scoped decoding plans. These are unexecuted development proposals,
with core admission and confirmation still pending.

## Layout

```text
experiments/
└── examples/
    └── structured-ctrnn-smoke/
        ├── experiment.toml
        └── plans/
            └── 01-structured_ctrnn_search_smoke.toml
```

The structured CTRNN example is a small planned smoke protocol. It demonstrates how to
search one fixed node design on a development target and evaluate the selected model on a
held-out target. Its one-generation budget validates the protocol only. It does not support
a performance or generality claim.

`tracking-plasticity-branching-v1/` is a planned three-condition Falandays Tracking
protocol. It compares plasticity frozen at tick 1, plasticity frozen at tick 1800, and
continuous plasticity across paired 7200-tick trials. Its profile operations retain the
declared full-run task outcome and aggregate branching-diagnostic series.

## Validate and run

Validate the whole bundle without simulation:

```bash
julia --project=. bin/brainlesslab.jl check-experiment \
  experiments/examples/structured-ctrnn-smoke
```

Run each contained operation and write standard records:

```bash
julia -t auto --project=. bin/brainlesslab.jl run-experiment \
  experiments/examples/structured-ctrnn-smoke --root experiment-records
```

Use `write_experiment(directory, spec)` when publishing a new bundle. It validates the
conditions and writes `experiment.toml` plus one strict plan file for each operation.
`read_experiment(directory)` rejects disagreements between repeated condition definitions.

## Evidence rules

The allowed evidence states are `planned`, `exploratory`, `tuned`, `frozen`, `confirmed`,
`promoted`, and `retired`. Changing the state does not change the data. It records how the
protocol and results may be interpreted.

Create a new version when a scientific change alters the question, conditions, endpoint,
seed policy, exclusions, or operation. Do not edit an executed version in place. Store
operation outputs under a records root or an immutable external archive; do not copy
numerical claims into this directory by hand.

The former bespoke experiment runner was removed before the 0.3.0 release. Git history
retains it; it is not part of the current public workflow and should not be revived.
