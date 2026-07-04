# EXPERIMENTAL second-order activity signatures.
#
# These are intentionally lightweight finite-window estimators for comparing
# node-within-reservoir and agent-within-ensemble regimes. They do not include
# finite-size scaling, stationarity checks, or uncertainty estimates beyond the
# per-agent summaries returned at node level.

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

function _participation_ratio_from_activity(activity::AbstractMatrix{<:Real})
    n_ticks, n_units = size(activity)
    n_units == 0 && return NaN
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
    rates = _analysis_rate_matrix(sim, :susceptibility)
    n_agents = size(rates, 2)
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
"""
function susceptibility(sim::SimResult; level::Symbol=:node)
    level = _second_order_level(level, :susceptibility)
    return level == :node ? _susceptibility_node(sim) : _susceptibility_agent(sim)
end

function _fano_node(sim::SimResult)
    counts = _analysis_node_count_matrix(sim, :fano_factor)
    values = [_fano_from_counts(@view(counts[:, i])) for i in axes(counts, 2)]
    return (;
        level=:node,
        fano_factor=_analysis_finite_mean(values),
        fano=_analysis_finite_mean(values),
        fano_factor_std=_analysis_finite_std(values),
        distribution=Float64.(values),
        per_agent=Float64.(values),
        activity=counts,
        n_agents=size(counts, 2),
        summary=(
            mean=_analysis_finite_mean(values),
            std=_analysis_finite_std(values),
        ),
    )
end

function _fano_agent(sim::SimResult; turn_threshold::Real=DEFAULT_TURN_THRESHOLD)
    events = _analysis_agent_activity_matrix(sim, :fano_factor; turn_threshold=turn_threshold)
    counts = _analysis_row_sums(events)
    value = _fano_from_counts(counts)
    return (;
        level=:agent,
        fano_factor=value,
        fano=value,
        activity=counts,
        agent_events=events,
        n_agents=size(events, 2),
        turn_threshold=Float64(turn_threshold),
    )
end

"""
    fano_factor(sim; level=:node, turn_threshold=DEFAULT_TURN_THRESHOLD)

Compute an EXPERIMENTAL finite-window Fano factor, `var(activity count) /
mean(activity count)`.

At `level=:node`, activity count is each agent's node spike count per tick. At
`level=:agent`, activity count is the number of agents whose absolute recorded
heading change exceeds `turn_threshold` (default `pi/12` radians) at each tick.
When only rates are recorded for node-level fallbacks, the configured `n_nodes`
is treated as a homogeneous per-agent node count.
"""
function fano_factor(sim::SimResult; level::Symbol=:node, turn_threshold::Real=DEFAULT_TURN_THRESHOLD)
    level = _second_order_level(level, :fano_factor)
    return level == :node ? _fano_node(sim) : _fano_agent(sim; turn_threshold=turn_threshold)
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
is over per-agent population-rate activity.
"""
function participation_ratio(sim::SimResult; level::Symbol=:node)
    level = _second_order_level(level, :participation_ratio)
    return level == :node ? _participation_node(sim) : _participation_agent(sim)
end
