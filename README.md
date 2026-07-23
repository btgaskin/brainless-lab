# BrainlessLab.jl

[![CI](https://github.com/btgaskin/brainless-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/btgaskin/brainless-lab/actions/workflows/ci.yml)

<p align="center"><img src="brainless-lab.png" alt="BrainlessLab" width="760"></p>

<p align="center">
  <em>Behaviour from collectives of simple neuron-like nodes.</em><br>
  <a href="https://brainless-lab.pages.dev/core/getting-started/"><strong>Core handbook</strong></a>
  &middot;
  <a href="https://brainless-lab.pages.dev/experimental/">Experimental catalog</a>
  &middot;
  <a href="https://disi.org">Diverse Intelligences Summer Institute 2026</a>
</p>

BrainlessLab v0.2.0 is an **experimental research preview** for neural reservoirs in
closed sensorimotor loops. It provides tasks, generic embodiment, single-agent and
population worlds, recording, analysis, batch tools, and evidence-aware experiment
workflows. APIs and artifact layouts may change before 1.0.

The canonical baseline is `node=:falandays`: an authors-faithful implementation of the
tested Falandays homeostatic spiking reservoir. It adapts neural activity online and has no
trained readout. Other reservoirs, embodiment components, physical worlds, analyses, and
studies are experimental unless their documentation states a narrower validated boundary.

## Quickstart

BrainlessLab is not yet registered in Julia General. Install Julia 1.10 or newer,
clone the repository, and use its pinned project:

```bash
git clone https://github.com/btgaskin/brainless-lab.git
cd brainless-lab
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Run the canonical reservoir on tracking:

```bash
julia --project=. -e 'using BrainlessLab; sim = simulate(:tracking; node=:falandays, ticks=1000, seed=11); println(task_outcome(sim))'
```

`task_outcome(sim)` returns the task-declared outcome key, raw value, and value normalized
between that task's anchors. It returns `nothing` for a task with no scalar objective.
Scores are task-specific. Do not compare a tracking score directly with a Pong or forage
score.

Continue with:

1. [Getting started](https://brainless-lab.pages.dev/core/getting-started/)
2. [Core task tour](https://brainless-lab.pages.dev/core/task-tour/)
3. [Architecture](https://brainless-lab.pages.dev/core/architecture/)
4. [Design a study](https://brainless-lab.pages.dev/core/design-study/)

For a repeatable multi-run operation, validate a checked-in plan and write one portable
record:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
julia -t auto --project=. bin/brainlesslab.jl run plans/examples/profile_tracking.toml --root records
```

Every operation writes the same record shape: the request, fully resolved settings, seed
ledger, raw CSV tables, summary statistics, checksums, and a generated HTML report.

## Core composition

```text
NodeSpec + TaskSpec + body + InteractionCycle → CompositionSpec → closed-loop runtime
CompositionSpec + EvaluationSpec              → EvaluationTarget
EvaluationTarget(s)                           → operation plan → record
named conditions + operation plans            → ExperimentSpec
```

`AbstractBody` is the public body boundary. `Embodiment` is the generic concrete
composition of geometry, sensors, encoders, readouts, actuators, dynamics, optional physiology,
stable ports, and runtime state. An `Ensemble` of one and an ensemble of many use the same
synchronous lifecycle.

`FixedRateCycle` explicitly separates a world step from native neural frames. This supports
held inputs, temporal spike encoders, mean or instant reduction, and categorical voting
without putting task-specific timing branches into the simulation loop. Four experimental
Plank CartPole task profiles use this seam as an experimental proving ground;
Tracking and Pong remain the initial core benchmark tasks.

`ObjectWorld` demonstrates composition of physical components, objects, fields, spectral
appearance, and typed effects. It is not a calibrated benchmark. The established tracking
and Pong tasks are the first core task contracts.

## Discover the live surface

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

`DEFAULT_REGISTRY` is the canonical composition and operation catalog. The zero-argument
`variants()`, `tasks()`, and related registration helpers remain only for the established
interactive `simulate(:task; node=:node)` façade and older research scripts; do not use
them for new plans or extensions.

## Execution surfaces

- `simulate` runs one closed loop and returns an in-memory `SimResult`.
- `ProfilePlan` characterizes one registered node on one registered task.
- `SweepPlan` maps declared node parameters under paired evaluation seeds.
- `AblationPlan` disables registered functional elements against an implicit baseline.
- `EvolutionPlan` selects parameters on one target and evaluates the champion on declared
  held-out targets.
- `BenchmarkPlan` reports paired within-task comparisons without forming a cross-task score.
- `ExperimentSpec` registers a versioned scientific protocol above one or more operations.

All five operations use the same version-one TOML schema and record writer. The older
specialized directories remain research code, but they are no longer the canonical public
workflow. Start with the smallest operation that can answer the question. A selected sweep
cell is a development result, not a confirmed optimum. Agents and ticks in one world do not
increase the number of independent experimental units.

See [Tools and artifacts](https://brainless-lab.pages.dev/core/tools-artifacts/) and
[Runs, recording, and results](https://brainless-lab.pages.dev/core/runs-results/).

## Extend the lab

Public extension uses Julia generics and optional registries. Prefer composition and
multiple dispatch to model-name branches. Import every package generic that receives a new
method.

Copy-ready starting points:

- `examples/templates/new_project/` for a node, vector task, and metric;
- `examples/embodiments/` for strict embodiment TOML and `ObjectWorld` composition.

Read [Extend the lab](https://brainless-lab.pages.dev/core/extend/) before adding a public
part.

## Agent-assisted use

The repository includes `AGENTS.md` plus BrainlessLab and Julia skills. A compatible coding
agent can discover the public surface, run existing tools, explain outputs, and implement
bounded changes. The researcher still owns the question, risk boundary, interpretation,
and decision to promote evidence.

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
cd site
bun install
bun run build
```

The compute core has no Makie dependency. Load `CairoMakie` in a downstream or tool project
for saved figures and animations. Load `GLMakie` for an interactive window.

See [CONTRIBUTING.md](CONTRIBUTING.md), [CITATION.cff](CITATION.cff), and the
[MIT license](LICENSE).
