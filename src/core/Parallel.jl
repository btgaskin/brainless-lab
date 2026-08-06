import LinearAlgebra

const _PARALLEL_MAP_ACTIVE_KEY = gensym(:brainlesslab_parallel_map_active)

function _parallel_map_chunk(f, items, indices)
    storage = task_local_storage()
    had_previous = haskey(storage, _PARALLEL_MAP_ACTIVE_KEY)
    previous = get(storage, _PARALLEL_MAP_ACTIVE_KEY, false)
    storage[_PARALLEL_MAP_ACTIVE_KEY] = true
    try
        return map(index -> f(items[index]), indices)
    finally
        if had_previous
            storage[_PARALLEL_MAP_ACTIVE_KEY] = previous
        else
            delete!(storage, _PARALLEL_MAP_ACTIVE_KEY)
        end
    end
end

"""
    parallel_map(f, items; threaded=true)

Ordered map over `items` running `f` on Julia threads via dynamically
scheduled `Threads.@spawn` tasks. At most `Threads.nthreads()` worker tasks
are created, and a nested `parallel_map` runs serially inside its outer worker
so nested pipelines keep the same process-wide bound. Falls back to a serial `map` when
`threaded=false`, when Julia has a single thread, or when there is at most
one item. `f` must be thread-safe: no shared mutable state, and any RNG it
uses must be constructed inside the call (all BrainlessLab rollouts build
their RNGs from explicit seeds, so seeded rollouts qualify).

Results are returned in the order of `items` regardless of completion
order, so seeded pipelines produce byte-identical outputs with and without
threading.
"""
function parallel_map(f, items; threaded::Bool=true)
    items_v = collect(items)
    nested = get(task_local_storage(), _PARALLEL_MAP_ACTIVE_KEY, false)
    if !threaded || nested || Threads.nthreads() == 1 || length(items_v) <= 1
        return map(f, items_v)
    end

    worker_count = min(Threads.nthreads(), length(items_v))
    chunk_length = cld(length(items_v), worker_count)
    ranges = UnitRange{Int}[
        start:min(start + chunk_length - 1, length(items_v))
        for start in 1:chunk_length:length(items_v)
    ]
    tasks = [
        Threads.@spawn _parallel_map_chunk(f, items_v, indices)
        for indices in ranges
    ]
    chunks = [fetch(task) for task in tasks]
    return vcat(chunks...)
end

"""
    init_parallelism!(; verbose=false)

Prepare the process for coarse-grained (rollout-level) parallelism: when
Julia has more than one thread, pin BLAS/LAPACK to a single thread so
per-rollout linear algebra (e.g. `eigvals` spectral-radius probes) does not
oversubscribe cores underneath `parallel_map`. Single-threaded sessions are
left untouched so standalone linear algebra keeps BLAS's own threading.

Returns `(julia_threads=…, blas_threads=…)`. Call once from a run
entrypoint (sweep/profile/evolve) before heavy work.
"""
function init_parallelism!(; verbose::Bool=false)
    if Threads.nthreads() > 1
        LinearAlgebra.BLAS.set_num_threads(1)
    end
    info = (
        julia_threads=Threads.nthreads(),
        blas_threads=LinearAlgebra.BLAS.get_num_threads(),
    )
    if verbose
        @info "BrainlessLab parallelism" julia_threads = info.julia_threads blas_threads = info.blas_threads
        info.julia_threads == 1 && @info "running single-threaded; launch Julia with `-t auto` (or let the run scripts re-exec) to parallelise rollouts"
    end
    return info
end
