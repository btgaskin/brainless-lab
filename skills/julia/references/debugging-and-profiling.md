# Debugging and Profiling

## Logging beats printing

`println`/`@show` work, but Julia's logging macros (`@debug`, `@info`, `@warn`, `@error`) are
strictly more useful for anything beyond a one-off check: they record the source file and line,
can be filtered by severity and by source module (via the `JULIA_DEBUG` environment variable),
work correctly across threads (where interleaved `println` output gets garbled), and can be routed
to a file. Default to them over stray `println`s, especially in code that will be run more than
once.

```julia
@warn "negative population detected" species=i value=pop[i]
```

`@debug` messages are suppressed by default — set `JULIA_DEBUG=Main` (or your module's name) to
see them without deleting and re-adding print statements every time you need them.

## `Infiltrator.jl` — cheap, REPL-native breakpoints

```julia
using Infiltrator

function step!(model, t)
    @infiltrate          # pause here, drop into an `infil>` REPL with access to all locals
    ...
end
```

When a run hits `@infiltrate`, the REPL prompt changes to `infil>` and you can inspect or evaluate
against the local scope directly. `@exfiltrate` lets you pull specific locals out into a global
`safehouse` so you can keep inspecting them after you `@continue` past the breakpoint:

```julia
infil> @exfiltrate k F
infil> @continue
julia> safehouse.k     # available now, outside the function
```

`Infiltrator.jl` adds essentially no runtime overhead when the breakpoint isn't hit, which makes
it reasonable to leave in code during development, unlike a full debugger.

## `Debugger.jl` — full step-through

```julia
using Debugger
@enter step!(model, t)
```

`@enter` drops you into a true step-through debugger (`1|debug>` prompt) that can walk into
function calls you didn't write — including into Base or a dependency — at the cost of running
under an interpreter, which is much slower than normal execution. Reach for this when
`Infiltrator.jl`'s "pause and look" isn't enough and you need to actually trace execution path by
path, especially through code you don't control. (VSCode's Julia extension also provides a
graphical breakpoint-and-step debugger built on the same machinery, if you'd rather click than type
navigation commands.)

## Benchmarking correctly

### Why bare `@time` is misleading

```julia
@time sum_abs(v)   # first call: dominated by compilation time, not actual runtime
@time sum_abs(v)   # second call: closer to real, but still a single noisy sample
```

A function must be compiled before it can run, and `@time` includes that compilation cost on the
first call — you'll see something like "99% compilation time," which tells you almost nothing
about steady-state performance. Even on a warmed-up call, a single sample is vulnerable to
whatever else your machine happened to be doing at that instant.

### `BenchmarkTools.jl`

```julia
using BenchmarkTools
@btime sum_abs($v)     # the $ interpolates v as a literal value, avoiding global-variable overhead
```

`@btime` runs the code many times and reports a robust statistic, not a single sample. The `$`
interpolation matters specifically when benchmarking with variables defined at the REPL/global
scope — without it, you're partly measuring the cost of reading an untyped global, not your
function. For setups that need fresh random input on every sample:

```julia
@btime my_matmul(A, b) setup=(A = rand(1000,1000); b = rand(1000))
```

Watch for suspiciously fast results (sub-nanosecond) — the compiler may have constant-folded the
entire computation away because the benchmarked expression didn't depend on anything unpredictable
at compile time. That's a benchmark artifact, not a real result.

### `Chairmarks.jl`

A lighter-weight alternative with similar intent (`@b`/`@be` instead of `@btime`), useful when
`BenchmarkTools.jl`'s overhead or dependency footprint is unwelcome. Functionally interchangeable
for most everyday use.

## Profiling: find the bottleneck before changing anything

A benchmark tells you *that* something is slow in aggregate; a profiler tells you *which part*.
Don't optimize by guessing — profile first, especially once a simulation or model has more than a
handful of functions in its call path.

```julia
using Profile, ProfileView
@profview do_work(some_input)   # opens an interactive flame graph
```

(In VSCode's integrated REPL, `@profview` works without a separate package.) In a flame graph, each
horizontal layer is a level of the call stack and the width of a block is proportional to time
spent there — wide blocks are where your time is actually going. If the code under test runs too
fast to collect enough samples, wrap it in a loop before profiling.

For memory specifically, `Profile.Allocs` (or VSCode's `@profview_allocs`) profiles *allocations*
rather than time, which is the more direct tool when you already suspect a memory/GC problem
specifically rather than a generic slowdown.

For labeling and timing specific named sections of a larger program without the overhead of a full
profiler, `TimerOutputs.jl` lets you wrap sections in labels and prints a grouped summary table —
useful for "which phase of my simulation step is expensive" at a coarser grain than line-level
profiling.

## Putting it together

The order matters: confirm correctness (debugger/logging) → confirm type stability
(`type-stability.md`) → benchmark properly (`BenchmarkTools.jl`, not bare `@time`) → profile to find
the actual bottleneck → optimize that specific thing → re-benchmark to confirm the change helped.
Each step is cheap; skipping straight to "optimize" without the earlier steps tends to produce
effort spent on code that either wasn't the bottleneck or wasn't even correct to begin with.
