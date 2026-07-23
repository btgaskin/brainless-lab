---
name: brainless-lab
description: Guide for operating, extending, and interpreting BrainlessLab.jl, the Julia research platform for behaviour from self-organising neural substrates. Use for every task in the brainless-lab repository. Covers CompositionSpec, EvaluationSpec, typed registries, profile, sweep, ablation, evolution, benchmark plans, ExperimentSpec, versioned records, evidence boundaries, and node or task extension. Pair with the Julia skill for language, dispatch, inference, allocation, and package hygiene.
---

# BrainlessLab.jl

BrainlessLab studies what simple, locally governed neural units can do when coupled to
bodies and worlds. It supports node design, closed-loop tasks, repeated research
operations, and versioned experiments.

Always read the repository `AGENTS.md`. Pair this skill with the Julia skill whenever
Julia code is written or reviewed. Follow `docs/WRITING.md` for public prose.

## Preserve the architecture

```text
runtime
NodeSpec + TaskSpec + body + InteractionCycle
  → CompositionSpec
  → Reservoir + embodied agent(s) + Environment
  → SimResult

research
CompositionSpec + EvaluationSpec
  → EvaluationTarget
  → operation plan
  → typed result
  → record

named EvaluationTargets + operation plans
  → ExperimentSpec
```

Keep each type responsible for one level:

- `NodeSpec` owns the node builder, declared parameters, parameter sets, capabilities,
  equations, and default analyses. Node count belongs to `CompositionSpec`.
- `TaskSpec` owns setup, ports, interaction timing, raw outcome, anchors, descriptors, and
  experimental status. It does not own node parameters.
- `InteractionCycle` defines neural frames within one world step. It does not define trial
  replication.
- `CompositionSpec` records the complete runtime composition.
- `EvaluationSpec` defines blocks, trials per block, horizon, warm-up, construction scope,
  reset policy, root seed, named streams, and aggregation.
- `EvaluationTarget` names one composition with one evaluation protocol.
- `ExperimentSpec` records a scientific question, version, named conditions, operations,
  evidence state, limitations, and metadata. It is not another runner.

One `step!` lifecycle serves one agent and a population. Express differences through
typed bodies, tasks, readouts, interaction cycles, and registered implementations. Do not
add task-name or organism-name branches to the simulation loop.

## Choose the smallest valid path

Use `simulate` for one diagnostic run:

```julia
using BrainlessLab

sim = simulate(:tracking; node=:falandays, ticks=1000, seed=11)
task_outcome(sim)
```

The symbol form is a convenient façade. Construct a `CompositionSpec` when reusable work
must record node count, parameters, body, task options, and interaction timing.

Use an operation plan for repeated evaluation:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

`check` parses, validates, and resolves without simulation. `run` executes the plan and
writes one standard record. Do not introduce another YAML schema, bespoke callback
runner, or operation-specific protocol format.

## Use the five operations precisely

- `ProfilePlan` characterises one node/task composition with declared analyses. It records
  the channels required by those analyses and reports analysis failures.
- `SweepPlan` evaluates explicit or node-default parameter axes. Seeds are paired across
  cells. Call the output a development grid, not a confirmed optimum.
- `AblationPlan` compares an implicit baseline with registered interventions. Validation
  checks the intervention stage and required node capabilities. Inapplicable or unchanged
  interventions are errors, not silent no-ops.
- `EvolutionPlan` selects one registered node parameter set on a training target. Optimiser
  randomness is separate from evaluation streams. Held-out targets run only after
  champion selection.
- `BenchmarkPlan` compares declared conditions within each task under paired blocks. It
  reports task-specific outcomes and paired contrasts. It does not create a cross-task
  competence score.

Files under `plans/examples/` are executable syntax checks with small budgets. Versioned
study bundles live under `experiments/`.

Use `write_experiment` to write an `ExperimentSpec` as `experiment.toml` plus ordinary plan
files. `read_experiment` rejects inconsistent definitions of a repeated condition. The CLI
commands `check-experiment` and `run-experiment` validate or execute the bundle; each
operation still writes its own record.

## Interpret records correctly

Each operation writes a `brainlesslab-record` bundle:

```text
record-id/
├── record.toml
├── request.toml
├── resolved.toml
├── seeds.csv
├── data/
├── summary/
├── figures/
├── report/index.html
└── DONE
```

`request.toml` preserves the plan. `resolved.toml` records node defaults, task and body
options, interaction timing, evaluation settings, and operation-specific resolution.
`record.toml` inventories generated files and their SHA-256 checksums. CSV files are the
authoritative tables; HTML is a readable report over those data.

Shareable records must not contain host names or absolute local paths. `DONE` means record
generation completed. It does not mean the result is confirmed evidence.

## Keep reference and experimental claims narrow

`:falandays` is validated on declared reference trajectories from the Falandays
implementation. This validation covers the tested construction and update path. It does
not automatically cover every body, task, behavioural statistic, analysis, or biological
interpretation.

Tracking and Pong are the initial core benchmark tasks. Wall remains registered but is not
part of the core benchmark. The four Plank CartPole levels are experimental challenge
tasks. All use the general `EvaluationSpec`; there is no CartPole-specific evaluation
protocol.

Performance can reveal a capacity, limit, trade-off, or missing mechanism. Before
interpreting a poor score, check the task opportunity, body ports, control floor, horizon,
initialisation, and score definition.

## Extend nodes and tasks through public interfaces

Start from `examples/templates/new_project/`.

A node extension defines methods on imported BrainlessLab generics and registers a
`NodeSpec`. The builder receives a `NodeBuildContext` and resolved parameter values.
Declare:

- parameters and validators;
- whether each parameter belongs to the node or reservoir;
- default `:sweep`, `:evolve`, and optional connectivity parameter sets;
- capabilities used by ablations and tooling;
- equations and default analyses when known;
- stability and tags.

Do not infer evolvable parameters from struct fields. Keep runtime state out of the genome.
Online adaptation remains learning or plasticity even without a task loss, teacher, fitted
readout, or separate training phase.

A task extension registers a `TaskSpec` whose setup returns a `TaskSetup`. Validate port
widths before tick zero. A task may omit a scalar outcome and remain useful for profiling.
It cannot enter a scalar benchmark until it declares an outcome key and anchors.

Use `register!` with typed registries. Duplicate keys fail. Julia multiple dispatch remains
the extension mechanism; registries make implementations discoverable and configurable.

## Protect scientific evidence

Use the experiment evidence states:

```text
planned → exploratory → tuned → frozen → confirmed → promoted
```

`retired` records a withdrawn or superseded protocol. Keep calibration, development,
variance pilots, and held-out evaluation separate. The independent block or trial is the
usual inferential unit. Ticks and agents within one world do not multiply sample size.

Match the control to the claim. Random action, blind input, matched sham, mechanism
ablation, model baseline, and oracle policies answer different questions. Exact replay is
a regression control, not a causal null.

Use `task_outcome(sim)` for the declared task result. Report its key, raw score, normalised
score when used, blocks, trials, construction scope, reset, horizon, warm-up, and seed
policy. Normalised Tracking and Pong scores remain different quantities.

Treat criticality and information measures as estimator-dependent analyses. State their
nulls, assumptions, and finite-sample limits. Shared environmental drive can produce
apparent collective structure.

## Verify changes

For architecture or behaviour changes, run focused tests before the full package suite:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Build the locked site after guide or skill edits:

```bash
cd site
bun run build
```

Check `git diff --check`. Inspect the final diff for unrelated user changes. Keep the
checked-in and installed BrainlessLab skill identical only after code and documentation
agree.

## References

Read the relevant reference in full:

- `references/usage-and-workflows.md` for simulation, recording, results, and plots;
- `references/cli-tools.md` for plans, experiments, and records;
- `references/designing-nodes.md` for node and runtime-state design;
- `references/designing-environments-and-tasks.md` for tasks, bodies, ports, and worlds;
- `references/designing-analyses.md` for analysis and null design;
- `references/research-workflow.md` for evidence and interpretation;
- `references/agentic-safeguards.md` for safe agent operation.
