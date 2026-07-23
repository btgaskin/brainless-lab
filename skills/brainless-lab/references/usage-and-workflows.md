# Usage and workflows

Use this reference for interactive simulation, result inspection, recording, and plots.
Use `cli-tools.md` when a question requires repeated trials or a portable record.

## Run one simulation

```julia
using BrainlessLab

sim = simulate(:tracking; node=:falandays, ticks=1000, seed=11)
task_outcome(sim)
```

The symbol form constructs a registered task and node, runs one closed loop, and returns a
`SimResult`. It is useful for diagnostics and exploration. Reusable work should construct
a `CompositionSpec`; repeated evaluation should use an operation plan.

A `SimResult` contains:

- `recorder`, with sampled channels;
- `metrics`, with the task outcome and diagnostics;
- task and node identifiers;
- a configuration snapshot for the completed run.

## Discover registered parts

Query `DEFAULT_REGISTRY` instead of copying symbol lists:

```julia
nodes(DEFAULT_REGISTRY)
tasks(DEFAULT_REGISTRY)
tasks(DEFAULT_REGISTRY; tag=:benchmark)
analyses(DEFAULT_REGISTRY)
analyses(DEFAULT_REGISTRY; task=:tracking)
ablations(DEFAULT_REGISTRY)
compositions(DEFAULT_REGISTRY)
components()
readiness()
```

Typed queries are the source for new plans and extensions. Zero-argument discovery
functions remain available for the older symbol-based `simulate` façade.

## Common `simulate` options

`simulate(task::Symbol; node=:falandays, ...)` accepts:

- `ticks`: rollout length;
- `seed`: root seed for the diagnostic run;
- `record`: recorder channels;
- `every`: recorder sampling interval;
- `spectral_every`: sampling interval for the costly spectral-radius channel;
- `n_nodes` or `N`: reservoir width;
- `window`: trailing window for end-of-run metrics;
- `n_agents`: population size for tasks that support it;
- `body`: an `AbstractBody`, registered body name, or body constructor;
- `node_kwargs`, `env_kwargs`, and `swarm_kwargs`: explicit option groups;
- `metrics`: extra end-of-run analyses.

The interactive `ablation` keyword is a compatibility path and may record a no-op when the
intervention does not apply. Do not use that behaviour for a causal study. Use an
`AblationPlan`, which validates capabilities and fails if an intervention is inapplicable
or leaves the composition unchanged.

Falandays parameter options such as `leak`, `lrate_wmat`, `lrate_targ`, `input_amp`,
`threshold_mult`, `weight_init_mode`, `topology`, `sign`, and `drive` may be passed in the
node option group. Prefer an explicit `CompositionSpec` when these values must be retained
as a reusable condition.

## Read the declared task outcome

```julia
outcome = task_outcome(sim)
```

When the task declares a scalar outcome, the result contains:

- `key`: the task's outcome name;
- `raw`: the task-specific value;
- `normalized`: the value mapped between the task's declared anchors.

The function returns `nothing` when the task has no scalar outcome. Other fields under
`sim.metrics` are diagnostics unless the `TaskSpec` declares them as the outcome.

Raw outcomes are not comparable across tasks. Normalisation places values within each
task's anchors but does not make the measured capacities identical. Keep Tracking, Pong,
CartPole, and ecological outcomes separate.

## Record the channels an analysis needs

Analyses read completed recorder channels:

```julia
sim = simulate(
    :torus;
    node=:falandays,
    n_agents=6,
    ticks=400,
    seed=7,
    record=(:spikes, :rate, :poses, :polarization, :milling),
    every=1,
)
```

Node activity analyses usually need `:spikes` or `:rate`. Agent analyses usually need
`:poses`. Record `:spectral_radius` only at a suitable `spectral_every` interval because it
requires an eigenvalue calculation.

Call analyses as ordinary functions:

```julia
branching_ratio_mr(sim; level=:node, kmax=4)
susceptibility(sim; level=:agent)
spectral_radius(sim)
participation_ratio(sim)
correlation_length(sim)
crossshift_null(
    sim,
    shifted -> susceptibility(shifted; level=:agent).susceptibility;
    n_shifts=200,
)
```

Many analyses are experimental. State the estimator, scale, window, and null before
interpreting a result.

## Use physical embodiments

Read and materialise a strict component configuration:

```julia
config = read_embodiment_config("examples/embodiments/differential_robot.toml")
body = materialize_embodiment(config)

portspec(body)
component_slots(body)
```

Each materialisation creates fresh runtime state. Stable component IDs define port names,
recording names, and bounded parameter overrides. Query
`component_info(family, kind)` before writing component parameters.

`ObjectWorld` is the generic fixed-population physical runtime. The lower-level example
returns the live ensemble and recorder:

```julia
include("examples/embodiments/object_world_quickstart.jl")
result = run_object_world_quickstart(ticks=25, seed=7)
```

The task example adds a `TaskSpec` and returns a standard `SimResult`:

```julia
include("examples/embodiments/object_world_task.jl")
sim = run_object_world_task(ticks=25, seed=11)
task_outcome(sim)
```

Use a `DevelopmentSpec` to evolve declared scalar component parameters while keeping the
component graph fixed. Runtime state never belongs to the development genome.

## Plot without changing the compute package

The compute package does not depend on Makie. Load a backend in a downstream or tool
environment:

```julia
using BrainlessLab, CairoMakie

sim = simulate(:tracking; node=:falandays, ticks=1000, seed=11)
fig = visualize(sim; panels=[:raster, :rate, :trajectory])
save("tracking.png", fig)
```

Use `CairoMakie` for saved images and headless work. Use `GLMakie` for `explore`:

```julia
using BrainlessLab, GLMakie
explore(:torus; node=:falandays, n_agents=6)
```

Available recipes include `rasterplot`, `rateplot`, `trajectoryplot`, `swarmplot`,
`networkplot`, and `driftplot`. `animate` writes an animation when the recorder contains
the required channels.

For a multi-agent result, select a stable identity:

```julia
networkplot(sim; entity=EntityID(3))
```

Automatic network selection is allowed only when exactly one entity exposes a network.

## Move from exploration to a research operation

Use the smallest operation that answers the question:

- use `ProfilePlan` to describe one composition;
- use `SweepPlan` to map declared parameter values;
- use `AblationPlan` to test a registered intervention;
- use `EvolutionPlan` to select parameters and evaluate held-out targets;
- use `BenchmarkPlan` to compare paired conditions within tasks.

Validate before execution:

```bash
julia --project=. bin/brainlesslab.jl check plans/examples/profile_tracking.toml
julia -t auto --project=. bin/brainlesslab.jl run \
  plans/examples/profile_tracking.toml --root records
```

Use an `ExperimentSpec` when several named conditions and operations form one versioned
scientific protocol. See `cli-tools.md`.

## Set up the Julia environment

Instantiate the repository environment and run the headless quick start:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. examples/quickstart.jl
```

Use `Pkg.develop(path="/path/to/brainless-lab")` only from a separate downstream project
that must track this checkout. Do not add optional plotting packages to the BrainlessLab
root to render one figure.

Run package tests with:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

## Interpretation boundary

The `:falandays` node is validated on declared reference trajectories. This does not
establish behavioural equivalence for every task. Other nodes, tasks, analyses, and
physical components have their own readiness and evidence status.

A software-ready capability may still lack construct validity. A complete record may still
be exploratory. Report those facts separately.
