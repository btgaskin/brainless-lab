using Random

# CMA-ME: a MAP-Elites archive (keyed by discretized per-task-score descriptors,
# so nothing about the 5-task tradeoff gets collapsed the way evolve()'s
# :min/:mean aggregator does), filled by several independent sep-CMA-ES
# "improvement emitters" -- each one is a plain `SepCMA` from Evolve.jl, just
# told "how much did you improve the archive" (Fontaine et al. 2020) instead of
# raw fitness. An emitter restarts from a fresh random archive elite whenever it
# goes a few iterations without improving anything.

Base.@kwdef mutable struct MEArchive
    bins::Int
    n_tasks::Int
    cells::Dict{Vector{Int},NamedTuple{(:genome, :descriptor, :quality),Tuple{Vector{Float64},Vector{Float64},Float64}}} =
        Dict{Vector{Int},NamedTuple{(:genome, :descriptor, :quality),Tuple{Vector{Float64},Vector{Float64},Float64}}}()
end

function _descriptor_key(descriptor::AbstractVector{<:Real}, bins::Integer)
    return [clamp(floor(Int, Float64(d) * bins), 0, bins - 1) for d in descriptor]
end

# Returns the improvement (>0 means the archive got better/gained a cell) of
# inserting `genome` with `descriptor`/`quality`, and performs the insertion.
function _archive_offer!(archive::MEArchive, genome::Vector{Float64}, descriptor::Vector{Float64}, quality::Float64)
    key = _descriptor_key(descriptor, archive.bins)
    existing = get(archive.cells, key, nothing)
    if existing === nothing
        archive.cells[key] = (genome=copy(genome), descriptor=copy(descriptor), quality=quality)
        return quality  # empty cell: treat the full quality as the improvement
    elseif quality > existing.quality
        improvement = quality - existing.quality
        archive.cells[key] = (genome=copy(genome), descriptor=copy(descriptor), quality=quality)
        return improvement
    end
    return 0.0
end

function _pareto_cells(archive::MEArchive)
    ks = collect(keys(archive.cells))
    descs = [archive.cells[k].descriptor for k in ks]
    front = Vector{Vector{Int}}()
    for i in eachindex(ks)
        dominated = any(j -> j != i && _dominates_max(descs[j], descs[i]), eachindex(ks))
        dominated || push!(front, ks[i])
    end
    return front
end

mutable struct _Emitter
    es::SepCMA
    since_improvement::Int
end

function _new_emitter(rng::AbstractRNG, x0::Vector{Float64}, sigma0::Real, popsize::Integer, seed::Integer)
    return _Emitter(SepCMA(x0, Float64(sigma0); popsize=Int(popsize), seed=Int(seed)), 0)
end

function _restart_emitter!(emitter::_Emitter, rng::AbstractRNG, archive::MEArchive, sigma0::Real, popsize::Integer, seed::Integer)
    cells = collect(values(archive.cells))
    x0 = isempty(cells) ? emitter.es.x_mean : cells[rand(rng, 1:length(cells))].genome
    emitter.es = SepCMA(x0, Float64(sigma0); popsize=Int(popsize), seed=Int(seed))
    emitter.since_improvement = 0
    return emitter
end

"""
    cma_me(; model_sym, train_tasks, bins=5, n_emitters=4, emitter_popsize=6,
             iterations=50, k_trials=4, kwargs...)

Quality-diversity evolution over an archive keyed by discretized per-task
normalized scores (one axis per entry of `train_tasks`). `n_emitters`
independent sep-CMA-ES instances propose candidates each iteration; a
candidate's objective for its emitter is how much it improves the archive
(fills an empty cell, or beats that cell's current elite), not its raw task
score. An emitter restarts from a random archive elite after `patience`
iterations without an improvement.
"""
function cma_me(;
    model_sym::Symbol,
    train_tasks,
    bins::Integer=5,
    n_emitters::Integer=4,
    emitter_popsize::Integer=6,
    iterations::Integer=50,
    k_trials::Integer=4,
    sigma0::Real=2.5,
    patience::Integer=8,
    N=nothing,
    ticks=nothing,
    seed::Integer=0,
    wiring_seed_base::Integer=1000,
    link_p::Real=0.1,
    rho::Real=0.2,
    window=nothing,
    lam::Real=1.0,
    threaded::Bool=true,
    kwargs...,
)
    bins = Int(bins)
    n_emitters = Int(n_emitters)
    emitter_popsize = Int(emitter_popsize)
    iterations = Int(iterations)
    k_trials = Int(k_trials)
    bins >= 2 || throw(ArgumentError("bins must be at least 2"))
    n_emitters >= 1 || throw(ArgumentError("n_emitters must be at least 1"))
    emitter_popsize >= 2 || throw(ArgumentError("emitter_popsize must be at least 2"))
    iterations >= 0 || throw(ArgumentError("iterations must be nonnegative"))
    k_trials >= 1 || throw(ArgumentError("k_trials must be at least 1"))

    node_sym = _canonical_model_sym(model_sym)
    n_nodes = N === nothing ? _default_node_count(node_sym) : Int(N)
    tasks = Tuple(resolve_task(t) for t in train_tasks)
    isempty(tasks) && throw(ArgumentError("train_tasks must contain at least one task"))
    m = length(tasks)

    rng = Random.Xoshiro(Int(seed))
    x0 = _default_x0(node_sym, n_nodes; ticks=ticks, link_p=link_p, rho=rho, window=window, kwargs...)
    archive = MEArchive(bins=bins, n_tasks=m)

    function evaluate(pop::Vector{Vector{Float64}}, generation::Integer)
        seeds = _train_seed_tuple(generation, k_trials, wiring_seed_base)
        task_means = Matrix{Float64}(undef, length(pop), m)
        for (j, task) in enumerate(tasks)
            mat = evaluate_fitness_matrix(pop, task, seeds; model_sym=node_sym, N=n_nodes, ticks=ticks,
                                           link_p=link_p, rho=rho, window=window, lam=lam, threaded=threaded, kwargs...)
            @inbounds for i in eachindex(pop)
                task_means[i, j] = _evolve_mean(@view mat[i, :])
            end
        end
        return [clamp.(Float64.(@view(task_means[i, :])), 0.0, 1.0) for i in eachindex(pop)]
    end

    # Seed the archive with a batch of random-around-centroid genomes so emitters
    # have somewhere to restart from before any CMA search has happened.
    init_batch = [x0 .+ Float64(sigma0) .* randn(rng, length(x0)) for _ in 1:(n_emitters * emitter_popsize)]
    init_descriptors = evaluate(init_batch, 0)
    n_evaluated = length(init_batch)
    for i in eachindex(init_batch)
        _archive_offer!(archive, init_batch[i], init_descriptors[i], _evolve_mean(init_descriptors[i]))
    end

    emitters = [_new_emitter(rng, x0, sigma0, emitter_popsize, Int(seed) + e) for e in 1:n_emitters]
    for (e_idx, emitter) in enumerate(emitters)
        _restart_emitter!(emitter, rng, archive, sigma0, emitter_popsize, Int(seed) + e_idx)
    end

    coverage_hist = Float64[]
    best_quality_hist = Float64[]

    for iter in 1:iterations
        for (e_idx, emitter) in enumerate(emitters)
            candidates = ask(emitter.es)
            descriptors = evaluate(candidates, iter * n_emitters + e_idx)
            n_evaluated += length(candidates)
            qualities = [_evolve_mean(d) for d in descriptors]
            improvements = [
                _archive_offer!(archive, candidates[i], descriptors[i], qualities[i]) for i in eachindex(candidates)
            ]
            tell!(emitter.es, candidates, .-improvements)

            if maximum(improvements) > 0.0
                emitter.since_improvement = 0
            else
                emitter.since_improvement += 1
                if emitter.since_improvement >= patience
                    _restart_emitter!(emitter, rng, archive, sigma0, emitter_popsize, Int(seed) + e_idx + iter)
                end
            end
        end

        n_cells_total = bins^m
        push!(coverage_hist, length(archive.cells) / n_cells_total)
        push!(best_quality_hist, isempty(archive.cells) ? NaN : maximum(c -> c.quality, values(archive.cells)))
    end

    isempty(archive.cells) && throw(ErrorException("cma_me produced an empty archive -- no candidate reached a scoreable state"))

    entries = collect(values(archive.cells))
    best = entries[argmax([e.quality for e in entries])]
    pareto_keys = _pareto_cells(archive)
    n_cells_total = bins^m

    return (
        archive=archive,
        pareto_front=[(genome=archive.cells[k].genome, descriptor=archive.cells[k].descriptor, quality=archive.cells[k].quality)
                      for k in pareto_keys],
        n_cells_filled=length(archive.cells),
        n_cells_total=n_cells_total,
        coverage=length(archive.cells) / n_cells_total,
        best_genome=copy(best.genome),
        best_descriptor=copy(best.descriptor),
        best_quality=best.quality,
        n_evaluated=n_evaluated,
        history=(coverage=coverage_hist, best_quality=best_quality_hist),
        config=(
            model_sym=node_sym,
            train_tasks=Tuple(t.name for t in tasks),
            bins=bins,
            n_emitters=n_emitters,
            emitter_popsize=emitter_popsize,
            iterations=iterations,
            k_trials=k_trials,
            sigma0=Float64(sigma0),
            patience=patience,
            seed=Int(seed),
            N=n_nodes,
            ticks=ticks,
        ),
    )
end
