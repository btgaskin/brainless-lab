# BrainlessLab core benchmark

This is a self-contained benchmark project for comparing registered BrainlessLab neuron variants across registered tasks. It keeps the parent library lean: heavy plotting and statistics dependencies live here.

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

Each run contains resolved configuration, a provenance manifest, raw per-trial CSV, summary CSV, nonparametric statistics JSON, Markdown report, plots, and per-cell score/artifact directories.

Compare two or more completed benchmark runs:

    julia --project=. compare.jl runs/<runA> runs/<runB> --out comparisons/<label>

The comparison tool reads each run's `summary.csv`, aligns rows by neuron, task, and metric, and writes `comparison.csv` plus `comparison.md`. Missing cells are marked explicitly. The Markdown report groups tables by task and flags runs whose confidence interval does not overlap the first run's confidence interval.

Fairness rule:

Falandays-family neurons default to `untrained`, which uses seeded per-trial wiring and default parameters while online plasticity acts during the rollout. Compartmental-family neurons default to `trained`, because untrained non-plastic weights are not a meaningful benchmark. If a cell requires a trained genome and none exists, the pipeline falls back to untrained evaluation and marks that cell with `trained-required-but-untrained` in outputs.

Statistics:

The pipeline uses normalized score for all inference and keeps raw score in the raw CSV. Per-task omnibus tests use Kruskal-Wallis. Pairwise tests use Mann-Whitney U with Cliff's delta and Holm correction within each task. Baseline-relative tables compare each neuron against the configured baseline, include bootstrap CIs for mean differences, achieved bootstrap power, and a search for the smallest sampled n reaching 0.80 power. Benjamini-Hochberg q-values are applied across all emitted pairwise p-values in the grid.

Stats tests:

    julia --project=. test_stats.jl
