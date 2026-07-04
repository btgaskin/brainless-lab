# EXPERIMENTAL neuronal-avalanche analysis.
#
# Beggs & Plenz (2003) defined neuronal avalanches as contiguous excursions of
# population activity above a quiet baseline. The exponent estimates here use a
# simple continuous MLE over xmin = the smallest positive observed value. That is
# a pragmatic first-pass estimator for recorded BrainlessLab activity, but it has
# no xmin search, no goodness-of-fit test, and is unreliable for short rollouts
# or small avalanche counts.

const _AVALANCHE_MIN_FIT_COUNT = 5

function _median_positive(values::AbstractVector{<:Real})
    positives = Float64[x for x in values if isfinite(Float64(x)) && Float64(x) > 0.0]
    isempty(positives) && return 0.0

    sort!(positives)
    n = length(positives)
    mid = fld(n + 1, 2)
    return isodd(n) ? positives[mid] : 0.5 * (positives[mid] + positives[mid + 1])
end

function _avalanche_runs(activity::AbstractVector{<:Real}, threshold::Real)
    sizes = Float64[]
    durations = Int[]

    size = 0.0
    duration = 0
    theta = Float64(threshold)

    @inbounds for value in activity
        a = Float64(value)
        if isfinite(a) && a > theta
            size += a
            duration += 1
        elseif duration > 0
            push!(sizes, size)
            push!(durations, duration)
            size = 0.0
            duration = 0
        end
    end

    if duration > 0
        push!(sizes, size)
        push!(durations, duration)
    end

    return sizes, durations
end

function _continuous_powerlaw_exponent(values::AbstractVector{<:Real}; min_count::Integer=_AVALANCHE_MIN_FIT_COUNT)
    xs = Float64[x for x in values if isfinite(Float64(x)) && Float64(x) > 0.0]
    length(xs) >= min_count || return NaN

    xmin = minimum(xs)
    xmin > 0.0 || return NaN

    denom = 0.0
    @inbounds for x in xs
        denom += log(x / xmin)
    end

    return denom > 0.0 ? 1.0 + length(xs) / denom : NaN
end

function _mean_size_duration_exponent(sizes::AbstractVector{<:Real}, durations::AbstractVector{<:Integer})
    length(sizes) == length(durations) ||
        throw(DimensionMismatch("sizes and durations must have the same length"))

    unique_durations = sort!(unique(Int.(durations)))
    xs = Float64[]
    ys = Float64[]

    for duration in unique_durations
        duration > 0 || continue
        total = 0.0
        count = 0
        @inbounds for i in eachindex(sizes, durations)
            if Int(durations[i]) == duration
                s = Float64(sizes[i])
                if isfinite(s) && s > 0.0
                    total += s
                    count += 1
                end
            end
        end
        count == 0 && continue
        push!(xs, log(Float64(duration)))
        push!(ys, log(total / count))
    end

    length(xs) >= 2 || return NaN
    return _intercept_corrected_slope(xs, ys)
end

function _avalanches_from_activity(activity::AbstractVector{<:Real}, threshold)
    theta = threshold === nothing ? _median_positive(activity) : Float64(threshold)
    isfinite(theta) || throw(ArgumentError("avalanches threshold must be finite"))

    sizes, durations = _avalanche_runs(activity, theta)
    n_avalanches = length(sizes)

    tau = _continuous_powerlaw_exponent(sizes)
    alpha = _continuous_powerlaw_exponent(durations)
    gamma_fit = n_avalanches >= _AVALANCHE_MIN_FIT_COUNT ?
        _mean_size_duration_exponent(sizes, durations) :
        NaN
    gamma_pred = isfinite(tau) && isfinite(alpha) && tau != 1.0 ?
        (alpha - 1.0) / (tau - 1.0) :
        NaN

    return (;
        sizes=sizes,
        durations=durations,
        tau=tau,
        alpha=alpha,
        gamma_fit=gamma_fit,
        gamma_pred=gamma_pred,
        n_avalanches=n_avalanches,
        threshold=theta,
    )
end

function _avalanches_level_summary(counts::AbstractMatrix{<:Real}, per_agent)
    taus = [res.tau for res in per_agent]
    alphas = [res.alpha for res in per_agent]
    gammas = [res.gamma_fit for res in per_agent]
    gamma_preds = [res.gamma_pred for res in per_agent]
    n_avalanches = [res.n_avalanches for res in per_agent]
    thresholds = [res.threshold for res in per_agent]
    return (;
        level=:node,
        per_agent=per_agent,
        sizes=[res.sizes for res in per_agent],
        durations=[res.durations for res in per_agent],
        tau=_analysis_finite_mean(taus),
        tau_std=_analysis_finite_std(taus),
        tau_distribution=Float64.(taus),
        alpha=_analysis_finite_mean(alphas),
        alpha_std=_analysis_finite_std(alphas),
        alpha_distribution=Float64.(alphas),
        gamma_fit=_analysis_finite_mean(gammas),
        gamma_fit_std=_analysis_finite_std(gammas),
        gamma_fit_distribution=Float64.(gammas),
        gamma_pred=_analysis_finite_mean(gamma_preds),
        gamma_pred_std=_analysis_finite_std(gamma_preds),
        gamma_pred_distribution=Float64.(gamma_preds),
        n_avalanches_distribution=Int.(n_avalanches),
        n_avalanches=_analysis_finite_mean(n_avalanches),
        threshold_distribution=Float64.(thresholds),
        threshold=_analysis_finite_mean(thresholds),
        activity=Matrix{Float64}(counts),
        n_agents=size(counts, 2),
        summary=(
            tau_mean=_analysis_finite_mean(taus),
            tau_std=_analysis_finite_std(taus),
            alpha_mean=_analysis_finite_mean(alphas),
            alpha_std=_analysis_finite_std(alphas),
            n_avalanches_mean=_analysis_finite_mean(n_avalanches),
        ),
    )
end

"""
    avalanches(sim; threshold=nothing, level=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD)

Compute EXPERIMENTAL neuronal-avalanche size and duration statistics from a
recorded rollout.

`level=:pooled` preserves the legacy population activity: total recorded spike
count per tick from `:spikes`; if `:spikes` is absent, `:rate` is multiplied by
the configured node count as a rate*N fallback. `level=:node` computes
avalanches inside each agent's node population and returns per-agent
distributions plus mean/std summaries. `level=:agent` treats each agent's
turn event as one ensemble count, where a turn event is a recorded heading
change with absolute size greater than `turn_threshold` (default `pi/12`
radians).

An avalanche is a maximal run of ticks with `A(t) > threshold`, bounded by
sub-threshold ticks. The default threshold is the median nonzero population
activity. Returns `(sizes, durations, tau, alpha, gamma_fit, gamma_pred,
n_avalanches, threshold)`.

`tau` and `alpha` are first-pass continuous power-law MLE estimates using
xmin = the smallest positive observed size/duration. `gamma_fit` is the slope of
`log(<S>(D)) ~ log(D)`, and `gamma_pred = (alpha - 1) / (tau - 1)` is the
crackling-noise scaling prediction. These fits need long runs and adequate
avalanche counts; tiny samples return `NaN` exponents.
"""
function avalanches(sim::SimResult; threshold=nothing, level::Symbol=:pooled, turn_threshold::Real=DEFAULT_TURN_THRESHOLD)
    level = _analysis_level(level, :avalanches)
    if level == :pooled
        return _avalanches_from_activity(_analysis_population_count_series(sim, :avalanches), threshold)
    elseif level == :node
        counts = _analysis_node_count_matrix(sim, :avalanches)
        per_agent = [_avalanches_from_activity(@view(counts[:, i]), threshold) for i in axes(counts, 2)]
        return _avalanches_level_summary(counts, per_agent)
    end

    events = _analysis_agent_activity_matrix(sim, :avalanches; turn_threshold=turn_threshold)
    activity = _analysis_row_sums(events)
    res = _avalanches_from_activity(activity, threshold)
    return (; level=:agent, res..., activity=activity, agent_events=events, n_agents=size(events, 2), turn_threshold=Float64(turn_threshold))
end
