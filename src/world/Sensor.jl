# An AbstractSensor is the perception-geometry of the situated layer: it is to sensing
# what `Motor` is to action. It answers two questions — WHERE the sensory rays
# point (the per-ray angle vector) and HOW a ray/target intersection becomes an
# activation (the encoding) — and nothing else. The sense-cone math itself
# (`sense_agents`/`sense_source`/`_sense_circular_targets`/...) is already
# geometry-agnostic: it takes the angle vector + encoding as arguments. So a
# An AbstractSensor is simply the source of that vector and encoding, carried on the
# embodiment and task configuration.
#
# The DEFAULT `BearingSensor()` is a strict byte-identical no-op: its angles are
# the historical two-eye 62-ray fan and its `:binary` encoding is the old
# `sens_agent_dist == 0` hit→1.0 map, so every width/port/activation/RNG draw is
# unchanged. This is a *discovery* instrument, not a controller: the canonical
# field is the explicit per-ray `angles_deg`; the structured `bearing_eyes`
# constructor is a sweep-only convenience whose knobs are NOT stored; and the
# genome operates on raw per-ray angles so a multi-eye layout can EMERGE rather
# than be imposed.

"""
    AbstractSensor

Abstract supertype for perception components carried by an `Embodiment`. A
sensor supplies its physical placement and raw sampling contract; the bearing
sensor additionally exposes the historical intersection
encoding consumed by the (geometry-agnostic) sense-cone functions.
"""
abstract type AbstractSensor end

"""Abstract supertype for components that map raw sensor samples to receptors."""
abstract type AbstractEncoder end

"""Fixed-width identity mapping from raw samples to named receptor ports."""
struct IdentityEncoder{N,S<:Tuple} <: AbstractEncoder
    port_ids::NTuple{N,Symbol}
    source_ids::S

    function IdentityEncoder(
        port_ids::NTuple{N,Symbol},
        source_ids::S,
    ) where {N,S<:Tuple}
        length(unique(port_ids)) == N ||
            throw(ArgumentError("identity-encoder receptor port IDs must be unique"))
        all(id -> id isa Symbol, source_ids) || throw(ArgumentError(
            "identity-encoder source IDs must be symbols",
        ))
        length(unique(source_ids)) == length(source_ids) || throw(ArgumentError(
            "identity-encoder source IDs must be unique",
        ))
        return new{N,S}(port_ids, source_ids)
    end
end

IdentityEncoder{N}(port_ids::NTuple{N,Symbol}) where {N} = IdentityEncoder(port_ids, ())

IdentityEncoder(ids; sources=()) = begin
    ids_ = Tuple(Symbol(id) for id in ids)
    sources_ = Tuple(Symbol(id) for id in sources)
    IdentityEncoder(ids_, sources_)
end

function IdentityEncoder(width::Integer; prefix::Symbol=:receptor, sources=())
    width_ = Int(width)
    width_ >= 0 || throw(ArgumentError("identity-encoder width must be non-negative"))
    return IdentityEncoder(
        ntuple(i -> Symbol(prefix, :_, i), width_);
        sources=sources,
    )
end

encoder_sources(::AbstractEncoder) = nothing
encoder_sources(encoder::IdentityEncoder) =
    isempty(encoder.source_ids) ? nothing : encoder.source_ids

n_receptors(encoder::IdentityEncoder) = length(encoder.port_ids)
function portspec(encoder::IdentityEncoder)
    receptors = Port{NoPlacement}[Port(id) for id in encoder.port_ids]
    return PortSpec(length(receptors), 0, receptors, Port{NoPlacement}[])
end

function encode!(encoder::IdentityEncoder, samples)
    values = _component_float_vector(samples)
    length(values) == n_receptors(encoder) || throw(DimensionMismatch(
        "identity encoder expected $(n_receptors(encoder)) samples, got $(length(values))",
    ))
    return values
end

# --- accessors (generic contract) ----------------------------------------------

"""
    n_sensors(spec)

Number of active sensory rays the spec emits (the width the receptor bank layout
derives from).
"""
function n_sensors end

"""
    angles_deg(spec)

The active per-ray angles in degrees (agent-frame bearings).
"""
function angles_deg end

"""
    angles_rad(spec)

The active per-ray angles in radians. Generic: derived from [`angles_deg`](@ref).
"""
angles_rad(s::AbstractSensor) = angles_deg(s) .* (pi / 180.0)

"""
    encoding(spec)

The intersection→activation encoding symbol (`:binary` or `:graded`).
"""
function encoding end

# Clear errors for a spec that has not implemented the contract.
n_sensors(s::AbstractSensor) = throw(ArgumentError("n_sensors not implemented for $(typeof(s))"))
angles_deg(s::AbstractSensor) = throw(ArgumentError("angles_deg not implemented for $(typeof(s))"))
encoding(s::AbstractSensor) = throw(ArgumentError("encoding not implemented for $(typeof(s))"))
rawspec(s::AbstractSensor) = (kind=Symbol(lowercase(string(nameof(typeof(s))))), width=n_sensors(s))

# --- the one built-in sensor ---------------------------------------------------

# The canonical historical placement: two overlapping ±60° fans stepped every 4°,
# offset by ±30°, each sorted descending. Kept verbatim so the default sensor is a
# byte-identical no-op.
_default_bearing_angles_deg() = Float64.(
    vcat(
        reverse(sort(collect(-60.0:4.0:60.0) .+ 30.0)),
        reverse(sort(collect(-60.0:4.0:60.0) .- 30.0)),
    ),
)

function _coerce_angles_deg(angles)
    vals = Float64.(vec(collect(angles)))
    bad = findfirst(x -> !isfinite(x), vals)
    bad === nothing ||
        throw(ArgumentError("BearingSensor angles_deg must be finite; value at index $(bad) is $(vals[bad])"))
    return vals
end

function _coerce_degree_range(name::Symbol, range)
    vals = Float64.(vec(collect(range)))
    length(vals) == 2 ||
        throw(ArgumentError("BearingSensor $(name) must contain exactly two values (lo, hi); got $(length(vals))"))
    lo, hi = vals
    (isfinite(lo) && isfinite(hi)) ||
        throw(ArgumentError("BearingSensor $(name) must be finite; got ($(lo), $(hi))"))
    lo <= hi ||
        throw(ArgumentError("BearingSensor $(name) must be ordered with lo <= hi; got ($(lo), $(hi))"))
    return (lo, hi)
end

"""
    BearingSensor(; angles_deg, encoding=:binary, tuning_deg=0.0,
                    angle_range_deg=(-180.0, 180.0), tuning_range_deg=(0.0, 0.0),
                    enabled=trues(0))

The first built-in `AbstractSensor`: a bank of bearing rays.

  - `angles_deg` — the CANONICAL explicit per-ray placement (agent-frame degrees).
    Defaults to the historical two-eye 62-ray fan.
  - `encoding` — `:binary` (default; a struck ray reads `1.0`, matching the old
    `sens_agent_dist == 0`) or `:graded` (`1 - d/max_d`, the old `≠ 0`).
  - `tuning_deg` — receptive-field half-width. `0.0` (default) is today's hard ray;
    consumed only by a future `:gaussian_bearing` spec.

Evolution-bound fields, inert until the genome is packed/evolved:

  - `angle_range_deg` — per-ray angle bounds the genome maps into.
  - `tuning_range_deg` — `tuning_deg` bounds; a degenerate `(lo, lo)` (the default)
    drops `tuning` from the parameter space entirely.
  - `enabled` — per-ray on/off gate for a variable ray count. Empty means all rays
    are on (the byte-identical default); otherwise one bit per stored ray.
"""
Base.@kwdef struct BearingSensor <: AbstractSensor
    angles_deg::Vector{Float64} = _default_bearing_angles_deg()
    encoding::Symbol = :binary
    tuning_deg::Float64 = 0.0
    angle_range_deg::NTuple{2,Float64} = (-180.0, 180.0)
    tuning_range_deg::NTuple{2,Float64} = (0.0, 0.0)
    enabled::BitVector = trues(0)

    function BearingSensor(angles_deg, encoding, tuning_deg, angle_range_deg, tuning_range_deg, enabled)
        deg = _coerce_angles_deg(angles_deg)
        enc = Symbol(encoding)
        enc in (:binary, :graded) ||
            throw(ArgumentError("BearingSensor encoding must be :binary or :graded, got :$(enc)"))
        tuning = Float64(tuning_deg)
        isfinite(tuning) ||
            throw(ArgumentError("BearingSensor tuning_deg must be finite; got $(tuning)"))
        angle_range = _coerce_degree_range(:angle_range_deg, angle_range_deg)
        tuning_range = _coerce_degree_range(:tuning_range_deg, tuning_range_deg)
        mask = BitVector(vec(collect(enabled)))
        (isempty(mask) || length(mask) == length(deg)) || throw(DimensionMismatch(
            "BearingSensor enabled mask has length $(length(mask)); expected 0 (all-on) or $(length(deg))",
        ))
        return new(deg, enc, tuning, angle_range, tuning_range, mask)
    end
end

# The default sensor is the byte-identical no-op carried by every morphology /
# SwarmConfig that does not override it.
const BEARING_DEFAULT = BearingSensor()

# Empty `enabled` == all rays on.
_enabled_mask(s::BearingSensor) = isempty(s.enabled) ? trues(length(s.angles_deg)) : s.enabled

n_sensors(s::BearingSensor) = isempty(s.enabled) ? length(s.angles_deg) : count(s.enabled)
angles_deg(s::BearingSensor) = isempty(s.enabled) ? copy(s.angles_deg) : s.angles_deg[s.enabled]
encoding(s::BearingSensor) = s.encoding

"""
    bearing_eyes(; n_eyes=2, eye_offsets_deg=(30.0, -30.0), half_fov_deg=60.0,
                   n_per_eye=31, encoding=:binary, kwargs...)

Sweep-only convenience constructor: lay out `n_eyes` fans of `n_per_eye` rays,
each spanning `±half_fov_deg` and re-centred on its `eye_offsets_deg`, then
descending-sorted per eye. Only the resulting `angles_deg` is stored — the
structured knobs are constructor arguments, not fields (the discovery
commitment). Extra `kwargs` (e.g. `enabled`, `angle_range_deg`) forward to
[`BearingSensor`](@ref).
"""
function bearing_eyes(;
    n_eyes::Integer=2,
    eye_offsets_deg=(30.0, -30.0),
    half_fov_deg::Real=60.0,
    n_per_eye::Integer=31,
    encoding::Symbol=:binary,
    kwargs...,
)
    length(eye_offsets_deg) == n_eyes ||
        throw(ArgumentError("bearing_eyes expects $(n_eyes) eye offsets, got $(length(eye_offsets_deg))"))
    Int(n_per_eye) >= 1 || throw(ArgumentError("n_per_eye must be at least 1"))
    h = Float64(half_fov_deg)
    degs = Float64[]
    for off in eye_offsets_deg
        fan = collect(range(-h, h; length=Int(n_per_eye))) .+ Float64(off)
        append!(degs, reverse(sort(fan)))
    end
    return BearingSensor(; angles_deg=degs, encoding=Symbol(encoding), kwargs...)
end

# --- genome (raw per-ray angles) -----------------------------------------------

_sensor_sigmoid(x) = sigmoid(clamp(Float64(x), -60.0, 60.0))
function _sensor_logit01(p)
    q = clamp(Float64(p), 1e-12, 1.0 - 1e-12)
    return log(q / (1.0 - q))
end
# Bounded map lo + (hi-lo)·σ(g) and its inverse, mirroring FalandaysParams.
_sensor_map(raw, lo, hi) = Float64(lo) + (Float64(hi) - Float64(lo)) * _sensor_sigmoid(raw)
_sensor_unmap(x, lo, hi) = _sensor_logit01((Float64(x) - Float64(lo)) / (Float64(hi) - Float64(lo)))

_tuning_evolvable(s::BearingSensor) = s.tuning_range_deg[1] != s.tuning_range_deg[2]

"""
    paramspace(spec)

Labeled `(label, lo, hi)` bounds for each evolvable scalar of an `AbstractSensor`. For
`BearingSensor`: one `angle_<i>` per active ray (bounded by `angle_range_deg`),
plus a trailing `tuning` entry iff `tuning_range_deg` is non-degenerate.
"""
function paramspace end

function paramspace(s::BearingSensor)
    lo, hi = s.angle_range_deg
    degs = angles_deg(s)
    space = NamedTuple{(:label, :lo, :hi),Tuple{Symbol,Float64,Float64}}[]
    for i in eachindex(degs)
        push!(space, (label=Symbol("angle_", i), lo=Float64(lo), hi=Float64(hi)))
    end
    if _tuning_evolvable(s)
        tlo, thi = s.tuning_range_deg
        push!(space, (label=:tuning, lo=Float64(tlo), hi=Float64(thi)))
    end
    return space
end

paramdim(s::BearingSensor) = n_sensors(s) + (_tuning_evolvable(s) ? 1 : 0)

# The genome operates on the ACTIVE (enabled) rays: pack maps each active angle to
# an unconstrained raw value; unpack writes the mapped angles back into the active
# ray positions of a copy of the template, leaving disabled rays, encoding, ranges
# and the mask untouched. `unpack_params(::BearingSensor, raw)` takes an instance
# template (not a Type) because the ray count and bounds live on the instance.
function pack_params(s::BearingSensor)
    lo, hi = s.angle_range_deg
    g = Float64[_sensor_unmap(d, lo, hi) for d in angles_deg(s)]
    if _tuning_evolvable(s)
        tlo, thi = s.tuning_range_deg
        push!(g, _sensor_unmap(s.tuning_deg, tlo, thi))
    end
    return g
end

function unpack_params(s::BearingSensor, raw::AbstractVector{<:Real})::BearingSensor
    n = paramdim(s)
    length(raw) == n ||
        throw(DimensionMismatch("BearingSensor genome expects $(n) raw parameters, got $(length(raw))"))
    lo, hi = s.angle_range_deg
    mask = _enabled_mask(s)
    new_angles = copy(s.angles_deg)
    k = 0
    @inbounds for i in eachindex(new_angles)
        if mask[i]
            k += 1
            new_angles[i] = _sensor_map(raw[k], lo, hi)
        end
    end
    new_tuning = s.tuning_deg
    if _tuning_evolvable(s)
        tlo, thi = s.tuning_range_deg
        new_tuning = _sensor_map(raw[k + 1], tlo, thi)
    end
    return BearingSensor(;
        angles_deg=new_angles,
        encoding=s.encoding,
        tuning_deg=new_tuning,
        angle_range_deg=s.angle_range_deg,
        tuning_range_deg=s.tuning_range_deg,
        enabled=copy(s.enabled),
    )
end

# --- encoding resolution (used by the sense-cone functions in Body.jl) ---------

# Resolve the sense-cone activation encoding. A `Symbol` passes through; a legacy
# Real `sens_agent_dist` maps 0 -> :binary (hit==1.0) and anything else -> :graded
# (1 - d/max_d), so direct callers passing the old integer knob stay byte-identical
# while an AbstractSensor can supply :binary/:graded directly.
_sensor_encoding(enc::Symbol) = enc
_sensor_encoding(dist::Real) = Float64(dist) == 0.0 ? :binary : :graded
