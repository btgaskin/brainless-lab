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
format_version = 2
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

Version 1 remains readable for non-evolution plans. The writer emits version 2. Evolution
plans require version 2 and `[evolve.run]`.

The default root-seed policy derives `:topology` and `:world`. `construction_scope`
controls topology sharing, while each trial receives its own world seed. Declare another
named stream only when a node, body, task, or mechanism consumes it. Records write every
declared realised stream seed.

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

Search one declared fixed node design:

```toml
[evolve]
training = ["tracking_development"]
heldout = ["pong_heldout"]

[evolve.run]
strategy = "sepcma"
iterations = 2
search_seed = 42
measure = "normalized_score"
direction = "maximise"

[evolve.run.initialisation]
centre = "zero"
scale = 0.25

[evolve.run.options]
population = 4
reducer = "minimum"
```

`Evolution.RunConfig` is embedded in the `EvolutionPlan`. `search_seed` controls normal
initialisation and later search decisions. Each evaluation target keeps its own root seed.

The public strategies `sepcma`, `nsga2`, and `cmame` resolve through one typed
search-strategy registry. SepCMA writes the stable model role `selected`. NSGA-II writes
ordered Pareto model IDs, and CMA-ME writes ordered archive-cell IDs. The multi-objective
strategies do not select an implicit champion.

Any registered node that declares a reviewed `Evolution.NodeDesignSpec` can use this
operation. The built-in schemas cover `FalandaysParams`, `StructuredCompartmental`, and
`DenseCompartmental`. Search does not change topology, node count, body structure, or ports.
The Falandays schema keeps `learn_on=true` because its evolved arm retains online plasticity.

An evolution operation writes a standard full record. If it stops after at least one
complete generation, continue the same record to its original iteration budget:

```julia
continued = BrainlessLab.Evolution.resume(record_directory; registry=DEFAULT_REGISTRY)
```

Use a recorded model in a later benchmark:

```julia
model = BrainlessLab.Evolution.model_reference(record_directory, "selected")
target = EvaluationTarget(:saved_model, composition, evaluation; model=model)
```

The `BenchmarkPlan` must name the saved model explicitly. A successful search is
development output, not scientific evidence.

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

A case with exactly one condition may omit `baseline`. It then reports the condition's raw
and normalised statistics and writes an empty contrasts table. A case with multiple
conditions must declare its baseline.

## Record contents

```text
record-id/
├── record.toml
├── request.toml
├── resolved.toml
├── environment/Manifest.toml
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
settings used by the executor. `environment/Manifest.toml` preserves the exact dependency
resolution used by the executor. `record.toml` inventories generated files and their
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

The checked example under `experiments/examples/structured-ctrnn-smoke/` is planned smoke
work. It searches one fixed CTRNN design. Its one-generation budget tests the protocol and
executor, not a scientific claim.

## Current and archived directories

- `plans/examples/` contains small standalone plan examples.
- `experiments/` contains current versioned `ExperimentSpec` bundles.
- `records/` and other selected roots contain generated operation records.
- `tools/` holds the calibration harness and the sweep CLI driver.

Do not revive the former bespoke experiment runner or add an operation-specific config schema. New repeated
work uses typed plans and the standard record writer.

## Public run contributions

Merge an `ExperimentSpec` and any required software before collecting a public contribution.
The run-only contribution must point to a clean source SHA that is reachable from `main`.

A contributor opens a draft, run-only pull request with `submission/`. The final validator
requires the maintainer replay, review fields, comparison, and acceptance decision, so it
does not validate a partial draft.

A maintainer runs the merged experiment at that exact SHA and adds `replay/` to the same
contribution. Compare the contributor and maintainer roles after both records exist:

```bash
julia --project=. bin/brainlesslab.jl compare-contribution DIR --write
```

`--write` updates the comparison artifact. It does not accept the contribution or change its
evidence state. The two roles belong to one contribution and are not independent samples.

After deciding to accept the contribution, complete its review fields and run the final
validation:

```bash
git fetch origin main
julia --project=. bin/brainlesslab.jl check-contribution DIR \
  --repository . --main-ref origin/main --base origin/main
```

Then rebuild the public index before merge:

```bash
julia --project=. bin/brainlesslab.jl index-research \
  --root research --output research/catalogue.json
```

The index contains paths and descriptive settings. It does not aggregate task outcomes, rank
records, or infer a scientific claim.

Aim for at most 1 MiB of text-only files in the complete contribution. The hard limit is
5 MiB. This Git-native pipeline does not accept files above that limit, and large datasets
remain out of scope.
