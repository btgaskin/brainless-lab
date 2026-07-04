function _crossshift_measure_value(value)
    if value isa Number
        return Float64(value)
    elseif value isa NamedTuple
        for key in (:m_mr, :susceptibility, :correlation_length, :largest_component_frac_mean, :mean_component_size_mean, :n_components_mean)
            haskey(value, key) || continue
            return _crossshift_measure_value(getproperty(value, key))
        end
    end
    throw(ArgumentError("crossshift_null measure_fn must return a number or a known scalar analysis NamedTuple"))
end

# Channels recorded per-agent (one value/vector/tuple per agent per tick) that
# _crossshift_channel knows how to shift. :polarization/:milling are handled
# separately (dropped, not shifted -- they're whole-ensemble scalars with no
# per-agent decomposition, and downstream analyses recompute them from the
# already-shifted :poses). Any OTHER recorded channel (e.g. :scene, or a
# future addition) is neither in this set nor known-global, so it is left
# unshifted and _crossshift_surrogate warns rather than silently passing it
# through -- a measure_fn that reads such a channel would otherwise get a
# surrogate that looks nulled but silently isn't.
const _CROSSSHIFT_PER_AGENT_CHANNELS = (:poses, :rate, :rates, :spikes, :effectors, :percepts, :sensors, :spectral_radius)
const _CROSSSHIFT_GLOBAL_CHANNELS = (:polarization, :milling)

function _crossshift_n_agents(sim::SimResult)
    for channel in (:poses, :rate, :spikes)
        raw = getchannel(sim.recorder, channel)
        isempty(raw) && continue
        first = raw[1]
        if first isa AbstractVector
            return hasproperty(sim.config, :n_agents) ? Int(sim.config.n_agents) : length(first)
        elseif first isa Number
            return 1
        end
    end
    throw(ArgumentError("crossshift_null needs at least one recorded per-agent channel (:poses, :rate, or :spikes)"))
end

function _crossshift_agent_value(entry, agent::Integer, n_agents::Integer)
    if entry isa Number
        n_agents == 1 || throw(ArgumentError("cannot cross-shift scalar channel for multiple agents"))
        return entry
    elseif entry isa AbstractVector
        if n_agents == 1 && length(entry) != 1
            return entry
        end
        length(entry) >= agent ||
            throw(DimensionMismatch("recorded channel has $(length(entry)) agents; expected at least $(agent)"))
        return entry[agent]
    end
    throw(ArgumentError("crossshift_null channel entries must be numbers or per-agent vectors"))
end

function _crossshift_channel(raw::AbstractVector, shifts::AbstractVector{<:Integer}, n_agents::Integer)
    n_ticks = length(raw)
    shifted = Vector{Any}(undef, n_ticks)
    n_ticks == 0 && return shifted

    if n_agents == 1 && raw[1] isa Number
        shift = Int(shifts[1])
        @inbounds for t in 1:n_ticks
            shifted[t] = raw[mod1(t - shift, n_ticks)]
        end
        return shifted
    end

    @inbounds for t in 1:n_ticks
        entry = Vector{Any}(undef, n_agents)
        for agent in 1:n_agents
            source_t = mod1(t - Int(shifts[agent]), n_ticks)
            entry[agent] = _crossshift_agent_value(raw[source_t], agent, n_agents)
        end
        shifted[t] = entry
    end
    return shifted
end

function _crossshift_surrogate(sim::SimResult, shifts::AbstractVector{<:Integer}, n_agents::Integer)
    shifted_channels = Dict{Symbol,Vector{Any}}()
    for (channel, raw) in sim.recorder.channels
        if channel in _CROSSSHIFT_GLOBAL_CHANNELS
            continue
        elseif channel in _CROSSSHIFT_PER_AGENT_CHANNELS
            shifted_channels[channel] = _crossshift_channel(raw, shifts, n_agents)
        else
            @warn "crossshift_null does not know how to cross-shift channel; leaving it unshifted -- any measure_fn that depends on it will not get a valid null" channel
            shifted_channels[channel] = copy(raw)
        end
    end

    rec = Recorder(enabled=collect(keys(shifted_channels)), every=sim.recorder.every)
    rec.channels = shifted_channels
    rec.tick = sim.recorder.tick
    return SimResult(rec, sim.metrics, sim.task, sim.node, sim.config)
end

"""
    crossshift_null(sim, measure_fn; n_shifts, rng)

Compute a circular-shift null test for a cross-agent measure. Each surrogate
independently circular-shifts every agent's recorded time series, preserving
single-agent dynamics while destroying inter-agent timing. Returns
`(real, null_mean, null_std, ratio)`.
"""
function crossshift_null(sim::SimResult, measure_fn; n_shifts::Integer, rng::AbstractRNG)
    n = Int(n_shifts)
    n >= 1 || throw(ArgumentError("crossshift_null needs n_shifts >= 1"))
    n_agents = _crossshift_n_agents(sim)
    n_ticks = maximum(length(raw) for raw in values(sim.recorder.channels))
    n_ticks >= 1 || throw(ArgumentError("crossshift_null needs at least one recorded tick"))

    real_value = _crossshift_measure_value(measure_fn(sim))
    null_values = Vector{Float64}(undef, n)
    shifts = Vector{Int}(undef, n_agents)
    @inbounds for draw in 1:n
        for agent in 1:n_agents
            shifts[agent] = rand(rng, 0:(n_ticks - 1))
        end
        surrogate = _crossshift_surrogate(sim, shifts, n_agents)
        null_values[draw] = _crossshift_measure_value(measure_fn(surrogate))
    end

    null_mean = _analysis_finite_mean(null_values)
    null_std = _analysis_finite_std(null_values)
    ratio = isfinite(real_value) && isfinite(null_mean) && null_mean != 0.0 ? real_value / null_mean : NaN
    return (real=real_value, null_mean=null_mean, null_std=null_std, ratio=ratio)
end
