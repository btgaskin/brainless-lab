function _median_positive(values::AbstractVector{<:Real})
    positives = Float64[x for x in values if isfinite(Float64(x)) && Float64(x) > 0.0]
    isempty(positives) && return 0.0

    sort!(positives)
    n = length(positives)
    mid = fld(n + 1, 2)
    return isodd(n) ? positives[mid] : 0.5 * (positives[mid] + positives[mid + 1])
end

function _quantile_positive(values::AbstractVector{<:Real}, q::Real)
    q_ = Float64(q)
    0.0 <= q_ <= 1.0 || throw(ArgumentError("positive quantile q must be in [0, 1]"))

    positives = Float64[x for x in values if isfinite(Float64(x)) && Float64(x) > 0.0]
    isempty(positives) && return 0.0

    sort!(positives)
    n = length(positives)
    n == 1 && return positives[1]

    pos = 1.0 + (n - 1) * q_
    lo = floor(Int, pos)
    hi = ceil(Int, pos)
    lo == hi && return positives[lo]
    return positives[lo] + (pos - lo) * (positives[hi] - positives[lo])
end

function _avalanche_runs(activity::AbstractVector{<:Real}, threshold::Real)
    sizes = Float64[]
    durations = Int[]
    inter_event_intervals = Int[]

    size = 0.0
    duration = 0
    last_onset = 0
    theta = Float64(threshold)

    @inbounds for (tick, value) in enumerate(activity)
        a = Float64(value)
        if isfinite(a) && a > theta
            if duration == 0
                last_onset > 0 && push!(inter_event_intervals, tick - last_onset)
                last_onset = tick
            end
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

    return sizes, durations, inter_event_intervals
end

function _avalanches_from_activity(activity::AbstractVector{<:Real}, threshold)
    theta = threshold === nothing ? _median_positive(activity) : Float64(threshold)
    isfinite(theta) || throw(ArgumentError("avalanches threshold must be finite"))

    sizes, durations, inter_event_intervals = _avalanche_runs(activity, theta)
    n_avalanches = length(sizes)

    return (;
        sizes=sizes,
        durations=durations,
        inter_event_intervals=inter_event_intervals,
        mean_inter_event_interval=_analysis_finite_mean(inter_event_intervals),
        n_avalanches=n_avalanches,
        threshold=theta,
    )
end

function _avalanches_level_summary(counts::AbstractMatrix{<:Real}, per_agent)
    mean_inter_event_intervals = [res.mean_inter_event_interval for res in per_agent]
    n_avalanches = [res.n_avalanches for res in per_agent]
    thresholds = [res.threshold for res in per_agent]
    return (;
        level=:node,
        per_agent=per_agent,
        sizes=[res.sizes for res in per_agent],
        durations=[res.durations for res in per_agent],
        inter_event_intervals=[res.inter_event_intervals for res in per_agent],
        mean_inter_event_interval_distribution=Float64.(mean_inter_event_intervals),
        mean_inter_event_interval=_analysis_finite_mean(mean_inter_event_intervals),
        n_avalanches_distribution=Int.(n_avalanches),
        n_avalanches=_analysis_finite_mean(n_avalanches),
        threshold_distribution=Float64.(thresholds),
        threshold=_analysis_finite_mean(thresholds),
        activity=Matrix{Float64}(counts),
        n_agents=size(counts, 2),
        summary=(
            mean_inter_event_interval=_analysis_finite_mean(mean_inter_event_intervals),
            n_avalanches_mean=_analysis_finite_mean(n_avalanches),
        ),
    )
end

"""
    avalanches(sim; threshold=nothing, level=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD)

Extract EXPERIMENTAL descriptive neuronal-avalanche events from a recorded
rollout. This function does not fit avalanche exponents or distributions.
Beggs and Plenz (2003) define neuronal avalanches as contiguous excursions of
population activity above a quiet baseline. BrainlessLab reports the extracted
events and threshold without fitting the small event samples.

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
activity. The result contains sizes, durations, onset-to-onset inter-event
intervals, their mean, the event count, and the threshold used.

Current BrainlessLab runs provide too few events for distributional fits and
show about 25-fold seed-to-seed count swings at a fixed condition. Treat this
output as a within-run description. It does not support comparative claims
between conditions.
"""
function avalanches(sim::SimResult; threshold=nothing, level::Symbol=:pooled, turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, neighbor_radius=nothing)
    level = _analysis_level(level, :avalanches)
    if level == :pooled
        return _avalanches_from_activity(_analysis_population_count_series(sim, :avalanches), threshold)
    elseif level == :node
        counts = _analysis_node_count_matrix(sim, :avalanches)
        per_agent = [_avalanches_from_activity(@view(counts[:, i]), threshold) for i in axes(counts, 2)]
        return _avalanches_level_summary(counts, per_agent)
    end

    observable_activity = _analysis_agent_activity(
        sim,
        :avalanches;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        neighbor_radius=neighbor_radius,
    )
    activity = _analysis_row_sums(observable_activity.events)
    res = _avalanches_from_activity(activity, threshold)
    return (;
        level=:agent,
        res...,
        activity=activity,
        agent_events=observable_activity.events,
        agent_magnitudes=observable_activity.magnitudes,
        n_agents=size(observable_activity.events, 2),
        turn_threshold=observable_activity.threshold,
        observable_kind=observable_activity.spec.kind,
        observable_id=observable_activity.spec.id,
        neighbor_radius=observable_activity.spec.neighbor_radius,
    )
end
