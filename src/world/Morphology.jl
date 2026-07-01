struct NoPlacement end

const NO_PLACEMENT = NoPlacement()

struct Port{P}
    id::Symbol
    placement::P
end

Port(id::Symbol) = Port(id, NO_PLACEMENT)
Port(id::Symbol, placement::P) where {P} = Port{P}(id, placement)

struct PortSpec{RP,EP}
    n_receptors::Int
    n_effectors::Int
    receptor_ports::Vector{Port{RP}}
    effector_ports::Vector{Port{EP}}
end

function PortSpec(
    n_receptors::Integer,
    n_effectors::Integer,
    receptor_ports::AbstractVector{Port{RP}},
    effector_ports::AbstractVector{Port{EP}},
) where {RP,EP}
    n_receptors_ = Int(n_receptors)
    n_effectors_ = Int(n_effectors)
    length(receptor_ports) == n_receptors_ ||
        throw(DimensionMismatch("PortSpec expected $(n_receptors_) receptor ports, got $(length(receptor_ports))"))
    length(effector_ports) == n_effectors_ ||
        throw(DimensionMismatch("PortSpec expected $(n_effectors_) effector ports, got $(length(effector_ports))"))
    return PortSpec{RP,EP}(
        n_receptors_,
        n_effectors_,
        collect(receptor_ports),
        collect(effector_ports),
    )
end

function _numbered_ports(prefix::Symbol, n::Integer)
    n_ = Int(n)
    out = Vector{Port{NoPlacement}}(undef, n_)
    @inbounds for i in 1:n_
        out[i] = Port(Symbol(string(prefix), "_", i))
    end
    return out
end

PortSpec(n_receptors::Integer, n_effectors::Integer) = PortSpec(
    n_receptors,
    n_effectors,
    _numbered_ports(:receptor, n_receptors),
    _numbered_ports(:effector, n_effectors),
)

n_receptors(spec::PortSpec) = spec.n_receptors
n_effectors(spec::PortSpec) = spec.n_effectors
ports(spec::PortSpec) = (receptors=spec.receptor_ports, effectors=spec.effector_ports)

abstract type Morphology end

struct PassthroughMorphology <: Morphology
    n_receptors::Int
    n_effectors::Int
end

PassthroughMorphology(n_receptors::Integer, n_effectors::Integer) =
    PassthroughMorphology(Int(n_receptors), Int(n_effectors))

Base.@kwdef struct VENMorphology <: Morphology
    sensory_scaling::Bool = true
end

const VEN_MORPHOLOGY = VENMorphology()
const _PASSTHROUGH_BODY_MORPHOLOGY = PassthroughMorphology(0, 0)
const _VEN_RECEPTOR_PLACEMENT = Union{NoPlacement,Float64}

n_receptors(m::PassthroughMorphology) = m.n_receptors
n_effectors(m::PassthroughMorphology) = m.n_effectors
n_receptors(::VENMorphology) = 64
n_effectors(::VENMorphology) = 3

function portspec(m::PassthroughMorphology)::PortSpec
    return PortSpec(n_receptors(m), n_effectors(m))
end

function _ven_receptor_ports()
    out = Vector{Port{_VEN_RECEPTOR_PLACEMENT}}(undef, 64)
    out[1] = Port{_VEN_RECEPTOR_PLACEMENT}(:reserved_1, NO_PLACEMENT)
    out[2] = Port{_VEN_RECEPTOR_PLACEMENT}(:reserved_2, NO_PLACEMENT)
    @inbounds for i in eachindex(SENS_ANGLES_DEG)
        out[i + 2] = Port{_VEN_RECEPTOR_PLACEMENT}(Symbol("bearing_", i), Float64(SENS_ANGLES_DEG[i]))
    end
    return out
end

function _ven_effector_ports()
    return Port{NoPlacement}[
        Port(:turn_left),
        Port(:turn_right),
        Port(:forward),
    ]
end

function portspec(m::VENMorphology)::PortSpec
    return PortSpec(n_receptors(m), n_effectors(m), _ven_receptor_ports(), _ven_effector_ports())
end

ports(m::Morphology) = ports(portspec(m))

encode_receptors(::PassthroughMorphology, percept) = percept
decode_effectors(::PassthroughMorphology, e) = e

function encode_receptors(m::VENMorphology, percept)
    vals = Float64.(vec(collect(percept)))
    if length(vals) == 64
        return copy(vals)
    elseif length(vals) == 62
        return assemble_inputs(vals, m.sensory_scaling)
    end
    throw(DimensionMismatch("VENBody percept must have length 62 or 64, got $(length(vals))"))
end

decode_effectors(::VENMorphology, e) = _ven_output_acts(e)

default_morphology(env) = PassthroughMorphology(n_receptors(env), n_effectors(env))
default_morphology(::VENBody) = VEN_MORPHOLOGY
default_morphology(::Type{VENBody}) = VEN_MORPHOLOGY

receptors(::PassthroughBody, percept) =
    encode_receptors(_PASSTHROUGH_BODY_MORPHOLOGY, percept)

motor(::PassthroughBody, e) =
    decode_effectors(_PASSTHROUGH_BODY_MORPHOLOGY, e)

receptors(::VENBody, percept) =
    encode_receptors(default_morphology(VENBody), percept)

motor(::VENBody, e) =
    decode_effectors(default_morphology(VENBody), e)
