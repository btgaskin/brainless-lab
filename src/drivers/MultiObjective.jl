using Random

# NSGA-II over the per-task normalized scores as separate objectives (maximized),
# rather than the `:min`/`:mean` scalarization `evolve()` uses. No fitness collapse
# happens anywhere in this loop -- selection works from (rank, crowding distance)
# computed on the raw objective vectors, and the output is a Pareto front, not a
# single winner.

function _dominates_max(a::AbstractVector{<:Real}, b::AbstractVector{<:Real})
    all_ge = true
    any_gt = false
    @inbounds for k in eachindex(a)
        if a[k] < b[k]
            all_ge = false
            break
        elseif a[k] > b[k]
            any_gt = true
        end
    end
    return all_ge && any_gt
end

function _fast_nondominated_sort(objs::Vector{Vector{Float64}})
    n = length(objs)
    dominated_by = [Int[] for _ in 1:n]
    dom_count = zeros(Int, n)
    fronts = Vector{Vector{Int}}()
    front1 = Int[]

    for p in 1:n
        for q in 1:n
            p == q && continue
            if _dominates_max(objs[p], objs[q])
                push!(dominated_by[p], q)
            elseif _dominates_max(objs[q], objs[p])
                dom_count[p] += 1
            end
        end
        dom_count[p] == 0 && push!(front1, p)
    end
    push!(fronts, front1)

    i = 1
    while !isempty(fronts[i])
        next_front = Int[]
        for p in fronts[i]
            for q in dominated_by[p]
                dom_count[q] -= 1
                dom_count[q] == 0 && push!(next_front, q)
            end
        end
        i += 1
        push!(fronts, next_front)
    end
    pop!(fronts)
    return fronts
end

function _crowding_distance(front::Vector{Int}, objs::Vector{Vector{Float64}})
    n = length(front)
    dist = zeros(Float64, n)
    n == 0 && return dist
    m = length(objs[front[1]])

    for k in 1:m
        vals = [objs[i][k] for i in front]
        order = sortperm(vals)
        dist[order[1]] = Inf
        dist[order[end]] = Inf
        span = vals[order[end]] - vals[order[1]]
        if span > 0 && n > 2
            for idx in 2:(n - 1)
                dist[order[idx]] += (vals[order[idx + 1]] - vals[order[idx - 1]]) / span
            end
        end
    end
    return dist
end

function _tournament(rng::AbstractRNG, pop::Vector{Vector{Float64}}, rank::Vector{Int}, crowd::Vector{Float64})
    n = length(pop)
    i = rand(rng, 1:n)
    j = rand(rng, 1:n)
    rank[i] != rank[j] && return rank[i] < rank[j] ? pop[i] : pop[j]
    return crowd[i] >= crowd[j] ? pop[i] : pop[j]
end

function _sbx_crossover(rng::AbstractRNG, p1::Vector{Float64}, p2::Vector{Float64},
                         lower::Vector{Float64}, upper::Vector{Float64}, pc::Real, eta_c::Real)
    c1 = copy(p1)
    c2 = copy(p2)
    rand(rng) > pc && return c1, c2

    @inbounds for j in eachindex(p1)
        rand(rng) > 0.5 && continue
        x1, x2 = p1[j], p2[j]
        abs(x1 - x2) < 1e-14 && continue
        xl, xu = lower[j], upper[j]
        y1, y2 = x1 < x2 ? (x1, x2) : (x2, x1)
        u = rand(rng)

        beta = 1.0 + 2.0 * (y1 - xl) / (y2 - y1)
        alpha = 2.0 - beta^(-(eta_c + 1.0))
        betaq = u <= 1.0 / alpha ? (u * alpha)^(1.0 / (eta_c + 1.0)) : (1.0 / (2.0 - u * alpha))^(1.0 / (eta_c + 1.0))
        child1 = 0.5 * ((y1 + y2) - betaq * (y2 - y1))

        beta = 1.0 + 2.0 * (xu - y2) / (y2 - y1)
        alpha = 2.0 - beta^(-(eta_c + 1.0))
        betaq = u <= 1.0 / alpha ? (u * alpha)^(1.0 / (eta_c + 1.0)) : (1.0 / (2.0 - u * alpha))^(1.0 / (eta_c + 1.0))
        child2 = 0.5 * ((y1 + y2) + betaq * (y2 - y1))

        child1 = clamp(child1, xl, xu)
        child2 = clamp(child2, xl, xu)
        if rand(rng) <= 0.5
            c1[j], c2[j] = child2, child1
        else
            c1[j], c2[j] = child1, child2
        end
    end
    return c1, c2
end

function _poly_mutate(rng::AbstractRNG, x::Vector{Float64}, lower::Vector{Float64}, upper::Vector{Float64},
                       pm::Real, eta_m::Real)
    y = copy(x)
    @inbounds for j in eachindex(x)
        rand(rng) > pm && continue
        xl, xu = lower[j], upper[j]
        xu <= xl && continue
        xj = y[j]
        delta1 = (xj - xl) / (xu - xl)
        delta2 = (xu - xj) / (xu - xl)
        u = rand(rng)
        mut_pow = 1.0 / (eta_m + 1.0)
        if u < 0.5
            xy = 1.0 - delta1
            val = 2.0 * u + (1.0 - 2.0 * u) * xy^(eta_m + 1.0)
            deltaq = val^mut_pow - 1.0
        else
            xy = 1.0 - delta2
            val = 2.0 * (1.0 - u) + 2.0 * (u - 0.5) * xy^(eta_m + 1.0)
            deltaq = 1.0 - val^mut_pow
        end
        y[j] = clamp(xj + deltaq * (xu - xl), xl, xu)
    end
    return y
end

"""
    nsga2(; model_sym, train_tasks, popsize=32, generations=30, k_trials=4, kwargs...)

Multi-objective evolution treating each task in `train_tasks` as a separate
objective (maximized). Returns the final population, its objective vectors,
the rank-1 Pareto front, and a `best_mean_genome` convenience pick (the
population member with the highest mean objective, useful when a caller wants
one genome rather than a front).
"""
function nsga2(;
    model_sym::Symbol,
    train_tasks,
    popsize::Integer=32,
    generations::Integer=30,
    k_trials::Integer=4,
    sigma0::Real=2.5,
    bound_scale::Real=6.0,
    pc::Real=0.9,
    eta_c::Real=15.0,
    pm::Union{Nothing,Real}=nothing,
    eta_m::Real=20.0,
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
    popsize = Int(popsize)
    generations = Int(generations)
    k_trials = Int(k_trials)
    popsize >= 4 || throw(ArgumentError("popsize must be at least 4"))
    generations >= 0 || throw(ArgumentError("generations must be nonnegative"))
    k_trials >= 1 || throw(ArgumentError("k_trials must be at least 1"))

    node_sym = _canonical_model_sym(model_sym)
    n_nodes = N === nothing ? _default_node_count(node_sym) : Int(N)
    tasks = Tuple(resolve_task(t) for t in train_tasks)
    isempty(tasks) && throw(ArgumentError("train_tasks must contain at least one task"))
    m = length(tasks)

    rng = Random.Xoshiro(Int(seed))
    x0 = _default_x0(node_sym, n_nodes; ticks=ticks, link_p=link_p, rho=rho, window=window, kwargs...)
    n_dim = length(x0)
    lower = x0 .- Float64(bound_scale) * Float64(sigma0)
    upper = x0 .+ Float64(bound_scale) * Float64(sigma0)
    pm_ = pm === nothing ? 1.0 / n_dim : Float64(pm)

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

    pop = [clamp.(x0 .+ Float64(sigma0) .* randn(rng, n_dim), lower, upper) for _ in 1:popsize]
    objs = evaluate(pop, 0)
    n_evaluated = popsize

    gens_seen = Int[]
    mean_objectives_hist = Vector{Vector{Float64}}()
    n_front1_hist = Int[]

    for gen in 1:generations
        fronts = _fast_nondominated_sort(objs)
        rank = Vector{Int}(undef, length(pop))
        crowd = zeros(Float64, length(pop))
        for (r, front) in enumerate(fronts)
            d = _crowding_distance(front, objs)
            for (k, idx) in enumerate(front)
                rank[idx] = r
                crowd[idx] = d[k]
            end
        end

        offspring = Vector{Vector{Float64}}(undef, popsize)
        i = 1
        while i <= popsize
            p1 = _tournament(rng, pop, rank, crowd)
            p2 = _tournament(rng, pop, rank, crowd)
            c1, c2 = _sbx_crossover(rng, p1, p2, lower, upper, pc, eta_c)
            offspring[i] = _poly_mutate(rng, c1, lower, upper, pm_, eta_m)
            i += 1
            if i <= popsize
                offspring[i] = _poly_mutate(rng, c2, lower, upper, pm_, eta_m)
                i += 1
            end
        end

        offspring_objs = evaluate(offspring, gen)
        n_evaluated += popsize

        combined_pop = vcat(pop, offspring)
        combined_objs = vcat(objs, offspring_objs)
        c_fronts = _fast_nondominated_sort(combined_objs)

        new_pop = Vector{Vector{Float64}}()
        new_objs = Vector{Vector{Float64}}()
        for front in c_fronts
            if length(new_pop) + length(front) <= popsize
                for idx in front
                    push!(new_pop, combined_pop[idx])
                    push!(new_objs, combined_objs[idx])
                end
            else
                d = _crowding_distance(front, combined_objs)
                order = sortperm(d; rev=true)
                remaining = popsize - length(new_pop)
                for k in 1:remaining
                    idx = front[order[k]]
                    push!(new_pop, combined_pop[idx])
                    push!(new_objs, combined_objs[idx])
                end
                break
            end
        end

        pop = new_pop
        objs = new_objs

        push!(gens_seen, gen)
        push!(mean_objectives_hist, [_evolve_mean([o[k] for o in objs]) for k in 1:m])
        push!(n_front1_hist, length(_fast_nondominated_sort(objs)[1]))
    end

    final_fronts = _fast_nondominated_sort(objs)
    front1_idx = final_fronts[1]
    pareto = [(genome=copy(pop[i]), objectives=copy(objs[i])) for i in front1_idx]
    best_mean_idx = argmax([_evolve_mean(o) for o in objs])

    return (
        pareto_front=pareto,
        population=copy(pop),
        objectives=copy(objs),
        best_mean_genome=copy(pop[best_mean_idx]),
        best_mean_objectives=copy(objs[best_mean_idx]),
        n_evaluated=n_evaluated,
        history=(generation=gens_seen, mean_objectives=mean_objectives_hist, n_front1=n_front1_hist),
        config=(
            model_sym=node_sym,
            train_tasks=Tuple(t.name for t in tasks),
            popsize=popsize,
            generations=generations,
            k_trials=k_trials,
            sigma0=Float64(sigma0),
            seed=Int(seed),
            N=n_nodes,
            ticks=ticks,
        ),
    )
end
