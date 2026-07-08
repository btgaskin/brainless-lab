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

function _branching_mr_fit_quality(r_k::AbstractVector{<:Real})
    fit_lags = [k for k in eachindex(r_k) if isfinite(Float64(r_k[k])) && Float64(r_k[k]) > 0.0]
    n_used = length(fit_lags)
    n_used >= 2 || return (m_mr=NaN, r2=NaN, n_used=n_used)

    xs = Float64.(fit_lags)
    ys = log.(@view r_k[fit_lags])
    slope = _intercept_corrected_slope(xs, ys)
    isfinite(slope) || return (m_mr=NaN, r2=NaN, n_used=n_used)

    mx = _series_mean(xs)
    my = _series_mean(ys)
    intercept = my - slope * mx
    ss_res = 0.0
    ss_tot = 0.0
    @inbounds for i in eachindex(xs, ys)
        yhat = intercept + slope * xs[i]
        dy = ys[i] - my
        ss_res += (ys[i] - yhat) * (ys[i] - yhat)
        ss_tot += dy * dy
    end
    r2 = ss_tot > 0.0 ? 1.0 - ss_res / ss_tot : 1.0
    return (m_mr=exp(slope), r2=r2, n_used=n_used)
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
function branching_ratio(sim::SimResult; level::Symbol=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, threshold=nothing, neighbor_radius=nothing)
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

    activity = _analysis_agent_activity(
        sim,
        :branching_ratio;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        threshold=threshold,
        neighbor_radius=neighbor_radius,
    )
    pop = _analysis_row_sums(activity.events)
    res = _branching_from_rates(pop)
    return (;
        level=:agent,
        per_tick=res.per_tick,
        sigma=res.sigma,
        sigma_ols=res.sigma_ols,
        population_rate=pop,
        agent_activity=pop,
        agent_events=activity.events,
        agent_magnitudes=activity.magnitudes,
        n_agents=size(activity.events, 2),
        turn_threshold=activity.threshold,
        observable_kind=activity.spec.kind,
        observable_id=activity.spec.id,
        neighbor_radius=activity.spec.neighbor_radius,
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
function branching_ratio_mr(sim::SimResult; kmax::Integer=20, transient::Integer=0, level::Symbol=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, threshold=nothing, neighbor_radius=nothing)
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

    activity = _analysis_agent_activity(
        sim,
        :branching_ratio_mr;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        threshold=threshold,
        neighbor_radius=neighbor_radius,
    )
    pop = _analysis_row_sums(activity.events)
    res = _branching_mr_from_rates(pop; kmax=kmax, transient=transient)
    return (;
        level=:agent,
        res...,
        population_rate=pop,
        agent_activity=pop,
        agent_events=activity.events,
        agent_magnitudes=activity.magnitudes,
        n_agents=size(activity.events, 2),
        transient=transient,
        turn_threshold=activity.threshold,
        observable_kind=activity.spec.kind,
        observable_id=activity.spec.id,
        neighbor_radius=activity.spec.neighbor_radius,
    )
end

function _branching_validate_window(level::Symbol, window::Integer, stride::Integer, kmax::Integer)
    kmax >= 2 || throw(ArgumentError("branching_ratio_mr_windowed needs kmax >= 2"))
    stride >= 1 || throw(ArgumentError("branching_ratio_mr_windowed needs stride >= 1"))
    window > kmax + 2 || throw(ArgumentError("branching_ratio_mr_windowed needs window > kmax + 2"))
    min_window = level === :agent ? 6 * kmax : 5 * kmax
    window >= min_window ||
        throw(ArgumentError("branching_ratio_mr_windowed needs window >= $(min_window) for level=:$(level) and kmax=$(kmax)"))
    return nothing
end

function _branching_window_starts(n::Integer, window::Integer, stride::Integer)
    n >= window || return Int[]
    return collect(1:stride:(n - window + 1))
end

function _analysis_residualize_series(values::AbstractVector{<:Real}, drive::AbstractVector{<:Real})
    n = min(length(values), length(drive))
    n >= 2 || return Float64.(values)

    y = Float64.(values)
    x = Float64.(drive[1:n])
    mx = _series_mean(x)
    my = _series_mean(@view y[1:n])
    cov_xy = 0.0
    var_x = 0.0
    @inbounds for i in 1:n
        dx = x[i] - mx
        cov_xy += dx * (y[i] - my)
        var_x += dx * dx
    end
    var_x > 0.0 || return y

    slope = cov_xy / var_x
    intercept = my - slope * mx
    @inbounds for i in 1:n
        y[i] = y[i] - (intercept + slope * x[i]) + my
    end
    return y
end

function _branching_drive_series(sim::SimResult, drive)
    drive === nothing && return nothing
    if drive === :distance_to_source || drive === :distance || drive == "distance_to_source" || drive == "distance"
        return distance_to_source(sim)
    elseif drive === :object_in_view || drive == "object_in_view"
        return object_in_view(sim)
    elseif drive === :heading_error || drive == "heading_error"
        return heading_error(sim)
    end
    drive isa AbstractVector{<:Real} && return drive
    throw(ArgumentError("branching_ratio_mr_windowed drive must be nothing, :distance_to_source, :object_in_view, :heading_error, or a numeric vector"))
end

function _branching_windowed_vector(pop::AbstractVector{<:Real}; window::Integer, stride::Integer, kmax::Integer, min_r2::Real)
    starts = _branching_window_starts(length(pop), window, stride)
    n_windows = length(starts)
    centers = Vector{Float64}(undef, n_windows)
    m_series = Vector{Float64}(undef, n_windows)
    r2_series = Vector{Float64}(undef, n_windows)
    n_used_series = Vector{Int}(undef, n_windows)

    @inbounds for idx in eachindex(starts)
        start = starts[idx]
        stop = start + window - 1
        centers[idx] = start + 0.5 * (window - 1)
        res = _branching_mr_from_rates(@view(pop[start:stop]); kmax=kmax, transient=0)
        fit = _branching_mr_fit_quality(res.r_k)
        n_used_series[idx] = fit.n_used
        r2_series[idx] = fit.r2
        m_series[idx] = fit.n_used >= 2 && isfinite(fit.r2) && fit.r2 >= Float64(min_r2) ? fit.m_mr : NaN
    end
    return centers, m_series, r2_series, n_used_series
end

function _branching_windowed_matrix(rates::AbstractMatrix{<:Real}; window::Integer, stride::Integer, kmax::Integer, min_r2::Real)
    starts = _branching_window_starts(size(rates, 1), window, stride)
    n_windows = length(starts)
    centers = Vector{Float64}(undef, n_windows)
    m_series = Vector{Float64}(undef, n_windows)
    r2_series = Vector{Float64}(undef, n_windows)
    n_used_series = Vector{Int}(undef, n_windows)

    @inbounds for idx in eachindex(starts)
        start = starts[idx]
        stop = start + window - 1
        centers[idx] = start + 0.5 * (window - 1)
        ms = Float64[]
        r2s = Float64[]
        n_total = 0
        for agent in axes(rates, 2)
            res = _branching_mr_from_rates(@view(rates[start:stop, agent]); kmax=kmax, transient=0)
            fit = _branching_mr_fit_quality(res.r_k)
            n_total += fit.n_used
            if fit.n_used >= 2 && isfinite(fit.r2) && fit.r2 >= Float64(min_r2) && isfinite(fit.m_mr)
                push!(ms, fit.m_mr)
                push!(r2s, fit.r2)
            end
        end
        n_used_series[idx] = n_total
        r2_series[idx] = _analysis_finite_mean(r2s)
        m_series[idx] = _analysis_finite_mean(ms)
    end
    return centers, m_series, r2_series, n_used_series
end

"""
    branching_ratio_mr_windowed(sim; level=:pooled, window, stride=window, kmax=20,
        observable=nothing, drive=nothing, min_r2=0.0)

Compute sliding-window Wilting-Priesemann MR branching estimates. Returns
`(t_centers, m_series, r2_series, n_used_series)`. At `level=:agent`,
`observable` may specify `kind=:turn|:speed|:align|:graded`, `threshold`, and
`neighbor_radius`; the threshold is resolved once over the full run and reused
inside every window.
"""
function branching_ratio_mr_windowed(
    sim::SimResult;
    level::Symbol=:pooled,
    window::Integer,
    stride::Integer=window,
    kmax::Integer=20,
    observable=nothing,
    turn_threshold=DEFAULT_TURN_THRESHOLD,
    event_kind::Symbol=:turn,
    threshold=nothing,
    neighbor_radius=nothing,
    drive=nothing,
    min_r2::Real=0.0,
)
    level = _analysis_level(level, :branching_ratio_mr_windowed)
    window = Int(window)
    stride = Int(stride)
    kmax = Int(kmax)
    _branching_validate_window(level, window, stride, kmax)
    driver = _branching_drive_series(sim, drive)

    if level === :pooled
        pop = _analysis_population_rate_series(sim, :branching_ratio_mr_windowed)
        driver === nothing || (pop = _analysis_residualize_series(pop, driver))
        return _branching_windowed_vector(pop; window=window, stride=stride, kmax=kmax, min_r2=min_r2)
    elseif level === :node
        rates = _analysis_node_rate_matrix(sim, :branching_ratio_mr_windowed)
        if driver !== nothing
            adjusted = Matrix{Float64}(undef, size(rates)...)
            @inbounds for i in axes(rates, 2)
                adjusted[:, i] .= _analysis_residualize_series(@view(rates[:, i]), driver)
            end
            rates = adjusted
        end
        return _branching_windowed_matrix(rates; window=window, stride=stride, kmax=kmax, min_r2=min_r2)
    end

    activity = _analysis_agent_activity(
        sim,
        :branching_ratio_mr_windowed;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        threshold=threshold,
        neighbor_radius=neighbor_radius,
    )
    pop = _analysis_row_sums(activity.events)
    driver === nothing || (pop = _analysis_residualize_series(pop, driver))
    return _branching_windowed_vector(pop; window=window, stride=stride, kmax=kmax, min_r2=min_r2)
end

"""
    branching_ratio_mr_conditioned(sim; condition=:object_in_view, window=200, stride=window,
        kmax=20, in_view_frac=0.5, min_r2=0.0)

Split the windowed pooled MR branching estimate by a per-tick `condition` series
(a symbol resolved via the drive machinery — `:object_in_view` / `:heading_error`
/ `:distance_to_source` — or a numeric vector) and contrast the two regimes. A
window counts as "in condition" when the mean of `condition` over its ticks is at
least `in_view_frac`. Returns `(; condition, window, stride, m_in, m_out, m_diff,
n_in, n_out)`.

This is the honest form of "branching ratio *while the object is being tracked*"
(PJ's request): each window's MR fit stays over contiguous ticks, so the estimate
is never corrupted by concatenating non-adjacent in-view samples. Read `m_diff`
beside `spectral_radius(sim)` — the Falandays homeostat pins the rate, so a
near-1 `m` may be rate-pinned rather than emergent, and the difference should be
checked against a phase-aware null (see `temporal_null`).
"""
function branching_ratio_mr_conditioned(
    sim::SimResult;
    condition=:object_in_view,
    window::Integer=200,
    stride::Integer=window,
    kmax::Integer=20,
    in_view_frac::Real=0.5,
    min_r2::Real=0.0,
)
    window = Int(window)
    stride = Int(stride)
    cond = _branching_drive_series(sim, condition)
    cond === nothing &&
        throw(ArgumentError("branching_ratio_mr_conditioned needs a condition series, got nothing"))

    centers, m_series, _r2, _n = branching_ratio_mr_windowed(
        sim; level=:pooled, window=window, stride=stride, kmax=kmax, min_r2=min_r2,
    )
    starts = _branching_window_starts(length(cond), window, stride)

    in_ms = Float64[]
    out_ms = Float64[]
    n = min(length(starts), length(m_series))
    @inbounds for idx in 1:n
        isfinite(m_series[idx]) || continue
        start = starts[idx]
        stop = start + window - 1
        frac = _series_mean(@view cond[start:stop])
        if frac >= Float64(in_view_frac)
            push!(in_ms, m_series[idx])
        else
            push!(out_ms, m_series[idx])
        end
    end

    m_in = _analysis_finite_mean(in_ms)
    m_out = _analysis_finite_mean(out_ms)
    return (;
        condition = condition isa Union{Symbol,AbstractString} ? Symbol(condition) : :custom,
        window,
        stride,
        m_in,
        m_out,
        m_diff = m_in - m_out,
        n_in = length(in_ms),
        n_out = length(out_ms),
    )
end
