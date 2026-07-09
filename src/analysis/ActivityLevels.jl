const _ANALYSIS_LEVELS = (:pooled, :node, :agent)
const DEFAULT_TURN_THRESHOLD = pi / 12
const DEFAULT_ENSEMBLE_THRESHOLD = (:quantile, 0.85)
const _ENSEMBLE_OBSERVABLE_KINDS = (:turn, :speed, :align, :graded)

function _analysis_level(level::Symbol, name::Symbol)
    level in _ANALYSIS_LEVELS ||
        throw(ArgumentError("$(name) level must be one of :pooled, :node, or :agent"))
    return level
end

function _analysis_numeric_vector(entry, name::Symbol, t::Integer)
    if entry isa Number
        return [Float64(entry)]
    elseif entry isa AbstractArray
        if all(x -> x isa Number, entry)
            return [Float64(x) for x in entry]
        end

        out = Float64[]
        for x in entry
            append!(out, _analysis_numeric_vector(x, name, t))
        end
        return out
    elseif entry isa Tuple
        out = Float64[]
        for x in entry
            append!(out, _analysis_numeric_vector(x, name, t))
        end
        return out
    end

    throw(ArgumentError("$(name) needs numeric recorder entries; bad entry at tick $(t)"))
end

function _analysis_sample_matrix(raw, name::Symbol)
    isempty(raw) && throw(ArgumentError("$(name) needs a recorded channel with at least one sample"))

    n_ticks = length(raw)
    rows = Vector{Vector{Float64}}(undef, n_ticks)
    @inbounds for t in 1:n_ticks
        rows[t] = _analysis_numeric_vector(raw[t], name, t)
    end

    width = length(rows[1])
    width > 0 || throw(ArgumentError("$(name) needs non-empty numeric recorder entries"))

    out = Matrix{Float64}(undef, n_ticks, width)
    @inbounds for t in 1:n_ticks
        length(rows[t]) == width ||
            throw(DimensionMismatch("$(name) sample $(t) has width $(length(rows[t])); expected $(width)"))
        out[t, :] .= rows[t]
    end
    return out
end

function _analysis_config_int(sim::SimResult, field::Symbol, default::Integer)
    if hasproperty(sim.config, field)
        return Int(getproperty(sim.config, field))
    end
    return Int(default)
end

function _analysis_agent_node_vectors(entry, name::Symbol, t::Integer)
    if entry isa Number
        return [[Float64(entry)]]
    elseif entry isa AbstractArray
        if all(x -> x isa Number, entry)
            return [[Float64(x) for x in entry]]
        end

        entry isa AbstractVector ||
            throw(ArgumentError("$(name) needs per-agent entries as a vector of node vectors; bad entry at tick $(t)"))
        out = Vector{Float64}[]
        for agent_entry in entry
            push!(out, _analysis_numeric_vector(agent_entry, name, t))
        end
        return out
    elseif entry isa Tuple
        return [_analysis_numeric_vector(entry, name, t)]
    end

    throw(ArgumentError("$(name) needs numeric recorder entries; bad entry at tick $(t)"))
end

function _analysis_agent_node_matrices(sim::SimResult, channel::Symbol, name::Symbol)
    channel in (:rate, :rates) &&
        throw(ArgumentError("$(name) needs per-node reservoir channels; :$(channel) only records per-agent rates"))
    raw = getchannel(sim.recorder, channel)
    isempty(raw) && throw(ArgumentError("$(name) needs the :$(channel) channel recorded; run simulate(...; record=(:$(channel), ...))"))

    n_ticks = length(raw)
    first = _analysis_agent_node_vectors(raw[1], name, 1)
    n_agents = length(first)
    n_agents > 0 || throw(ArgumentError("$(name) needs at least one recorded agent"))
    widths = length.(first)
    all(>(0), widths) || throw(ArgumentError("$(name) needs non-empty node vectors"))

    out = [Matrix{Float64}(undef, n_ticks, widths[i]) for i in 1:n_agents]
    @inbounds for i in 1:n_agents
        out[i][1, :] .= first[i]
    end

    @inbounds for t in 2:n_ticks
        rows = _analysis_agent_node_vectors(raw[t], name, t)
        length(rows) == n_agents ||
            throw(DimensionMismatch("$(name) sample $(t) has $(length(rows)) agents; expected $(n_agents)"))
        for i in 1:n_agents
            length(rows[i]) == widths[i] ||
                throw(DimensionMismatch("$(name) sample $(t) agent $(i) has width $(length(rows[i])); expected $(widths[i])"))
            out[i][t, :] .= rows[i]
        end
    end

    return out
end

function _analysis_spike_matrices(sim::SimResult, name::Symbol)
    return _analysis_agent_node_matrices(sim, :spikes, name)
end

function _analysis_rate_matrix_from_raw(raw, name::Symbol)
    isempty(raw) && throw(ArgumentError("$(name) needs the :rate channel recorded; run simulate(...; record=(:rate, ...))"))

    n_ticks = length(raw)
    rows = Vector{Vector{Float64}}(undef, n_ticks)
    @inbounds for t in 1:n_ticks
        entry = raw[t]
        if entry isa Number
            rows[t] = [Float64(entry)]
        elseif entry isa AbstractVector && all(x -> x isa Number, entry)
            rows[t] = Float64.(entry)
        else
            rows[t] = _analysis_numeric_vector(entry, name, t)
        end
    end

    n_agents = length(rows[1])
    n_agents > 0 || throw(ArgumentError("$(name) needs non-empty rate samples"))
    out = Matrix{Float64}(undef, n_ticks, n_agents)
    @inbounds for t in 1:n_ticks
        length(rows[t]) == n_agents ||
            throw(DimensionMismatch("$(name) sample $(t) has $(length(rows[t])) rates; expected $(n_agents)"))
        out[t, :] .= rows[t]
    end
    return out
end

function _analysis_row_sums(mat::AbstractMatrix{<:Real})
    out = Vector{Float64}(undef, size(mat, 1))
    @inbounds for t in axes(mat, 1)
        total = 0.0
        for j in axes(mat, 2)
            total += Float64(mat[t, j])
        end
        out[t] = total
    end
    return out
end

function _analysis_row_means(mat::AbstractMatrix{<:Real})
    out = Vector{Float64}(undef, size(mat, 1))
    width = size(mat, 2)
    @inbounds for t in axes(mat, 1)
        total = 0.0
        for j in axes(mat, 2)
            total += Float64(mat[t, j])
        end
        out[t] = width == 0 ? 0.0 : total / width
    end
    return out
end

function _analysis_rate_matrix_from_spikes(sim::SimResult, name::Symbol)
    spike_mats = _analysis_spike_matrices(sim, name)
    n_ticks = size(spike_mats[1], 1)
    n_agents = length(spike_mats)
    rates = Matrix{Float64}(undef, n_ticks, n_agents)
    @inbounds for i in 1:n_agents
        rates[:, i] .= _analysis_row_means(spike_mats[i])
    end
    return rates
end

function _analysis_rate_matrix(sim::SimResult, name::Symbol)
    raw = getchannel(sim.recorder, :rate)
    isempty(raw) || return _analysis_rate_matrix_from_raw(raw, name)
    return _analysis_rate_matrix_from_spikes(sim, name)
end

function _analysis_node_rate_matrix(sim::SimResult, name::Symbol)
    raw = getchannel(sim.recorder, :spikes)
    if !isempty(raw)
        return _analysis_rate_matrix_from_spikes(sim, name)
    end
    return _analysis_rate_matrix(sim, name)
end

function _analysis_node_count_matrix_and_widths(sim::SimResult, name::Symbol)
    raw = getchannel(sim.recorder, :spikes)
    if !isempty(raw)
        spike_mats = _analysis_spike_matrices(sim, name)
        n_ticks = size(spike_mats[1], 1)
        n_agents = length(spike_mats)
        counts = Matrix{Float64}(undef, n_ticks, n_agents)
        widths = Vector{Int}(undef, n_agents)
        @inbounds for i in 1:n_agents
            widths[i] = size(spike_mats[i], 2)
            counts[:, i] .= _analysis_row_sums(spike_mats[i])
        end
        return counts, widths
    end

    n_nodes = _analysis_config_int(sim, :n_nodes, 1)
    rates = _analysis_rate_matrix(sim, name)
    if size(rates, 2) > 1 && !hasproperty(sim.config, :n_nodes)
        throw(ArgumentError("$(name) rate fallback for multiple agents needs homogeneous n_nodes in sim.config; record :spikes to avoid this assumption"))
    end
    return rates .* Float64(n_nodes), fill(Int(n_nodes), size(rates, 2))
end

function _analysis_node_count_matrix(sim::SimResult, name::Symbol)
    counts, _ = _analysis_node_count_matrix_and_widths(sim, name)
    return counts
end

function _analysis_population_rate_series(sim::SimResult, name::Symbol)
    return _analysis_row_means(_analysis_rate_matrix(sim, name))
end

_analysis_wrap_to_pi(a::Real) = atan(sin(a), cos(a))

function _analysis_threshold_from_table(value, name::Symbol)
    value isa AbstractDict ||
        throw(ArgumentError("$(name) threshold table must define quantile, fixed, or median"))
    if haskey(value, "quantile")
        return (:quantile, Float64(value["quantile"]))
    elseif haskey(value, :quantile)
        return (:quantile, Float64(value[:quantile]))
    elseif haskey(value, "fixed")
        return Float64(value["fixed"])
    elseif haskey(value, :fixed)
        return Float64(value[:fixed])
    elseif get(value, "median", get(value, :median, false)) == true
        return :median
    end
    throw(ArgumentError("$(name) threshold table must define quantile, fixed, or median"))
end

function _analysis_resolve_activity_threshold(value, values::AbstractVector{<:Real}, name::Symbol)
    value isa AbstractDict && (value = _analysis_threshold_from_table(value, name))
    if value isa Number
        threshold = Float64(value)
        isfinite(threshold) && threshold >= 0.0 ||
            throw(ArgumentError("$(name) activity threshold must be finite and non-negative"))
        return threshold
    elseif value === :median || value === :adaptive
        return _quantile_positive(values, 0.5)
    elseif value isa Tuple && length(value) == 2 && value[1] === :quantile
        return _quantile_positive(values, Float64(value[2]))
    end
    throw(ArgumentError("$(name) activity threshold must be a non-negative number, :median, :adaptive, or (:quantile, q)"))
end

function _analysis_turn_threshold(value, values::AbstractVector{<:Real}, name::Symbol)
    threshold = _analysis_resolve_activity_threshold(value, values, name)
    isfinite(threshold) && threshold >= 0.0 ||
        throw(ArgumentError("$(name) turn_threshold must be finite and non-negative"))
    return threshold
end

function _analysis_observable_get(observable, key::Symbol, default)
    observable === nothing && return default
    if observable isa NamedTuple
        return haskey(observable, key) ? getproperty(observable, key) : default
    elseif observable isa AbstractDict
        return haskey(observable, string(key)) ? observable[string(key)] :
            haskey(observable, key) ? observable[key] : default
    elseif observable isa Symbol && key === :kind
        return observable
    end
    return default
end

function _analysis_observable_spec(observable, name::Symbol; event_kind::Symbol=:turn, threshold=nothing, turn_threshold=DEFAULT_TURN_THRESHOLD, neighbor_radius=nothing)
    kind = Symbol(_analysis_observable_get(observable, :kind, event_kind))
    kind in _ENSEMBLE_OBSERVABLE_KINDS ||
        throw(ArgumentError("$(name) observable kind must be one of $(join(string.(_ENSEMBLE_OBSERVABLE_KINDS), ", "))"))

    raw_threshold = _analysis_observable_get(observable, :threshold, threshold)
    if raw_threshold === nothing && kind != :graded
        raw_threshold = observable === nothing ? turn_threshold : DEFAULT_ENSEMBLE_THRESHOLD
    end
    radius = _analysis_observable_get(observable, :neighbor_radius, neighbor_radius)
    id = string(_analysis_observable_get(observable, :id, _analysis_observable_id(kind, raw_threshold)))
    return (kind=kind, threshold=raw_threshold, neighbor_radius=radius, id=id)
end

function _analysis_observable_id(kind::Symbol, threshold)
    kind === :graded && return "graded"
    return string(kind) * "_" * _analysis_threshold_id(threshold)
end

function _analysis_threshold_id(threshold)
    threshold isa AbstractDict && (threshold = _analysis_threshold_from_table(threshold, :observable_id))
    threshold === nothing && return "none"
    threshold === :median && return "median"
    threshold === :adaptive && return "median"
    if threshold isa Tuple && length(threshold) == 2 && threshold[1] === :quantile
        q = Float64(threshold[2])
        pct = 100.0 * q
        if isapprox(pct, round(pct); atol=1e-9)
            return "q" * string(round(Int, pct))
        end
        return "q" * replace(string(round(q; digits=3)), "." => "p")
    elseif threshold isa Number
        return "fixed_" * replace(replace(string(round(Float64(threshold); digits=4)), "." => "p"), "-" => "m")
    end
    return replace(string(threshold), ":" => "", " " => "_")
end

function _analysis_turn_magnitude_matrix(headings::AbstractMatrix{<:Real})
    n_ticks, n_agents = size(headings)
    n_ticks >= 2 || return zeros(Float64, 0, n_agents)

    magnitudes = Matrix{Float64}(undef, n_ticks - 1, n_agents)
    @inbounds for t in 1:(n_ticks - 1), i in 1:n_agents
        magnitudes[t, i] = abs(_analysis_wrap_to_pi(Float64(headings[t + 1, i]) - Float64(headings[t, i])))
    end
    return magnitudes
end

function _analysis_speed_change_matrix(sim::SimResult, name::Symbol)
    vx, vy, _, _, _ = _analysis_velocity_matrices(sim, name)
    n_steps, n_agents = size(vx)
    n_steps >= 2 || return zeros(Float64, 0, n_agents)

    speeds = Matrix{Float64}(undef, n_steps, n_agents)
    @inbounds for t in 1:n_steps, i in 1:n_agents
        speeds[t, i] = hypot(vx[t, i], vy[t, i])
    end

    changes = Matrix{Float64}(undef, n_steps - 1, n_agents)
    @inbounds for t in 1:(n_steps - 1), i in 1:n_agents
        changes[t, i] = abs(speeds[t + 1, i] - speeds[t, i])
    end
    return changes
end

function _analysis_neighbor_radius(sim::SimResult, radius, name::Symbol)
    if radius === nothing || radius === :vision_range || radius == "vision_range"
        if hasproperty(sim.config, :environment) && hasproperty(sim.config.environment, :vision_range)
            resolved = sim.config.environment.vision_range
            resolved === nothing &&
                throw(ArgumentError("$(name) align observable needs neighbor_radius or environment vision_range"))
            return Float64(resolved)
        end
        throw(ArgumentError("$(name) align observable needs neighbor_radius or environment vision_range"))
    end

    resolved = Float64(radius)
    isfinite(resolved) && resolved >= 0.0 ||
        throw(ArgumentError("$(name) neighbor_radius must be finite and non-negative"))
    return resolved
end

function _analysis_alignment_change_matrix(sim::SimResult, name::Symbol, radius)
    xs, ys, headings = _analysis_pose_matrices(getchannel(sim.recorder, :poses), name)
    n_ticks, n_agents = size(headings)
    n_ticks >= 2 || return zeros(Float64, 0, n_agents)

    radius_ = _analysis_neighbor_radius(sim, radius, name)
    torus_size = _analysis_environment_size(sim)
    torus = torus_size === nothing ? nothing : Torus(torus_size)
    alignment = zeros(Float64, n_ticks, n_agents)

    @inbounds for t in 1:n_ticks
        for i in 1:n_agents
            sx = 0.0
            sy = 0.0
            count = 0
            for j in 1:n_agents
                i == j && continue
                d = torus === nothing ?
                    hypot(xs[t, j] - xs[t, i], ys[t, j] - ys[t, i]) :
                    tdistance(torus, (xs[t, i], ys[t, i]), (xs[t, j], ys[t, j]))
                if d <= radius_
                    sx += cos(headings[t, j])
                    sy += sin(headings[t, j])
                    count += 1
                end
            end
            if count > 0
                norm = hypot(sx, sy)
                alignment[t, i] = norm > 0.0 ? (cos(headings[t, i]) * sx + sin(headings[t, i]) * sy) / norm : 0.0
            end
        end
    end

    changes = Matrix{Float64}(undef, n_ticks - 1, n_agents)
    @inbounds for t in 1:(n_ticks - 1), i in 1:n_agents
        changes[t, i] = abs(alignment[t + 1, i] - alignment[t, i])
    end
    return changes
end

function _analysis_agent_observable_magnitudes(sim::SimResult, name::Symbol, spec)
    if spec.kind === :turn || spec.kind === :graded
        _, _, headings = _analysis_pose_matrices(getchannel(sim.recorder, :poses), name)
        return _analysis_turn_magnitude_matrix(headings)
    elseif spec.kind === :speed
        return _analysis_speed_change_matrix(sim, name)
    elseif spec.kind === :align
        return _analysis_alignment_change_matrix(sim, name, spec.neighbor_radius)
    end
    throw(ArgumentError("$(name) unsupported observable kind $(spec.kind)"))
end

function _analysis_agent_activity(sim::SimResult, name::Symbol; turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, threshold=nothing, neighbor_radius=nothing)
    spec = _analysis_observable_spec(
        observable,
        name;
        event_kind=event_kind,
        threshold=threshold,
        turn_threshold=turn_threshold,
        neighbor_radius=neighbor_radius,
    )
    magnitudes = _analysis_agent_observable_magnitudes(sim, name, spec)
    if spec.kind === :graded
        return (; spec=spec, events=magnitudes, magnitudes=magnitudes, threshold=NaN)
    end

    theta = _analysis_turn_threshold(spec.threshold, vec(magnitudes), name)
    events = Matrix{Float64}(undef, size(magnitudes)...)
    @inbounds for i in eachindex(magnitudes)
        events[i] = magnitudes[i] > theta ? 1.0 : 0.0
    end
    return (; spec=spec, events=events, magnitudes=magnitudes, threshold=theta)
end

function _analysis_agent_activity_matrix(sim::SimResult, name::Symbol; turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, threshold=nothing, neighbor_radius=nothing)
    return _analysis_agent_activity(
        sim,
        name;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        threshold=threshold,
        neighbor_radius=neighbor_radius,
    ).events
end

function _analysis_agent_activity_series(sim::SimResult, name::Symbol; turn_threshold=DEFAULT_TURN_THRESHOLD, observable=nothing, event_kind::Symbol=:turn, threshold=nothing, neighbor_radius=nothing)
    return _analysis_row_sums(_analysis_agent_activity_matrix(
        sim,
        name;
        turn_threshold=turn_threshold,
        observable=observable,
        event_kind=event_kind,
        threshold=threshold,
        neighbor_radius=neighbor_radius,
    ))
end

function _analysis_population_count_series(sim::SimResult, name::Symbol)
    raw_spikes = getchannel(sim.recorder, :spikes)
    if !isempty(raw_spikes)
        return _analysis_row_sums(_analysis_node_count_matrix(sim, name))
    end

    raw_rates = getchannel(sim.recorder, :rate)
    isempty(raw_rates) && throw(ArgumentError("$(name) needs :spikes recorded, or :rate recorded for the rate*N fallback"))

    n_nodes = _analysis_config_int(sim, :n_nodes, 1)
    n_agents = _analysis_config_int(sim, :n_agents, 1)
    if n_agents > 1 && !hasproperty(sim.config, :n_nodes)
        throw(ArgumentError("$(name) rate fallback for multiple agents needs homogeneous n_nodes in sim.config; record :spikes to avoid this assumption"))
    end
    activity = Vector{Float64}(undef, length(raw_rates))
    @inbounds for t in eachindex(raw_rates)
        rates = _analysis_numeric_vector(raw_rates[t], name, t)
        multiplier = length(rates) == 1 ? n_nodes * n_agents : n_nodes
        activity[t] = multiplier * sum(rates)
    end
    return activity
end

function _analysis_finite_values(values)
    out = Float64[]
    for value in values
        x = Float64(value)
        isfinite(x) && push!(out, x)
    end
    return out
end

function _analysis_finite_mean(values)
    xs = _analysis_finite_values(values)
    isempty(xs) && return NaN
    total = 0.0
    @inbounds for x in xs
        total += x
    end
    return total / length(xs)
end

function _analysis_finite_std(values)
    xs = _analysis_finite_values(values)
    isempty(xs) && return NaN
    length(xs) == 1 && return 0.0
    mean = _analysis_finite_mean(xs)
    total = 0.0
    @inbounds for x in xs
        dx = x - mean
        total += dx * dx
    end
    return sqrt(total / length(xs))
end

function _analysis_pose_matrices(raw, name::Symbol)
    isempty(raw) && throw(ArgumentError("$(name) needs the :poses channel recorded; run simulate(...; record=(:poses, ...))"))
    first_entry = raw[1]
    first_entry isa AbstractVector ||
        throw(ArgumentError("$(name) needs :poses entries shaped as vectors of (x, y, heading) tuples"))

    n_ticks = length(raw)
    n_agents = length(first_entry)
    n_agents > 0 || throw(ArgumentError("$(name) needs at least one recorded agent pose"))

    xs = Matrix{Float64}(undef, n_ticks, n_agents)
    ys = Matrix{Float64}(undef, n_ticks, n_agents)
    headings = Matrix{Float64}(undef, n_ticks, n_agents)

    @inbounds for t in 1:n_ticks
        entry = raw[t]
        entry isa AbstractVector ||
            throw(ArgumentError("$(name) needs :poses entries shaped as vectors of (x, y, heading) tuples"))
        length(entry) == n_agents ||
            throw(DimensionMismatch("$(name) sample $(t) has $(length(entry)) poses; expected $(n_agents)"))
        for i in 1:n_agents
            pose = entry[i]
            (pose isa Tuple || pose isa AbstractVector) && length(pose) >= 3 ||
                throw(ArgumentError("$(name) needs each pose shaped as (x, y, heading)"))
            xs[t, i] = Float64(pose[1])
            ys[t, i] = Float64(pose[2])
            headings[t, i] = Float64(pose[3])
        end
    end

    return xs, ys, headings
end

function _analysis_environment_size(sim::SimResult)
    hasproperty(sim.config, :environment) || return nothing
    environment = getproperty(sim.config, :environment)
    if hasproperty(environment, :size)
        size = getproperty(environment, :size)
        size === nothing || return Float64(size)
    end
    return nothing
end

function _analysis_axis_delta(a::Real, b::Real, size)
    delta = Float64(b) - Float64(a)
    size === nothing && return delta
    s = Float64(size)
    return mod(delta + 0.5 * s, s) - 0.5 * s
end

function _analysis_sample_stride(sim::SimResult)
    if hasproperty(sim.config, :every)
        return max(Float64(getproperty(sim.config, :every)), 1.0)
    end
    return 1.0
end

function _analysis_velocity_matrices(sim::SimResult, name::Symbol)
    xs, ys, headings = _analysis_pose_matrices(getchannel(sim.recorder, :poses), name)
    n_ticks, n_agents = size(xs)
    n_ticks >= 2 || return zeros(Float64, 0, n_agents), zeros(Float64, 0, n_agents), xs, ys, headings

    torus_size = _analysis_environment_size(sim)
    stride = _analysis_sample_stride(sim)
    vx = Matrix{Float64}(undef, n_ticks - 1, n_agents)
    vy = Matrix{Float64}(undef, n_ticks - 1, n_agents)
    @inbounds for t in 1:(n_ticks - 1), i in 1:n_agents
        vx[t, i] = _analysis_axis_delta(xs[t, i], xs[t + 1, i], torus_size) / stride
        vy[t, i] = _analysis_axis_delta(ys[t, i], ys[t + 1, i], torus_size) / stride
    end
    return vx, vy, xs, ys, headings
end

function _analysis_source_position(sim::SimResult, name::Symbol, source_position)
    if source_position !== nothing
        return (Float64(source_position[1]), Float64(source_position[2]))
    end
    if hasproperty(sim.config, :environment) && hasproperty(sim.config.environment, :source_position)
        pos = sim.config.environment.source_position
        pos === nothing ||
            return (Float64(pos[1]), Float64(pos[2]))
    end
    throw(ArgumentError("$(name) needs a forage source_position in sim.config.environment or an explicit source_position"))
end

"""
    distance_to_source(sim; source_position=nothing, subset=nothing)

Return the per-recorded-tick mean torus distance from the swarm to the forage
source. Requires `:poses` and either `sim.config.environment.source_position` or
an explicit `source_position`. `subset` (a collection of agent indices) restricts
the mean to those agents -- e.g. pass the follower indices to read whether a
blind subset is nonetheless drawn toward the source.
"""
function distance_to_source(sim::SimResult; source_position=nothing, subset=nothing)
    xs, ys, _ = _analysis_pose_matrices(getchannel(sim.recorder, :poses), :distance_to_source)
    source = _analysis_source_position(sim, :distance_to_source, source_position)
    torus_size = _analysis_environment_size(sim)
    torus = torus_size === nothing ? nothing : Torus(torus_size)
    idxs = subset === nothing ? collect(1:size(xs, 2)) : collect(Int.(subset))
    out = Vector{Float64}(undef, size(xs, 1))
    @inbounds for t in axes(xs, 1)
        total = 0.0
        for i in idxs
            (1 <= i <= size(xs, 2)) ||
                throw(ArgumentError("distance_to_source subset index $(i) outside 1:$(size(xs, 2))"))
            total += torus === nothing ?
                hypot(xs[t, i] - source[1], ys[t, i] - source[2]) :
                tdistance(torus, (xs[t, i], ys[t, i]), source)
        end
        out[t] = isempty(idxs) ? NaN : total / length(idxs)
    end
    return out
end

function _analysis_polarization_series(sim::SimResult, name::Symbol)
    raw = getchannel(sim.recorder, :polarization)
    if !isempty(raw)
        mat = _analysis_sample_matrix(raw, name)
        size(mat, 2) == 1 ||
            throw(DimensionMismatch("$(name) expected scalar :polarization samples, got width $(size(mat, 2))"))
        return vec(copy(mat[:, 1]))
    end

    _, _, headings = _analysis_pose_matrices(getchannel(sim.recorder, :poses), name)
    out = Vector{Float64}(undef, size(headings, 1))
    @inbounds for t in axes(headings, 1)
        out[t] = polarization(@view headings[t, :])
    end
    return out
end
