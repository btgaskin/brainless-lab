# BrainlessLab New Project Template

This directory is a copy-and-edit scaffold for a group project that uses BrainlessLab.jl without forking the framework. The worked example is deliberately Falandays-style: a small online-plastic reservoir self-organizes during the rollout. There is no evolution step.

## Files

- `my_node.jl` defines `MyNode <: Reservoir`, a leaky homeostatic reservoir with online recurrent-weight and target adaptation, then registers it as `:my_node`.
- `my_task.jl` defines `MyTrackingEnv <: TaskWorld`, wraps it in a `TaskSpec`, then registers it as `:my_task`.
- `my_metric.jl` registers a small metric function as `:final_error_abs`, requested by symbol in `run.jl`.
- `run.jl` includes those three files, runs `simulate(:my_task; node=:my_node)`, prints metrics, and saves a Makie figure.
- `config.toml` is a benchmark config snippet that follows `bench/configs/core.toml`.

## Setup

From this directory:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path="../../.."); Pkg.instantiate()'
```

Run the example with this template environment:

```bash
julia --project=. run.jl
```

The template `Project.toml` depends on `BrainlessLab` and `CairoMakie`. `Pkg.develop(path="../../..")` points the template environment at the local framework checkout, so you can copy this directory into your own project and keep using the framework as a dependency instead of editing `src/`.

## First Result

```bash
julia --project=. run.jl --ticks 300 --seed 1 --n-nodes 80
```

Artifacts:

- Printed task metrics, including `score`, `mean_abs_error`, `final_error`, liveness, and the registered custom `final_error_abs`.
- `output/my_task_my_node_visualize.png`, containing spike raster, population firing rate, and spike-pattern drift panels.

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
n_receptors(node)
n_effectors(node)
```

`my_node.jl` also implements `snapshot_state` and `load_state!` to show the parameter/state split. `MyNodeParams` is static configuration; `acts`, `targets`, `spikes`, `errors`, and `wmat` are rollout state. The registration declares `genome_type=MyNodeParams`, so `rollout` and `evolve` can derive the genome dimension through `paramdim`, `pack_params`, and `unpack_params`.

Important Julia gotcha: when extending BrainlessLab generics from outside the package, import the names you extend:

```julia
import BrainlessLab: step!, effectors, n_receptors, n_effectors, reset!
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

## Custom Metric

`my_metric.jl` demonstrates the registry pattern:

```julia
register_metric!(:final_error_abs, final_error_abs)
```

In `run.jl`, the simulation requests the metric with `metrics=[:final_error_abs]`; the high-level runner resolves the symbol and appends the derived value to `sim.metrics`.

## Benchmark

`config.toml` follows the schema in `../../../bench/configs/core.toml`:

```toml
neurons = ["falandays_base", "my_node"]
tasks = ["my_task"]
n_trials = 5
n_nodes = 80
ticks = 300
baseline = "falandays_base"

[prep]
my_node = "untrained"
```

The benchmark runner loads registered BrainlessLab symbols, then uses the node's declared `genome_type` to stamp parameters through the public `NodeModel` contract. No framework fork or private-symbol bridge is needed.

From the repo root, after setting up `bench/` as described in `../../../bench/README.md`, run:

```bash
julia --project=bench -e 'include("examples/templates/new_project/my_node.jl"); include("examples/templates/new_project/my_task.jl"); include("bench/Benchmark.jl"); using .Benchmark; cfg = Benchmark.read_bench_config("examples/templates/new_project/config.toml"); result = Benchmark.run_benchmark(cfg); println(result.dir); Benchmark.print_short_summary(result.summaries)'
```

Benchmark artifacts are written under `bench/runs/` and include resolved config, manifest, raw trial CSV, summary CSV, stats JSON, report Markdown, plots, and per-cell figures.

## Make It Your Own

1. Copy this directory outside the framework checkout or rename it in place.
2. Rename `MyNode`, `MyNodeParams`, `MyTrackingEnv`, `MY_TASK`, `:my_node`, and `:my_task`.
3. Keep receptor and effector counts aligned: `TaskSpec.n_receptors` must match the vector from `sense(env)`, and the node constructor receives that count.
4. Keep online plasticity inside `step!`; no evolution is needed for a Falandays-style first experiment.
5. Add task-specific metrics to `metrics(env, window)` first. Use `register_metric!` for reusable analysis functions that can be resolved by symbol.
6. Start with `simulate` and `visualize`; move to `bench/` only after the single run behaves sensibly.

## Read More

The docs live in the Astro/Starlight site (<https://brainless-lab.pages.dev>, or `cd site && bun run dev`):

- [Nodes — overview](https://brainless-lab.pages.dev/nodes/overview/)
- [Environments & Tasks](https://brainless-lab.pages.dev/environments-tasks/)
- [Receptors & Effectors](https://brainless-lab.pages.dev/receptors-effectors/)
- [Extending it](https://brainless-lab.pages.dev/extending/)
- `../../../bench/README.md`
