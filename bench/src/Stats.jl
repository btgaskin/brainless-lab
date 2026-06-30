module Stats

using HypothesisTests
using Random
using Statistics

export bootstrap_ci,
    cliffs_delta,
    holm_adjust,
    benjamini_hochberg,
    mannwhitney_p,
    kruskalwallis_p,
    mean_diff_ci,
    achieved_power,
    min_n_for_080,
    analyze_task

_as_float_vector(xs) = Vector{Float64}(Float64.(collect(xs)))

function _resample_mean(xs::Vector{Float64}, n::Integer, rng::AbstractRNG)
    n = Int(n)
    total = 0.0
    @inbounds for _ in 1:n
        total += xs[rand(rng, 1:length(xs))]
    end
    return total / n
end

function _all_same(groups::Vector{Vector{Float64}})
    seen = false
    first_value = 0.0
    for group in groups
        for value in group
            if !seen
                first_value = value
                seen = true
            elseif value != first_value
                return false
            end
        end
    end
    return seen
end

_all_same(x::Vector{Float64}, y::Vector{Float64}) = _all_same([x, y])

function bootstrap_ci(xs; nboot::Integer=2000, alpha::Real=0.05, rng::AbstractRNG=Random.Xoshiro(0))
    x = _as_float_vector(xs)
    n = length(x)
    n == 0 && return (NaN, NaN)
    nboot = Int(nboot)
    nboot >= 1 || throw(ArgumentError("nboot must be at least 1"))

    means = Vector{Float64}(undef, nboot)
    @inbounds for b in 1:nboot
        means[b] = _resample_mean(x, n, rng)
    end

    a = Float64(alpha)
    0.0 < a < 1.0 || throw(ArgumentError("alpha must be in (0, 1)"))
    return (
        Statistics.quantile(means, a / 2.0),
        Statistics.quantile(means, 1.0 - a / 2.0),
    )
end

function mean_diff_ci(xs, ys; nboot::Integer=2000, alpha::Real=0.05, rng::AbstractRNG=Random.Xoshiro(0))
    x = _as_float_vector(xs)
    y = _as_float_vector(ys)
    (isempty(x) || isempty(y)) && return (NaN, NaN)
    nboot = Int(nboot)
    nboot >= 1 || throw(ArgumentError("nboot must be at least 1"))

    diffs = Vector{Float64}(undef, nboot)
    @inbounds for b in 1:nboot
        diffs[b] = _resample_mean(x, length(x), rng) - _resample_mean(y, length(y), rng)
    end

    a = Float64(alpha)
    0.0 < a < 1.0 || throw(ArgumentError("alpha must be in (0, 1)"))
    return (
        Statistics.quantile(diffs, a / 2.0),
        Statistics.quantile(diffs, 1.0 - a / 2.0),
    )
end

function cliffs_delta(xs, ys)
    x = _as_float_vector(xs)
    y = _as_float_vector(ys)
    (isempty(x) || isempty(y)) && return NaN

    greater = 0
    less = 0
    @inbounds for xi in x
        for yj in y
            if xi > yj
                greater += 1
            elseif xi < yj
                less += 1
            end
        end
    end
    return (greater - less) / (length(x) * length(y))
end

function mannwhitney_p(xs, ys)
    x = _as_float_vector(xs)
    y = _as_float_vector(ys)
    (isempty(x) || isempty(y)) && return NaN
    _all_same(x, y) && return 1.0

    try
        p = pvalue(MannWhitneyUTest(x, y))
        return isfinite(p) ? clamp(Float64(p), 0.0, 1.0) : NaN
    catch
        _all_same(x, y) && return 1.0
        rethrow()
    end
end

function kruskalwallis_p(groups...)
    valid = [_as_float_vector(group) for group in groups if !isempty(group)]
    length(valid) < 2 && return NaN
    _all_same(valid) && return 1.0

    try
        p = pvalue(KruskalWallisTest(valid...))
        return isfinite(p) ? clamp(Float64(p), 0.0, 1.0) : NaN
    catch
        _all_same(valid) && return 1.0
        rethrow()
    end
end

function holm_adjust(pvals)
    m = length(pvals)
    m == 0 && return Float64[]
    clean = [isfinite(Float64(p)) ? clamp(Float64(p), 0.0, 1.0) : 1.0 for p in pvals]
    order = sortperm(clean)
    adjusted = zeros(Float64, m)
    running = 0.0

    for rank in 1:m
        idx = order[rank]
        value = (m - rank + 1) * clean[idx]
        running = max(running, value)
        adjusted[idx] = min(running, 1.0)
    end

    return adjusted
end

function benjamini_hochberg(pvals)
    m = length(pvals)
    m == 0 && return Float64[]
    clean = [isfinite(Float64(p)) ? clamp(Float64(p), 0.0, 1.0) : 1.0 for p in pvals]
    order = sortperm(clean)
    adjusted = zeros(Float64, m)
    running = 1.0

    for rank in m:-1:1
        idx = order[rank]
        value = clean[idx] * m / rank
        running = min(running, value)
        adjusted[idx] = min(running, 1.0)
    end

    return adjusted
end

function achieved_power(xs, ys; B::Integer=500, n::Integer=min(length(xs), length(ys)),
        alpha::Real=0.05, rng::AbstractRNG=Random.Xoshiro(0))
    x = _as_float_vector(xs)
    y = _as_float_vector(ys)
    (isempty(x) || isempty(y)) && return NaN

    B = Int(B)
    n = Int(n)
    B >= 1 || throw(ArgumentError("B must be at least 1"))
    n >= 2 || return NaN

    hits = 0
    xr = Vector{Float64}(undef, n)
    yr = Vector{Float64}(undef, n)

    @inbounds for _ in 1:B
        for i in 1:n
            xr[i] = x[rand(rng, 1:length(x))]
            yr[i] = y[rand(rng, 1:length(y))]
        end
        p = mannwhitney_p(xr, yr)
        if isfinite(p) && p < alpha
            hits += 1
        end
    end

    return hits / B
end

function min_n_for_080(xs, ys; B::Integer=500, alpha::Real=0.05,
        rng::AbstractRNG=Random.Xoshiro(0), target::Real=0.8)
    for n in 2:5:120
        pow = achieved_power(xs, ys; B=B, n=n, alpha=alpha, rng=rng)
        if isfinite(pow) && pow >= target
            return n
        end
    end
    return nothing
end

function analyze_task(group_vectors::AbstractDict; baseline::Symbol=:falandays_base,
        alpha::Real=0.05, nboot::Integer=2000, power_boot::Integer=500,
        rng::AbstractRNG=Random.Xoshiro(0))
    names = sort(collect(keys(group_vectors)); by=String)
    groups = [group_vectors[name] for name in names]
    omnibus = kruskalwallis_p(groups...)

    pair_core = NamedTuple[]
    if isfinite(omnibus) && omnibus < alpha
        for i in eachindex(names)
            for j in (i + 1):lastindex(names)
                a_name = names[i]
                b_name = names[j]
                a = group_vectors[a_name]
                b = group_vectors[b_name]
                push!(pair_core, (
                    neuron_a=a_name,
                    neuron_b=b_name,
                    p=mannwhitney_p(a, b),
                    cliffs_delta=cliffs_delta(a, b),
                ))
            end
        end
    end

    pair_holm = holm_adjust([row.p for row in pair_core])
    pairwise = NamedTuple[]
    for i in eachindex(pair_core)
        push!(pairwise, merge(pair_core[i], (holm_p=pair_holm[i], bh_q=NaN)))
    end

    baseline_core = NamedTuple[]
    if haskey(group_vectors, baseline) && !isempty(group_vectors[baseline])
        base = group_vectors[baseline]
        for name in names
            name == baseline && continue
            xs = group_vectors[name]
            isempty(xs) && continue
            p = mannwhitney_p(xs, base)
            lo, hi = mean_diff_ci(xs, base; nboot=nboot, alpha=alpha, rng=rng)
            push!(baseline_core, (
                baseline=baseline,
                neuron=name,
                p=p,
                cliffs_delta=cliffs_delta(xs, base),
                delta_mean=Statistics.mean(xs) - Statistics.mean(base),
                delta_ci_lo=lo,
                delta_ci_hi=hi,
                achieved_power=achieved_power(xs, base; B=power_boot, alpha=alpha, rng=rng),
                min_n_for_080=min_n_for_080(xs, base; B=power_boot, alpha=alpha, rng=rng),
            ))
        end
    end

    baseline_holm = holm_adjust([row.p for row in baseline_core])
    baseline_rows = NamedTuple[]
    for i in eachindex(baseline_core)
        push!(baseline_rows, merge(baseline_core[i], (holm_p=baseline_holm[i], bh_q=NaN)))
    end

    return (
        omnibus_kw_p=omnibus,
        pairwise=pairwise,
        baseline=baseline_rows,
    )
end

end
