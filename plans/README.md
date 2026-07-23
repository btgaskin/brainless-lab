# Operation plans

This directory contains strict `brainlesslab-plan` TOML files. Each plan combines one or
more `EvaluationTarget`s with one research operation:

```text
CompositionSpec + EvaluationSpec
  → EvaluationTarget
  → ProfilePlan | SweepPlan | AblationPlan | EvolutionPlan | BenchmarkPlan
  → record
```

Validate a plan without simulation:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
```

Run it and write a portable record:

```bash
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

Files under `plans/examples/` are small executable checks. They demonstrate plan syntax
and validation, not benchmark evidence.

A versioned scientific protocol belongs under [`../experiments/`](../experiments/).
`ExperimentSpec` names its conditions and refers to ordinary operation plans, so the
experiment and standalone paths use the same executor and record format.
