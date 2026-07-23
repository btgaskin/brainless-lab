---
name: brainless-lab
description: Guide for operating, extending, and interpreting BrainlessLab.jl, the Julia research platform for behavior from self-organising neural substrates. Use for every task in the brainless-lab repository. Covers CompositionSpec, EvaluationSpec, typed registries, profile/sweep/ablation/evolution/benchmark plans, ExperimentSpec, version-one records, evidence boundaries, and node/task extension. Pair with the Julia skill for language, dispatch, inference, allocation, and package hygiene.
---

# BrainlessLab.jl

BrainlessLab is a research platform for asking what simple, locally governed neural units
can do when coupled to bodies and worlds. It is not one model and it is not a leaderboard.
Its public value is a clean way to design a node, compose it with a sensorimotor task,
measure performance and dynamics, and preserve the exact protocol and evidence surface.

Always read the repository `AGENTS.md`. Pair this skill with the Julia skill whenever code
is written or reviewed.

## The architecture to preserve

There are two ladders:

```text
runtime
NodeSpec + TaskSpec + body + InteractionCycle
  → CompositionSpec → Reservoir + embodied agent(s) + Environment → SimResult

research
CompositionSpec + EvaluationSpec
  → EvaluationTarget → operation plan → typed result → research record
named EvaluationTargets + operation plans
  → ExperimentSpec
```

Keep the boundaries explicit:

- `NodeSpec` owns the node builder, declared parameters, parameter sets, capabilities,
  equations, and default analyses. Node count belongs to `CompositionSpec`, not the node
  parameter genome. Connectivity may be reservoir-owned and should say so in
  `ParameterSpec.owner`.
- `TaskSpec` owns setup, ports, interaction timing, raw outcome, anchors, descriptors, and
  experimental status. It does not own node parameters.
- `InteractionCycle` governs neural frames inside one world step. It does not govern trial
  replication.
- `EvaluationSpec` is the only outer evaluation protocol: blocks, trials per block,
  horizon, warm-up, construction scope, reset, root seed, named streams, and aggregation.
- `ExperimentSpec` is the scientific envelope above operations: version, question, named
  conditions, evidence state, limitations, and metadata. It is not another runner.

One `step!` lifecycle serves a single agent and a population. Do not create task- or
organism-name branches inside the simulation loop when a typed body, task, readout,
interaction cycle, or registered implementation expresses the distinction.

## Start with the smallest surface

For one diagnostic run:

```julia
using BrainlessLab

sim = simulate(:tracking; node=:falandays, ticks=1000, seed=11)
task_outcome(sim)
```

The symbol/keyword form remains a friendly façade. New reusable work should construct a
`CompositionSpec` so node count, parameters, body, task options, and interaction timing are
explicit.

For a repeated operation, use the one plan path:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

`check` must parse, validate, and resolve without simulation. `run` executes the operation
and writes the record. Do not introduce another YAML schema, operation-specific protocol,
or independent configuration path.

## The five operations

- `ProfilePlan`: characterize one node/task composition with declared analyses. The
  executor unions required recorder channels and reports analysis failures explicitly.
- `SweepPlan`: evaluate explicit or node-default parameter axes. Seeds are paired across
  cells. Call the result a development grid, never a confirmed optimum.
- `AblationPlan`: compare an implicit baseline with registered capability-checked
  interventions. An ablation must declare its stage and required capabilities and must not
  silently no-op.
- `EvolutionPlan`: select a registered node parameter set on one training target. Optimizer
  randomness is separate from evaluation streams. Held-out targets run only after champion
  selection. Candidate evaluations run in parallel when Julia has multiple threads, while
  records retain every candidate's trial outcomes and seeds.
- `BenchmarkPlan`: compare declared conditions within each task under paired blocks. Report
  raw and normalized Student-t intervals and paired contrasts, keep tasks separate, and do
  not form a cross-task aggregate merely because scores are normalized.

Checked-in smoke plans live in `plans/examples/`. The reciprocal evolution examples encode
the intended first flagship direction: evolve Falandays parameters on Tracking, then test
on fresh Tracking seeds and held-out Pong; reverse the direction for Pong. They are small
executable examples, not finished evidence.

Use `write_experiment` to publish an `ExperimentSpec` as one strict manifest plus its
ordinary operation plan files. `read_experiment` validates that repeated condition names
have identical definitions. The unified CLI provides `check-experiment` and
`run-experiment`; every contained operation still produces its own standard record.

## Records are the evidence surface

Every operation writes `brainlesslab-record`, format version 1:

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

The request and executed result must correspond exactly. `resolved.toml` must contain full
node defaults, task/body options, interaction timing, evaluation settings, and
operation-specific resolution. `record.toml` must derive Git provenance from the package
checkout, enumerate every generated artifact, and include SHA-256 checksums. Shareable
records must not include hostnames or absolute local paths.

CSV is the authoritative tabular format. The generated HTML is a readable view over the
same typed result: method, tables, node equations, and convergence where relevant. `DONE`
means the bundle completed; `FAILED` means it did not. A complete record is not
automatically confirmed evidence.

## Reference and experimental boundaries

`:falandays` is the authors-faithful reference node on the declared trajectory fixtures.
That claim does not transfer automatically to a body, task, behavioral statistic,
analysis, or biological interpretation. Preserve its update equations, initialization,
and task presets unless a deliberate divergence is documented and tested.

Tracking and Pong are the initial core benchmark tasks. Wall remains registered but is not
core qualification. The four Plank CartPole levels are experimental challenge tasks. They
use the general `EvaluationSpec`; there is no CartPole-specific evaluation protocol. Do not
average their levels or the core tasks into a generic competence number.

Performance can be informative without being a success story. A task can expose a limit,
a trade-off, or missing capacity. Before interpreting failure, verify the task opportunity,
body and port contract, null/controller floor, horizon, initialization, and score.

## Extending nodes and tasks

Start from `examples/templates/new_project/`.

A node extension defines methods on imported BrainlessLab generics, then registers a
`NodeSpec`. The builder receives `NodeBuildContext` and resolved values. Declare:

- parameters and validators;
- `owner` for node or reservoir concerns;
- default `:sweep`, `:evolve`, and optional connectivity parameter sets;
- capabilities used by ablations and tooling;
- equations and default analyses when known;
- stability and tags.

Do not infer a node's evolvable surface from struct fields. Do not place runtime state in
the genome. Online adaptation remains runtime behavior even when there is no task loss,
teacher, fitted readout, or separate training phase.

A task extension registers a `TaskSpec` with a setup returning a `TaskSetup`. Port widths
must be validated before tick zero. A task may omit a scalar outcome; it remains valid for
profiling or descriptive work but cannot enter a scalar benchmark until it declares an
outcome contract and anchors.

Use `register!` on typed registries. Duplicate keys fail. Julia multiple dispatch is still
the extension mechanism; registries make implementations discoverable and configurable.

## Scientific discipline

Use the evidence ladder: planned → exploratory → tuned → frozen → confirmed → promoted.
Keep calibration, development, variance pilots, and held-out evaluation separate. The
independent randomized block or trial is normally the inferential unit; ticks and agents in
one world do not multiply sample size.

Match the control to the claim. Random action, blind input, matched sham, mechanism
ablation, model baseline, and oracle answer different questions. Exact replay is a
regression control, not a causal null.

Use `task_outcome(sim)` for the declared task result. Report raw score, normalized score if
used, viability gates, blocks/trials, construction scope, reset, horizon, warm-up, and seed
policy. A normalized Tracking value and normalized Pong value are still different
quantities.

Criticality and information measures require nulls and estimator caveats. Prefer MR
branching estimates to naive slopes, use windowed analyses for non-stationary processes,
and treat apparent collective structure as shared drive until a suitable surrogate test is
cleared.

## Verification

For architecture or behavior changes, run the narrow tests first, then the root suite in
the pinned project. Preserve authors-parity fixtures. Build the locked site after handbook
or skill edits. Check `git diff --check` and inspect the final diff for unrelated user work.

The canonical documentation is under `site/src/content/docs/core/`. Historical experiment
pages may describe older bespoke scripts; do not treat them as the public platform
contract. The checked-in skill and installed copy should be updated only after code and
docs agree.

## References

Read the relevant reference in full when needed:

- `references/usage-and-workflows.md` for interactive simulation, recording, and plots;
- `references/cli-tools.md` for the unified plan CLI, schemas, operations, and records;
- `references/designing-nodes.md` for node/runtime-state design;
- `references/designing-environments-and-tasks.md` for task, body, ports, and worlds;
- `references/designing-analyses.md` for analysis and null contracts;
- `references/research-workflow.md` for evidence and interpretation;
- `references/agentic-safeguards.md` for safe agent operation.
