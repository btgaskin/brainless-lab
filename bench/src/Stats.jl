module Stats

using Random
using Statistics

export bootstrap_ci,
    paired_mean_diff_ci,
    paired_signflip_p,
    paired_superiority,
    repeated_measures_p,
    holm_adjust,
    benjamini_hochberg,
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

function _paired_vectors(xs, ys)
    x = _as_float_vector(xs)
    y = _as_float_vector(ys)
    length(x) == length(y) || throw(DimensionMismatch(
        "paired samples have lengths $(length(x)) and $(length(y))",
    ))
    return x, y
end

function paired_mean_diff_ci(
    xs,
    ys;
    nboot::Integer=2000,
    alpha::Real=0.05,
    rng::AbstractRNG=Random.Xoshiro(0),
)
    x, y = _paired_vectors(xs, ys)
    isempty(x) && return (NaN, NaN)
    differences = x .- y
    return bootstrap_ci(differences; nboot=nboot, alpha=alpha, rng=rng)
end

function paired_superiority(xs, ys)
    x, y = _paired_vectors(xs, ys)
    isempty(x) && return NaN
    return sum(sign, x .- y) / length(x)
end

function paired_signflip_p(
    xs,
    ys;
    nperm::Integer=20_000,
    rng::AbstractRNG=Random.Xoshiro(0),
)
    x, y = _paired_vectors(xs, ys)
    isempty(x) && return NaN
    differences = x .- y
    all(iszero, differences) && return 1.0
    observed = abs(Statistics.mean(differences))
    n = length(differences)

    if n <= 16
        total = 1 << n
        hits = 0
        @inbounds for mask in 0:(total - 1)
            candidate = 0.0
            for index in 1:n
                candidate += ((mask >> (index - 1)) & 1 == 1 ? 1.0 : -1.0) *
                    differences[index]
            end
            abs(candidate / n) >= observed - eps(Float64) && (hits += 1)
        end
        return hits / total
    end

    nperm = Int(nperm)
    nperm >= 1 || throw(ArgumentError("nperm must be at least 1"))
    hits = 0
    @inbounds for _ in 1:nperm
        candidate = 0.0
        for difference in differences
            candidate += (rand(rng, Bool) ? 1.0 : -1.0) * difference
        end
        abs(candidate / n) >= observed && (hits += 1)
    end
    return (hits + 1) / (nperm + 1)
end

function _repeated_measures_stat(matrix::AbstractMatrix{<:Real})
    condition_means = vec(Statistics.mean(matrix; dims=1))
    grand_mean = Statistics.mean(condition_means)
    return sum(value -> (value - grand_mean)^2, condition_means)
end

function repeated_measures_p(
    groups...;
    nperm::Integer=10_000,
    rng::AbstractRNG=Random.Xoshiro(0),
)
    valid = [_as_float_vector(group) for group in groups if !isempty(group)]
    length(valid) < 2 && return NaN
    n_blocks = length(first(valid))
    all(group -> length(group) == n_blocks, valid) || throw(DimensionMismatch(
        "repeated-measures groups must contain the same paired blocks",
    ))
    matrix = reduce(hcat, valid)
    observed = _repeated_measures_stat(matrix)
    observed == 0.0 && return 1.0

    nperm = Int(nperm)
    nperm >= 1 || throw(ArgumentError("nperm must be at least 1"))
    permuted = similar(matrix)
    hits = 0
    @inbounds for _ in 1:nperm
        for block in axes(matrix, 1)
            order = randperm(rng, size(matrix, 2))
            for condition in axes(matrix, 2)
                permuted[block, condition] = matrix[block, order[condition]]
            end
        end
        _repeated_measures_stat(permuted) >= observed && (hits += 1)
    end
    return (hits + 1) / (nperm + 1)
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

function analyze_task(group_vectors::AbstractDict; baseline::Symbol=:falandays,
        alpha::Real=0.05, nboot::Integer=2000, nperm::Integer=10_000,
        rng::AbstractRNG=Random.Xoshiro(0))
    names = sort([name for name in keys(group_vectors) if !isempty(group_vectors[name])]; by=String)
    groups = [group_vectors[name] for name in names]
    omnibus = repeated_measures_p(groups...; nperm=nperm, rng=rng)

    pair_core = NamedTuple[]
    for i in eachindex(names)
        for j in (i + 1):lastindex(names)
            a_name = names[i]
            b_name = names[j]
            a = group_vectors[a_name]
            b = group_vectors[b_name]
            push!(pair_core, (
                neuron_a=a_name,
                neuron_b=b_name,
                p=paired_signflip_p(a, b; nperm=nperm, rng=rng),
                delta_mean=Statistics.mean(a .- b),
                delta_median=Statistics.median(a .- b),
                paired_superiority=paired_superiority(a, b),
            ))
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
            p = paired_signflip_p(xs, base; nperm=nperm, rng=rng)
            lo, hi = paired_mean_diff_ci(xs, base; nboot=nboot, alpha=alpha, rng=rng)
            push!(baseline_core, (
                baseline=baseline,
                neuron=name,
                p=p,
                delta_mean=Statistics.mean(xs) - Statistics.mean(base),
                delta_median=Statistics.median(xs .- base),
                paired_superiority=paired_superiority(xs, base),
                delta_ci_lo=lo,
                delta_ci_hi=hi,
            ))
        end
    end

    baseline_holm = holm_adjust([row.p for row in baseline_core])
    baseline_rows = NamedTuple[]
    for i in eachindex(baseline_core)
        push!(baseline_rows, merge(baseline_core[i], (holm_p=baseline_holm[i], bh_q=NaN)))
    end

    return (
        omnibus_rm_p=omnibus,
        pairwise=pairwise,
        baseline=baseline_rows,
    )
end

end
