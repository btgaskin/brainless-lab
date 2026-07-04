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

Train a stored genome for one cell:

    julia --project=. train.jl compartmental_structured wall --generations 30 --popsize 16 --seed 1 --N 120 --ticks 300

Stored genomes are written to:

    bench/genomes/<neuron>__<task>/genome.jld2
    bench/genomes/<neuron>__<task>/train_manifest.toml

Run outputs are written to:

    bench/runs/<UTCstamp>_<shortgit>_<id>/

Each run is a timestamped run directory with:

- `manifest.toml` -- git SHA, Julia/package versions, seeds, and resolved grid metadata.
- `config.resolved.toml` -- resolved benchmark configuration.
- `summary.csv` -- per-neuron x task summaries used for ranking.
- `results_raw.csv` -- raw per-trial scores.
- `stats.json` -- omnibus, pairwise, and baseline-relative nonparametric tests.
- `figures/*.png` -- house-palette heatmap and per-task comparison bars.
- `cells/<neuron>__<task>/` -- per-cell scores, representative figure, and best/representative/worst GIFs when enabled.
- `README.md` -- headline ranking callout for the run.
- `report.md` -- expanded Markdown statistical report.

Compare two or more completed benchmark runs:

    julia --project=. compare.jl runs/<runA> runs/<runB> --out comparisons/<label>

The comparison tool reads each run's `summary.csv`, aligns rows by neuron, task, and metric, and writes `comparison.csv` plus `comparison.md`. Missing cells are marked explicitly. The Markdown report groups tables by task and flags runs whose confidence interval does not overlap the first run's confidence interval.

Fairness rule:

Falandays-family neurons default to `untrained`, which uses seeded per-trial wiring and default parameters while online plasticity acts during the rollout. Compartmental-family neurons default to `trained`, because untrained non-plastic weights are not a meaningful benchmark. If a cell requires a trained genome and none exists, the pipeline falls back to untrained evaluation and marks that cell with `trained-required-but-untrained` in outputs.

Statistics:

The pipeline uses normalized score for all inference and keeps raw score in the raw CSV. Per-task omnibus tests use Kruskal-Wallis. Pairwise tests use Mann-Whitney U with Cliff's delta and Holm correction within each task. Baseline-relative tables compare each neuron against the configured baseline, include bootstrap CIs for mean differences, achieved bootstrap power, and a search for the smallest sampled n reaching 0.80 power. Benjamini-Hochberg q-values are applied across all emitted pairwise p-values in the grid.

Stats tests:

    julia --project=. test_stats.jl
