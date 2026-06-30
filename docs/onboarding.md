# Onboarding

BrainlessLab has one root package plus two separate utility projects. Instantiate each project in the
directory where you use it; `bench/` and `demo/` do not share the root environment automatically.

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

## Demo project

From `brainless-lab/demo`:

```bash
julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'
julia --project=. run.jl --list
julia --project=. run.jl wall --save
```

For live windows, add `GLMakie` in the demo project:

```bash
julia --project=. -e 'using Pkg; Pkg.add("GLMakie")'
```

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
