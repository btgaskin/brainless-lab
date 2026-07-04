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

function _branching_level_summary(level::Symbol, rates::AbstractMatrix{<:Real}, per_agent)
    sigmas = [res.sigma for res in per_agent]
    sigma_ols = [res.sigma_ols for res in per_agent]
    return (;
        level=level,
        per_agent=per_agent,
        per_tick=[res.per_tick for res in per_agent],
        population_rate=Matrix{Float64}(rates),
        sigma=_analysis_finite_mean(sigmas),
        sigma_std=_analysis_finite_std(sigmas),
        sigma_distribution=Float64.(sigmas),
        sigma_ols=_analysis_finite_mean(sigma_ols),
        sigma_ols_std=_analysis_finite_std(sigma_ols),
        sigma_ols_distribution=Float64.(sigma_ols),
        n_agents=size(rates, 2),
        summary=(
            sigma_mean=_analysis_finite_mean(sigmas),
            sigma_std=_analysis_finite_std(sigmas),
            sigma_ols_mean=_analysis_finite_mean(sigma_ols),
            sigma_ols_std=_analysis_finite_std(sigma_ols),
        ),
    )
end

function _branching_mr_from_rates(pop::AbstractVector{<:Real}; kmax::Integer, transient::Integer)
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

function _branching_mr_level_summary(level::Symbol, rates::AbstractMatrix{<:Real}, per_agent, kmax::Integer, transient::Integer)
    m_values = [res.m_mr for res in per_agent]
    return (;
        level=level,
        per_agent=per_agent,
        m_mr=_analysis_finite_mean(m_values),
        m_mr_std=_analysis_finite_std(m_values),
        m_mr_distribution=Float64.(m_values),
        r_k=[res.r_k for res in per_agent],
        kmax=Int(kmax),
        transient=Int(transient),
        population_rate=Matrix{Float64}(rates),
        n_agents=size(rates, 2),
        summary=(
            m_mr_mean=_analysis_finite_mean(m_values),
            m_mr_std=_analysis_finite_std(m_values),
        ),
    )
end

"""
    branching_ratio(sim; level=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD)

Compute branching-ratio summaries from a recorded rollout's `:rate` channel.

`level=:pooled` preserves the legacy population series. `level=:node` computes
the estimator inside each agent's node population and returns per-agent
distributions plus mean/std summaries. `level=:agent` uses an agent-scale turn
event count: per tick, it counts agents whose absolute recorded heading change
exceeds `turn_threshold` (default `pi/12` radians).

Returns the high-variance per-tick ratio `A(t+1)/A(t)`, the legacy
through-origin least-squares `sigma`, the intercept-corrected single-lag
`sigma_ols`, and the activity series. The legacy `sigma` is kept for backward
compatibility and existing visualizations; under subsampling it is biased.
Prefer `branching_ratio_mr` for a subsampling-robust estimate of m.
"""
function branching_ratio(sim::SimResult; level::Symbol=:pooled, turn_threshold::Real=DEFAULT_TURN_THRESHOLD)
    level = _analysis_level(level, :branching_ratio)
    if level == :pooled
        pop = _analysis_population_rate_series(sim, :branching_ratio)
        res = _branching_from_rates(pop)
        return (per_tick=res.per_tick, sigma=res.sigma, sigma_ols=res.sigma_ols, population_rate=pop)
    elseif level == :node
        rates = _analysis_node_rate_matrix(sim, :branching_ratio)
        per_agent = [_branching_from_rates(@view(rates[:, i])) for i in axes(rates, 2)]
        return _branching_level_summary(:node, rates, per_agent)
    end

    events = _analysis_agent_activity_matrix(sim, :branching_ratio; turn_threshold=turn_threshold)
    pop = _analysis_row_sums(events)
    res = _branching_from_rates(pop)
    return (;
        level=:agent,
        per_tick=res.per_tick,
        sigma=res.sigma,
        sigma_ols=res.sigma_ols,
        population_rate=pop,
        agent_activity=pop,
        agent_events=events,
        n_agents=size(events, 2),
        turn_threshold=Float64(turn_threshold),
    )
end

"""
    branching_ratio_mr(sim; kmax=20, transient=0, level=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD)

Estimate the branching ratio m with the Wilting-Priesemann multistep-regression
(MR) estimator. After optionally dropping `transient` initial ticks, it computes
the intercept-corrected lag slopes `r_k` for `k = 1:kmax` and fits
`r_k = b * m^k` over positive finite `r_k`.

`level=:pooled` preserves the legacy population series. `level=:node` returns
per-agent MR estimates across reservoirs. `level=:agent` uses the same
turn-event count as `branching_ratio`.
"""
function branching_ratio_mr(sim::SimResult; kmax::Integer=20, transient::Integer=0, level::Symbol=:pooled, turn_threshold::Real=DEFAULT_TURN_THRESHOLD)
    kmax = Int(kmax)
    transient = Int(transient)
    level = _analysis_level(level, :branching_ratio_mr)
    kmax >= 1 || throw(ArgumentError("branching_ratio_mr needs kmax >= 1"))
    transient >= 0 || throw(ArgumentError("branching_ratio_mr needs transient >= 0"))

    if level == :pooled
        pop = _analysis_population_rate_series(sim, :branching_ratio_mr)
        return _branching_mr_from_rates(pop; kmax=kmax, transient=transient)
    elseif level == :node
        rates = _analysis_node_rate_matrix(sim, :branching_ratio_mr)
        per_agent = [
            _branching_mr_from_rates(@view(rates[:, i]); kmax=kmax, transient=transient)
            for i in axes(rates, 2)
        ]
        return _branching_mr_level_summary(:node, rates, per_agent, kmax, transient)
    end

    events = _analysis_agent_activity_matrix(sim, :branching_ratio_mr; turn_threshold=turn_threshold)
    pop = _analysis_row_sums(events)
    res = _branching_mr_from_rates(pop; kmax=kmax, transient=transient)
    return (; level=:agent, res..., population_rate=pop, agent_activity=pop, agent_events=events, n_agents=size(events, 2), transient=transient, turn_threshold=Float64(turn_threshold))
end
