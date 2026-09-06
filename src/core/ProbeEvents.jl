"""One sparse observation of emitted node activity, with stable entity IDs.

`features` owns a copy. Labels are diagnostic metadata and are not fed back to
the reservoir. The response observation is the mean over the response window.
"""
struct ProbeEvent{F,M}
    task::Symbol
    point::Symbol
    tick::Int
    round::Int
    label::Int
    channel::Symbol
    features::F
    metadata::M
end

_probe_record_context(::Environment) = nothing
function _probe_record_context(env::CapacityProbeEnv)
    round = min(env.round, length(env.responses))
    round > 1 && env.tick == last(env.responses[round - 1]) && (round -= 1)
    return (task=_probe_name(env), tick=env.tick, round, cue_end=env.cue_ends[round],
        response=env.responses[round], label=env.labels[round], metadata=env.metadata)
end
function _probe_record_context(env::DelayedCueEnv)
    return (task=:delayed_cue, tick=env.tick, round=1, cue_end=env.cue_ticks,
        response=env.cue_ticks + env.delay + 1:env.cue_ticks + env.delay + env.response_ticks,
        label=env.cue, metadata=(delay=env.delay, cue_mode=env.cue_mode))
end

function _record_probe_events!(rec, ensemble, spikes)
    context = _probe_record_context(ensemble.environment)
    context === nothing && throw(ArgumentError(":probe_events requires a capacity probe task"))
    rec.every == 1 || throw(ArgumentError(":probe_events requires record_every=1"))
    return _record_probe_events!(rec, ensemble, spikes, context)
end

function _record_probe_events!(rec, ensemble, spikes, context)
    t = context.tick
    for (point, at) in ((:cue_end, context.cue_end), (:delay_end, first(context.response) - 1))
        if t == at
            features = _entity_frame(ensemble, [collect(Float64, s) for s in spikes])
            record!(rec, :probe_events, ProbeEvent(context.task, point, t, context.round,
                context.label, :emitted_activity, features, context.metadata))
        end
    end
    if t in context.response
        sums = if t == first(context.response)
            values = [collect(Float64, s) for s in spikes]
            rec.cache[:probe_response_sum] = values
            values
        else
            _accumulate_probe_features!(rec.cache[:probe_response_sum], spikes)
        end
        if t == last(context.response)
            features = _entity_frame(ensemble, [s ./ length(context.response) for s in sums])
            record!(rec, :probe_events, ProbeEvent(context.task, :response, t, context.round,
                context.label, :emitted_activity, features, context.metadata))
            delete!(rec.cache, :probe_response_sum)
        end
    end
    return rec
end

function _accumulate_probe_features!(sums, spikes)
    for i in eachindex(sums, spikes)
        sums[i] .+= spikes[i]
    end
    return sums
end
