# Memory and Allocations

## What an allocation is, and why it costs more than it looks like

A "heap allocation" happens whenever Julia creates a value whose size isn't known statically (a
resizable `Vector`, a new `String`, a boxed value from a type instability). Julia's garbage
collector (a mark-and-sweep collector) periodically pauses execution to reclaim unused heap memory
— so allocations don't just cost the allocation itself, they cost GC time later, and that GC pause
affects the *whole program*, not just the function that allocated. Numbers (other than `BigInt`),
tuples, and immutable structs of concrete fields don't need this — they can live on the stack or
in registers, which is essentially free by comparison.

**Practical rule:** unexpected allocations reported by `@time`, `@allocated`, or a profiler are
almost always a symptom of a type instability (see `type-stability.md`) or of avoidable temporary
array creation, not just an inherent cost of the computation. Treat "why is this allocating" as a
question with a findable answer, not background noise.

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

The `!`-suffix convention (`push!`, `sort!`, and the entire `f!(du, u, p, t)` style used by
`DifferentialEquations.jl`) exists specifically to let a function write into memory that's already
been allocated, instead of allocating fresh output every call. If you're writing a function that
will be called every step of a simulation, every iteration of an optimizer, or every agent on every
tick — write the in-place form:

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

For arrays whose size is known at compile time and small (roughly under 20-100 elements —
the exact cutoff depends on the operation), `StaticArrays.jl` encodes the size *in the type*:

```julia
using StaticArrays
v = SA[1.0, 2.0, 3.0]        # SVector{3,Float64} — immutable, stack-allocated
m = SA[1.0 0.0; 0.0 1.0]     # SMatrix{2,2,Float64}
```

Because the size is part of the type, `SArray`/`SVector`/`SMatrix` are immutable and can live on
the stack — no GC involvement at all, and operations on them (especially linear algebra) get
specialized, unrolled methods via dispatch on the size. `MArray`/`MVector`/`MMatrix` give you a
mutable variant when you need to update in place but still want the stack-allocation benefit.

This is exactly the right tool for **per-agent state in an agent-based model** or **per-neuron
state in a small ODE system** (e.g. a single Hodgkin-Huxley neuron's `(V, m, h, n)` state) — small,
fixed shape, created and destroyed extremely often. See `scientific-ecosystem.md` for the
`DifferentialEquations.jl`-specific version of this (small systems should use a `StaticArray` as
`u0` and an out-of-place, non-mutating right-hand side).

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

For functions where you want a compile-time-checkable promise of zero allocation (e.g. a
hot inner kernel called millions of times per simulation step):

```julia
using AllocCheck
@check_allocs function kernel(x, y)
    ...
end
```

This raises an error if the compiler detects the function might allocate — useful as a regression
test (`@test isempty(AllocCheck.check_allocs(kernel, (Float64, Float64)))`) so a future innocuous-
looking change can't silently reintroduce allocation into a function you've already tuned.

## Sequencing

Fix type stability before chasing allocations — an unstable function usually allocates *because*
it's unstable, and optimizing array layout on top of unresolved instability is solving the wrong
problem. Once stability is settled, allocation profiling (`Profile.Allocs`, or simply `@allocated`
on a candidate function) will point you at real remaining costs rather than noise from boxing.
