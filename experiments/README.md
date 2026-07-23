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

## Layout

```text
experiments/
└── examples/
    └── falandays-cross-task-smoke/
        ├── experiment.toml
        └── plans/
            ├── 01-evolve_tracking_test_pong_example.toml
            └── 02-evolve_pong_test_tracking_example.toml
```

The reciprocal Falandays example is a small planned smoke protocol. It demonstrates how to
evolve parameters on Tracking and evaluate the selected champion on Pong, then reverse the
direction. Its small budgets are for validation only and do not support a performance
claim.

## Validate and run

Validate the whole bundle without simulation:

```bash
julia --project=. bin/brainlesslab.jl check-experiment \
  experiments/examples/falandays-cross-task-smoke
```

Run each contained operation and write standard records:

```bash
julia -t auto --project=. bin/brainlesslab.jl run-experiment \
  experiments/examples/falandays-cross-task-smoke --root experiment-records
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

The archived bespoke experiment runner is retained under
`archive/2026-07-legacy-research/experiments/` for historical reproduction. It is not part
of the current public workflow.
