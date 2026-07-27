"""
    Recorder(; enabled=Symbol[], every=1, compute_every=Dict{Symbol,Int}())

Lightweight channel recorder for off-hot-path diagnostics and visualization.

Only enabled channels are stored. Samples are retained once every `every` ticks.
Call `tick!` to advance the internal counter. A channel takes the concrete type
of its first sample and widens only if a later sample has a different type, so
analysis function barriers can specialise on the stored channel element type.

`compute_every` declares per-channel *compute* strides for channels whose
payload is expensive to produce (e.g. `:spectral_radius`, a dense
eigendecomposition per agent): producers consult [`compute_stride`](@ref) and
may recompute only every K ticks, re-recording the cached last value in
between via `cache` so the stored series keeps one sample per recorded tick.
"""
mutable struct Recorder
    channels::Dict{Symbol,Vector}
    enabled::Set{Symbol}
    every::Int
    tick::Int
    compute_every::Dict{Symbol,Int}
    cache::Dict{Symbol,Any}

    function Recorder(; enabled=Symbol[], every::Integer=1, compute_every=Dict{Symbol,Int}())
        every >= 1 || throw(ArgumentError("Recorder `every` must be >= 1."))
        strides = Dict{Symbol,Int}(Symbol(k) => Int(v) for (k, v) in compute_every)
        all(v -> v >= 1, values(strides)) ||
            throw(ArgumentError("Recorder `compute_every` strides must be >= 1."))
        return new(Dict{Symbol,Vector}(), Set{Symbol}(enabled), Int(every), 0, strides, Dict{Symbol,Any}())
    end
end

function _append_sample!(
    channels::Dict{Symbol,Vector},
    channel::Symbol,
    samples::Vector{T},
    value::T,
) where {T}
    push!(samples, value)
    return samples
end

function _append_sample!(
    channels::Dict{Symbol,Vector},
    channel::Symbol,
    samples::Vector{T},
    value,
) where {T}
    U = Union{T,typeof(value)}
    widened = Vector{U}(undef, length(samples) + 1)
    copyto!(widened, samples)
    widened[end] = value
    channels[channel] = widened
    return widened
end

function _append_sample!(channels::Dict{Symbol,Vector}, channel::Symbol, value)
    samples = get(channels, channel, nothing)
    if samples === nothing
        channels[channel] = [value]
    else
        _append_sample!(channels, channel, samples, value)
    end
    return channels
end

"""
    compute_stride(rec, channel)

Return the declared compute stride for `channel` (1 when unset): producers of
expensive payloads may recompute only when `rem(rec.tick, stride) == 0` and
reuse `rec.cache[channel]` on intermediate ticks.
"""
compute_stride(rec::Recorder, channel::Symbol) = max(get(rec.compute_every, channel, 1), 1)

"""
    record!(rec, channel, value)

Store `value` in `channel` when the channel is enabled and the current tick is
on the recorder stride. Returns `rec`.
"""
function record!(rec::Recorder, channel::Symbol, value)
    if channel in rec.enabled && rem(rec.tick, rec.every) == 0
        _append_sample!(rec.channels, channel, value)
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
    empty!(rec.cache)
    rec.tick = 0
    return rec
end
