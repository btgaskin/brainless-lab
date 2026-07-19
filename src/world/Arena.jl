using Random

"""
    WalledArena(size)

Square, non-periodic arena. Agent centres are clamped to its interior; unlike a
`Torus`, positions and sight lines do not wrap across an edge.
"""
struct WalledArena
    size::Float64

    function WalledArena(size::Real)
        size_ = Float64(size)
        isfinite(size_) && size_ > 0.0 ||
            throw(ArgumentError("walled arena size must be finite and positive"))
        return new(size_)
    end
end

arena_size(arena::Union{Torus,WalledArena}) = arena.size
arena_bounds(arena::Union{Torus,WalledArena}) = (0.0, arena.size, 0.0, arena.size)
arena_max_distance(arena::Torus) = max_dist(arena)
arena_max_distance(arena::WalledArena) = sqrt(2.0) * arena.size

arena_delta(arena::Torus, a, b) = tdelta(arena, a, b)
arena_distance(arena::Torus, a, b) = tdistance(arena, a, b)
arena_bearing(arena::Torus, a, b) = bearing(arena, a, b)

function arena_delta(::WalledArena, a, b)
    return (Float64(b[1]) - Float64(a[1]), Float64(b[2]) - Float64(a[2]))
end

function arena_distance(arena::WalledArena, a, b)
    dx, dy = arena_delta(arena, a, b)
    return Float64(hypot(dx, dy))
end

function arena_bearing(arena::WalledArena, a, b)
    dx, dy = arena_delta(arena, a, b)
    return Float64(atan(dy, dx))
end

arena_position(arena::Torus, x::Real, y::Real, radius::Real=0.0) =
    (wrap(arena, x, y), false)

function arena_position(arena::WalledArena, x::Real, y::Real, radius::Real=0.0)
    radius_ = max(0.0, Float64(radius))
    radius_ <= arena.size / 2.0 ||
        throw(ArgumentError("radius $(radius_) does not fit in arena of size $(arena.size)"))
    x_ = clamp(Float64(x), radius_, arena.size - radius_)
    y_ = clamp(Float64(y), radius_, arena.size - radius_)
    return ((x_, y_), x_ != Float64(x) || y_ != Float64(y))
end

function sample_position(rng, arena::Union{Torus,WalledArena}; radius::Real=0.0)
    radius_ = arena isa WalledArena ? max(0.0, Float64(radius)) : 0.0
    span = arena.size - 2.0 * radius_
    span >= 0.0 || throw(ArgumentError("radius $(radius_) does not fit in arena"))
    return (radius_ + rand(rng) * span, radius_ + rand(rng) * span)
end

"""An object never respawns after its finite capacity is exhausted."""
struct NoRespawn end

"""Respawn at the object's original position after `delay` complete unavailable ticks."""
struct SamePositionRespawn
    delay::Int

    function SamePositionRespawn(delay::Integer)
        delay_ = Int(delay)
        delay_ >= 0 || throw(ArgumentError("respawn delay must be non-negative"))
        return new(delay_)
    end
end

"""Respawn uniformly after `delay` complete unavailable ticks."""
struct UniformRespawn
    delay::Int

    function UniformRespawn(delay::Integer)
        delay_ = Int(delay)
        delay_ >= 0 || throw(ArgumentError("respawn delay must be non-negative"))
        return new(delay_)
    end
end

"""Public extension boundary for the perceptual appearance of an object type."""
abstract type AbstractObjectAppearance end

"""An object with no optical appearance. It remains available to fields and contact."""
struct NoAppearance <: AbstractObjectAppearance end

"""
    ObjectType(name; bank=name, radius=0.5, effects=(), capacity=nothing,
               respawn=NoRespawn(), appearance=NoAppearance())

Static policy shared by objects of one type. `capacity=nothing` makes contact
persistent; a positive integer makes each instance consumable that many times.
Contact effects are ordinary values interpreted by `expose!(body, effect)`.
Appearance is optional and independent from contact or analytic fields.
"""
struct ObjectType{E<:Tuple,R,A<:AbstractObjectAppearance}
    name::Symbol
    bank::Union{Nothing,Symbol}
    radius::Float64
    effects::E
    capacity::Union{Nothing,Int}
    respawn::R
    appearance::A
end

function ObjectType(
    name::Symbol;
    bank=name,
    radius::Real=0.5,
    effects=(),
    capacity=nothing,
    respawn=NoRespawn(),
    appearance::AbstractObjectAppearance=NoAppearance(),
)
    radius_ = Float64(radius)
    isfinite(radius_) && radius_ >= 0.0 ||
        throw(ArgumentError("object radius must be finite and non-negative"))
    capacity_ = capacity === nothing ? nothing : Int(capacity)
    capacity_ === nothing || capacity_ >= 1 ||
        throw(ArgumentError("finite object capacity must be at least one"))
    effects_ = effects isa Tuple ? effects : Tuple(effects)
    bank_ = bank === nothing ? nothing : Symbol(bank)
    return ObjectType{typeof(effects_),typeof(respawn),typeof(appearance)}(
        Symbol(name),
        bank_,
        radius_,
        effects_,
        capacity_,
        respawn,
        appearance,
    )
end

ObjectType(name::AbstractString; kwargs...) = ObjectType(Symbol(name); kwargs...)

_same_object_appearance(a::AbstractObjectAppearance, b::AbstractObjectAppearance) =
    isequal(a, b)
_same_object_appearance(::NoAppearance, ::NoAppearance) = true

function _same_object_policy(a::ObjectType, b::ObjectType)
    return a.name === b.name &&
           a.bank === b.bank &&
           a.radius == b.radius &&
           isequal(a.effects, b.effects) &&
           a.capacity == b.capacity &&
           isequal(a.respawn, b.respawn) &&
           _same_object_appearance(a.appearance, b.appearance)
end

"""Concrete initial positions for all instances of one `ObjectType`."""
struct ObjectPopulation{K<:ObjectType}
    kind::K
    positions::Vector{NTuple{2,Float64}}

    function ObjectPopulation(
        kind::K,
        positions::Vector{NTuple{2,Float64}},
    ) where {K<:ObjectType}
        all(position -> all(isfinite, position), positions) ||
            throw(ArgumentError("object positions must be finite"))
        return new{K}(kind, positions)
    end
end

function ObjectPopulation(kind::ObjectType, positions)
    values = NTuple{2,Float64}[(Float64(p[1]), Float64(p[2])) for p in positions]
    all(position -> all(isfinite, position), values) ||
        throw(ArgumentError("object positions must be finite"))
    return ObjectPopulation(kind, values)
end

function ObjectPopulation(kind::ObjectType, count::Integer, arena; rng=Random.default_rng())
    count_ = Int(count)
    count_ >= 0 || throw(ArgumentError("object count must be non-negative"))
    positions = [sample_position(rng, arena; radius=kind.radius) for _ in 1:count_]
    return ObjectPopulation(kind, positions)
end
