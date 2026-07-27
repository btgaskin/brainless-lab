function _second_order_level(level::Symbol, name::Symbol)
    level = _analysis_level(level, name)
    level == :pooled &&
        throw(ArgumentError("$(name) is defined for level=:node or level=:agent"))
    return level
end

function _series_mean(values::AbstractVector{<:Real})
    isempty(values) && return NaN
    total = 0.0
    @inbounds for value in values
        total += Float64(value)
    end
    return total / length(values)
end

function _series_variance(values::AbstractVector{<:Real})
    isempty(values) && return NaN
    mean = _series_mean(values)
    total = 0.0
    @inbounds for value in values
        dx = Float64(value) - mean
        total += dx * dx
    end
    return total / length(values)
end

function _fano_from_counts(counts::AbstractVector{<:Real})
    mean = _series_mean(counts)
    var = _series_variance(counts)
    if mean > 0.0
        return var / mean
    end
    return var == 0.0 ? 0.0 : NaN
end

function _rate_summary_from_counts(counts::AbstractVector{<:Real}, n_units::Integer)
    n = Int(n_units)
    n > 0 || throw(ArgumentError("rate summary needs at least one unit"))
    return (;
        rate_mean=_series_mean(counts) / n,
        rate_variance=_series_variance(counts) / Float64(n)^2,
        fano_factor=_fano_from_counts(counts),
    )
end

function _participation_ratio_from_activity(activity::AbstractMatrix{<:Real})
    n_ticks, n_units = size(activity)
    n_units == 0 && return NaN
    n_ticks < n_units && throw(ArgumentError(
        "participation_ratio needs at least as many recorded ticks as units; " *
        "got $(n_ticks) ticks and $(n_units) units. Record more often or run longer.",
    ))
    n_ticks < 2 && return 0.0

    mat = Matrix{Float64}(activity)
    means = Vector{Float64}(undef, n_units)
    @inbounds for j in 1:n_units
        means[j] = _series_mean(@view mat[:, j])
        for t in 1:n_ticks
            mat[t, j] -= means[j]
        end
    end

    cov = (transpose(mat) * mat) ./ (n_ticks - 1)
    trace = 0.0
    frob2 = 0.0
    @inbounds for i in 1:n_units, j in 1:n_units
        value = cov[i, j]
        frob2 += value * value
        i == j && (trace += value)
    end
    return frob2 > 0.0 ? (trace * trace) / frob2 : 0.0
end

function _node_activity_matrices(sim::SimResult, name::Symbol)
    raw = getchannel(sim.recorder, :spikes)
    if !isempty(raw)
        return _analysis_spike_matrices(sim, name)
    end

    rates = _analysis_node_rate_matrix(sim, name)
    return [reshape(copy(@view rates[:, i]), size(rates, 1), 1) for i in axes(rates, 2)]
end

function _susceptibility_node(sim::SimResult)
    counts, widths = _analysis_node_count_matrix_and_widths(sim, :susceptibility)
    values = Vector{Float64}(undef, size(counts, 2))
    order = Matrix{Float64}(undef, size(counts)...)
    @inbounds for i in axes(counts, 2)
        n = Float64(widths[i])
        order[:, i] .= @view(counts[:, i]) ./ n
        values[i] = n * _series_variance(@view order[:, i])
    end
    return (;
        level=:node,
        susceptibility=_analysis_finite_mean(values),
        susceptibility_std=_analysis_finite_std(values),
        distribution=values,
        per_agent=values,
        order_parameter=order,
        n_agents=size(counts, 2),
        n_units=widths,
        summary=(
            mean=_analysis_finite_mean(values),
            std=_analysis_finite_std(values),
        ),
    )
end

function _susceptibility_agent(sim::SimResult)
    polar = _analysis_polarization_series(sim, :susceptibility)
    n_agents =
        hasproperty(sim.config, :n_agents) ? Int(sim.config.n_agents) :
        try
            size(_analysis_rate_matrix(sim, :susceptibility), 2)
        catch
            _, _, headings = _analysis_pose_matrices(getchannel(sim.recorder, :poses), :susceptibility)
            size(headings, 2)
        end
    value = n_agents * _series_variance(polar)
    return (;
        level=:agent,
        susceptibility=value,
        order_parameter=polar,
        n_agents=n_agents,
        n_units=n_agents,
    )
end

"""
    susceptibility(sim; level=:node)

Compute an EXPERIMENTAL finite-window susceptibility estimate.

At `level=:node`, each agent contributes `N * var(mean(node activity))`, where
`N` is that agent's node count. At `level=:agent`, the order parameter is swarm
polarization and the estimate is `n_agents * var(polarization)`.

For independent Bernoulli activity, the node-scale estimator has a rate floor
of `p(1-p)`. Two zero-correlation reservoirs firing at 10% and 30% therefore
differ by about 2.4 times from rate alone. Match activity rates or use an
explicit rate-conditioned control before comparing susceptibility.
"""
function susceptibility(sim::SimResult; level::Symbol=:node)
    level = _second_order_level(level, :susceptibility)
    return level == :node ? _susceptibility_node(sim) : _susceptibility_agent(sim)
end

function _window_validate(name::Symbol, window::Integer, stride::Integer)
    window >= 2 || throw(ArgumentError("$(name) needs window >= 2"))
    stride >= 1 || throw(ArgumentError("$(name) needs stride >= 1"))
    return nothing
end

function _window_centers(n::Integer, window::Integer, stride::Integer)
    starts = _branching_window_starts(n, window, stride)
    centers = Vector{Float64}(undef, length(starts))
    @inbounds for i in eachindex(starts)
        centers[i] = starts[i] + 0.5 * (window - 1)
    end
    return starts, centers
end

function _susceptibility_node_windowed(sim::SimResult, window::Integer, stride::Integer)
    counts, widths = _analysis_node_count_matrix_and_widths(sim, :susceptibility_windowed)
    starts, centers = _window_centers(size(counts, 1), window, stride)
    values = Vector{Float64}(undef, length(starts))
    order = Matrix{Float64}(undef, size(counts)...)
    @inbounds for i in axes(counts, 2)
        order[:, i] .= @view(counts[:, i]) ./ Float64(widths[i])
    end

    @inbounds for idx in eachindex(starts)
        start = starts[idx]
        stop = start + window - 1
        per_agent = Vector{Float64}(undef, size(order, 2))
        for agent in axes(order, 2)
            per_agent[agent] = Float64(widths[agent]) * _series_variance(@view order[start:stop, agent])
        end
        values[idx] = _analysis_finite_mean(per_agent)
    end
    return (; level=:node, t_centers=centers, susceptibility=values, window=window, stride=stride)
end

function _susceptibility_agent_windowed(sim::SimResult, window::Integer, stride::Integer)
    polar = _analysis_polarization_series(sim, :susceptibility_windowed)
    n_agents = _analysis_config_int(sim, :n_agents, 1)
    starts, centers = _window_centers(length(polar), window, stride)
    values = Vector{Float64}(undef, length(starts))
    @inbounds for idx in eachindex(starts)
        start = starts[idx]
        stop = start + window - 1
        values[idx] = Float64(n_agents) * _series_variance(@view polar[start:stop])
    end
    return (; level=:agent, t_centers=centers, susceptibility=values, window=window, stride=stride)
end

"""
    susceptibility_windowed(sim; level=:node, window, stride=window)

Compute an EXPERIMENTAL finite-window susceptibility at `level=:node` or
`level=:agent` over a recorded rollout. Returns
`(; level, t_centers, susceptibility, window, stride)`.

At node scale, independent Bernoulli activity has the rate floor `p(1-p)`.
Changing activity from 10% to 30% changes this floor by about 2.4 times without
introducing correlation.
"""
function susceptibility_windowed(sim::SimResult; level::Symbol=:node, window::Integer, stride::Integer=window)
    level = _second_order_level(level, :susceptibility_windowed)
    window = Int(window)
    stride = Int(stride)
    _window_validate(:susceptibility_windowed, window, stride)
    return level === :node ?
        _susceptibility_node_windowed(sim, window, stride) :
        _susceptibility_agent_windowed(sim, window, stride)
end

function _fano_node(sim::SimResult)
    counts, widths = _analysis_node_count_matrix_and_widths(sim, :fano_factor)
    summaries = [
        _rate_summary_from_counts(@view(counts[:, i]), widths[i])
        for i in axes(counts, 2)
    ]
    rate_means = [summary.rate_mean for summary in summaries]
    rate_variances = [summary.rate_variance for summary in summaries]
    values = [summary.fano_factor for summary in summaries]
    return (;
        level=:node,
        rate_mean=_analysis_finite_mean(rate_means),
        rate_variance=_analysis_finite_mean(rate_variances),
        fano_factor=_analysis_finite_mean(values),
        fano=_analysis_finite_mean(values),
        rate_mean_distribution=Float64.(rate_means),
        rate_variance_distribution=Float64.(rate_variances),
        fano_factor_std=_analysis_finite_std(values),
        distribution=Float64.(values),
        per_agent=Float64.(values),
        activity=counts,
        n_agents=size(counts, 2),
        n_units=widths,
        summary=(
            mean=_analysis_finite_mean(values),
            std=_analysis_finite_std(values),
            rate_mean=_analysis_finite_mean(rate_means),
            rate_variance=_analysis_finite_mean(rate_variances),
        ),
    )
end

function _fano_agent(sim::SimResult; turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, neighbor_radius=nothing)
    activity = _analysis_agent_activity(
        sim,
        :fano_factor;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        neighbor_radius=neighbor_radius,
    )
    counts = _analysis_row_sums(activity.events)
    summary = _rate_summary_from_counts(counts, size(activity.events, 2))
    return (;
        level=:agent,
        rate_mean=summary.rate_mean,
        rate_variance=summary.rate_variance,
        fano_factor=summary.fano_factor,
        fano=summary.fano_factor,
        activity=counts,
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
    fano_factor(sim; level=:node, turn_threshold=DEFAULT_TURN_THRESHOLD)

Return a finite-window activity-rate summary with `rate_mean`,
`rate_variance`, and the count Fano factor, `var(activity count) /
mean(activity count)`. An all-silent series returns zero for all three fields.

At `level=:node`, activity count is each agent's node spike count per tick. At
`level=:agent`, activity count is the number of agents whose absolute recorded
heading change exceeds `turn_threshold` (default `pi/12` radians) at each tick.
When only rates are recorded for node-level fallbacks, the configured `n_nodes`
is treated as a homogeneous per-agent node count. These values describe the
recorded window; they do not establish stationarity or independence across
ticks.
"""
function fano_factor(sim::SimResult; level::Symbol=:node, turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, neighbor_radius=nothing)
    level = _second_order_level(level, :fano_factor)
    return level == :node ? _fano_node(sim) : _fano_agent(
        sim;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        neighbor_radius=neighbor_radius,
    )
end

function _participation_node(sim::SimResult)
    mats = _node_activity_matrices(sim, :participation_ratio)
    values = [_participation_ratio_from_activity(mat) for mat in mats]
    return (;
        level=:node,
        participation_ratio=_analysis_finite_mean(values),
        participation_ratio_std=_analysis_finite_std(values),
        distribution=Float64.(values),
        per_agent=Float64.(values),
        n_agents=length(values),
        n_units=[size(mat, 2) for mat in mats],
        summary=(
            mean=_analysis_finite_mean(values),
            std=_analysis_finite_std(values),
        ),
    )
end

function _participation_agent(sim::SimResult)
    rates = _analysis_rate_matrix(sim, :participation_ratio)
    value = _participation_ratio_from_activity(rates)
    return (;
        level=:agent,
        participation_ratio=value,
        n_agents=size(rates, 2),
        n_units=size(rates, 2),
    )
end

"""
    participation_ratio(sim; level=:node)

Compute an EXPERIMENTAL covariance participation ratio,
`(sum(lambda))^2 / sum(lambda^2)`, where `lambda` are eigenvalues of the
activity covariance matrix.

At `level=:node`, the covariance is over nodes within each agent and the return
value summarizes the per-agent distribution. At `level=:agent`, the covariance
is over per-agent population-rate activity. The estimator throws when the
number of recorded ticks is smaller than the number of observed units because
its rank ceiling would otherwise dominate the result silently.

The covariance rank is at most `n_ticks - 1`, so the reported participation
ratio also ceilings at `n_ticks - 1` even when more units are recorded. Increase
the recorded duration before comparing high-dimensional reservoirs.
"""
function participation_ratio(sim::SimResult; level::Symbol=:node)
    level = _second_order_level(level, :participation_ratio)
    return level == :node ? _participation_node(sim) : _participation_agent(sim)
end
