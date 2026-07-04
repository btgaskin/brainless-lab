# Multiple Dispatch and Design

## Functions vs. methods

In Julia, a **function** is just a name (`push!`, `+`, `step!`). A **method** is one specific
implementation of that function for a particular combination of argument types. Defining
`f(x::Int) = ...` and `f(x::String) = ...` creates two methods of one function `f`. Choosing which
method runs for a given call is **dispatch**, and Julia chooses based on the runtime types of
*all* of a function's arguments, not just the first one (as in single-dispatch OO languages, where
only the receiver — `self`/`this` — determines the method). This is what "multiple dispatch" means,
and it is Julia's primary mechanism for abstraction — not a performance feature bolted on, *the*
design idiom the rest of the language is built around.

## Composition over inheritance

Julia structs cannot inherit fields or behavior from one another (only abstract types form a
hierarchy, and abstract types carry no fields or methods of their own — they exist purely to be
dispatched on). This is a deliberate design choice, not a missing feature. The idiomatic
replacement for "subclass and override" is: define an abstract type for the *interface*, write
generic functions against it, and add concrete struct + method pairs for each variant. There's no
`super.method()` call to reach for — if you want shared behavior, you either write a generic
method that already works for all subtypes (via dispatch on the abstract supertype), or you
compose: hold an instance of another type as a field and forward to it explicitly.

```julia
abstract type Neuron end

step!(n::Neuron, dt) = error("step! not implemented for $(typeof(n))")  # interface contract

struct LIFNeuron <: Neuron
    v::Float64
    τ::Float64
end
step!(n::LIFNeuron, dt) = ...   # concrete implementation

struct IzhikevichNeuron <: Neuron
    v::Float64
    u::Float64
end
step!(n::IzhikevichNeuron, dt) = ...   # different implementation, same interface
```

Generic code that only calls `step!(n, dt)` works for any current or future subtype of `Neuron`
without modification — this is the same payoff polymorphism gives you elsewhere, achieved without
a class hierarchy.

## The anti-pattern: branching where a method belongs

The most common thing to fix when reviewing Julia code — especially code translated from a
Python/MATLAB mental model, human or model-generated — is type-checking branches that should be
methods:

```julia
# works, but fights the language
function area(shape)
    if shape isa Circle
        return π * shape.r^2
    elseif shape isa Rectangle
        return shape.w * shape.h
    end
end

# idiomatic: each case is its own method, dispatch picks the right one
area(s::Circle) = π * s.r^2
area(s::Rectangle) = s.w * s.h
```

The dispatch version isn't just shorter — it's open to extension. Anyone (including you, in a
different file) can later add `area(s::Triangle) = ...` without touching the original function at
all. The `isinstance`-style version requires editing the original function every time a new case
is added, and it's also frequently *type-unstable*, because the return type can end up depending
on which branch fires rather than on the argument type alone (see `type-stability.md`).

This generalizes beyond shapes: an agent-stepping function with a big `if agent.kind == :predator`
branch in an ABM, or a neuron-update function with `if neuron_type == "LIF"` — both are usually
better expressed as one function with multiple methods (or one method per agent/neuron *type*,
which Agents.jl supports natively — see `scientific-ecosystem.md`).

## Method ambiguity

Adding methods freely is powerful but can create ambiguity: two methods that are both maximally
specific for a given call, with neither strictly more specific than the other.

```julia
f(x, y::String) = "x & string"
f(x::String, y) = "string & x"

f("a", "b")  # ERROR: MethodError: f(::String, ::String) is ambiguous
```

The fix is almost always to add the explicit, more specific method that resolves the overlap:

```julia
f(x::String, y::String) = "string & string"
```

Read ambiguity errors as the compiler asking you to be more specific about an intersection you
hadn't considered — not as a sign multiple dispatch is broken. It's the same kind of edge case
that diamond inheritance creates in OO languages, surfaced explicitly instead of resolved by a
silent (and sometimes surprising) method-resolution-order rule.

## Holy Traits — dispatching across an unrelated type hierarchy

Sometimes you want to dispatch on a *property* of a type that cuts across its natural type
hierarchy — for example, "is this iterable thing sized in O(1) or not," independent of what kind
of container it is. You can't express that with a `Union` of types cleanly, because the set isn't
closed (you want new types to be able to opt in later). The idiomatic answer is the **Holy Traits**
pattern: a generic function that maps types to a small set of marker types (the "trait"), which
you then dispatch on.

```julia
abstract type IterationStyle end
struct HasLength <: IterationStyle end
struct IsInfinite <: IterationStyle end

iteration_style(::Type{<:AbstractArray}) = HasLength()
iteration_style(::Type{<:Base.Generator}) = IsInfinite()   # illustrative

# dispatch on the trait, not the concrete type
collect_safely(x) = collect_safely(iteration_style(typeof(x)), x)
collect_safely(::HasLength, x) = collect(x)
collect_safely(::IsInfinite, x) = error("can't collect an infinite iterator")
```

Reach for this when you find yourself wanting to write `if T <: A || T <: B` style logic against
an open-ended, extensible set of types — it's a real pattern with a name, not a hack, and you'll
recognize it in a lot of Julia ecosystem code (e.g. how broadcasting and array styles work
internally) once you know what to look for.

## Function barriers (design angle)

Covered in `type-stability.md` from the performance side; the design-level version of the same
idea is: write an outer function that handles setup, parsing, and anything inherently
type-unstable, then dispatch into an inner function that does the actual repeated work. This is
good *structure* independent of performance — it separates "figure out what we're doing" from
"do the thing," which tends to make code easier to test and read, and as a side effect it's also
exactly what keeps instability from propagating into your hot loop.

## When not to over-engineer this

Two methods and a straightforward `if` are not the same problem. If you have one true conditional
that will never grow new cases (e.g. handling a `nothing` sentinel), a plain `if`/`isnothing` check
is fine and often clearer than inventing a trait or a method split for it. Reach for dispatch when
the branch is really "this is a different *kind* of thing and more kinds are likely to show up,"
not for every conditional in the codebase.
