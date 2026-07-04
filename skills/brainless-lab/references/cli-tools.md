# CLI Tools

Four command-line entrypoints, each a distinct job writing a self-describing **run-dir**
(`manifest.toml` with git SHA + seeds + package versions, CSVs, `figures/*.png` in the
house palette, a `README.md` headline). Full prose at https://brainless-lab.pages.dev/tooling/;
the sweep TOML schema at https://brainless-lab.pages.dev/reference/.

| Tool | Job | Project env | Run-dir |
|---|---|---|---|
| `bench/` | roster of nodes across a task grid — rank + baseline stats | own | `bench/runs/<stamp>/` |
| `profile/` | one node in depth — full analytic suite + GIFs | own | `profile/runs/<node>/<stamp>/` |
| `sweep/` | perturb parameter axes, measure signatures per cell | root | `sweeps/<id>/` |
| `calibration/` | task score floor/ceiling anchors | root | stdout |

`<stamp>` is `<UTCstamp>_<shortgit>_<id>`. `bench`/`profile` timestamp every run so
repeats never collide; `sweep`/`ablate` key the run-dir on the sweep **id**, so re-running
the same id resumes in place (completed cells skipped) — that is why `sweeps/` is not
timestamped.

## Environments

`bench/` and `profile/` each carry their **own** `Project.toml` and must be instantiated
once (they `Pkg.develop` the repo they live in). `sweep/` and `calibration/` run against
the **root** project with `--project=.`.

```bash
cd bench    && julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'
cd profile  && julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add(["CairoMakie","Statistics","Printf","TOML"]); Pkg.instantiate()'
# root, once, for sweep + calibration:
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

Every entry script **self-relaunches with `-t auto`** when Julia started single-threaded
and no count was pinned — rollouts run in parallel across threads. Opt out with
`BRAINLESSLAB_AUTOTHREADS=0` or `JULIA_NUM_THREADS=1` (or `sweep.threaded = false` in the
sweep TOML).

## bench/ — cross-node comparison

Runs a roster of registered node variants across a task grid, ranks by normalized score,
reports baseline-relative nonparametric statistics. Use `profile/` instead when you want
one node in depth, not a ranking.

```bash
cd bench && julia --project=. run.jl --neurons falandays_base,compartmental_structured --tasks wall,pong --no-gifs
```

Flags: `--config core.toml` (default `bench/configs/core.toml`; `--neurons` / `--tasks` /
`--no-gifs` override it), `--neurons a,b`, `--tasks x,y`, `--no-gifs`. An empty roster in
the config means all registered variants. The `[prep]` block encodes the fairness rule:
falandays\* default to `untrained` (seeded wiring + online plasticity), compartmental\*
default to `trained`; a cell needing a trained genome that has none falls back to
untrained and is flagged `trained-required-but-untrained`.

Outputs under `bench/runs/<stamp>/`: `summary.csv` (per-neuron × task, used for ranking),
`results_raw.csv` (raw per-trial scores), `stats.json` (Kruskal-Wallis omnibus,
Mann-Whitney U + Cliff's delta pairwise with Holm/BH correction, bootstrap CIs and power),
`figures/*.png`, `cells/<neuron>__<task>/` (scores + best/representative/worst GIFs),
`README.md`, `report.md`, `config.resolved.toml`, `manifest.toml`.

Two companion scripts:

```bash
julia --project=. train.jl compartmental_structured wall --generations 30 --popsize 16 --seed 1 --N 120 --ticks 300
julia --project=. compare.jl runs/<runA> runs/<runB> --out comparisons/<label>
```

`train.jl` evolves a genome for one cell, writing `bench/genomes/<neuron>__<task>/genome.jld2`
plus `train_manifest.toml`. `compare.jl` aligns two or more completed runs by
neuron/task/metric and writes `comparison.csv` + `comparison.md`, flagging non-overlapping
CIs against the first run.

## profile/ — single-node deep characterization

Characterizes one registered node variant across the default task tuple (`wall`, `tracking`,
`pong`, `cartpole` + `_hard`/`_swingup`/`_long`). Not a ranking tool.

```bash
cd profile && julia --project=. run.jl falandays_base --seeds 8
```

Flags: positional node symbol (default `falandays_base`), `--seeds <n>` (default 8),
`--out <runs-root>`, `--no-gifs`, `--report` (opt-in `report.html` stub only). Outputs
under `profile/runs/<node>/<stamp>/`: `metrics.csv` (per-task score, `sigma_mr`, spectral
radius, liveness/rate, avalanche summaries), `figures/*.png`, `gifs/*.gif` (one
representative behaviour GIF per task), `manifest.toml`, `config.resolved.toml`, `README.md`.

## sweep/ — parameter + ablation sweeps

Perturbs the parameters that shape a run and records analytic signatures per cell, so you
see performance *and* criticality against each knob. Same runner does both a config sweep
and the config-free `ablate` subcommand.

```bash
julia --project=. sweep/run.jl configs/sweep_tracking.toml            # config sweep
julia --project=. sweep/run.jl --list-axes --node falandays_base --task wall   # discover axes
julia --project=. sweep/run.jl ablate falandays_base wall             # baseline vs each ablation
```

Flags: `--force` (overwrite completed cells instead of resuming), `--debug` (rethrow
instead of a one-line error). `--list-axes` prints every sweepable path for a node/task
with defaults and ranges — always run it before writing a config. A failing cell records
its error and the sweep **continues**.

Outputs under `sweeps/<id>/`: `results.csv` (one row per cell: axis × value × score + each
measure + `frac_viable`), per-axis breakdown `figures/*.png` (score, σ, ρ(W), liveness vs
the knob), `cells/cell_NNN/` (each cell's `metrics.csv` + manifest, plus captured GIFs /
timeseries / null-test CSVs when enabled), `manifest.toml`, `config.resolved.toml`,
`README.md`. Note `sweeps/` is the **output** directory holding completed runs and a rolled-up
`ALL_RESULTS.csv` — it is not a script.

## calibration/ — score anchors

```bash
julia --project=. calibration/run_calibration.jl
```

Prints, per task (`wall`, `pong`, `pong_hitrate`, `cartpole_swingup`, `forage`), the score
**floor** and **ceiling** anchors with their kind and provenance — the reference points
that normalize raw task scores into the `0..1` normalized score everything else reports.

## Sweep config schema

See `configs/sweep_tracking.toml` (single-task viability scan) and `configs/sweep_forage_*.toml`
(swarm ensemble analytics) for worked examples. Sections:

```toml
[sweep]
id = "tracking_viability"     # names the run-dir: sweeps/tracking_viability/
mode = "one_at_a_time"        # each axis varied alone (Σ of axis lengths); or "factorial" (cartesian product)
seeds = [0, 1, 2, 3]          # seed offsets added to baseline seed_base
max_cells = 200               # cost guards; the cost preview shows cells × seeds rollouts
max_rollouts = 200
# threaded = false            # opt out of thread parallelism

[baseline]                    # the canonical setup every axis perturbs around
node = "falandays_base"       # node preset; task = "wall" | "tracking" | "forage" | ...
task = "tracking"
N = 200                       # alias n_nodes; reservoir size
ticks = 2000
window = 300                  # metric/liveness window (defaults to ticks, task default for swarm)
n_agents = 40                 # swarm/forage population
# seed_base = 0 (alias seed); body / drive preset symbols; ablation = "none"
"node.input_weight" = 0.75    # dotted pass-through: node.* / env.* / drive.* / task.* pin any simulate kwarg
"env.vision_range" = 4.0

[axes]                        # dotted path -> list of values; "ablation" and "seed" are also valid axes
"task.N" = [100, 200, 300]
"node.lrate_targ" = [0.0, 0.005, 0.01, 0.02]
"env.stim_speed_rad" = [0.0087, 0.0175, 0.0349]
"ablation" = ["none", "freeze_plasticity", "zero_recurrent"]

[analytics]
measures = ["sigma_mr", "spectral_radius", "liveness"]   # default set; see the full list below
viable_threshold = 0.5        # a seed is "viable" if normalized score >= this

[capture]                     # optional: opt-in per-cell artifacts (GIF, criticality timeseries, null test)
group = "collective"          # "none" (default) | "all" | a named group selecting cells by params
timeseries = true
gif = false
window = 300
stride = 75
n_shifts = 30                 # circular-shift null-test replicates
seed = 4242

[capture.groups.collective]
"env.conspecific_vision" = true

[[ensemble]]                  # agent-scale observable specs (for sigma_mr_agent etc.)
kind = "turn"                 # turn | align | speed | graded
threshold = { quantile = 0.85 }
# neighbor_radius = "vision_range"   # required for align
```

Axis namespaces route into the real `simulate` kwargs and are validated up front — a wrong
or inapplicable axis is a "did you mean…" error, not a silent no-op. Modes: `one_at_a_time`
varies each axis alone against the baseline; `factorial` takes the full cartesian product.

### `measures` — valid names

`sigma_mr` (pooled MR branching ratio), `sigma_mr_node` (per-agent reservoir branching),
`sigma_mr_agent` (agent-scale turn-event branching, one column per ensemble observable),
`spectral_radius` (dominant recurrent-eigenvalue magnitude), `liveness`,
`susceptibility_node`, `susceptibility_agent`, `correlation_length`, `contact_clusters`
(emits `cluster_n_components` / `cluster_largest_component_frac` /
`cluster_mean_component_size`), `regime` (swarm-regime label + `regime_polarization` /
`regime_milling` / `regime_speed`), `dist_to_source`, `forage_score`. Aliases `clusters` /
`cluster_stats` / `contact_graph_clusters` all canonicalize to `contact_clusters`. Cross-check
against the [reference page](https://brainless-lab.pages.dev/reference/).

## See also

- `usage-and-workflows.md` — end-to-end recipes tying these tools together.
- `designing-analyses.md` — what each measure means and when it survives the null.
- `designing-environments-and-tasks.md` — the node/task/env registries the axes address.
