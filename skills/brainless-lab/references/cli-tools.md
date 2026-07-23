# Operations, experiments, and records

Use one command and one strict TOML plan schema for repeated evaluation:

```bash
julia --project=. bin/brainlesslab.jl check PLAN.toml
julia -t auto --project=. bin/brainlesslab.jl run PLAN.toml --root records
```

`check` parses, validates, and resolves the plan without simulation. `run` calls
`run_operation` and writes one standard record.

## Plan envelope

```toml
format = "brainlesslab-plan"
format_version = 1
operation = "profile" # profile | sweep | ablate | evolve | benchmark
id = "stable_plan_id"

[[targets]]
id = "tracking"

[targets.composition]
id = "falandays_tracking_profile"
preset = "falandays_tracking"

[targets.evaluation]
blocks = 2
trials_per_block = 4
horizon = 7200
warmup = 100
construction_scope = "trial" # evaluation | block | trial
reset = "full"
root_seed = 4101
aggregate = "mean"
```

Unknown keys and duplicate target IDs fail. A composition may refer to a registered
`preset`, or declare its node, task, node count, body, agent count, parameters, task or
body options, and fixed-rate interaction cycle.

The root seed derives named streams for topology, node state, world, body, task, and
mechanism randomness. `construction_scope` controls topology and node-state sharing.
Records write the realised stream seeds for each trial and agent.

## Operation sections

Profile one composition:

```toml
[profile]
target = "tracking"
analyses = ["branching_ratio_mr", "node_target_error"]
record_every = 1
```

Sweep declared node parameters:

```toml
[sweep]
target = "tracking"
mode = "factorial" # factorial | one_at_a_time
max_rollouts = 100

[[sweep.axes]]
parameter = "leak"
values = [0.25, 0.5]
```

If `axes` is absent, resolution uses the node's registered `:sweep` parameter set and each
parameter's declared candidate values.

Ablate registered functional elements:

```toml
[ablate]
target = "tracking"
ablations = ["freeze_plasticity", "clamp_target"]
```

The executor adds the paired baseline. Validation checks the intervention stage and
required node capabilities. An inapplicable intervention, unsupported stage, or unchanged
composition is an error.

Evolve one registered parameter set:

```toml
[evolve]
training = "tracking_development"
heldout = ["pong_heldout"]
optimizer = "sepcma"
parameter_set = "evolve"
objective = "normalized_score"
generations = 100
popsize = 96
sigma0 = 0.5
```

Optimiser and evaluation streams are separate. Held-out targets execute after champion
selection. Training and held-out targets must use the same registered node type.

Benchmark paired conditions within tasks:

```toml
[benchmark]

[[benchmark.cases]]
id = "tracking"
conditions = ["tracking_falandays", "tracking_random"]
baseline = "tracking_random"
```

Conditions in one case must share block count, trials per block, and root seed. The result
reports within-task statistics and paired contrasts. It has no cross-task aggregate.

## Record contents

```text
record-id/
├── record.toml
├── request.toml
├── resolved.toml
├── seeds.csv
├── data/trials.csv
├── data/task_metrics.csv
├── data/<operation tables>.csv
├── summary/statistics.csv
├── summary/contrasts.csv
├── summary/summary.json
├── figures/
├── report/index.html
└── DONE
```

`request.toml` preserves the input plan. `resolved.toml` records all defaults and operation
settings used by the executor. `record.toml` inventories generated files and their
SHA-256 checksums. CSV tables are authoritative.

If execution or record generation fails, the bundle contains `FAILED` instead of `DONE`.
Completion does not set the experiment evidence state.

## Versioned experiments

Use `ExperimentSpec` to publish a question, version, named conditions, operations,
limitations, and evidence state. Write a directory with:

```julia
write_experiment("experiments/my-study", experiment)
```

This creates `experiment.toml` and one ordinary plan file per operation. Validate or run
the bundle:

```bash
julia --project=. bin/brainlesslab.jl check-experiment experiments/my-study
julia -t auto --project=. bin/brainlesslab.jl run-experiment \
  experiments/my-study --root experiment-records
```

`read_experiment` rejects mismatched definitions of a condition repeated across plans.
`run-experiment` executes each ordinary plan and writes one standard record per operation.

The checked example under `experiments/examples/falandays-cross-task-smoke/` is planned
smoke work. Its small evolution budgets test the protocol and executor, not a scientific
claim.

## Current and archived directories

- `plans/examples/` contains small standalone plan examples.
- `experiments/` contains current versioned `ExperimentSpec` bundles.
- `records/` and other selected roots contain generated operation records.
- `archive/2026-07-legacy-research/experiments/` preserves the former bespoke experiment
  runner for historical work.

Do not extend the archived runner or add an operation-specific config schema. New repeated
work uses typed plans and the standard record writer.
