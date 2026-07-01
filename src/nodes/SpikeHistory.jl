mutable struct SpikeHistory
    buffer::Matrix{Float64}
    head::Int
    maxdelay::Int
end

SpikeHistory(N::Integer, maxdelay::Integer) =
    SpikeHistory(zeros(Float64, max(1, Int(maxdelay)), Int(N)), 0, max(1, Int(maxdelay)))

function push_spikes!(h::SpikeHistory, spikes::AbstractVector{<:Real})
    n = size(h.buffer, 2)
    length(spikes) == n ||
        throw(DimensionMismatch("spike history width $n does not match spike length $(length(spikes))"))

    h.head = mod1(h.head + 1, h.maxdelay)
    @inbounds for i in 1:n
        h.buffer[h.head, i] = Float64(spikes[i])
    end
    return h
end

@inline function _delayed_spike(h::SpikeHistory, i::Int, d::Int)
    h.head == 0 && return 0.0
    row = mod1(h.head - d + 1, h.maxdelay)
    return h.buffer[row, i]
end

function delayed_spike(h::SpikeHistory, i::Integer, d::Integer)
    i_ = Int(i)
    d_ = Int(d)
    d_ >= 1 || throw(ArgumentError("delay must be at least 1"))
    1 <= i_ <= size(h.buffer, 2) ||
        throw(BoundsError(h.buffer, (max(h.head, 1), i_)))
    d_ <= h.maxdelay ||
        throw(BoundsError(h.buffer, (h.head - d_ + 1, i_)))
    return _delayed_spike(h, i_, d_)
end

function reset_history!(h::SpikeHistory)
    fill!(h.buffer, 0.0)
    h.head = 0
    return h
end
