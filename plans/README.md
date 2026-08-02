# Operation plans

This directory contains strict `brainlesslab-plan` TOML files. Each plan combines one or
more `EvaluationTarget`s with one research operation:

```text
CompositionSpec + EvaluationSpec
  → EvaluationTarget
  → ProfilePlan | SweepPlan | AblationPlan | EvolutionPlan | BenchmarkPlan
  → record
```

The current writer emits `format_version = 2`. Version 1 remains readable for
non-evolution plans. Evolution plans require version 2 and `[evolve.run]`.

Validate a plan without simulation:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
```

Run it and write a portable record:

```bash
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

Files under `plans/examples/` use small replication budgets and the minimum scored interval
declared by each task. They demonstrate plan syntax and validation, not benchmark evidence.
`check` rejects a scored target when `horizon - warmup` is below that task minimum.

## Evolution plans

An `EvolutionPlan` embeds `BrainlessLab.Evolution.RunConfig`. The configuration declares
the search strategy, iteration budget, search seed, measure, direction, explicit normal
initialisation, and strategy options.

```toml
[evolve]
training = ["tracking_development"]
heldout = ["tracking_heldout"]

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

The public typed strategy registry contains `sepcma`, `nsga2`, and `cmame`. Any registered
node that declares a reviewed `Evolution.NodeDesignSpec` can use an evolution plan. The
built-in fixed designs cover `FalandaysParams`, `StructuredCompartmental`, and
`DenseCompartmental`. Search does not change topology, node count, body structure, or ports.

Every evolution operation writes a standard full record. An interrupted record can resume
in place from its last complete generation:

```julia
Evolution.resume(record_directory; registry=DEFAULT_REGISTRY)
```

SepCMA records the stable model role `selected`. NSGA-II and CMA-ME write ordered model
sets, so a later operation must name a model explicitly. Attach a portable model reference
to a new evaluation target:

```julia
model = Evolution.model_reference(record_directory, "selected")
target = EvaluationTarget(:saved_model, composition, evaluation; model=model)
```

Use that target in a later `BenchmarkPlan`. A completed search is experimental software
output. It is not scientific evidence by itself.

A versioned scientific protocol belongs under [`../experiments/`](../experiments/).
`ExperimentSpec` names its conditions and refers to ordinary operation plans, so the
experiment and standalone paths use the same executor and record format.
