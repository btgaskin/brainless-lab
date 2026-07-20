using Random

"""
    SensorResponse(; tau=0, dt=1, shared_sigma=0, independent_sigma=0,
                     minimum=0, maximum=1)

First-order sensor response followed by separate shared and independent Gaussian
noise. Noise never feeds back into the lag state.
"""
struct SensorResponse
    tau::Float64
    dt::Float64
    shared_sigma::Float64
    independent_sigma::Float64
    minimum::Float64
    maximum::Float64

    function SensorResponse(
        tau::Real,
        dt::Real,
        shared_sigma::Real,
        independent_sigma::Real,
        minimum::Real,
        maximum::Real,
    )
        tau_, dt_ = Float64(tau), Float64(dt)
        shared_, independent_ = Float64(shared_sigma), Float64(independent_sigma)
        lo, hi = Float64(minimum), Float64(maximum)
        all(isfinite, (tau_, dt_, shared_, independent_)) &&
            (isfinite(lo) || lo == -Inf) &&
            (isfinite(hi) || hi == Inf) ||
            throw(ArgumentError("sensor-response parameters must be finite except for open bounds"))
        tau_ >= 0.0 || throw(ArgumentError("sensor-response tau must be non-negative"))
        dt_ > 0.0 || throw(ArgumentError("sensor-response dt must be positive"))
        shared_ >= 0.0 && independent_ >= 0.0 ||
            throw(ArgumentError("sensor-response noise scales must be non-negative"))
        lo < hi || throw(ArgumentError("sensor-response minimum must be below maximum"))
        return new(tau_, dt_, shared_, independent_, lo, hi)
    end
end

SensorResponse(; tau=0.0, dt=1.0, shared_sigma=0.0, independent_sigma=0.0,
                 minimum=0.0, maximum=1.0) =
    SensorResponse(tau, dt, shared_sigma, independent_sigma, minimum, maximum)

@inline response_alpha(response::SensorResponse) =
    response.tau == 0.0 ? 1.0 : -expm1(-response.dt / response.tau)

"""Mutable lag and independently seeded noise state for one sensor bank."""
mutable struct SensorResponseState{SR<:AbstractRNG,IR<:AbstractRNG}
    values::Vector{Float64}
    initial::Vector{Float64}
    output::Vector{Float64}
    shared_buffer::Vector{Float64}
    shared_rng::SR
    independent_rng::IR
    shared_seed::Union{Nothing,Int}
    independent_seed::Union{Nothing,Int}
end

function SensorResponseState(
    width::Integer;
    initial=0.0,
    shared_seed=0,
    independent_seed=1,
)
    width_ = Int(width)
    width_ >= 1 || throw(ArgumentError("sensor-response state width must be positive"))
    initial_ = if initial isa Real
        fill(Float64(initial), width_)
    else
        values = Float64.(vec(collect(initial)))
        length(values) == width_ || throw(DimensionMismatch(
            "sensor-response initial state has $(length(values)) values; expected $(width_)",
        ))
        values
    end
    all(isfinite, initial_) ||
        throw(ArgumentError("sensor-response initial state must be finite"))
    shared_seed_ = shared_seed === nothing ? nothing : Int(shared_seed)
    independent_seed_ = independent_seed === nothing ? nothing : Int(independent_seed)
    shared_rng = shared_seed_ === nothing ? MersenneTwister() : MersenneTwister(shared_seed_)
    independent_rng = independent_seed_ === nothing ? MersenneTwister() : MersenneTwister(independent_seed_)
    return SensorResponseState{typeof(shared_rng),typeof(independent_rng)}(
        copy(initial_), copy(initial_), copy(initial_), zeros(Float64, width_),
        shared_rng, independent_rng, shared_seed_, independent_seed_,
    )
end

function reset!(state::SensorResponseState)
    copyto!(state.values, state.initial)
    copyto!(state.output, state.initial)
    fill!(state.shared_buffer, 0.0)
    state.shared_seed === nothing || Random.seed!(state.shared_rng, state.shared_seed)
    state.independent_seed === nothing || Random.seed!(state.independent_rng, state.independent_seed)
    return state
end

function _response_groups(groups, width::Int)
    if groups === nothing
        return fill(1, width)
    end
    values = Int.(vec(collect(groups)))
    length(values) == width || throw(DimensionMismatch(
        "sensor-response groups have $(length(values)) entries; expected $(width)",
    ))
    all(>(0), values) || throw(ArgumentError("sensor-response group IDs must be positive"))
    return values
end

"""
    respond!(state, response, samples; groups=nothing)

Advance lag state and return the state's reusable noisy output buffer. Channels
with the same positive group ID receive the same shared-noise draw.
"""
function respond!(
    state::SensorResponseState,
    response::SensorResponse,
    samples;
    groups=nothing,
)
    input = samples isa Vector{Float64} ? samples : Float64.(vec(collect(samples)))
    width = length(state.values)
    length(input) == width || throw(DimensionMismatch(
        "sensor response received $(length(input)) samples; expected $(width)",
    ))
    all(isfinite, input) || throw(ArgumentError("sensor samples must be finite"))
    group_ids = _response_groups(groups, width)
    max_group = maximum(group_ids)
    max_group <= length(state.shared_buffer) || resize!(state.shared_buffer, max_group)

    alpha = response_alpha(response)
    @inbounds for i in 1:width
        state.values[i] += alpha * (input[i] - state.values[i])
    end
    if response.shared_sigma == 0.0
        fill!(@view(state.shared_buffer[1:max_group]), 0.0)
    else
        @inbounds for group in 1:max_group
            state.shared_buffer[group] = response.shared_sigma * randn(state.shared_rng)
        end
    end
    @inbounds for i in 1:width
        independent = response.independent_sigma == 0.0 ? 0.0 :
            response.independent_sigma * randn(state.independent_rng)
        state.output[i] = clamp(
            state.values[i] + state.shared_buffer[group_ids[i]] + independent,
            response.minimum,
            response.maximum,
        )
    end
    return state.output
end

"""Two explicitly mounted scalar-field probes, ordered `(left, right)`."""
struct BilateralFieldProbe
    mounts::NTuple{2,Mount2D}
    response::SensorResponse
end

function BilateralFieldProbe(
    left::Mount2D,
    right::Mount2D;
    response::SensorResponse=SensorResponse(),
)
    return BilateralFieldProbe((left, right), response)
end

function BilateralFieldProbe(;
    baseline::Real=1.0,
    forward_offset::Real=0.0,
    yaw::Real=0.0,
    response::SensorResponse=SensorResponse(),
)
    baseline_ = Float64(baseline)
    isfinite(baseline_) && baseline_ >= 0.0 ||
        throw(ArgumentError("bilateral baseline must be finite and non-negative"))
    forward_ = Float64(forward_offset)
    yaw_ = Float64(yaw)
    all(isfinite, (forward_, yaw_)) ||
        throw(ArgumentError("bilateral probe placement must be finite"))
    left = Mount2D(forward_, baseline_ / 2.0, yaw_)
    right = Mount2D(forward_, -baseline_ / 2.0, yaw_)
    return BilateralFieldProbe(left, right; response=response)
end

function _field_tuple(fields::NamedTuple)
    return Tuple(values(fields))
end

_field_tuple(fields::Tuple) = fields

"""
    sample_bilateral_fields!(output, probe, fields, position, heading, tick, arena)

Sample scalar fields in channel-major, mount-minor order:
`[channel1_left, channel1_right, channel2_left, channel2_right, ...]`.
"""
function sample_bilateral_fields!(
    output::AbstractVector{Float64},
    probe::BilateralFieldProbe,
    fields::Union{NamedTuple,Tuple},
    position,
    heading::Real,
    tick::Integer,
    arena::Union{Torus,WalledArena},
)
    field_values = _field_tuple(fields)
    all(field -> field isa AbstractSpatialField, field_values) ||
        throw(ArgumentError("bilateral probes can sample only AbstractSpatialField values"))
    length(output) == 2 * length(field_values) || throw(DimensionMismatch(
        "bilateral output has width $(length(output)); expected $(2 * length(field_values))",
    ))
    poses = (
        mounted_pose(position, heading, probe.mounts[1], arena),
        mounted_pose(position, heading, probe.mounts[2], arena),
    )
    @inbounds for channel in eachindex(field_values)
        field = field_values[channel]
        output[2channel - 1] = _checked_field_value(field, poses[1].position, tick, arena)
        output[2channel] = _checked_field_value(field, poses[2].position, tick, arena)
    end
    return output
end

function sample_bilateral_fields(
    probe::BilateralFieldProbe,
    fields::Union{NamedTuple,Tuple},
    position,
    heading::Real,
    tick::Integer,
    arena::Union{Torus,WalledArena},
)
    output = Vector{Float64}(undef, 2 * length(fields))
    return sample_bilateral_fields!(output, probe, fields, position, heading, tick, arena)
end

bilateral_noise_groups(n_channels::Integer) =
    reduce(vcat, ([channel, channel] for channel in 1:Int(n_channels)); init=Int[])

function respond_bilateral_fields!(
    state::SensorResponseState,
    probe::BilateralFieldProbe,
    raw,
)
    length(raw) % 2 == 0 || throw(DimensionMismatch("bilateral samples must contain left/right pairs"))
    return respond!(
        state,
        probe.response,
        raw;
        groups=bilateral_noise_groups(length(raw) ÷ 2),
    )
end

abstract type AbstractBilateralEncoder <: AbstractEncoder end
struct RawBilateralEncoder <: AbstractBilateralEncoder end
struct CommonModeEncoder <: AbstractBilateralEncoder end

struct UnitContrastEncoder <: AbstractBilateralEncoder
    epsilon::Float64

    function UnitContrastEncoder(epsilon::Real=sqrt(eps(Float64)))
        epsilon_ = Float64(epsilon)
        isfinite(epsilon_) && epsilon_ > 0.0 ||
            throw(ArgumentError("bilateral contrast epsilon must be finite and positive"))
        return new(epsilon_)
    end
end

function _paired_samples(samples)
    values = samples isa Vector{Float64} ? samples : Float64.(vec(collect(samples)))
    iseven(length(values)) || throw(DimensionMismatch("bilateral encoding needs left/right pairs"))
    all(isfinite, values) || throw(ArgumentError("bilateral samples must be finite"))
    return values
end

encode_bilateral(::RawBilateralEncoder, samples) = copy(_paired_samples(samples))
encode!(encoder::RawBilateralEncoder, samples) = encode_bilateral(encoder, samples)

function encode_bilateral(::CommonModeEncoder, samples)
    values = _paired_samples(samples)
    output = Vector{Float64}(undef, length(values) ÷ 2)
    @inbounds for channel in eachindex(output)
        output[channel] = (values[2channel - 1] + values[2channel]) / 2.0
    end
    return output
end
encode!(encoder::CommonModeEncoder, samples) = encode_bilateral(encoder, samples)

"""
Unit-normalized right-minus-left contrast. Equal inputs map to `0.5`, maximal
left dominance to `0`, and maximal right dominance to `1`.
"""
function encode_bilateral(encoder::UnitContrastEncoder, samples)
    values = _paired_samples(samples)
    output = Vector{Float64}(undef, length(values) ÷ 2)
    @inbounds for channel in eachindex(output)
        left = values[2channel - 1]
        right = values[2channel]
        denominator = abs(left) + abs(right) + encoder.epsilon
        output[channel] = clamp(0.5 + 0.5 * (right - left) / denominator, 0.0, 1.0)
    end
    return output
end
encode!(encoder::UnitContrastEncoder, samples) = encode_bilateral(encoder, samples)
