# BrainlessLab core benchmark

This is the cross-node comparison tool for BrainlessLab. `bench` runs a roster
of registered neuron variants across a task grid, ranks them by normalized
score, and reports baseline-relative statistics. Use `profile/` when you want
to characterize one node in depth rather than compare nodes.

Setup from `brainless-lab/bench`:

    julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'

Run the default grid:

    julia --project=. run.jl

Run a smaller grid:

    julia --project=. run.jl --neurons falandays_base,compartmental_structured --tasks wall,pong --no-gifs

Benchmark rollouts run on Julia threads. `run.jl` self-launches with `-t auto`
when Julia starts single-threaded and no thread count was pinned; set
`BRAINLESSLAB_AUTOTHREADS=0` or `JULIA_NUM_THREADS=1` to opt out.

Train a stored genome for one cell:

    julia --project=. train.jl compartmental_structured wall --generations 30 --popsize 16 --seed 1 --N 120 --ticks 300

Stored genomes are written to:

    bench/genomes/<neuron>__<task>/genome.jld2
    bench/genomes/<neuron>__<task>/train_manifest.toml

Train one generalist genome across all core tasks at once with NSGA-II
(multi-objective -- each task is a separate maximized objective, never
scalarized into a single fitness number):

    julia --project=. train_moo.jl

The Pareto-front member with the highest mean objective is saved identically
under every task cell:

    bench/genomes/compartmental_structured_nsga__<task>/genome.jld2
    bench/genomes/compartmental_structured_nsga__<task>/train_manifest.toml

Train one generalist genome with CMA-ME (quality-diversity -- a MAP-Elites
archive keyed by discretized per-task scores, filled by sep-CMA-ES
"improvement emitters"):

    julia --project=. train_qd.jl

The highest-quality archive elite is saved identically under every task cell:

    bench/genomes/compartmental_structured_cmame__<task>/genome.jld2
    bench/genomes/compartmental_structured_cmame__<task>/train_manifest.toml

Run outputs are written to:

    bench/runs/<UTCstamp>_<shortgit>_<id>/

Each run is a timestamped run directory with:

- `manifest.toml` -- git SHA, Julia/package versions, seeds, and resolved grid metadata.
- `config.resolved.toml` -- resolved benchmark configuration.
- `summary.csv` -- per-neuron x task summaries used for ranking.
- `results_raw.csv` -- raw per-trial scores.
- `stats.json` -- within-seed repeated-measures, paired sign-flip, and paired-bootstrap results.
- `figures/*.png` -- house-palette heatmap and per-task comparison bars.
- `cells/<neuron>__<task>/` -- per-cell scores, representative figure, and best/representative/worst GIFs when enabled.
- `README.md` -- headline ranking callout for the run.
- `report.md` -- expanded Markdown statistical report.

Compare two or more completed benchmark runs:

    julia --project=. compare.jl runs/<runA> runs/<runB> --out comparisons/<label>

The comparison tool reads each run's `summary.csv`, aligns rows by neuron, task, and metric, and writes `comparison.csv` plus `comparison.md`. Missing cells are marked explicitly. The Markdown report groups tables by task and flags runs whose confidence interval does not overlap the first run's confidence interval.

Fairness rule:

Falandays-family neurons default to `untrained`, which uses seeded per-trial wiring while online plasticity acts during the rollout. "Default parameters" means the generic `FalandaysParams()` genome defaults for every variant *except* canonical `:falandays` (and its `:falandays_base` compatibility alias) on a task with a registered paper config (`:wall`/`:tracking`/`:pong`) -- for those, it means the task's authors-faithful constants (`falandays_paper_config(task)`: task-specific `lrate_wmat`/`lrate_targ`/input weight), matching what plain `simulate(task; node=:falandays)` runs with. Compartmental-family neurons default to `trained`, because untrained non-plastic weights are not a meaningful benchmark. If a cell requires a trained genome and none exists, the pipeline falls back to untrained evaluation and marks that cell with `trained-required-but-untrained` in outputs.

Rankings are conditional on the configured node roster, task roster, task weighting,
preparation policy, and seeds. A `trained-required-but-untrained` fallback must not enter an
unqualified ranking. Training, model/parameter selection, and evaluation seeds must be
disjoint. When every model shares the same randomized trial seeds within a task, analyze
model contrasts as paired by seed. Agents and ticks within a rollout are repeated
observations, not additional independent trials.

Normalized task scores are not universal cross-task units. Any aggregate ranking encodes a
declared weighting over different operational contracts; it should be reported alongside
per-task results and preparation status.

Statistics:

The pipeline uses normalized score for its current summaries and keeps raw score in the raw
CSV. Trial seeds are shared across node conditions within a task, so inferential output is
block-aware: the omnibus test permutes condition labels within seed, pairwise comparisons
use paired sign flips, and mean-difference intervals bootstrap whole paired seed blocks.
Holm correction is applied within each task and Benjamini-Hochberg q-values across emitted
pairwise comparisons in the grid. `paired_superiority` is the mean sign of the within-seed
difference, in `[-1, 1]`; ties contribute zero.

The benchmark does not emit retrospective “achieved power.” Plan a fresh evaluation from a
meaningful-effect margin and a variance pilot over independent blocks. Flagged
`trained-required-but-untrained` cells remain visible in raw and summary outputs but are
excluded from inferential groups and aggregate rankings.

Stats tests:

    julia --project=. test_stats.jl
