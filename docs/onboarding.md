# Onboarding

BrainlessLab has one root package plus separate utility projects. Instantiate each project in the
directory where you use it; `bench/` and `profile/` do not share the root environment automatically.

## Root package

From `brainless-lab/`:

```julia
pkg> dev .
pkg> add CairoMakie
```

Then:

```julia
using BrainlessLab, CairoMakie

sim = simulate(:wall; node=:falandays_base, ticks=300)
visualize(sim)
```

Use `CairoMakie` for static figures. Use `GLMakie` if you want `explore(...)` interactive windows.

## Profile project

From `brainless-lab/profile`:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'
julia --project=. run.jl falandays_base --seeds 2
```

The profile tool characterizes one node and writes `metrics.csv`, figures,
GIFs, manifest, and a signature README under `profile/runs/`.

## Sweep and ablation runner

From the root package:

```bash
julia --project=. sweep/run.jl configs/sweep_falandays_wall.toml
julia --project=. sweep/run.jl ablate falandays_base wall
```

Sweep and ablation outputs use the same run-dir convention: manifest,
`results.csv`, per-cell metrics/GIFs, figures, and a README callout.

## Benchmark project

From `brainless-lab/bench`:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'
julia --project=. run.jl --neurons falandays_base --tasks wall --no-gifs
```

The benchmark has heavier statistics and plotting dependencies, so keep it separate from the root package.

## First-result expectations

The first Julia/Makie call can spend noticeable time compiling. That is normal; repeat calls are much
faster. Getting from install to `simulate` + `visualize` in an afternoon is realistic. Full evolution runs
are a separate experiment budget, especially for compartmental/CTRNN nodes.
