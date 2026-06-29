using Random
using LinearAlgebra

mutable struct SepCMA <: AbstractEvolutionStrategy
    n_dim::Int
    lambda::Int
    mu::Int
    weights::Vector{Float64}
    positive_weights::Vector{Float64}
    mu_eff::Float64
    c_sigma::Float64
    d_sigma::Float64
    c_c::Float64
    c1::Float64
    c_mu::Float64
    chi_n::Float64
    x_mean::Vector{Float64}
    sigma::Float64
    C_diag::Vector{Float64}
    p_c::Vector{Float64}
    p_sigma::Vector{Float64}
    rng::Random.AbstractRNG
    countiter::Int
    countevals::Int
    best_x::Vector{Float64}
    best_value::Float64
end

function _chi_n(n::Integer)
    n = Int(n)
    n >= 1 || throw(ArgumentError("dimension must be positive"))
    value = isodd(n) ? sqrt(2.0 / pi) : sqrt(pi / 2.0)
    k = isodd(n) ? 1 : 2
    while k < n
        value *= (k + 1) / k
        k += 2
    end
    return Float64(value)
end

function _recombination_weights(lambda::Integer)
    lambda = Int(lambda)
    lambda >= 2 || throw(ArgumentError("popsize must be at least 2"))

    raw = [log((lambda + 1) / 2) - log(i) for i in 1:lambda]
    mu = count(>(0.0), raw)
    mu >= 1 || throw(ArgumentError("popsize produced no positive recombination weights"))

    spos = sum(@view raw[1:mu])
    weights = raw ./ spos
    sneg = sum(@view weights[(mu + 1):lambda])
    if sneg != 0.0
        @inbounds for i in (mu + 1):lambda
            weights[i] /= -sneg
        end
    end

    mu_eff = 1.0 / sum(abs2, @view weights[1:mu])
    return weights, mu, Float64(mu_eff)
end

function _mueffminus(weights::Vector{Float64}, mu::Integer)
    mu >= length(weights) && return 0.0
    neg = @view weights[(mu + 1):length(weights)]
    sneg = sum(neg)
    denom = sum(abs2, neg)
    return sneg == 0.0 ? 0.0 : Float64(sneg * sneg / denom)
end

function _negative_weights_set_sum!(weights::Vector{Float64}, mu::Integer, value::Real)
    mu >= length(weights) && return weights
    value = abs(Float64(value))
    neg = @view weights[(mu + 1):length(weights)]
    sneg = sum(neg)
    sneg == 0.0 && return weights
    factor = abs(value / sneg)
    @inbounds for i in (mu + 1):length(weights)
        weights[i] *= factor
    end
    return weights
end

function _negative_weights_limit_sum!(weights::Vector{Float64}, mu::Integer, value::Real)
    mu >= length(weights) && return weights
    value = abs(Float64(value))
    sneg = sum(@view weights[(mu + 1):length(weights)])
    sneg >= -value && return weights
    factor = abs(value / sneg)
    @inbounds for i in (mu + 1):length(weights)
        weights[i] *= factor
    end
    return weights
end

function _finalize_negative_weights!(
    weights::Vector{Float64},
    mu::Integer,
    mu_eff::Real,
    n_dim::Integer,
    c1::Real,
    c_mu::Real,
)
    if weights[end] < 0.0 && c_mu > 0.0
        _negative_weights_set_sum!(weights, mu, 1.0 + Float64(c1) / Float64(c_mu))
        mu_eff_minus = _mueffminus(weights, mu)
        _negative_weights_limit_sum!(weights, mu, 1.0 + 2.0 * mu_eff_minus / (Float64(mu_eff) + 2.0))
    end
    return weights
end

function _c1_sep(n_dim::Integer, mu_eff::Real)
    n = Float64(n_dim)
    return 1.0 / (n + 2.0 * sqrt(n) + Float64(mu_eff) / n)
end

function _cmu_sep(n_dim::Integer, mu_eff::Real, c1::Real)
    n = Float64(n_dim)
    mu = Float64(mu_eff)
    rankmu_offset = 0.25
    value = (rankmu_offset + mu + inv(mu) - 2.0) / (n + 4.0 * sqrt(n) + mu / 2.0)
    return min(1.0 - Float64(c1), value)
end

function _cc_sep(n_dim::Integer, mu_eff::Real)
    n = Float64(n_dim)
    mu = Float64(mu_eff)
    return (1.0 + inv(n) + mu / n) / (sqrt(n) + inv(n) + 2.0 * mu / n)
end

function _csa_damps(n_dim::Integer, lambda::Integer, mu_eff::Real, c_sigma::Real)
    n = Float64(n_dim)
    damp_in_eff = max(1.0, 3.0 * (1.0 - 0.5^(n / 10.0)))
    exponent = 0.5
    extra = 2.0 * max(0.0, damp_in_eff * ((Float64(mu_eff) - 1.0) / (n + 1.0))^exponent - 1.0)
    return 1.0 + extra + Float64(c_sigma)
end

function SepCMA(x0::AbstractVector{<:Real}, sigma0::Real; popsize=nothing, seed::Integer=0)
    x = Vector{Float64}(Float64.(x0))
    n = length(x)
    n >= 1 || throw(ArgumentError("x0 must be non-empty"))
    sigma = Float64(sigma0)
    sigma > 0.0 || throw(ArgumentError("sigma0 must be positive"))

    lambda = popsize === nothing ? 4 + floor(Int, 3 * log(n)) : Int(popsize)
    weights, mu, mu_eff = _recombination_weights(lambda)
    c1 = _c1_sep(n, mu_eff)
    c_mu = _cmu_sep(n, mu_eff, c1)
    _finalize_negative_weights!(weights, mu, mu_eff, n, c1, c_mu)

    c_sigma = (mu_eff + 2.0) / (n + mu_eff + 3.0)
    return SepCMA(
        n,
        lambda,
        mu,
        weights,
        copy(weights[1:mu]),
        mu_eff,
        c_sigma,
        _csa_damps(n, lambda, mu_eff, c_sigma),
        _cc_sep(n, mu_eff),
        c1,
        c_mu,
        _chi_n(n),
        copy(x),
        sigma,
        ones(Float64, n),
        zeros(Float64, n),
        zeros(Float64, n),
        Random.Xoshiro(seed),
        0,
        0,
        copy(x),
        Inf,
    )
end

function ask(es::SepCMA)
    scale = sqrt.(es.C_diag)
    return [
        es.x_mean .+ es.sigma .* scale .* randn(es.rng, es.n_dim)
        for _ in 1:es.lambda
    ]
end

function _as_solution_vectors(solutions, n_dim::Integer)
    out = Vector{Vector{Float64}}(undef, length(solutions))
    for i in eachindex(solutions)
        x = Vector{Float64}(Float64.(solutions[i]))
        length(x) == n_dim ||
            throw(DimensionMismatch("solution $i has length $(length(x)); expected $n_dim"))
        out[i] = x
    end
    return out
end

function _weighted_mean(pop::Vector{Vector{Float64}}, weights::Vector{Float64}, n_dim::Integer)
    out = zeros(Float64, n_dim)
    @inbounds for i in eachindex(weights)
        w = weights[i]
        x = pop[i]
        for j in 1:n_dim
            out[j] += w * x[j]
        end
    end
    return out
end

function _update_best!(es::SepCMA, pop::Vector{Vector{Float64}}, losses::Vector{Float64})
    @inbounds for i in eachindex(pop)
        loss = Float64(losses[i])
        if loss < es.best_value
            es.best_value = loss
            es.best_x = copy(pop[i])
        end
    end
    return es
end

function _update_cdiag!(es::SepCMA, pop::Vector{Vector{Float64}}, old_mean::Vector{Float64}, c1a::Float64)
    n = es.n_dim
    lambda = length(pop)
    old_scale = sqrt.(es.C_diag)
    weights = Vector{Float64}(undef, lambda + 1)
    weights[1] = log(2.0) * c1a
    @inbounds for i in 1:lambda
        weights[i + 1] = log(2.0) * es.c_mu * es.weights[i]
    end
    sum_weights = sum(weights)

    @inbounds for j in 1:n
        z2_average = weights[1] * es.p_c[j]^2
        denom = es.sigma * old_scale[j]
        for i in 1:lambda
            z = (pop[i][j] - old_mean[j]) / denom
            z2_average += weights[i + 1] * z * z
        end
        fac = exp((z2_average - sum_weights) / 2.0)
        es.C_diag[j] *= fac * fac
        if !(isfinite(es.C_diag[j])) || es.C_diag[j] <= 0.0
            es.C_diag[j] = eps(Float64)
        end
    end
    return es
end

function tell!(es::SepCMA, solutions, losses)
    length(solutions) == length(losses) ||
        throw(DimensionMismatch("solutions and losses must have the same length"))
    length(solutions) >= es.mu ||
        throw(ArgumentError("not enough solutions: got $(length(solutions)), need at least $(es.mu)"))

    pop_unsorted = _as_solution_vectors(solutions, es.n_dim)
    loss_vec = Vector{Float64}(Float64.(losses))
    _update_best!(es, pop_unsorted, loss_vec)

    order = sortperm(loss_vec)
    pop = [pop_unsorted[i] for i in order]

    old_mean = copy(es.x_mean)
    es.countiter += 1
    es.countevals += length(pop)
    es.x_mean = _weighted_mean(pop, es.positive_weights, es.n_dim)

    old_scale = sqrt.(es.C_diag)
    delta = es.x_mean .- old_mean
    z = delta ./ old_scale
    z .*= sqrt(es.mu_eff) / es.sigma

    es.p_sigma .*= (1.0 - es.c_sigma)
    es.p_sigma .+= sqrt(es.c_sigma * (2.0 - es.c_sigma)) .* z

    denom = 1.0 - (1.0 - es.c_sigma)^(2 * es.countiter)
    squared_sum = sum(abs2, es.p_sigma) / denom
    hsig = squared_sum / es.n_dim - 1.0 < 1.0 + 4.0 / (es.n_dim + 1.0)
    h = hsig ? 1.0 : 0.0
    c1a = es.c1 * (1.0 - (1.0 - h * h) * es.c_c * (2.0 - es.c_c))

    es.p_c .*= (1.0 - es.c_c)
    if hsig
        es.p_c .+= sqrt(es.c_c * (2.0 - es.c_c) * es.mu_eff) .* (delta ./ old_scale) ./ es.sigma
    end

    _update_cdiag!(es, pop, old_mean, c1a)

    s = norm(es.p_sigma) / es.chi_n - 1.0
    s *= es.c_sigma / es.d_sigma
    s = clamp(s, -1.0, 1.0)
    es.sigma *= exp(s)
    return es
end

function result(es::SepCMA)
    return (
        x=copy(es.best_x),
        value=Float64(es.best_value),
        xbest=copy(es.best_x),
        fbest=Float64(es.best_value),
        x_mean=copy(es.x_mean),
        sigma=Float64(es.sigma),
        C_diag=copy(es.C_diag),
        countiter=es.countiter,
        countevals=es.countevals,
    )
end

Base.@kwdef mutable struct EvolveDriver <: Driver
    model_sym::Symbol = :falandays
    train_tasks::Tuple = (:wall,)
    generations::Int = 30
    popsize::Int = 16
    k_trials::Int = 8
    aggregator::Symbol = :min
    N::Union{Nothing,Int} = nothing
    ticks::Any = nothing
    sigma0::Float64 = 2.5
    x0::Any = nothing
    seed::Int = 0
    wiring_seed_base::Int = 1000
    link_p::Float64 = 0.1
    rho::Float64 = 0.2
    window::Any = nothing
    lam::Float64 = 1.0
    threaded::Bool = true
    result::Any = nothing
end

function _finite_unit(value)
    value = Float64(value)
    isfinite(value) || return 0.0
    return clamp(value, 0.0, 1.0)
end

function _evolve_mean(values)
    isempty(values) && return NaN
    total = 0.0
    for value in values
        total += Float64(value)
    end
    return total / length(values)
end

function _median_float(values)
    isempty(values) && return NaN
    sorted = sort(Float64.(collect(values)))
    n = length(sorted)
    mid = fld(n + 1, 2)
    return isodd(n) ? sorted[mid] : (sorted[mid] + sorted[mid + 1]) / 2.0
end

function _aggregate_task_scores(values, aggregator::Symbol)
    aggregator == :min && return minimum(values)
    aggregator == :mean && return _evolve_mean(values)
    throw(ArgumentError("aggregator must be :min or :mean"))
end

function _default_x0(model_sym::Symbol, N; ticks=nothing, link_p=0.1, rho=0.2, window=nothing, kwargs...)
    node_sym = _canonical_model_sym(model_sym)
    if node_sym in _FALANDAYS_MODEL_SYMS
        return pack_params(FalandaysParams())
    end
    return find_alive_centroid(node_sym, N; ticks=ticks === nothing ? 300 : min(Int(ticks), 300), link_p=link_p, rho=rho, window=window, kwargs...)
end

function evolve(;
    model_sym=:falandays,
    train_tasks=(:wall,),
    generations::Integer=30,
    popsize::Integer=16,
    k_trials::Integer=8,
    aggregator::Symbol=:min,
    N=nothing,
    ticks=nothing,
    sigma0::Real=2.5,
    x0=nothing,
    seed::Integer=0,
    wiring_seed_base::Integer=1000,
    link_p::Real=0.1,
    rho::Real=0.2,
    window=nothing,
    lam::Real=1.0,
    threaded::Bool=true,
    kwargs...,
)
    generations = Int(generations)
    popsize = Int(popsize)
    k_trials = Int(k_trials)
    generations >= 1 || throw(ArgumentError("generations must be at least 1"))
    popsize >= 2 || throw(ArgumentError("popsize must be at least 2"))
    k_trials >= 1 || throw(ArgumentError("k_trials must be at least 1"))

    node_sym = _canonical_model_sym(model_sym)
    n_nodes = N === nothing ? _default_node_count(node_sym) : Int(N)
    tasks = Tuple(resolve_task(t) for t in train_tasks)
    isempty(tasks) && throw(ArgumentError("train_tasks must contain at least one task"))

    x0_vec = x0 === nothing ?
        _default_x0(node_sym, n_nodes; ticks=ticks, link_p=link_p, rho=rho, window=window, kwargs...) :
        Vector{Float64}(Float64.(x0))
    es = SepCMA(x0_vec, Float64(sigma0); popsize=popsize, seed=Int(seed))

    generations_seen = Int[]
    fitness_best = Float64[]
    fitness_median = Float64[]
    fitness_mean = Float64[]
    fitnesses_by_generation = Vector{Vector{Float64}}()
    last_generation_best = copy(x0_vec)
    last_fitness_best = 0.0

    for generation in 0:(generations - 1)
        seeds = _train_seed_tuple(generation, k_trials, wiring_seed_base)
        solutions = ask(es)
        task_means = Matrix{Float64}(undef, length(solutions), length(tasks))

        for (task_idx, task) in enumerate(tasks)
            matrix = evaluate_fitness_matrix(
                solutions,
                task,
                seeds;
                model_sym=node_sym,
                N=n_nodes,
                ticks=ticks,
                link_p=link_p,
                rho=rho,
                window=window,
                lam=lam,
                threaded=threaded,
                kwargs...,
            )
            @inbounds for i in axes(matrix, 1)
                task_means[i, task_idx] = _evolve_mean(@view matrix[i, :])
            end
        end

        fitnesses = Vector{Float64}(undef, length(solutions))
        @inbounds for i in eachindex(fitnesses)
            fitnesses[i] = _finite_unit(_aggregate_task_scores(@view(task_means[i, :]), aggregator))
        end

        tell!(es, solutions, .-fitnesses)

        best_idx = argmax(fitnesses)
        last_generation_best = copy(solutions[best_idx])
        last_fitness_best = fitnesses[best_idx]

        push!(generations_seen, generation)
        push!(fitness_best, maximum(fitnesses))
        push!(fitness_median, _median_float(fitnesses))
        push!(fitness_mean, _evolve_mean(fitnesses))
        push!(fitnesses_by_generation, copy(fitnesses))
    end

    es_result = result(es)
    best_fitness = _finite_unit(-es_result.fbest)
    out = (
        optimizer=es,
        best=copy(es_result.xbest),
        best_raw=copy(es_result.xbest),
        best_fitness=best_fitness,
        best_score=best_fitness,
        last_generation_best=last_generation_best,
        last_fitness_best=last_fitness_best,
        fitnesses=fitnesses_by_generation,
        history=(
            generation=generations_seen,
            fitness_best=fitness_best,
            fitness_median=fitness_median,
            fitness_mean=fitness_mean,
        ),
        config=(
            model_sym=node_sym,
            train_tasks=Tuple(t.name for t in tasks),
            generations=generations,
            popsize=popsize,
            k_trials=k_trials,
            aggregator=aggregator,
            N=n_nodes,
            ticks=ticks,
            sigma0=Float64(sigma0),
            seed=Int(seed),
            wiring_seed_base=Int(wiring_seed_base),
            link_p=Float64(link_p),
            rho=Float64(rho),
            window=window,
            lam=Float64(lam),
        ),
    )
    return out
end

function evolve(driver::EvolveDriver)
    out = evolve(
        model_sym=driver.model_sym,
        train_tasks=driver.train_tasks,
        generations=driver.generations,
        popsize=driver.popsize,
        k_trials=driver.k_trials,
        aggregator=driver.aggregator,
        N=driver.N,
        ticks=driver.ticks,
        sigma0=driver.sigma0,
        x0=driver.x0,
        seed=driver.seed,
        wiring_seed_base=driver.wiring_seed_base,
        link_p=driver.link_p,
        rho=driver.rho,
        window=driver.window,
        lam=driver.lam,
        threaded=driver.threaded,
    )
    driver.result = out
    return out
end

function _dense_thr_base_offset()
    offset = 1
    for (name, shape) in _DENSE_COMPARTMENTAL_SCHEMA
        count = prod(shape)
        name == :thr_base && return offset
        offset += count
    end
    return nothing
end

function _shift_thr_base(vector::Vector{Float64}, model_sym::Symbol, thr_bias::Real)
    shifted = copy(vector)
    node_sym = _canonical_model_sym(model_sym)
    if node_sym == :compartmental_dense && thr_bias != 0
        offset = _dense_thr_base_offset()
        offset === nothing || (shifted[offset] += Float64(thr_bias))
    end
    return shifted
end

function _sample_init_vector(model_sym::Symbol, sigma0::Real, thr_bias::Real, rng::AbstractRNG)
    T = _model_param_type(model_sym)
    raw = Float64(sigma0) .* randn(rng, paramdim(T))
    return _shift_thr_base(raw, model_sym, thr_bias)
end

function _alive_fraction_for_config(
    model_sym::Symbol,
    sigma0::Real,
    thr_bias::Real,
    rng::AbstractRNG,
    seeds;
    n_genomes::Integer,
    N::Integer,
    ticks::Integer,
    link_p::Real,
    rho::Real,
    window,
)
    alive_pairs = 0
    any_alive = 0
    total_pairs = Int(n_genomes) * length(seeds)

    for _ in 1:Int(n_genomes)
        candidate = _sample_init_vector(model_sym, sigma0, thr_bias, rng)
        genome_alive = false
        for seed in seeds
            out = rollout(
                :wall,
                candidate,
                seed;
                model_sym=model_sym,
                N=N,
                ticks=ticks,
                link_p=link_p,
                rho=rho,
                window=window,
            )
            alive_pairs += out.alive ? 1 : 0
            genome_alive |= out.alive
        end
        any_alive += genome_alive ? 1 : 0
    end

    return (
        fraction_alive=alive_pairs / total_pairs,
        fraction_any_alive=any_alive / Int(n_genomes),
    )
end

function find_alive_centroid(
    model_sym::Union{Symbol,AbstractString}=:compartmental,
    N::Integer=100;
    sigma0_grid=(1.5, 2.0, 2.5, 3.0),
    thr_bias_grid=(-0.5, 0.0, 0.5),
    n_genomes::Integer=12,
    seeds=(0, 1, 2),
    ticks::Integer=300,
    link_p::Real=0.1,
    rho::Real=0.2,
    window=nothing,
    n_samples::Integer=200,
    search_seed::Integer=0,
)
    node_sym = _canonical_model_sym(model_sym)
    node_sym in _FALANDAYS_MODEL_SYMS && return pack_params(FalandaysParams())

    seed_tuple = Tuple(Int.(collect(seeds)))
    isempty(seed_tuple) && throw(ArgumentError("seeds must contain at least one seed"))
    win = window === nothing ? min(200, Int(ticks)) : Int(window)
    rng = Random.Xoshiro(Int(search_seed))

    best_sigma = Float64(first(sigma0_grid))
    best_thr = Float64(first(thr_bias_grid))
    best_alive = -Inf
    best_any = -Inf

    for sigma0 in sigma0_grid, thr_bias in thr_bias_grid
        score = _alive_fraction_for_config(
            node_sym,
            sigma0,
            thr_bias,
            rng,
            seed_tuple;
            n_genomes=n_genomes,
            N=Int(N),
            ticks=Int(ticks),
            link_p=link_p,
            rho=rho,
            window=win,
        )
        if (score.fraction_alive, score.fraction_any_alive) > (best_alive, best_any)
            best_alive = score.fraction_alive
            best_any = score.fraction_any_alive
            best_sigma = Float64(sigma0)
            best_thr = Float64(thr_bias)
        end
    end

    rng2 = Random.Xoshiro(Int(search_seed) + 1)
    first_seeds = seed_tuple[1:min(2, length(seed_tuple))]
    fallback = nothing
    for _ in 1:Int(n_samples)
        candidate = _sample_init_vector(node_sym, best_sigma, best_thr, rng2)
        fallback === nothing && (fallback = candidate)
        alive_count = 0
        for seed in first_seeds
            out = rollout(
                :wall,
                candidate,
                seed;
                model_sym=node_sym,
                N=Int(N),
                ticks=Int(ticks),
                link_p=link_p,
                rho=rho,
                window=win,
            )
            alive_count += out.alive ? 1 : 0
        end
        alive_count >= min(2, length(first_seeds)) && return candidate
    end

    return fallback === nothing ? _sample_init_vector(node_sym, best_sigma, best_thr, rng2) : fallback
end
