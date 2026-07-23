# BrainlessLab.jl

[![CI](https://github.com/btgaskin/brainless-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/btgaskin/brainless-lab/actions/workflows/ci.yml)

<p align="center"><img src="brainless-lab.png" alt="BrainlessLab" width="760"></p>

<p align="center">
  <em>Behaviour from collectives of simple neuron-like nodes.</em><br>
  <a href="https://brainless-lab.pages.dev/core/getting-started/">Getting started</a>
  &middot;
  <a href="https://brainless-lab.pages.dev/core/operations-records/">Operations and records</a>
  &middot;
  <a href="https://brainless-lab.pages.dev/experimental/">Experimental capabilities</a>
</p>

BrainlessLab is an experimental Julia platform for studying neural reservoirs in closed
sensorimotor loops. It separates four concerns:

- a node type and its registered parameters;
- a body, task, and interaction cycle;
- an evaluation protocol over independent trials;
- a research operation that writes a portable record.

The canonical `:falandays` node is validated against declared reference trajectories.
That validation covers the tested construction and update path. It does not establish
behavioural equivalence across every task or validate a biological interpretation.

## Quick start

BrainlessLab is not yet registered in Julia General. Clone the repository and use its
project environment:

```bash
git clone https://github.com/btgaskin/brainless-lab.git
cd brainless-lab
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Run one diagnostic simulation:

```bash
julia --project=. -e 'using BrainlessLab; sim = simulate(:tracking; node=:falandays, ticks=1000, seed=11); println(task_outcome(sim))'
```

`task_outcome(sim)` returns the task's outcome key, raw value, and normalised value. It
returns `nothing` when the task declares no scalar outcome. Scores remain task-specific,
even after normalisation.

The public guide starts with:

1. [Getting started](https://brainless-lab.pages.dev/core/getting-started/)
2. [Core task tour](https://brainless-lab.pages.dev/core/task-tour/)
3. [Architecture](https://brainless-lab.pages.dev/core/architecture/)
4. [Design a study](https://brainless-lab.pages.dev/core/design-study/)

## Compose a run, then choose an operation

```text
NodeSpec + TaskSpec + body + InteractionCycle
  → CompositionSpec

CompositionSpec + EvaluationSpec
  → EvaluationTarget

EvaluationTarget(s) + operation settings
  → ProfilePlan | SweepPlan | AblationPlan | EvolutionPlan | BenchmarkPlan
  → versioned record

named conditions + operation plans
  → ExperimentSpec
```

`simulate` is the convenient path for one in-memory run. A `CompositionSpec` records the
same runtime choices explicitly and is the preferred input for reusable work.

For repeated work, validate and run a plan:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

Each operation writes its request, resolved settings, seed ledger, CSV tables, summary,
checksums, and HTML report. `ExperimentSpec` groups named conditions and ordinary
operation plans into a versioned scientific protocol. It does not add another runner.

The five operations answer different questions:

- `ProfilePlan` describes one composition and its recorded dynamics.
- `SweepPlan` maps declared parameter values on development trials.
- `AblationPlan` compares registered interventions with a paired baseline.
- `EvolutionPlan` selects node parameters on one target, then evaluates the champion on
  declared held-out targets.
- `BenchmarkPlan` compares conditions within each task under paired evaluation blocks.

See [Operations and records](https://brainless-lab.pages.dev/core/operations-records/) and
[Runs and results](https://brainless-lab.pages.dev/core/runs-results/).

## Discover registered parts

```julia
using BrainlessLab

nodes(DEFAULT_REGISTRY)
tasks(DEFAULT_REGISTRY)
tasks(DEFAULT_REGISTRY; tag=:benchmark)
analyses(DEFAULT_REGISTRY)
ablations(DEFAULT_REGISTRY)
compositions(DEFAULT_REGISTRY)
components()
readiness()
```

The registry supports discovery and configuration by name. Julia methods and direct
composition remain the extension mechanism.

## Extend the lab

Start from `examples/templates/new_project/` when adding a node, vector task, or analysis.
Start from `examples/embodiments/` when composing a physical body and `ObjectWorld`.

Keep node dynamics independent of task names. Derive receptor and effector widths from the
body ports. Register parameters explicitly so sweeps and evolution do not infer a genome
from runtime fields.

Read [Extend the lab](https://brainless-lab.pages.dev/core/extend/) and
[Interface contracts](https://brainless-lab.pages.dev/contracts/) before adding a public
part.

## Scientific limits

Tracking and Pong form the initial core benchmark. The four Plank CartPole levels are
experimental challenge tasks. Wall and ecological tasks remain available for exploratory
work but are not part of the core benchmark.

A score can reveal a capacity, limit, or trade-off. It does not, by itself, establish
cognition, general competence, biological fidelity, or external validity. Keep
development, selection, and held-out evaluation seeds separate.

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
cd site
bun install
bun run build
```

The compute package has no Makie dependency. Use a downstream or tool environment with
`CairoMakie` for saved figures and `GLMakie` for interactive windows.

See [CONTRIBUTING.md](CONTRIBUTING.md), [CITATION.cff](CITATION.cff), and the
[MIT licence](LICENSE).
