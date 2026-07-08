function _crossshift_measure_value(value)
    if value isa Number
        return Float64(value)
    elseif value isa NamedTuple
        for key in (:m_mr, :m_diff, :susceptibility, :correlation_length, :largest_component_frac_mean, :mean_component_size_mean, :n_components_mean)
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
function crossshift_null(sim::SimResult, measure_fn; n_shifts::Integer, rng::AbstractRNG, threaded::Bool=true)
    n = Int(n_shifts)
    n >= 1 || throw(ArgumentError("crossshift_null needs n_shifts >= 1"))
    n_agents = _crossshift_n_agents(sim)
    n_ticks = maximum(length(raw) for raw in values(sim.recorder.channels))
    n_ticks >= 1 || throw(ArgumentError("crossshift_null needs at least one recorded tick"))

    real_value = _crossshift_measure_value(measure_fn(sim))

    # Draw every surrogate's shifts up front from the caller's rng (same draw
    # order as the historical serial loop), so the null is deterministic in the
    # seed while the expensive measure recomputations fan out across threads.
    # Surrogates only read `sim`, so concurrent draws are safe.
    shift_draws = Vector{Vector{Int}}(undef, n)
    for draw in 1:n
        shifts = Vector{Int}(undef, n_agents)
        for agent in 1:n_agents
            shifts[agent] = rand(rng, 0:(n_ticks - 1))
        end
        shift_draws[draw] = shifts
    end
    null_values = Float64[
        Float64(v) for v in parallel_map(shift_draws; threaded=threaded) do shifts
            surrogate = _crossshift_surrogate(sim, shifts, n_agents)
            _crossshift_measure_value(measure_fn(surrogate))
        end
    ]

    null_mean = _analysis_finite_mean(null_values)
    null_std = _analysis_finite_std(null_values)
    ratio = isfinite(real_value) && isfinite(null_mean) && null_mean != 0.0 ? real_value / null_mean : NaN
    return (real=real_value, null_mean=null_mean, null_std=null_std, ratio=ratio)
end

function _circshift_condition(condition::AbstractVector{<:Real}, shift::Integer)
    nt = length(condition)
    out = Vector{Float64}(undef, nt)
    s = Int(shift)
    @inbounds for t in 1:nt
        out[t] = Float64(condition[mod1(t - s, nt)])
    end
    return out
end

"""
    temporal_null(sim, condition, measure_fn; n_shifts, rng, threaded=true)

Within-network (single-agent) null for a drive-CONDITIONED statistic. Each
surrogate circularly shifts the per-tick `condition` series by a random offset,
destroying its phase alignment with the network's own dynamics while preserving
the condition's marginal distribution and periodic power spectrum *exactly*.

This is the null to use — not `crossshift_null` — when the claim is within a
single reservoir (e.g. "branching differs while the object is in view"), and
especially when the task carries a periodic stimulus (the tracking direction
flips every 720 ticks) that would otherwise make any two stimulus-locked signals
look coupled. The shift is applied to the *condition*, not to the rate series
whose branching is measured, so it is genuinely destructive here — unlike
circularly shifting a lone branching series, which is a no-op.

`measure_fn(sim, condition)` must return a number or a scalar analysis NamedTuple
(e.g. `branching_ratio_mr_conditioned`'s `m_diff`). Returns
`(real, null_mean, null_std, ratio)`; `ratio` near 1 ⇒ the conditioning effect is
indistinguishable from a phase-shuffled stimulus.
"""
function temporal_null(sim::SimResult, condition::AbstractVector{<:Real}, measure_fn; n_shifts::Integer, rng::AbstractRNG, threaded::Bool=true)
    n = Int(n_shifts)
    n >= 1 || throw(ArgumentError("temporal_null needs n_shifts >= 1"))
    nt = length(condition)
    nt >= 2 || throw(ArgumentError("temporal_null needs a condition series of length >= 2"))

    real_value = _crossshift_measure_value(measure_fn(sim, condition))

    # Draw shifts up front for seed-determinism, then fan the recomputations out.
    shift_draws = Vector{Int}(undef, n)
    for i in 1:n
        shift_draws[i] = rand(rng, 1:(nt - 1))
    end
    null_values = Float64[
        Float64(v) for v in parallel_map(shift_draws; threaded=threaded) do shift
            surrogate = _circshift_condition(condition, shift)
            _crossshift_measure_value(measure_fn(sim, surrogate))
        end
    ]

    null_mean = _analysis_finite_mean(null_values)
    null_std = _analysis_finite_std(null_values)
    ratio = isfinite(real_value) && isfinite(null_mean) && null_mean != 0.0 ? real_value / null_mean : NaN
    return (real=real_value, null_mean=null_mean, null_std=null_std, ratio=ratio)
end
