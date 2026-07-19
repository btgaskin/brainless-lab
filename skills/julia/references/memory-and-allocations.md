# Memory and Allocations

## What an allocation is, and why it costs more than it looks like

A heap allocation reserves garbage-collected storage for a value that escapes its local context or
needs a runtime-managed representation, such as most resizable `Vector`s and `String`s. Boxing
caused by imprecise inference can allocate too. Julia's compiler may scalar-replace or eliminate
apparently allocated immutable values, so source syntax alone does not determine whether something
lives on the heap, stack, or in registers. Measure the compiled call.

**Practical rule:** repeated unexpected allocations reported by `@allocated`, a benchmark, or an
allocation profiler are often caused by imprecise inference or temporary array creation. Some
allocations are intentional API costs, so optimize the measured hot path rather than demanding
zero allocation everywhere.

## Array slices copy; views don't

```julia
A = rand(1000, 1000)

s = A[1:500, :]        # copies — a new 500×1000 array
v = view(A, 1:500, :)  # a SubArray referencing A's memory, no copy
v2 = @views A[1:500, :] # same as view(), nicer syntax; @views applies to a whole expression/block
```

Copying is sometimes what you want (you're about to do many operations on a smaller, contiguous
chunk, and the cache-locality win outweighs the copy cost). For a one-off read inside a loop that
runs many times, prefer a view — the repeated copies otherwise dominate.

`@views` in front of a function definition or a block applies it to every slicing expression
inside, which is usually cleaner than sprinkling `view(...)` calls individually.

## Column-major order

Julia stores multidimensional arrays column-major (like Fortran/MATLAB/R; unlike C/NumPy's default).
The innermost loop should walk the *first* index fastest:

```julia
# good — first index varies fastest, matches memory layout
for j in 1:size(A, 2), i in 1:size(A, 1)
    A[i, j] = ...
end

# bad — strides across memory on every step, much worse cache behavior for large A
for i in 1:size(A, 1), j in 1:size(A, 2)
    A[i, j] = ...
end
```

This matters most for large arrays where cache misses dominate; for small arrays the difference is
negligible, so don't contort readable code chasing this on something tiny.

## Mutating APIs: reuse buffers in hot loops

The `!`-suffix convention (`push!`, `sort!`, and the `f!(du, u, p, t)` style used by SciML)
communicates that one or more arguments are mutated. Mutation often enables output-buffer reuse,
but a `!` function may still allocate internally. If a function is called every simulation step
and its output shape is reusable, provide an in-place form and verify its allocations:

```julia
# allocates a new array every call — fine occasionally, expensive in a hot loop
f(u, p, t) = [p.σ*(u[2]-u[1]), u[1]*(p.ρ-u[3])-u[2], u[1]*u[2]-p.β*u[3]]

# in-place: writes into the caller-provided buffer du, no allocation per call
function f!(du, u, p, t)
    du[1] = p.σ * (u[2] - u[1])
    du[2] = u[1] * (p.ρ - u[3]) - u[2]
    du[3] = u[1] * u[2] - p.β * u[3]
    return nothing
end
```

The `!` is a *convention*, not enforced by the compiler — it's a signal to callers (and to you)
that an argument gets mutated, almost always the first one.

## Preallocating accumulators

```julia
# bad inside a loop that runs many times: v grows by reallocating repeatedly
v = []
for i in 1:n
    push!(v, compute(i))
end

# better: known size up front
v = Vector{Float64}(undef, n)
for i in 1:n
    v[i] = compute(i)
end

# if size truly isn't known up front but is roughly predictable, at least hint it
v = Float64[]
sizehint!(v, n)
```

## `StaticArrays.jl` — small, fixed-size state

For arrays whose size is known at compile time and small enough for specialization to remain
cheap, `StaticArrays.jl` encodes the size *in the type*. The useful size range depends on the
operation and compiler workload, so benchmark instead of relying on a fixed cutoff:

```julia
using StaticArrays
v = SA[1.0, 2.0, 3.0]        # SVector{3,Float64} — immutable, size in the type
m = SA[1.0 0.0; 0.0 1.0]     # SMatrix{2,2,Float64}
```

Because the size is part of the type, operations on `SArray`/`SVector`/`SMatrix` can be specialized
and unrolled. The compiler may keep small values inline, in registers, or on the stack, but storage
placement and allocation elimination are compiler decisions rather than guarantees.
`MArray`/`MVector`/`MMatrix` provide mutable fixed-size storage; mutation does not by itself
guarantee stack allocation.

This is a good candidate for compact **per-agent state in an agent-based model** or **per-neuron
state in a small ODE system** (e.g. a single Hodgkin-Huxley neuron's `(V, m, h, n)` state) when the
shape is fixed and measurements support it. See `scientific-ecosystem.md` for the
`DifferentialEquations.jl`-specific tradeoff.

Don't reach for `StaticArrays.jl` for large or dynamically-sized arrays — the size-in-the-type
mechanism works against you there (compilation blows up, and you lose the point of dynamic
sizing).

## `ComponentArrays.jl` — named, structured state without giving up array semantics

A common pattern in scientific code is a state vector with several named, semantically distinct
parts (e.g. a neuron population's voltages and recovery variables; a predator and prey population
size in a Lotka-Volterra system) that nonetheless needs to be a single flat array because that's
what an ODE solver or optimizer expects. Indexing into that array by raw integer position
(`u[1]`, `u[2]`, ...) is both error-prone and unreadable.

```julia
using ComponentArrays
u0 = ComponentArray(prey = 1.0, predator = 0.5)

function lotka!(D, u, p, t)
    D.prey = p.α * u.prey - p.β * u.prey * u.predator
    D.predator = -p.γ * u.predator + p.δ * u.prey * u.predator
    return nothing
end
```

`u.prey` and `u.predator` are views into one contiguous backing array — you get readable, named
access with no performance loss, and it remains a plain `AbstractArray` as far as a solver is
concerned, so it drops straight into `DifferentialEquations.jl`, `Optim.jl`, or anything else
expecting a flat state vector. This is usually a better fit than hand-rolled integer indexing or a
plain mutable struct once a model has more than two or three state variables, or any time you want
the model to stay readable as it grows.

## `AllocCheck.jl` — hard guarantees

For functions where you want a static allocation check for a concrete call signature (e.g. a hot
inner kernel called millions of times per simulation step):

```julia
using AllocCheck
@check_allocs function kernel(x, y)
    ...
end
```

This raises an error if the analysis detects a possible allocation for the checked signature. Use
it as a regression test alongside runtime measurements; dynamic dispatch and compiler-version
changes can affect what is provable.

## Sequencing

Fix type stability before chasing allocations — an unstable function usually allocates *because*
it's unstable, and optimizing array layout on top of unresolved instability is solving the wrong
problem. Once stability is settled, allocation profiling (`Profile.Allocs`, or simply `@allocated`
on a candidate function) will point you at real remaining costs rather than noise from boxing.
