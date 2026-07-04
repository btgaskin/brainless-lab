# Type Stability

## What it actually means

A piece of code is **type stable** if the compiler can infer a single, concrete type for every
variable and every expression, using only the types of the function's arguments — not their
runtime values. "Concrete" matters specifically: `Int64` and `Float64` are concrete; `Real`,
`Number`, `Any`, and an unparameterized `Vector` (`Vector{T} where T`) are not. A field, variable,
or return value typed as something abstract can't be given a fixed memory layout at compile time,
so the compiler has to fall back on heap-allocated, pointer-chasing, runtime-dispatched code —
the dynamic-language slow path, in a language that otherwise avoids it.

This is the single biggest lever on Julia performance, and it's also a *correctness/maintainability*
signal: type-stable code is what `JET.jl`-style static analysis can actually reason about, what
the compiler can inline and specialize well, and what tends to have fewer accidental bugs, because
"the type changed somewhere I didn't expect" is itself usually the bug.

## Detecting instability

### `@code_warntype` — single function, ground truth

```julia
function put_in_vec_and_sum(x)
    v = []
    push!(v, x)
    return sum(v)
end

@code_warntype put_in_vec_and_sum(1)
```

Read the `Body::` line at the top of the output. If it's an abstract type (`Any`, a `Union`, or
similar) instead of something concrete like `Int64`, the function is not type-stable. In a REPL,
unstable lines are colored red. The locals section will also show `v::Vector{Any}` here — the
literal `[]` has no element type information, so `push!`-ing into it produces an `Any`-typed
container, and everything downstream (`sum(v)`) inherits that uncertainty.

**Limitation:** `@code_warntype` only shows you *one* function body. Calls to other functions are
opaque — if the instability is two or three calls deep, this won't show it to you directly.

### `JET.jl` — whole-call-stack analysis

```julia
using JET
@report_opt put_in_vec_and_sum(1)
```

`@report_opt` walks the entire call graph and reports every place a runtime dispatch happens
because of a type instability, including ones buried inside functions you didn't write (Base,
stdlib, or a dependency). This is the right tool when `@code_warntype` looks clean at the top
level but something is still slow — the instability is almost always somewhere downstream that
the single-frame view can't see.

JET also has an *error* analysis mode (`@report_call`, or `report_package`/`test_package` for a
whole package) that finds likely `MethodError`s and similar bugs statically, without running the
code — useful as a lint pass over generated or unfamiliar code before you even run it.

### `Cthulhu.jl` — interactive descent

```julia
using Cthulhu
@descend put_in_vec_and_sum(1)
```

`@descend` is `@code_warntype`, but interactive: you can step into any call shown in the output and
look at *its* typed code, recursively. Use this when JET has told you instability exists somewhere
in a deep call chain and you need to localize exactly which frame introduces it.

### `DispatchDoctor.jl` — make instability loud instead of silent

```julia
using DispatchDoctor
@stable function f(x)
    ...
end
```

`@stable` turns a type instability into a hard error at the call site, rather than a silent
slowdown. Useful on functions you've already fixed once, as a regression guard.

## Common causes, and how to fix or contain each

### 1. Untyped or non-`const` globals

```julia
# bad: x's type can change at any time
x = 1.0
f() = x + 1

# fixed: make it const, or...
const x = 1.0

# ...better: don't use a global at all, pass it as an argument
f(x) = x + 1
```

This is the single most common beginner instability, and the official Julia manual leads with it
for a reason: every other instability on this list is at least somewhat structural, but this one
is purely a habit to drop.

### 2. Abstract or unparameterized struct fields

```julia
# bad: Real is abstract — the compiler doesn't know if a field is Float64, Int, BigFloat...
struct Particle
    mass::Real
    velocity::Real
end

# fixed: parametrize, and let the constructor infer T
struct Particle{T<:Real}
    mass::T
    velocity::T
end
```

`isconcretetype(Real)` is `false`; `isconcretetype(Particle{Float64})` is `true`. The unparametrized
version forces every field access to go through a boxed pointer. This matters enormously for
anything holding per-agent or per-neuron state in a simulation loop — exactly the kind of struct
that gets created thousands or millions of times.

A subtlety: `isconcretetype(Vector{Real})` is actually `true` — but it's still slow in practice,
because each *element* of the vector is independently boxed (the vector itself is a concrete
container of an abstract element type). Concrete-container-of-abstract-element is its own version
of this same mistake.

### 3. Return type depends on a runtime value, not argument types

```julia
# bad: the branch taken depends on n's *value*, not its type — return type is Union{Int,Float64}
function maybe_float(n)
    if n > 0
        return n
    else
        return float(n)
    end
end
```

Even Julia's own `findfirst` is type-unstable in exactly this way — it returns an index or
`nothing` depending on whether anything matched. This is sometimes acceptable (see "function
barriers" below for how to contain it), but avoid introducing it gratuitously in your own hot-path
code.

### 4. Closures that capture a reassigned variable

This is the least obvious one and worth internalizing as its own category, because it produces
correct-looking code that is silently 10-100x slower with no warning:

```julia
function abmult(r1::Int)
    if r1 < 0
        r1 = -r1        # reassignment! r1 is mutated after being introduced
    end
    f = x -> x * r1      # closure captures r1
    return f
end
```

Because `r1` is reassigned inside the function, Julia's compiler can't prove its type won't change
again later, so it heap-allocates a `Core.Box` to hold it and the closure reads through that box —
losing all concrete-type information, even though `r1` is always an `Int` in practice. Check with
`@code_warntype`: a captured variable showing up as `::Core.Box` instead of its real type is this
exact issue.

Fixes, in order of preference:
- Don't reassign the captured variable; introduce a new name instead (`r1_abs = abs(r1)`).
- Annotate the captured variable's type explicitly: `r::Int = r1`.
- Wrap the closure in a `let` block that re-binds the variable locally (`FastClosures.jl`'s
  `@closure` macro automates this).

This shows up constantly in `Threads.@threads` loops and in callback functions passed to solvers
or optimizers — anywhere a closure is built inside a loop or conditional.

### 5. Untyped container literals

```julia
v = []          # Vector{Any} — every push! boxes its argument
v = Float64[]   # concrete, stable
```

### Containing instability you can't eliminate: function barriers

Sometimes a type instability is unavoidable at a boundary (reading a heterogeneous file, dispatch
on a value only known at runtime, etc.). The fix isn't to eliminate it everywhere — it's to *contain*
it, by pushing the unstable part into a thin outer function that immediately hands off to a
concrete, stable inner function:

```julia
function process(data)            # unstable: data's element type isn't known until runtime
    return _process_typed(data)   # function barrier — compiler specializes this call fully
end

function _process_typed(data::Vector{T}) where T   # stable from here down
    ...
end
```

The instability "stops" at the barrier; everything inside `_process_typed` is compiled as if `T`
were known from the start, because it *is* known once you're inside that call. This is the
standard way to write a `setup`-then-`run-many-iterations` function (also a good idea for clarity
on its own): do the ambiguous part once, then call into a stable core that runs in a loop.

## A note on proportionality

Not all instability is worth chasing. If an unstable value is produced once, never touches a hot
loop, and is immediately consumed by something else that's stable, the cost is bounded and may not
matter. Use `@code_warntype`/JET to *find* instability, but use judgment about whether it's on a
path that's actually called often before spending time fixing it. The two-pillar framing in the
main `SKILL.md` exists precisely so you reason about *why* something matters rather than chasing
every red line mechanically.
