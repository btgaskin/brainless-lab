# Visual test environment

The visual tests use a separate environment so that the default package tests do not install
or load Makie.

From the repository root, prepare the environment once:

```bash
julia --project=test/visual -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
```

Then run the visual tests:

```bash
julia --project=test/visual test/visual/runtests.jl
```
