"""
    SectorVision(source; channels=16, field_of_view=deg2rad(300),
                 max_range=6, mode=:veridical, sham_seed=0)

Experimental egocentric sector vision for circular objects or conspecifics.
Each target contributes to the sector containing its centre bearing. The
nearest target in a sector determines its activation, which falls linearly
with surface distance and is zero beyond `max_range`.

`mode=:blind` retains the receptor layout while returning zeros.
`mode=:bearing_sham` circularly shifts every observation by a deterministic,
non-zero offset derived from the sensor seed, entity identity, and world tick.
It therefore preserves the instantaneous value multiset while breaking the
alignment between body heading and perceived bearing.
"""
struct SectorVision{S<:SensorySource} <: AbstractSensor
    source::S
    channels::Int
    field_of_view::Float64
    max_range::Float64
    mode::Symbol
    sham_seed::Int

    function SectorVision(
        source::S,
        channels::Integer,
        field_of_view::Real,
        max_range::Real,
        mode::Symbol,
        sham_seed::Integer,
    ) where {S<:SensorySource}
        channels_ = Int(channels)
        fov_ = Float64(field_of_view)
        range_ = Float64(max_range)
        channels_ >= 1 || throw(ArgumentError("sector vision needs at least one channel"))
        isfinite(fov_) && 0.0 < fov_ <= 2pi || throw(ArgumentError(
            "sector-vision field_of_view must lie in (0, 2pi]",
        ))
        isfinite(range_) && range_ > 0.0 || throw(ArgumentError(
            "sector-vision max_range must be finite and positive",
        ))
        mode in (:veridical, :blind, :bearing_sham) || throw(ArgumentError(
            "sector-vision mode must be :veridical, :blind, or :bearing_sham",
        ))
        mode === :bearing_sham && channels_ < 2 && throw(ArgumentError(
            "bearing sham requires at least two sector channels",
        ))
        return new{S}(source, channels_, fov_, range_, mode, Int(sham_seed))
    end
end

SectorVision(
    source::SensorySource;
    channels::Integer=16,
    field_of_view::Real=deg2rad(300.0),
    max_range::Real=6.0,
    mode::Symbol=:veridical,
    sham_seed::Integer=0,
) = SectorVision(source, channels, field_of_view, max_range, mode, sham_seed)

n_sensors(sensor::SectorVision) = sensor.channels
n_receptors(sensor::SectorVision) = sensor.channels
n_effectors(::SectorVision) = 0

function _sector_centres(sensor::SectorVision)
    width = sensor.field_of_view / sensor.channels
    start = -sensor.field_of_view / 2.0 + width / 2.0
    return ntuple(index -> start + (index - 1) * width, sensor.channels)
end

rawspec(sensor::SectorVision) = (
    kind=:sector_vision,
    width=sensor.channels,
    source=sensor.source,
    field_of_view=sensor.field_of_view,
    max_range=sensor.max_range,
    mode=sensor.mode,
)

function portspec(sensor::SectorVision)
    placements = _sector_centres(sensor)
    receptors = Port{Float64}[
        Port(Symbol(:sector_, index), placements[index])
        for index in 1:sensor.channels
    ]
    return PortSpec(sensor.channels, 0, receptors, Port{NoPlacement}[])
end

ports(sensor::SectorVision) = ports(portspec(sensor))

function encode!(sensor::SectorVision, samples)
    length(samples) == sensor.channels || throw(DimensionMismatch(
        "sector vision expected $(sensor.channels) values, got $(length(samples))",
    ))
    values = samples isa Vector{Float64} ? samples : Float64.(vec(collect(samples)))
    all(value -> isfinite(value) && 0.0 <= value <= 1.0, values) ||
        throw(ArgumentError("sector-vision samples must lie in [0, 1]"))
    return values
end

component_state(::SectorVision) = NamedTuple()
reset!(sensor::SectorVision) = sensor

@inline _signed_angle(angle::Real) = atan(sin(Float64(angle)), cos(Float64(angle)))

function _sector_index(sensor::SectorVision, relative_bearing::Real)
    bearing = _signed_angle(relative_bearing)
    half = sensor.field_of_view / 2.0
    tolerance = 16eps(Float64)
    abs(bearing) <= half + tolerance || return nothing
    width = sensor.field_of_view / sensor.channels
    return clamp(floor(Int, (bearing + half) / width) + 1, 1, sensor.channels)
end

@inline function _sector_activation(surface_distance::Real, max_range::Real)
    distance = max(0.0, Float64(surface_distance))
    range_ = Float64(max_range)
    distance <= range_ || return 0.0
    return clamp(1.0 - distance / range_, 0.0, 1.0)
end

function _sector_sham_shift(sensor::SectorVision, entity_value::UInt64, tick::Integer)
    sensor.channels >= 2 || return 0
    value = UInt64(0xcbf29ce484222325)
    for byte in codeunits(string(sensor.sham_seed, ':', entity_value, ':', Int(tick)))
        value = xor(value, UInt64(byte)) * UInt64(0x00000100000001b3)
    end
    return Int(mod(value, UInt64(sensor.channels - 1))) + 1
end

function _apply_sector_mode!(
    values::Vector{Float64},
    sensor::SectorVision,
    entity_value::UInt64,
    tick::Integer,
)
    if sensor.mode === :blind
        fill!(values, 0.0)
    elseif sensor.mode === :bearing_sham
        shift = _sector_sham_shift(sensor, entity_value, tick)
        copyto!(values, circshift(copy(values), shift))
    end
    return values
end

"""Public extension boundary for cross-entity effects owned by an `ObjectWorld`."""
abstract type AbstractWorldRelation end

"""
    ProximityExposure(name; radius=2, amount=0.004, target_neighbors=2)

Restore a regulated variable according to nearby active conspecifics. Each
neighbor contributes a linear weight from one at contact to zero at `radius`;
the total is normalized by `target_neighbors` and capped at one. This relation
is deliberately independent of what an agent can see.
"""
struct ProximityExposure <: AbstractWorldRelation
    name::Symbol
    radius::Float64
    amount::Float64
    target_neighbors::Float64

    function ProximityExposure(
        name::Symbol,
        radius::Real,
        amount::Real,
        target_neighbors::Real,
    )
        radius_, amount_, target_ = Float64(radius), Float64(amount), Float64(target_neighbors)
        all(isfinite, (radius_, amount_, target_)) && radius_ > 0.0 &&
            amount_ >= 0.0 && target_ > 0.0 || throw(ArgumentError(
                "proximity exposure requires positive finite radius/target and non-negative amount",
            ))
        return new(Symbol(name), radius_, amount_, target_)
    end
end

ProximityExposure(
    name::Union{Symbol,AbstractString};
    radius::Real=2.0,
    amount::Real=0.004,
    target_neighbors::Real=2.0,
) = ProximityExposure(Symbol(name), radius, amount, target_neighbors)
