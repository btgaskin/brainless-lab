---
name: julia
description: Comprehensive guide for writing, reviewing, debugging, and optimizing Julia code for scientific computing — covering type stability, multiple dispatch design, memory and allocations, profiling/debugging tools, package and environment management, parallelism, and the scientific ecosystem (SciML/DifferentialEquations.jl, Agents.jl, DynamicalSystems.jl) relevant to computational neuroscience and artificial-life modeling. Use this skill any time Julia code is being written, generated, reviewed, refactored, explained, or debugged — including diagnosing why Julia code is slow, fixing type instabilities, choosing a package or data structure, setting up a Julia project environment, or reviewing someone else's (or your own previously generated) Julia code for correctness and idiom — even if the request doesn't explicitly mention "performance," "Julia," or this skill by name.
---

# Julia for Scientific Computing

This skill is a way of thinking about Julia, not a snippet library. Patterns go stale; the two
mechanical facts below don't. Hold onto them and most of what looks like a long list of "tips"
becomes one idea applied in different places.

## Serve the user's level of abstraction

When Julia is an implementation detail for a no/low-code user, operate the checked-in
project, examples, configs, and tests for them. Do not turn a research question into a Julia
lesson unless they ask. Lead with what ran, what changed, what the output means, and what was
verified; explain dispatch, types, or allocation only when it affects a decision.

Keep the environment safe: prefer the repository's pinned `--project=.` environment, do not
install into the shared global environment, and do not add optional visualization packages
to a package's root project merely to produce one figure. Use the repository's dedicated
tool/example environment or create a separate downstream environment.

## Pair Julia guidance with the project contract

When a repository supplies its own skill or handbook, read it with this skill. The
project-specific guide owns public names, scientific boundaries, execution tools, and
evidence language. This Julia guide owns language correctness, dispatch, inference,
allocations, environments, and package hygiene. Do not replace a project abstraction with a
more familiar Julia pattern until you have inspected its public methods and tests.

For BrainlessLab, use `skills/brainless-lab/SKILL.md` and the Core handbook. In particular,
preserve its task-outcome, embodiment, stable-identity, and synchronous-ensemble contracts
while applying the Julia checks below.

## The two pillars

Nearly everything about Julia performance, and a surprising amount about Julia *correctness* and
*style*, reduces to two questions:

1. **Can the compiler infer useful types through the hot path?** ("type stability")
2. **Does this code allocate memory it doesn't need to?** ("allocations")

Type instability can introduce dynamic dispatch, boxing, and allocations, but none of those
follows mechanically from every inferred `Union` or abstract boundary. Julia can efficiently
represent many small unions, and an unstable outer setup function may be harmless when a function
barrier hands concrete values to the hot loop. Allocations trigger garbage-collection work later,
so avoid them where repeated measurements show they matter. Almost every other rule in this skill
— avoid untyped globals, write functions not scripts, prefer dispatch over branching, use views,
preallocate buffers — is a consequence of these two questions, not an independent rule to
memorize. When you hit a Julia performance problem that is not covered explicitly below, inspect
inference and allocations before reaching for parallelism.

Use this distinction actively: it's the difference between teaching someone to spot a leak versus
handing them a list of buckets to check. A list of patterns tells you what to do in cases you've
seen before. The two pillars tell you what to look for in a case you haven't.

## Default posture when writing Julia code

Before reaching for any optimization trick, default to code that is naturally type-stable and
non-allocating:

- **Write functions, not top-level scripts.** Code at global/top-level scope is a major source of
  type instability (see below) and is also never specialized/compiled the way function bodies are.
  If you're writing more than a few lines of throwaway exploration, wrap it in a function.
- **Never read or write an untyped global inside a hot path.** A global's type can change at any
  time, so the compiler can't specialize code that touches it. If a value must be global, either
  make it `const`, or pass it as a function argument.
- **Prefer dispatch over runtime type-checking.** If you find yourself writing
  `if x isa Foo ... elseif x isa Bar ...`, that is very likely meant to be two methods of the same
  function, not one function with a branch. See `references/dispatch-and-design.md`.
  This is the single most common thing to fix when reviewing Julia code that was written by
  someone (or something) translating from a Python/MATLAB mental model.
- **Offer and use in-place operations in hot loops when output buffers can be reused.** A `!`
  suffix communicates mutation; it does not promise zero allocation, so measure the implementation.
- **Don't guess about types — read the actual code.** Annotate function arguments only when it
  clarifies intent or genuinely constrains dispatch; Julia's compiler already knows local variable
  and argument types from the call site in the vast majority of cases. Over-annotating is mostly
  harmless but it isn't the lever people coming from typed languages assume it is.
- **Set up a real project environment before adding packages.** `]activate .` (or
  `Pkg.activate(".")`) in a project folder before `]add`-ing anything, rather than installing into
  the shared default environment. See `references/packages-and-environments.md`.

## Reviewing or correcting Julia code

This is where most of the value of this skill lives day-to-day: catching the specific ways Julia
code goes wrong, whether written by a human translating habits from another language or generated
by a model pattern-matching on syntax without the underlying type-system reasoning. Run new or
unfamiliar Julia code through this list before trusting it:

| Smell | Why it's a problem | Where to look |
|---|---|---|
| `if x isa T1 ... elseif x isa T2` branching on type | Should usually be multiple dispatch | `dispatch-and-design.md` |
| A hot-path `struct` field typed `Real`, `Number`, `AbstractVector`, or `Any` | The compiler may not know the stored representation or method target; parameterize when the concrete type is part of the object | `type-stability.md` |
| `v = []` then `push!`-ing into it | Infers as `Vector{Any}`; every element boxed | `type-stability.md` |
| A hot function returning many unrelated types based on runtime values | Inference may widen and force dynamic dispatch downstream; small `Union{T,Nothing}` results are often efficient | `type-stability.md` |
| A closure that captures a variable reassigned after the closure is made | Gets heap-`Box`ed, loses all type info — easy to miss, large slowdown | `type-stability.md` |
| Global variables read inside a function, not passed as arguments | Compiler can't specialize; also makes the function untestable in isolation | this file, above |
| A new array allocated inside a loop that runs every step (e.g. inside an ODE right-hand-side or an agent step function) | Should be a preallocated buffer mutated in place | `memory-and-allocations.md` |
| `array[1:5, :]` used for a one-off read in a hot loop | Slicing copies; use `@views`/`view()` if you don't need a copy | `memory-and-allocations.md` |
| `@inbounds`/`@simd` sprinkled in before the code is even known to be correct or type-stable | Optimization theater — these don't fix instability and can hide real bugs (e.g. real out-of-bounds access) | `memory-and-allocations.md` |
| `@time` used once, inline, to judge performance | First call includes compilation time; single-sample timing is noisy | `debugging-and-profiling.md` |
| Threaded loop writing to a shared array without index-separated writes, or anything keyed on `threadid()` | Race condition / no longer safe across versions | `parallelism-and-gpu.md` |
| Packages added directly into the global `@v1.X` environment | Dependency-version conflicts across projects | `packages-and-environments.md` |
| An ODE/PDE right-hand-side that constructs a dynamic array on every call | May allocate at every solver step; compare an in-place form or a small static out-of-place state | `scientific-ecosystem.md` |

Don't just pattern-match this table mechanically, though — for each one, be able to say *why* in
terms of the two pillars. That's what lets you catch the variant that isn't on the list.

## Workflow: inspect → debug → clarify → optimize

When something is wrong or slow, work in this order. Skipping ahead (straight to "add `@threads`"
or "add `@inbounds`") on top of a type-unstable, allocation-heavy function just makes a slow thing
slow in more places.

1. **Inspect.** Is it even type-stable? `@code_warntype` for a single function;
   `JET.@report_opt` for instabilities buried several calls deep (`@code_warntype` only sees one
   function body at a time); `Cthulhu.@descend` to interactively walk down the call tree when JET's
   output is hard to localize. → `references/type-stability.md`
2. **Debug.** Is it even *correct*? `Infiltrator.@infiltrate` to pause and inspect locals cheaply;
   `Debugger.@enter` for full step-through when you need to walk into code you didn't write;
   `@debug`/`@info`/`@warn` instead of stray `println`s, since they carry source location and can
   be filtered/silenced. → `references/debugging-and-profiling.md`
3. **Clarify.** Do you actually understand what's being called and why? `@which f(x)` to find which
   method fires; `methodswith`, `supertypes`, `subtypes` from `InteractiveUtils` to explore the
   type hierarchy and available methods before assuming you need a new abstraction.
   → `references/dispatch-and-design.md`
4. **Optimize.** Only once the above are settled: benchmark properly with `BenchmarkTools.@btime`
   (interpolate external values with `$`) or `Chairmarks.@b`, not bare `@time`; profile with
   `Profile`/`ProfileView`/VSCode's `@profview` to find the actual bottleneck before changing
   anything; fix type stability and allocations first; reach for parallelism or GPU only after the
   single-threaded version is already lean, since parallelism multiplies whatever you start with,
   waste included. → `references/debugging-and-profiling.md`, `references/parallelism-and-gpu.md`

## Reference files

Read the relevant file(s) in full when a task calls for depth beyond the summary above — don't
guess at API details from memory once you're past the principle level.

- **`references/type-stability.md`** — what "type stable" precisely means, how to detect
  instability (`@code_warntype`, `JET.jl`, `Cthulhu.jl`), the specific causes (untyped globals,
  abstract struct fields, closures over reassigned variables, runtime-value-dependent return
  types), and how to fix or contain each one (function barriers, parametric structs,
  `DispatchDoctor.jl`).
- **`references/dispatch-and-design.md`** — multiple dispatch as Julia's actual design idiom
  (composition over inheritance), the Holy Traits pattern, method ambiguity and how to resolve it,
  function barriers, and the specific anti-pattern of writing `isinstance`-style branching instead
  of adding a method.
- **`references/memory-and-allocations.md`** — heap allocation and the GC, array views vs. copies,
  column-major iteration order, mutating (`!`) APIs and buffer reuse, `StaticArrays.jl` for small
  fixed-size state, `ComponentArrays.jl` for named structured state.
- **`references/debugging-and-profiling.md`** — `Infiltrator.jl`/`Debugger.jl`, logging macros,
  correct benchmarking with `BenchmarkTools.jl`/`Chairmarks.jl`, profiling and flame graphs with
  `Profile`/`ProfileView.jl`.
- **`references/packages-and-environments.md`** — `Project.toml`/`Manifest.toml`, environment
  activation, `Revise.jl`, precompilation (`PrecompileTools.jl`, `PackageCompiler.jl` sysimages),
  and code quality tooling (`Test.jl`, `Aqua.jl`, `JET.jl` test mode, `JuliaFormatter.jl`, style
  guides).
- **`references/parallelism-and-gpu.md`** — `Threads.@threads` and race-condition avoidance,
  `Distributed.jl`, GPU programming with `CUDA.jl`/`KernelAbstractions.jl`, SIMD, and when each is
  (and isn't) worth reaching for.
- **`references/scientific-ecosystem.md`** — domain-specific pointers for computational
  neuroscience and artificial-life work: `DifferentialEquations.jl`/`SciML` for ODE-based neuron
  and population models, `Agents.jl` for agent-based modeling, `DynamicalSystems.jl` for
  chaos/nonlinear-dynamics analysis. Read this when the task is domain work, not for general Julia
  questions — keep the core of this skill general-purpose.

## A note on scope

This skill is written to be useful for any Julia work, not only computational neuroscience or
artificial life — the two pillars and the inspect/debug/clarify/optimize workflow apply identically
to a data-cleaning script or a web backend. The domain ecosystem file exists because those are the
packages most likely to come up here, not because the skill assumes that's all you're doing. When
in doubt about which reference file to read, prefer the general one over the domain-specific one.
