"""
    AbstractSpatialField

Analytic scalar field sampled locally by a body. Implement
`sample_field(field, position, tick, arena)` for custom fields and return a
normalized value in `[0, 1]`.
"""
abstract type AbstractSpatialField end

function sample_field(field::AbstractSpatialField, position, tick::Integer, arena)
    throw(ArgumentError("sample_field is not implemented for $(typeof(field))"))
end

struct ConstantSpatialField <: AbstractSpatialField
    value::Float64

    function ConstantSpatialField(value::Real)
        value_ = Float64(value)
        isfinite(value_) && 0.0 <= value_ <= 1.0 ||
            throw(ArgumentError("constant spatial field must lie in [0, 1]"))
        return new(value_)
    end
end

sample_field(field::ConstantSpatialField, position, tick::Integer, arena) = field.value

"""
    LinearSpatialField(origin, direction; offset=0.5, scale=1)

Normalized planar gradient. `direction` is normalized at construction and
`scale` is the world-distance that changes the field by one unit.
"""
struct LinearSpatialField <: AbstractSpatialField
    origin::NTuple{2,Float64}
    direction::NTuple{2,Float64}
    offset::Float64
    scale::Float64
end

function LinearSpatialField(
    origin,
    direction;
    offset::Real=0.5,
    scale::Real=1.0,
)
    origin_ = (Float64(origin[1]), Float64(origin[2]))
    direction_ = (Float64(direction[1]), Float64(direction[2]))
    all(isfinite, origin_) && all(isfinite, direction_) ||
        throw(ArgumentError("linear spatial field vectors must be finite"))
    norm_ = hypot(direction_[1], direction_[2])
    norm_ > 0.0 || throw(ArgumentError("linear spatial field direction must be non-zero"))
    offset_ = Float64(offset)
    scale_ = Float64(scale)
    isfinite(offset_) || throw(ArgumentError("linear spatial field offset must be finite"))
    isfinite(scale_) && scale_ > 0.0 ||
        throw(ArgumentError("linear spatial field scale must be finite and positive"))
    return LinearSpatialField(
        origin_,
        (direction_[1] / norm_, direction_[2] / norm_),
        offset_,
        scale_,
    )
end

function sample_field(field::LinearSpatialField, position, tick::Integer, arena)
    dx, dy = arena_delta(arena, field.origin, position)
    projection = (dx * field.direction[1] + dy * field.direction[2]) / field.scale
    return clamp(field.offset + projection, 0.0, 1.0)
end

function _checked_field_value(field::AbstractSpatialField, position, tick::Integer, arena)
    value = Float64(sample_field(field, position, tick, arena))
    isfinite(value) || throw(ArgumentError("spatial field returned a non-finite value"))
    0.0 <= value <= 1.0 ||
        throw(ArgumentError("spatial field values must lie in [0, 1], got $(value)"))
    return value
end
