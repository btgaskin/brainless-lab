# BrainlessLab New Project Template

This directory is a copy-and-edit scaffold for a group project that uses BrainlessLab.jl without forking the framework. The worked example is deliberately Falandays-style: a small online-plastic reservoir self-organizes during the rollout. There is no evolution step.

If you do not write Julia, ask a coding agent to read the repository root `AGENTS.md`, then
copy and adapt this template from a plain-language task description. The agent should propose
observations, actions, metrics, controls, and calibration before editing.

## Files

- `my_node.jl` defines `MyNode <: Reservoir`, then registers a typed `NodeSpec` with parameters, capabilities, and default sweep/evolution sets.
- `my_task.jl` defines `MyTrackingEnv <: TaskWorld`, wraps it in a `TaskSpec`, then registers the task in `DEFAULT_REGISTRY`.
- `my_metric.jl` registers a small metric function as `:final_error_abs`, requested by symbol in `run.jl`.
- `run.jl` includes those files, runs one explicit `CompositionSpec`, prints metrics, and saves a Makie figure.
- `config.toml` is a version-one `ProfilePlan` using the same node, task, and evaluation contracts as every built-in operation.
- `run_plan.jl` loads the extension, executes `config.toml`, and writes the standard portable record.

## Setup

From this directory while the template remains inside a BrainlessLab checkout:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path="../../.."); Pkg.instantiate()'
```

Run the example with this template environment:

```bash
julia --project=. run.jl
```

The template `Project.toml` depends on `BrainlessLab` and `CairoMakie`.
`Pkg.develop(path="../../..")` points this in-repository copy at the local framework
checkout. After copying the template elsewhere, install the public package source instead:

```bash
julia --project=. -e 'using Pkg; Pkg.add(url="https://github.com/btgaskin/brainless-lab"); Pkg.instantiate()'
```

Once BrainlessLab is registered in Julia General, `Pkg.add("BrainlessLab")` becomes the
normal installation path.

## First Result

```bash
julia --project=. run.jl --ticks 300 --seed 1 --n-nodes 80
```

Artifacts:

- Printed task metrics, including `score`, `mean_abs_error`, `final_error`, liveness, and the registered custom `final_error_abs`.
- `output/my_task_my_node_visualize.png`, containing spike raster, population firing rate, and spike-pattern drift panels.

Then run the repeatable profile:

```bash
julia --project=. run_plan.jl config.toml records
```

Open `records/<record-id>/report/index.html`, or inspect the authoritative CSV tables and
the checksums in `record.toml`.

## Node Contract

A high-level node registered for `simulate` must be callable as:

```julia
MyNode(n_nodes, n_receptors, n_effectors; seed=0, kwargs...)
```

and must implement:

```julia
step!(node, receptors)      # returns a spike vector
effectors(node, spikes)     # maps spikes to the task effector vector
effectors(node)             # optional convenience method
reset!(node)                # resets dynamic rollout state
n_nodes(node)               # keeps an inactive body's stable agent slot sized correctly
n_receptors(node)
n_effectors(node)
```

`my_node.jl` also implements `snapshot_state` and `load_state!` to show the parameter/state split. `MyNodeParams` is static configuration; `acts`, `targets`, `spikes`, `errors`, and `wmat` are rollout state.

The public `NodeSpec` builder receives a `NodeBuildContext` and the fully resolved parameter
dictionary. The context supplies node count, body ports, named seeds, and any receptor
profile. `ParameterSpec` declares validation, default sweep values, evolution bounds, and
ownership. Here `link_p` is reservoir-owned connectivity while node count remains part of
the composition.

Important Julia gotcha: when extending BrainlessLab generics from outside the package, import the names you extend:

```julia
import BrainlessLab: step!, effectors, n_nodes, n_receptors, n_effectors, reset!
```

Do not rely on `using BrainlessLab` for method extension. Without `import`, Julia may create or call the wrong method surface, and `simulate` will not see your node contract.

## Task Contract

A single-agent task is a `TaskSpec` around a `TaskWorld`. The task world must implement:

```julia
sense(env)                  # returns the receptor vector
step!(env, effectors)       # advances the world one tick
reset!(env)
metrics(env, window)
n_receptors(env or Type)
n_effectors(env or Type)
default_ticks(env or Type)
default_window(env or Type)
```

`my_task.jl` keeps the task small: a one-dimensional agent tracks a sinusoidal target. Two receptors encode whether the target is to the right or left. Two effectors push right or left. The score is `1 - mean_abs_error / 2`, clamped to `[0, 1]`.

This template uses an already-vectorized `TaskWorld`, so the task setup supplies a direct
`Embodiment`: sensor and encoder relay the receptor vector, while the direct actuator relays
the task-specific effector vector. For a physical/ecological project, compose an
`Embodiment` from geometry, sensors, encoders, an actuator, compatible dynamics, and optional
physiology, then place it in an `ObjectWorld`. Start from one of
`../../embodiments/*.toml`; let `portspec(body)` determine the reservoir dimensions.

Component and port IDs should be stable names, not inferred tuple positions. New physical
sensors extend `sample_world_sensor!(sensor, world, motion_state)`, returning the sensor's
raw sample vector; body encoders still own the conversion to reservoir receptors.

## Custom Metric

`my_metric.jl` demonstrates the registry pattern:

```julia
register_metric!(:final_error_abs, final_error_abs)
```

In `run.jl`, the simulation requests the metric with `metrics=[:final_error_abs]`; the high-level runner resolves the symbol and appends the derived value to `sim.metrics`.

## Operations

`config.toml` uses the single `brainlesslab-plan` schema. Change `operation` and its final
section to profile, sweep, ablate, evolve, or benchmark. The target composition and
evaluation section stay the same.

The node's `:sweep` and `:evolve` parameter sets provide defaults. A plan can instead name
explicit sweep axes or another registered parameter set. Benchmark conditions reference
registered nodes and tasks but remain task-specific; registering a component does not
automatically qualify it for a benchmark.

## Make It Your Own

1. Copy this directory outside the framework checkout or rename it in place.
2. Rename `MyNode`, `MyNodeParams`, `MyTrackingEnv`, `MY_TASK`, `:my_node`, and `:my_task`.
3. Keep receptor and effector counts aligned: for a vector task, `TaskSpec.n_receptors` must match `sense(env)`; for a composed body, use `portspec(body)` as the source of truth.
4. Keep online plasticity inside `step!`; no evolution is needed for a Falandays-style first experiment.
5. Add task-specific metrics to `metrics(env, window)` first. Use `register_metric!` for reusable analysis functions that can be resolved by symbol.
6. Start with `simulate` and `visualize`; move to `ProfilePlan`, `SweepPlan`, or
   `BenchmarkPlan` only after the single composition behaves sensibly.

## Read More

The docs live in the Astro/Starlight site (<https://brainless-lab.pages.dev>, or `cd site && bun run dev`):

- [Nodes — overview](https://brainless-lab.pages.dev/nodes/overview/)
- [Environments & Tasks](https://brainless-lab.pages.dev/environments-tasks/)
- [Embodiment](https://brainless-lab.pages.dev/receptors-effectors/)
- [Extending it](https://brainless-lab.pages.dev/extending/)
- [Research workflow](https://brainless-lab.pages.dev/research-workflow/)
- [Agentic workflow](https://brainless-lab.pages.dev/agentic-workflow/)
- [Operations and records](https://brainless-lab.pages.dev/core/tools-artifacts/)
