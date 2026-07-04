# Parallelism and GPU

## Parallelize last, not first

Parallelism multiplies whatever the single-threaded version already does — including its waste. A
type-unstable, allocation-heavy function run on 8 threads is 8 parallel copies of the same
inefficiency, fighting each other for GC time besides. Get the serial version type-stable and
allocation-lean first (`type-stability.md`, `memory-and-allocations.md`); only then ask whether
parallelism is worth the added complexity for the remaining cost.

## Multithreading

Enable threads at startup, not at runtime:

```
julia --threads 4
julia -t auto
```

```julia
Threads.nthreads()   # confirm it took effect
```

Parallelize a loop with `Threads.@threads`:

```julia
results = zeros(Int, 4)
Threads.@threads for i in 1:4
    results[i] = i^2
end
```

**The rule that prevents almost all multithreading bugs here: separate which memory each thread
writes by loop index**, as above — thread `i` only ever writes `results[i]`. The moment two threads
might write the *same* location, you have a race condition, and the fix is almost never "add a
lock around everything" (which just serializes the work back to single-threaded with extra
overhead) — restructure so each thread owns disjoint output, or accumulate into per-thread buffers
and reduce them afterward.

**Don't use `threadid()` as an array index.** It's tempting (`buffer[threadid()] += ...`) but
unsafe across Julia versions, because tasks can migrate between threads mid-execution; what looked
like a per-thread buffer can silently become a shared, racily-written one. Prefer
`Threads.@threads` over manual `threadid()`-indexed buffers, or use a higher-level package (below)
that handles this correctly for you.

`OhMyThreads.jl` is a friendlier, less footgun-prone layer over `Threads` (map/reduce-style
primitives instead of raw loop indexing) — worth defaulting to once a parallel pattern is more
complex than a single flat loop. For very lightweight, frequently-spawned tasks where thread-spawn
latency itself becomes the bottleneck, `Polyester.jl` provides cheaper threads at the cost of some
flexibility.

**BLAS interaction:** linear algebra calls (`*`, `\`, etc.) already use their own internal thread
pool via BLAS/LAPACK. If you're also using `Threads.@threads` around code that calls into linear
algebra, you can oversubscribe the machine; consider `BLAS.set_num_threads(1)` (after `using
LinearAlgebra`) when you're providing the parallelism yourself at a higher level.

## Distributed computing

`Distributed.jl` is for **multiple processes** (no shared memory) rather than multiple threads in
one process — the natural fit for an HPC cluster, or for embarrassingly parallel work where each
unit is heavy enough that process-spawn overhead doesn't matter (e.g. independent replicate runs of
a stochastic agent-based or neural simulation, swept across parameter values).

```julia
using Distributed
addprocs(3)
@everywhere using SharedArrays
@everywhere f(x) = 3x^2

results = SharedArray{Int}(4)
@sync @distributed for i in 1:4
    results[i] = f(i)
end
```

`@everywhere` is required for any function or `using` statement that worker processes need to see
— easy to forget and a common source of `UndefVarError` on workers. `pmap` is the convenient
function for "map this over many inputs, distributed across workers" without hand-managing the
loop:

```julia
results = pmap(f, 1:100; distributed=true, batch_size=25)
```

For cluster-scale work specifically, `MPI.jl` (wrapping the standard, highly-optimized C MPI
library) typically outperforms plain `Distributed.jl` once you're scaling to a large number of
cores — worth reaching for at that point rather than before.

## GPU

`CUDA.jl` (NVIDIA) is the most mature entry point into Julia's GPU ecosystem;
`KernelAbstractions.jl` lets you write a kernel once in a vendor-agnostic way and target multiple
backends. GPU work is the right fit for **large, regular, dense workloads** — a grid-based
artificial-life world updated all at once, a large population of neurons sharing the same update
rule, a big matrix operation — and a poor fit for **small, irregular, branch-heavy workloads** where
individual agents take meaningfully different code paths, since GPUs execute most efficiently when
many threads run the same instructions together. An agent-based model with a handful of agent
types and light per-step logic is often better served by good multithreading on CPU than by a GPU
port; profile before assuming GPU is the answer.

## SIMD: last-mile, not first-resort

`@simd` and `@inbounds` are micro-optimizations that help the compiler vectorize tight numerical
loops — but they're meaningful only once the loop is already correct and type-stable, and
`@inbounds` specifically disables Julia's bounds checking, which means an actual out-of-bounds bug
becomes silent memory corruption instead of a clear error. Don't add either while a function is
still being debugged; add them last, after correctness is established, as a measured final pass
(confirm with a benchmark that it actually helped — the compiler often vectorizes well on its own
without help).
