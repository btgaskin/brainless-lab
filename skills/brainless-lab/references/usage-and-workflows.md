# Usage and Workflows

BrainlessLab.jl is a tinkering lab for *brainless* reservoirs — untrained recurrent
node populations — embodied in bodies, dropped into tasks and swarms, and read out
through analyses and figures. Almost everything you do at the top level flows through
one function and one struct: `simulate` builds and runs an ensemble, returning a
`SimResult`; `visualize` (and friends) turn that result into a picture. Prose docs live
at <https://brainless-lab.pages.dev>; the sibling references cover the extension points
(`designing-nodes.md`, `designing-environments-and-tasks.md`, `designing-analyses.md`)
and the batch/CLI surface (`cli-tools.md`).

## The two-liner mental model

```julia
using BrainlessLab, CairoMakie   # CairoMakie is what "activates" plotting
sim = simulate(:wall; node=:falandays_base, ticks=300)
fig = visualize(sim)
```

`simulate(task; node, ...) -> SimResult` is the whole compute surface. The core is
deliberately **Makie-free**: you can run, score, and analyze without any plotting
dependency loaded. `visualize`, `animate`, `explore`, `replay`, and the individual
recipes only come into existence when a Makie backend is imported — they live in a
package extension (`BrainlessLabMakieExt`, gated on the `Makie` weakdep in
`Project.toml`). Load **CairoMakie** for static/headless rendering (`save` to PNG/GIF),
**GLMakie** for the interactive `explore` window. If no backend is loaded, `visualize`
is simply undefined — that's expected, not a bug.

A `SimResult` holds `recorder` (sampled channels for plotting), `metrics` (task or swarm
diagnostics), and the `task`/`node` symbols plus a `config` snapshot that captured the
environment bounds, network adjacency, ablation notes, and seed.

## Discover, don't hardcode

The registry is the live source of truth. Node variants, tasks, and analyses are all
registered at load time, and third-party code can add more — so **query the registry
rather than pasting symbol lists** that will silently drift:

```julia
variants()             # registered node symbols, e.g. :falandays_base, :sorn, :compartmental_dense
tasks()                # registered task symbols, e.g. :wall, :tracking, :pong, :cartpole, :torus, :forage
analyses()             # every registered analysis symbol
task_analyses(:wall)   # analyses that declare themselves relevant to a given task
ablations()            # registered intervention symbols
```

Prefer these in scripts and generated code. A hardcoded `[:falandays, :sorn]` is a bug
waiting to happen once someone registers a new node.

## `simulate` keyword arguments

`simulate(task::Symbol; node=:falandays, ...)` funnels through `_build_ensemble`, which
sorts a flat bag of kwargs into node options, environment options, and run controls.
The load-bearing ones:

- `node` — a registered variant symbol (default `:falandays`).
- `ticks` — rollout length (defaults to the task's `default_ticks`).
- `seed` — base RNG seed; swarm agents get `seed + i` so each reservoir differs.
- `record` — channels to sample for plotting (default
  `(:spikes, :rate, :poses, :polarization, :milling)`); `every=N` subsamples them.
- `spectral_every` — stride for the (expensive) spectral-radius compute channel.
- `n_nodes` (alias `N`) — reservoir size; defaults are per-node and, for the
  Falandays base on a paper task, taken from the paper config.
- `window` — trailing window over which end-of-run metrics are computed.
- `n_agents` — **presence of this kwarg makes the run a swarm** (as do the `:torus`
  and `:forage` tasks). `:forage` gets a `ForageEnvironment`; otherwise `TorusEnvironment`.
- `body` — a `Body`, a registered body symbol (`:passthrough`, `:ven`), or a
  zero-arg constructor; defaults to `:passthrough` (single-agent) or `:ven` (swarm).
- `ablation` — a registered intervention (e.g. `:freeze_plasticity`, `:zero_recurrent`,
  `:clamp_target`, `:disable_vision`). Interventions are node-aware and record notes;
  an intervention that doesn't apply to the chosen node is a logged no-op, not an error.
- `node_kwargs` / `env_kwargs` / `swarm_kwargs` — explicit per-layer option bags, useful
  when a bare kwarg would be ambiguous.
- `metrics=[...]` — extra metric symbols to compute at rollout end.

For Falandays nodes, the recognized parameter kwargs (`lrate_wmat`, `lrate_targ`,
`input_amp`, `threshold_mult`, `weight_init_mode`, `topology`, `sign`, `drive`,
`membrane_noise`, `noise_gain`, ...) are pulled out of the flat kwargs and folded into a
`FalandaysParams` / drive instance for you — so you can write
`simulate(:wall; node=:falandays, lrate_wmat=0.02, topology=:watts_strogatz)` directly.

## Reading results

```julia
sim.metrics.score                      # single-agent task: a scalar figure of merit
sim.metrics.polarization               # swarm: order parameter (alignment)
sim.metrics.milling                    # swarm: rotational/vortex order
sim.metrics.mean_distance_to_source    # forage: closeness to the resource
```

**Scores are not comparable across tasks.** Each task defines its own effectors, its own
success signal, and its own normalization anchors — this non-uniformity is intentional,
not an oversight. A wall score and a pong score live on different axes; comparing their
raw numbers is meaningless. See the site's contracts page
(<https://brainless-lab.pages.dev/contracts/>) and environments/tasks page
(<https://brainless-lab.pages.dev/environments-tasks/>) for what each score actually measures.

## Visualization surface

Everything below requires a Makie backend loaded.

```julia
visualize(sim; panels=[:raster, :rate, :trajectory])   # stacked multi-panel overview
visualize(sim; panels=[:swarm, :rate])                 # swarm variant
animate(sim; path="activity.gif", branching=true)      # GIF/MP4; branching=true adds σ(t)
replay(sim)                                             # alias of visualize on a live result
replay("runs/2026-07-04-wall")                          # rebuild a SimResult from a saved run dir
explore(:torus; node=:falandays, n_agents=6)            # interactive GLMakie window (Play/Step)
```

Individual recipes each return a `Figure` and accept a `SimResult` (or bare `Recorder`):
`rasterplot`, `rateplot`, `trajectoryplot`, `swarmplot`, `networkplot`, and
`driftplot(sim; bin=N)` (spike-pattern autocorrelation heatmap). `explore` needs GLMakie
specifically and will raise if only CairoMakie is loaded. Panels resolve through the view
registry, so a custom registered view can also appear as a `panels=` entry.

## Analyses on a result

The analysis functions are ordinary functions you call on a `SimResult`; the compute core
exports them independent of Makie:

```julia
branching_ratio(sim)                              # per-tick σ(t) = A(t+1)/A(t)
branching_ratio_mr(sim; level=:node, kmax=4)      # MR estimator, subsampling-robust
branching_ratio_mr(sim; level=:agent, observable=spec)   # agent-level, on a chosen observable
susceptibility(sim; level=:node)                  # or level=:agent
spectral_radius(sim)                              # ρ(W)
participation_ratio(sim)
correlation_length(sim)                           # swarm velocity correlation length
crossshift_null(sim, s -> susceptibility(s; level=:agent).susceptibility; n_shifts=5)
transfer_entropy(sim)
```

Many are flagged *experimental* in the registry — treat their numbers as exploratory.
The null test (`crossshift_null`) is the discipline: a real measure should beat its
circular-shift surrogate. For the full picture — which measures pass which nulls, level
semantics, and how to register your own — see `designing-analyses.md`.

## Four end-to-end workflows

**(a) Baseline + figure + GIF.** Run, glance at the score, save both a static overview and
an animation:

```julia
using BrainlessLab, CairoMakie
sim = simulate(:wall; node=:falandays_base, ticks=300, seed=11)
@info "wall score" score=sim.metrics.score
save("wall_overview.png", visualize(sim))
animate(sim; path="wall.gif", branching=true)     # needs :rate recorded (it is, by default)
```

**(b) Compare variants.** Hold task/seed/ticks fixed, sweep the node symbol, and read the
per-variant metric — but remember scores are only comparable *within one task*:

```julia
for node in (:falandays_base, :falandays_oosawa, :sorn)
    s = simulate(:wall; node=node, ticks=220, seed=11)
    @info node score=s.metrics.score
end
```

For anything beyond a quick loop — proper replicate sweeps, CSV output, parallelism — use
the batch runner and `run_sweep`; see `cli-tools.md`.

**(c) Swarm / dyad.** Pass `n_agents` (or use `:torus`/`:forage`) and record the swarm
channels:

```julia
sim = simulate(:torus; node=:falandays, n_agents=2, ticks=400, seed=7,
               record=[:spikes, :rate, :poses, :polarization, :milling])
save("dyad.png", visualize(sim; panels=[:swarm, :rate]))
@info "order" P=sim.metrics.polarization M=sim.metrics.milling
```

Forage adds a resource source and closeness metric:
`simulate(:forage; node=:falandays_base, n_agents=4, vision_range=4.5, ...)`.

**(d) Headless / SSH.** There is no display, so **never call `explore`**. Load CairoMakie,
render, and `save` to a file:

```julia
using BrainlessLab, CairoMakie
save("out.png", visualize(simulate(:wall; node=:falandays_base)))
```

`explore` is GLMakie-only and needs a window server; on a headless box it will fail or
hang. CairoMakie + `save` is the always-safe path.

## Environment setup

BrainlessLab is a normal Julia project; activate it and add a backend for plotting:

```bash
julia --project=.
```

```julia
pkg> activate .
pkg> dev .            # or `add` from a registry once published
pkg> add CairoMakie   # Makie is a weakdep — the extension loads once a backend is present
```

Makie is declared under `[weakdeps]`/`[extensions]` in `Project.toml`, so the core
installs and runs without it. Run the test suite with `Pkg.test()` (or `pkg> test`).

## Stable vs. experimental discipline

`:falandays_base` (alias `:falandays`) is the **settled, authors-faithful 2021 baseline**
— treat it as the reference point you compare everything against. Every other node
variant, task, analysis, and ablation is **experimental platform**: useful, but not
canon. Scores and effectors are intentionally non-uniform across tasks — do not expect a
single normalized number that lets you rank a wall run against a pong run. When in doubt,
anchor on `:falandays_base` and read the contracts page before drawing conclusions.
