"""
    Recorder(; enabled=Symbol[], every=1)

Lightweight channel recorder for off-hot-path diagnostics and visualization.

Only enabled channels are stored. Samples are retained once every `every` ticks.
Call `tick!` to advance the internal counter.
"""
mutable struct Recorder
    channels::Dict{Symbol,Vector{Any}}
    enabled::Set{Symbol}
    every::Int
    tick::Int

    function Recorder(; enabled=Symbol[], every::Integer=1)
        every >= 1 || throw(ArgumentError("Recorder `every` must be >= 1."))
        return new(Dict{Symbol,Vector{Any}}(), Set{Symbol}(enabled), Int(every), 0)
    end
end

"""
    record!(rec, channel, value)

Store `value` in `channel` when the channel is enabled and the current tick is
on the recorder stride. Returns `rec`.
"""
function record!(rec::Recorder, channel::Symbol, value)
    if channel in rec.enabled && rem(rec.tick, rec.every) == 0
        push!(get!(rec.channels, channel, Any[]), value)
    end
    return rec
end

"""
    tick!(rec)

Advance the recorder tick counter. Returns `rec`.
"""
function tick!(rec::Recorder)
    rec.tick += 1
    return rec
end

"""
    getchannel(rec, channel)

Return stored samples for `channel`, or an empty vector if the channel is absent.
"""
getchannel(rec::Recorder, channel::Symbol)::Vector = get(rec.channels, channel, Any[])

Base.haskey(rec::Recorder, channel::Symbol) = haskey(rec.channels, channel)

"""
    reset!(rec)

Clear all recorded samples and reset the internal tick counter. Enabled channels
and stride are preserved.
"""
function reset!(rec::Recorder)
    empty!(rec.channels)
    rec.tick = 0
    return rec
end
