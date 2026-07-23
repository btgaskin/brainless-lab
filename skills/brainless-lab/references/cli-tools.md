# Unified operations and records

The canonical batch interface is one command over one strict TOML schema:

```bash
julia --project=. bin/brainlesslab.jl check PLAN.toml
julia -t auto --project=. bin/brainlesslab.jl run PLAN.toml --root records
```

The plan declares the operation. `check` parses, validates, and resolves without running.
`run` calls `run_operation` and prints the resulting record directory and compact summary.

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

Unknown keys and duplicate target IDs fail. A composition may use `preset`, or declare
`node`, `task`, `n_nodes`, optional `body`/`n_agents`, parameters, task/body options, and an
explicit fixed-rate interaction cycle.

The root seed derives named `topology`, `node_state`, `world`, `body`, `task`, and
`mechanism` streams. `construction_scope` controls only topology and node-state sharing.
The generic composition path requires `topology` and `world`; additional streams are
derived and exposed in `NodeBuildContext`. A component may leave a declared stream unused.
Records write one seed row per trial, agent, and stream.

## Operation sections

Profile:

```toml
[profile]
target = "tracking"
analyses = ["branching_ratio_mr", "node_target_error"]
record_every = 1
```

Sweep:

```toml
[sweep]
target = "tracking"
mode = "factorial" # factorial | one_at_a_time
max_rollouts = 100

[[sweep.axes]]
parameter = "leak"
values = [0.25, 0.5]
```

Omit axes to use the node's registered `:sweep` parameter set and each parameter's declared
candidate values.

Ablation:

```toml
[ablate]
target = "tracking"
ablations = ["freeze_plasticity", "clamp_target"]
```

The executor adds the paired baseline automatically.

Evolution:

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

Optimizer and evaluation streams are separate. Held-out targets execute once after
selection. They must use the same registered node type as the training target.

Benchmark:

```toml
[benchmark]

[[benchmark.cases]]
id = "tracking"
conditions = ["tracking_falandays", "tracking_random"]
baseline = "tracking_random"
```

Conditions within a case must share block count, trials per block, and root seed. The
result reports per-task statistics and paired contrasts; it has no cross-task aggregate.

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

`record.toml` inventories and hashes every generated artifact. `request.toml` is the input;
`resolved.toml` contains resolved defaults and operation settings. CSV tables are
authoritative. `FAILED` replaces successful completion when record generation throws.

Examples live in `plans/examples/`. They are intentionally small exploratory smoke plans.

## Versioned experiments

`write_experiment(directory, experiment)` writes `experiment.toml` plus one ordinary plan
file per operation. Validate or run the bundle with:

```bash
julia --project=. bin/brainlesslab.jl check-experiment PROTOCOL_DIR
julia -t auto --project=. bin/brainlesslab.jl run-experiment PROTOCOL_DIR --root experiment-records
```

`run-experiment` preserves the protocol and writes one standard record per operation. It
does not hide selection or evaluation inside a monolithic callback.

## Older tools

`bench/`, `profile/`, `sweep/`, `calibration/`, and `experiments/` contain earlier research
pipelines and curated studies. Preserve them when reproducing their historical artifacts,
but do not extend their separate configuration schemas as the platform API. New work uses
typed operation plans and the version-one record writer.
