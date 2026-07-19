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

# New recorder channels carry `EntityFrame`s and are shifted structurally,
# irrespective of their name. This allowlist exists only for old recordings
# whose per-agent data was positional and therefore cannot prove its identity.
const _CROSSSHIFT_LEGACY_POSITIONAL_CHANNELS = (
    :poses,
    :rate,
    :rates,
    :spikes,
    :effectors,
    :percepts,
    :sensors,
    :spectral_radius,
    :needs,
    :feedback,
    :body_alive,
    :fields,
    :receptors,
    :components,
    :conspecific_contacts,
    :acts,
    :targets,
    :soma,
    :V,
)
const _CROSSSHIFT_DROP_CHANNELS = (:polarization, :milling, :interactions, :deaths)
const _CROSSSHIFT_PASSTHROUGH_CHANNELS = (:objects,)

function _crossshift_config_ids(sim::SimResult)
    config = sim.config
    if hasproperty(config, :agents)
        agents = getproperty(config, :agents)
        if !isempty(agents)
            all(agent -> hasproperty(agent, :id), agents) || throw(ArgumentError(
                "crossshift_null requires every sim.config.agents entry to carry an :id",
            ))
            ids = EntityID[_entity_id(agent.id) for agent in agents]
            allunique(ids) || throw(ArgumentError("sim.config.agents contains duplicate entity IDs"))
            return ids
        end
    end
    if hasproperty(config, :entity_ids)
        raw_ids = getproperty(config, :entity_ids)
        if raw_ids !== nothing && !isempty(raw_ids)
            ids = EntityID[_entity_id(id) for id in raw_ids]
            allunique(ids) || throw(ArgumentError("sim.config.entity_ids contains duplicate entity IDs"))
            return ids
        end
    end
    return nothing
end

function _crossshift_context(sim::SimResult; strict::Bool=true)
    nonempty = Pair{Symbol,Any}[
        channel => raw for (channel, raw) in sim.recorder.channels if !isempty(raw)
    ]
    isempty(nonempty) && throw(ArgumentError("crossshift_null needs recorded samples"))
    n_ticks = length(last(first(nonempty)))
    n_ticks >= 2 || throw(ArgumentError("crossshift_null needs at least two recorded ticks"))
    for (channel, raw) in nonempty
        length(raw) == n_ticks || throw(DimensionMismatch(
            "crossshift_null channel :$(channel) has $(length(raw)) ticks; expected $(n_ticks)",
        ))
    end

    config_ids = _crossshift_config_ids(sim)
    first_frame = nothing
    for (_, raw) in nonempty, entry in raw
        if entry isa EntityFrame
            first_frame = entry
            break
        end
    end
    ids = if config_ids !== nothing
        config_ids
    elseif first_frame !== nothing
        copy(first_frame.ids)
    elseif hasproperty(sim.config, :n_agents) && sim.config.n_agents !== nothing
        EntityID.(1:Int(sim.config.n_agents))
    else
        candidate = findfirst(pair -> first(pair) in _CROSSSHIFT_LEGACY_POSITIONAL_CHANNELS, nonempty)
        candidate === nothing && throw(ArgumentError(
            "crossshift_null cannot infer entity identity; record EntityFrame channels or provide sim.config.agents",
        ))
        first_entry = first(last(nonempty[candidate]))
        first_entry isa AbstractVector || throw(ArgumentError(
            "legacy cross-shift channel :$(first(nonempty[candidate])) must contain positional vectors",
        ))
        EntityID.(1:length(first_entry))
    end
    n_agents = length(ids)
    n_agents >= 2 || throw(ArgumentError("crossshift_null requires at least two agents"))
    allunique(ids) || throw(ArgumentError("crossshift_null entity IDs must be unique"))

    if hasproperty(sim.config, :n_agents) && sim.config.n_agents !== nothing
        Int(sim.config.n_agents) == n_agents || throw(DimensionMismatch(
            "sim.config.n_agents=$(sim.config.n_agents) but recorder/config identity has $(n_agents) agents",
        ))
    end
    if hasproperty(sim.config, :ticks) && sim.config.ticks isa Integer &&
            hasproperty(sim.config, :every) && sim.config.every isa Integer
        expected_ticks = cld(Int(sim.config.ticks), Int(sim.config.every))
        expected_ticks == n_ticks || throw(DimensionMismatch(
            "sim.config describes $(expected_ticks) recorded ticks but recorder channels contain $(n_ticks)",
        ))
    end

    expected_ids = Set(ids)
    for (channel, raw) in nonempty
        frame_flags = map(entry -> entry isa EntityFrame, raw)
        if any(frame_flags)
            all(frame_flags) || throw(ArgumentError(
                "crossshift_null channel :$(channel) mixes EntityFrame and positional samples",
            ))
            for (tick, frame) in enumerate(raw)
                length(frame) == n_agents || throw(DimensionMismatch(
                    "crossshift_null channel :$(channel) tick $(tick) has $(length(frame)) agents; expected $(n_agents)",
                ))
                Set(frame.ids) == expected_ids || throw(ArgumentError(
                    "crossshift_null channel :$(channel) tick $(tick) has IDs $(frame.ids); expected $(ids)",
                ))
            end
        elseif channel in _CROSSSHIFT_LEGACY_POSITIONAL_CHANNELS
            for (tick, entry) in enumerate(raw)
                entry isa AbstractVector || throw(ArgumentError(
                    "legacy cross-shift channel :$(channel) tick $(tick) must be a positional vector",
                ))
                length(entry) == n_agents || throw(DimensionMismatch(
                    "legacy cross-shift channel :$(channel) tick $(tick) has $(length(entry)) agents; expected $(n_agents)",
                ))
            end
        elseif !(channel in _CROSSSHIFT_DROP_CHANNELS) &&
                !(channel in _CROSSSHIFT_PASSTHROUGH_CHANNELS) && strict
            throw(ArgumentError(
                "crossshift_null does not know how to treat non-EntityFrame channel :$(channel); " *
                "record it as EntityFrame, remove it, or call with strict=false",
            ))
        end
    end
    return (ids=ids, n_agents=n_agents, n_ticks=n_ticks)
end

function _crossshift_shift_map(ids, shifts, n_ticks::Integer)
    length(shifts) == length(ids) || throw(DimensionMismatch(
        "crossshift_null received $(length(shifts)) shifts for $(length(ids)) entities",
    ))
    length(shifts) >= 2 && all(==(first(shifts)), shifts) && throw(ArgumentError(
        "crossshift_null requires at least two distinct entity shifts; " *
        "a shared circular shift preserves cross-agent timing",
    ))
    out = Dict{EntityID,Int}()
    for (id, shift) in zip(ids, shifts)
        shift_ = Int(shift)
        0 <= shift_ < n_ticks || throw(ArgumentError(
            "crossshift_null shifts must lie in 0:$(n_ticks - 1); got $(shift_) for $(id)",
        ))
        out[id] = shift_
    end
    return out
end

function _crossshift_draw_shifts(rng::AbstractRNG, n_agents::Integer, n_ticks::Integer)
    shifts = zeros(Int, Int(n_agents))
    # A common offset has no effect on cross-agent alignment, so hold the first
    # entity at zero and draw relative offsets for the remainder. Condition out
    # the all-zero vector, which would reproduce the original sample exactly.
    while all(iszero, shifts)
        @inbounds for agent in 2:Int(n_agents)
            shifts[agent] = rand(rng, 0:(Int(n_ticks) - 1))
        end
    end
    return shifts
end

function _crossshift_entity_channel(raw::AbstractVector, shifts, n_ticks::Integer)
    shifted = Vector{Any}(undef, n_ticks)
    @inbounds for tick in 1:n_ticks
        target = raw[tick]
        values = [
            entity_value(raw[mod1(tick - shifts[id], n_ticks)], id)
            for id in target.ids
        ]
        shifted[tick] = EntityFrame(copy(target.ids), values)
    end
    return shifted
end

function _crossshift_positional_channel(raw::AbstractVector, shifts::AbstractVector{<:Integer}, n_agents::Integer)
    n_ticks = length(raw)
    shifted = Vector{Any}(undef, n_ticks)
    @inbounds for tick in 1:n_ticks
        entry = Vector{Any}(undef, n_agents)
        for agent in 1:n_agents
            source_tick = mod1(tick - Int(shifts[agent]), n_ticks)
            entry[agent] = raw[source_tick][agent]
        end
        shifted[tick] = entry
    end
    return shifted
end

function _crossshift_surrogate(
    sim::SimResult,
    shifts::AbstractVector{<:Integer},
    n_agents::Integer;
    strict::Bool=true,
)
    context = _crossshift_context(sim; strict=strict)
    context.n_agents == Int(n_agents) || throw(DimensionMismatch(
        "crossshift_null was given n_agents=$(n_agents), but the simulation contains $(context.n_agents)",
    ))
    shift_map = _crossshift_shift_map(context.ids, shifts, context.n_ticks)
    shifted_channels = Dict{Symbol,Vector{Any}}()
    for (channel, raw) in sim.recorder.channels
        isempty(raw) && continue
        if channel in _CROSSSHIFT_DROP_CHANNELS
            continue
        elseif channel in _CROSSSHIFT_PASSTHROUGH_CHANNELS
            shifted_channels[channel] = copy(raw)
        elseif all(entry -> entry isa EntityFrame, raw)
            shifted_channels[channel] = _crossshift_entity_channel(raw, shift_map, context.n_ticks)
        elseif channel in _CROSSSHIFT_LEGACY_POSITIONAL_CHANNELS
            shifted_channels[channel] = _crossshift_positional_channel(raw, shifts, context.n_agents)
        else
            strict && throw(ArgumentError(
                "crossshift_null does not know how to treat non-EntityFrame channel :$(channel)",
            ))
            @warn "crossshift_null is passing through an unknown non-EntityFrame channel because strict=false" channel
            shifted_channels[channel] = copy(raw)
        end
    end

    rec = Recorder(enabled=collect(keys(shifted_channels)), every=sim.recorder.every)
    rec.channels = shifted_channels
    rec.tick = sim.recorder.tick
    return SimResult(rec, NamedTuple(), sim.task, sim.node, sim.config)
end

function _crossshift_pvalue(real_value::Real, values, alternative::Symbol)
    finite_values = filter(isfinite, Float64.(values))
    (!isfinite(real_value) || isempty(finite_values)) && return NaN
    n = length(finite_values)
    greater = (1 + count(value -> value >= real_value, finite_values)) / (n + 1)
    less = (1 + count(value -> value <= real_value, finite_values)) / (n + 1)
    alternative === :greater && return greater
    alternative === :less && return less
    alternative === :two_sided && return min(1.0, 2.0 * min(greater, less))
    throw(ArgumentError("crossshift_null alternative must be :greater, :less, or :two_sided"))
end

"""
    crossshift_null(sim, measure_fn; n_shifts, rng, threaded=true,
                    strict=true, alternative=:greater)

Compute a circular-shift null test for a cross-agent measure. Each surrogate
independently circular-shifts every agent's recorded time series, preserving
single-agent dynamics while destroying inter-agent timing. Entity-owned channels
are aligned and shifted by stable `EntityID`; derived ensemble and event channels
are removed. In addition to the historical summary fields, the result includes
the sampled null values, effective sample count, requested count, alternative,
and a finite-sample Monte Carlo p-value.
"""
function crossshift_null(
    sim::SimResult,
    measure_fn;
    n_shifts::Integer,
    rng::AbstractRNG,
    threaded::Bool=true,
    strict::Bool=true,
    alternative::Symbol=:greater,
)
    n = Int(n_shifts)
    n >= 1 || throw(ArgumentError("crossshift_null needs n_shifts >= 1"))
    alternative in (:greater, :less, :two_sided) || throw(ArgumentError(
        "crossshift_null alternative must be :greater, :less, or :two_sided",
    ))
    context = _crossshift_context(sim; strict=strict)

    real_value = _crossshift_measure_value(measure_fn(sim))

    # Draw every surrogate's shifts up front from the caller's rng (same draw
    # order as the historical serial loop), so the null is deterministic in the
    # seed while the expensive measure recomputations fan out across threads.
    # Surrogates only read `sim`, so concurrent draws are safe.
    shift_draws = Vector{Vector{Int}}(undef, n)
    for draw in 1:n
        shift_draws[draw] = _crossshift_draw_shifts(
            rng,
            context.n_agents,
            context.n_ticks,
        )
    end
    null_values = Float64[
        Float64(v) for v in parallel_map(shift_draws; threaded=threaded) do shifts
            surrogate = _crossshift_surrogate(
                sim,
                shifts,
                context.n_agents;
                strict=strict,
            )
            _crossshift_measure_value(measure_fn(surrogate))
        end
    ]

    null_mean = _analysis_finite_mean(null_values)
    null_std = _analysis_finite_std(null_values)
    ratio = isfinite(real_value) && isfinite(null_mean) && null_mean != 0.0 ? real_value / null_mean : NaN
    n_valid = count(isfinite, null_values)
    pvalue = _crossshift_pvalue(real_value, null_values, alternative)
    return (
        real=real_value,
        null_mean=null_mean,
        null_std=null_std,
        ratio=ratio,
        null_values=null_values,
        n_valid=n_valid,
        n_requested=n,
        alternative=alternative,
        pvalue=pvalue,
    )
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
