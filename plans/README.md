# BrainlessLab plans

This directory contains strict `brainlesslab-plan` version-one TOML files for the canonical
operation path:

```text
CompositionSpec + EvaluationSpec → EvaluationTarget → operation → record
```

Validate without running:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
```

Execute and write a portable record:

```bash
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

The examples are deliberately small exploratory smoke plans. They are executable examples,
not benchmark evidence. The reciprocal evolution files show the intended direction of the
first flagship design: select on Tracking and evaluate on held-out Pong, then reverse the
direction. Larger budgets and frozen evaluation blocks should be declared in new versioned
plans rather than silently changing these examples.
