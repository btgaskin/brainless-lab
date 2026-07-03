# Branching estimator notes:
# - Per-tick A(t+1)/A(t) is high-variance and kept for visualization only.
# - The legacy `sigma` is a regression through the origin; Wilting &
#   Priesemann (2018, Nature Communications) showed this is biased under
#   subsampling, which applies to scalar population-rate observables.
# - `branching_ratio_mr` is the recommended multistep-regression estimator for
#   subsampling-robust m. See also Del Papa, Priesemann & Triesch (2017) for
#   criticality/homeostatic-plasticity context.

function _intercept_corrected_slope(xs, ys)
    length(xs) == length(ys) ||
        throw(DimensionMismatch("intercept-corrected slope needs equal-length inputs"))

    n = 0
    sx = 0.0
    sy = 0.0
    @inbounds for i in eachindex(xs, ys)
        x = Float64(xs[i])
        y = Float64(ys[i])
        if isfinite(x) && isfinite(y)
            n += 1
            sx += x
            sy += y
        end
    end
    n >= 2 || return NaN

    mx = sx / n
    my = sy / n
    cov_xy = 0.0
    var_x = 0.0
    @inbounds for i in eachindex(xs, ys)
        x = Float64(xs[i])
        y = Float64(ys[i])
        if isfinite(x) && isfinite(y)
            dx = x - mx
            cov_xy += dx * (y - my)
            var_x += dx * dx
        end
    end
    return var_x > 0.0 ? cov_xy / var_x : NaN
end

"""
    _branching_from_rates(rates)

Compute per-tick branching ratios, the legacy through-origin least-squares
estimate, and an intercept-corrected single-lag slope from population activity
recorded at each tick.
"""
function _branching_from_rates(rates::AbstractVector{<:Real})
    n = length(rates)
    per_tick = fill(NaN, max(n - 1, 0))
    @inbounds for t in 1:(n - 1)
        prev = Float64(rates[t])
        per_tick[t] = prev > 0.0 ? Float64(rates[t + 1]) / prev : NaN
    end

    num = 0.0
    den = 0.0
    @inbounds for t in 1:(n - 1)
        a = Float64(rates[t])
        b = Float64(rates[t + 1])
        if a > 0.0
            num += a * b
            den += a * a
        end
    end
    # Legacy compatibility: this is least-squares regression through the
    # origin. Under subsampling it is systematically biased, so prefer
    # `sigma_ols` for the single-lag slope and `branching_ratio_mr` for m.
    sigma = den > 0.0 ? num / den : NaN
    sigma_ols = n >= 2 ? _intercept_corrected_slope(@view(rates[1:(n - 1)]), @view(rates[2:n])) : NaN
    return (per_tick=per_tick, sigma=sigma, sigma_ols=sigma_ols)
end

function _population_rate(raw, name::Symbol)
    isempty(raw) && throw(ArgumentError("$(name) needs the :rate channel recorded; run simulate(...; record=(:rate, ...))"))
    return [
        v isa AbstractVector ? (isempty(v) ? 0.0 : sum(Float64, v) / length(v)) : Float64(v)
        for v in raw
    ]
end

"""
    branching_ratio(sim)

Compute branching-ratio summaries from a recorded rollout's `:rate` channel.

Returns the high-variance per-tick ratio `A(t+1)/A(t)`, the legacy
through-origin least-squares `sigma`, the intercept-corrected single-lag
`sigma_ols`, and the population-rate series. The legacy `sigma` is kept for
backward compatibility and existing visualizations; under subsampling it is
biased. Prefer `branching_ratio_mr` for a subsampling-robust estimate of m.
"""
function branching_ratio(sim::SimResult)
    raw = getchannel(sim.recorder, :rate)
    pop = _population_rate(raw, :branching_ratio)
    res = _branching_from_rates(pop)
    return (per_tick=res.per_tick, sigma=res.sigma, sigma_ols=res.sigma_ols, population_rate=pop)
end

"""
    branching_ratio_mr(sim; kmax=20, transient=0)

Estimate the branching ratio m with the Wilting-Priesemann multistep-regression
(MR) estimator. After optionally dropping `transient` initial ticks, it computes
the intercept-corrected lag slopes `r_k` for `k = 1:kmax` and fits
`r_k = b * m^k` over positive finite `r_k`.
"""
function branching_ratio_mr(sim::SimResult; kmax::Integer=20, transient::Integer=0)
    kmax = Int(kmax)
    transient = Int(transient)
    kmax >= 1 || throw(ArgumentError("branching_ratio_mr needs kmax >= 1"))
    transient >= 0 || throw(ArgumentError("branching_ratio_mr needs transient >= 0"))

    raw = getchannel(sim.recorder, :rate)
    pop = _population_rate(raw, :branching_ratio_mr)
    transient < length(pop) - 2 ||
        throw(ArgumentError("branching_ratio_mr needs at least 3 rate samples after transient"))

    rates = Float64.(pop[(transient + 1):end])
    n = length(rates)
    r_k = fill(NaN, kmax)
    @inbounds for k in 1:kmax
        if n - k >= 2
            r_k[k] = _intercept_corrected_slope(@view(rates[1:(n - k)]), @view(rates[(k + 1):n]))
        end
    end

    fit_lags = [k for k in 1:kmax if isfinite(r_k[k]) && r_k[k] > 0.0]
    if length(fit_lags) < 2
        return (m_mr=NaN, r_k=r_k, kmax=kmax)
    end

    xs = Float64.(fit_lags)
    ys = log.(@view r_k[fit_lags])
    slope = _intercept_corrected_slope(xs, ys)
    return (m_mr=isfinite(slope) ? exp(slope) : NaN, r_k=r_k, kmax=kmax)
end
