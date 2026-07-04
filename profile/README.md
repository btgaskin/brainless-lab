# BrainlessLab node profile

`profile` characterizes one registered node variant in depth. It is not a
ranking tool: use `bench/` for cross-node comparison and baseline-relative
statistics.

Setup from `brainless-lab/profile`:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add(["CairoMakie","Statistics","Printf","TOML"]); Pkg.instantiate()'
```

Run the default single-node profile:

```bash
julia --project=. run.jl falandays_base
```

Useful flags:

```bash
julia --project=. run.jl falandays_oosawa --seeds 12
julia --project=. run.jl falandays_base --no-gifs
julia --project=. run.jl falandays_base --report
```

Runs are written under:

```text
profile/runs/<node>/<UTCstamp>_<shortgit>_<id>/
```

Each run contains:

- `manifest.toml` -- git SHA, Julia/package versions, seeds, and resolved profile metadata.
- `config.resolved.toml` -- resolved profile settings.
- `metrics.csv` -- per-task score, `sigma_mr`, spectral radius, liveness/rate, and avalanche summaries.
- `figures/*.png` -- house-palette branching, spectral, target-error, and situated task panels where available.
- `gifs/*.gif` -- one representative behaviour GIF per task.
- `README.md` -- the node's signature summary.

HTML is off by default. `--report` writes a small `report.html` stub only; the
primary outputs are the CSV, figures, GIFs, manifest, and run README.
