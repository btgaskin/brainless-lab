# Packages and Environments

## Project-local environments, always

Every project should activate its own environment rather than installing packages into the shared
default (`@v1.X`) environment:

```julia
julia> ]activate .          # or: Pkg.activate(".")
(MyProject) pkg> add SomePackage
```

This creates/updates two files in the project folder:

- **`Project.toml`** — direct dependencies and version bounds, plus project metadata.
- **`Manifest.toml`** — the exact resolved versions of every direct *and indirect* dependency.
  Commit this alongside `Project.toml` for a reproducible project (a simulation you might want to
  re-run in a year and get the same numerical results from).

Keep the default environment minimal — only things you want available everywhere (REPL niceties,
`Revise.jl`). Installing project-specific packages there is the single most common cause of
mysterious cross-project dependency version conflicts.

```julia
julia --project=path/to/MyProject     # start Julia already inside a project's environment
```

`]instantiate` downloads everything listed in an existing `Project.toml`/`Manifest.toml` pair — the
command to run when picking up someone else's project (or your own, on a new machine) for the
first time.

## The REPL-driven workflow, and `Revise.jl`

Julia has meaningful startup/compilation latency, so the idiomatic workflow is not "run the script
from the terminal repeatedly" but "start one REPL, keep it open, and re-evaluate code into it as
you edit":

```julia
julia> include("myfile.jl")     # one-shot, no tracking
julia> using Revise; includet("myfile.jl")   # tracked — edits are picked up automatically
```

Once `Revise.jl` is loaded (most people put `using Revise` at the top of their startup file, before
anything else, so every subsequent package they load is tracked too), saving an edited source file
updates the running REPL session's definitions automatically, without restarting. This is
significant in scientific code specifically because restarting often means re-running expensive
setup (loading data, building a simulation's initial state) — `Revise.jl` lets you iterate on the
*logic* without paying that cost every time.

```julia
# ~/.julia/config/startup.jl
try
    using Revise
catch e
    @warn "Error initializing Revise"
end
```

## Local packages and `]develop`

Once a project outgrows a handful of script files, turn it into a package (`]generate MyPackage`,
or the more complete `PkgTemplates.jl` for a package meant to be shared/tested/CI'd). To work on a
package interactively while also using other tools (plotting, exploratory packages) that the
package itself shouldn't depend on, use a separate playground environment and `]develop` the
package's local path into it, rather than `]add`-ing a fixed version:

```julia
using Pkg
Pkg.activate("./MyPlayground")
Pkg.develop(path="./MyPackage")
using MyPackage
```

## Precompilation and startup latency

Two different tools for two different latency problems:

- **`PrecompileTools.jl`** — for package *authors*. Wrap representative calls in
  `@compile_workload` inside your package so that the methods are already compiled by the time a
  user's session loads the package, rather than paying that compile cost on first use:

  ```julia
  using PrecompileTools: @compile_workload
  @compile_workload begin
      # representative calls through your package's API
      simulate(default_model(), 10)
  end
  ```

- **`PackageCompiler.jl`** — for *users* running the same heavy environment repeatedly (e.g. a
  simulation environment with `DifferentialEquations.jl`/`Makie.jl` loaded every session). Builds a
  custom Julia **sysimage** with those packages baked in as already-compiled, so `using` them
  becomes near-instant:

  ```julia
  using PackageCompiler
  create_sysimage(["DifferentialEquations", "Agents"]; sysimage_path="MySysimage.so")
  ```
  ```
  julia --sysimage=MySysimage.so
  ```

  Worth doing once you find yourself restarting a heavy session many times a day during a project
  that has settled on its core dependencies.

If precompilation or recompilation behavior is itself the mystery (a package seems to recompile
when it shouldn't), `SnoopCompile.jl` diagnoses *invalidations* — places where loading one piece of
code forces previously-compiled code to be thrown away and recompiled.

## Code quality and testing

```julia
using Test
@testset "basic sanity" begin
    @test sqrt(4) ≈ 2
    @test_throws DomainError sqrt(-1)
end
```

Tests belong in `test/runtests.jl`, run via `]test`. Beyond ordinary unit tests:

- **`Aqua.jl`** (`Aqua.test_all(MyPackage)`) — checks package hygiene: unused dependencies,
  ambiguous methods, undefined exports, and similar structural issues that aren't really "bugs" but
  are exactly the kind of thing that's easy to introduce silently and worth catching automatically.
- **`JET.jl` test mode** (`JET.test_package(MyPackage)`) — runs JET's static error analysis as part
  of the test suite, catching likely `MethodError`s and instabilities without needing a test case
  that happens to exercise every code path at runtime.
- **`ExplicitImports.jl`** — flags places you're relying on a name being implicitly re-exported by
  some dependency rather than imported explicitly; makes a package more robust to upstream changes
  and easier to read ("where did this name come from").

Both `Aqua.jl` and `JET.jl` can report false positives on legitimate code — check their
documentation for how to suppress a specific known-fine case rather than ignoring the tool
entirely.

## Style and formatting

The official style guide is intentionally short; most real codebases instead adopt a fuller
third-party guide — **BlueStyle** or, especially in this ecosystem, **SciMLStyle** (used across the
`DifferentialEquations.jl`/`SciML` packages relevant to `scientific-ecosystem.md`). Enforce
automatically rather than manually:

```toml
# .JuliaFormatter.toml, at the project root
style = "blue"
```

```julia
using JuliaFormatter
JuliaFormatter.format(MyPackage)
```

Picking a style and formatting automatically matters more than which style you pick — the value is
in not relitigating formatting in every review.
