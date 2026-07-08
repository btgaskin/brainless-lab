struct NoPlacement end

const NO_PLACEMENT = NoPlacement()

struct Port{P}
    id::Symbol
    placement::P
end

Port(id::Symbol) = Port(id, NO_PLACEMENT)

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
    source_bank::Bool = false
    source_gain::Float64 = 1.0
    signalling::Bool = false
    norm_mode::Union{Nothing,Symbol} = nothing   # nothing -> derive from sensory_scaling
    norm_sigma::Float64 = 1.0                     # semi-saturation constant for :divisive
    conspecific_gain::Float64 = 1.0               # post-normalisation gain on the conspecific bank
    n_colours::Int = 1                            # colour-selective conspecific banks (>=1)
    colour_sensing::Bool = false                  # false => single colour-blind bank (default no-op)
end

const VEN_MORPHOLOGY = VENMorphology()
const _PASSTHROUGH_BODY_MORPHOLOGY = PassthroughMorphology(0, 0)
const _VEN_RECEPTOR_PLACEMENT = Union{NoPlacement,Float64}

"""
    PassthroughBody(morphology, motor)
    PassthroughBody(morphology)
    PassthroughBody()

A body that carries a `Morphology` and a `Motor` and relays encoding/decoding to
them. The zero-arg form is the stateless task-env relay (identity encode/decode
via the 0×0 passthrough morphology). Swarm agents share one
`PassthroughBody(VENMorphology(...), motor)`; their per-agent physical state and
per-agent `source_gain` live on the environment, not the body. The one- and
zero-arg forms default the motor to [`PASSTHROUGH_MOTOR`](@ref) — the
byte-identical no-op — so unmigrated callers are unchanged.
"""
struct PassthroughBody{M<:Morphology,Mt<:Motor} <: Body
    morphology::M
    motor::Mt
end
PassthroughBody(morphology::Morphology) = PassthroughBody(morphology, PASSTHROUGH_MOTOR)
PassthroughBody() = PassthroughBody(_PASSTHROUGH_BODY_MORPHOLOGY)

motor(b::PassthroughBody) = b.motor

n_receptors(m::PassthroughMorphology) = m.n_receptors
n_effectors(m::PassthroughMorphology) = m.n_effectors
function n_receptors(m::VENMorphology)
    consp = _ven_conspecific_width(m.colour_sensing, m.n_colours)
    return m.source_bank ? consp + VEN_BANK_RECEPTORS : consp
end
n_effectors(m::VENMorphology) = m.signalling ? 4 : 3

function portspec(m::PassthroughMorphology)::PortSpec
    return PortSpec(n_receptors(m), n_effectors(m))
end

# Conspecific receptor ports: 2 reserved leads followed by the bearing bank(s).
# Colour-blind (default) keeps the flat `bearing_<i>` names so the layout is a
# pure no-op; colour sensing lays out per-colour `conspecific_c<k>_bearing_<i>`.
function _ven_base_receptor_ports(n_colours::Int=1, colour_sensing::Bool=false)
    consp = _ven_conspecific_width(colour_sensing, n_colours)
    out = Vector{Port{_VEN_RECEPTOR_PLACEMENT}}(undef, consp)
    out[1] = Port{_VEN_RECEPTOR_PLACEMENT}(:reserved_1, NO_PLACEMENT)
    out[2] = Port{_VEN_RECEPTOR_PLACEMENT}(:reserved_2, NO_PLACEMENT)
    if colour_sensing
        @inbounds for c in 0:(n_colours - 1)
            base = 2 + c * VEN_BEARING_SENSOR_COUNT
            for i in eachindex(SENS_ANGLES_DEG)
                out[base + i] = Port{_VEN_RECEPTOR_PLACEMENT}(
                    Symbol("conspecific_c", c, "_bearing_", i),
                    Float64(SENS_ANGLES_DEG[i]),
                )
            end
        end
    else
        @inbounds for i in eachindex(SENS_ANGLES_DEG)
            out[i + 2] = Port{_VEN_RECEPTOR_PLACEMENT}(Symbol("bearing_", i), Float64(SENS_ANGLES_DEG[i]))
        end
    end
    return out
end

function _ven_receptor_ports(source_bank::Bool=false, signalling::Bool=false, n_colours::Int=1, colour_sensing::Bool=false)
    base = _ven_base_receptor_ports(n_colours, colour_sensing)
    source_bank || return base

    consp = length(base)
    acoustic_idx = consp + 1  # start of the (single, uncoloured) source region
    out = Vector{Port{_VEN_RECEPTOR_PLACEMENT}}(undef, consp + VEN_BANK_RECEPTORS)
    copyto!(out, 1, base, 1, consp)
    out[acoustic_idx] = Port{_VEN_RECEPTOR_PLACEMENT}(
        signalling ? :acoustic : :source_reserved_1,
        NO_PLACEMENT,
    )
    out[consp + 2] = Port{_VEN_RECEPTOR_PLACEMENT}(:source_reserved_2, NO_PLACEMENT)
    @inbounds for i in eachindex(SENS_ANGLES_DEG)
        out[consp + i + 2] =
            Port{_VEN_RECEPTOR_PLACEMENT}(Symbol("source_bearing_", i), Float64(SENS_ANGLES_DEG[i]))
    end
    return out
end

function _ven_effector_ports(signalling::Bool=false)
    out = Port{NoPlacement}[
        Port(:turn_left),
        Port(:turn_right),
        Port(:forward),
    ]
    signalling && push!(out, Port(:signal))
    return out
end

function portspec(m::VENMorphology)::PortSpec
    return PortSpec(
        n_receptors(m),
        n_effectors(m),
        _ven_receptor_ports(m.source_bank, m.signalling, m.n_colours, m.colour_sensing),
        _ven_effector_ports(m.signalling),
    )
end

ports(m::Morphology) = ports(portspec(m))

encode_receptors(::PassthroughMorphology, percept) = percept
decode_effectors(::PassthroughMorphology, e) = e

function encode_receptors(m::VENMorphology, percept)
    vals = _ven_float_vector(percept)
    # Already-encoded input (observe emits the full receptor layout, incl. coloured).
    length(vals) == n_receptors(m) && return copy(vals)

    nb = VEN_BEARING_SENSOR_COUNT
    consp_raw = m.colour_sensing ? m.n_colours * nb : nb  # raw conspecific-sensor width
    if m.source_bank
        if length(vals) == consp_raw + nb
            return assemble_forage_inputs(
                @view(vals[1:consp_raw]),
                @view(vals[(consp_raw + 1):(consp_raw + nb)]),
                m.sensory_scaling;
                source_gain=m.source_gain,
                norm_mode=m.norm_mode,
                norm_sigma=m.norm_sigma,
                conspecific_gain=m.conspecific_gain,
                n_colours=m.n_colours,
                colour_sensing=m.colour_sensing,
            )
        end
        throw(DimensionMismatch("forage VEN percept must have length $(consp_raw + nb) or $(n_receptors(m)), got $(length(vals))"))
    else
        if length(vals) == consp_raw
            return assemble_inputs(
                vals,
                m.sensory_scaling;
                norm_mode=m.norm_mode,
                norm_sigma=m.norm_sigma,
                gain=m.conspecific_gain,
                n_colours=m.n_colours,
                colour_sensing=m.colour_sensing,
            )
        end
    end
    throw(DimensionMismatch("VEN percept must have length $(consp_raw) or $(n_receptors(m)), got $(length(vals))"))
end

decode_effectors(::VENMorphology, e) = _ven_output_acts(e)

default_morphology(env) = PassthroughMorphology(n_receptors(env), n_effectors(env))
default_morphology(b::PassthroughBody) = b.morphology

receptors(b::PassthroughBody, percept) = encode_receptors(b.morphology, percept)
decode_effectors(b::PassthroughBody, e) = decode_effectors(b.morphology, e)
