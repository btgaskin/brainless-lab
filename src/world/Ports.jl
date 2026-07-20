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

    function PortSpec(
        n_receptors::Integer,
        n_effectors::Integer,
        receptor_ports::AbstractVector{Port{RP}},
        effector_ports::AbstractVector{Port{EP}},
    ) where {RP,EP}
        n_receptors_ = Int(n_receptors)
        n_effectors_ = Int(n_effectors)
        n_receptors_ >= 0 || throw(ArgumentError(
            "PortSpec receptor count must be non-negative, got $(n_receptors_)",
        ))
        n_effectors_ >= 0 || throw(ArgumentError(
            "PortSpec effector count must be non-negative, got $(n_effectors_)",
        ))
        length(receptor_ports) == n_receptors_ || throw(DimensionMismatch(
            "PortSpec expected $(n_receptors_) receptor ports, got $(length(receptor_ports))",
        ))
        length(effector_ports) == n_effectors_ || throw(DimensionMismatch(
            "PortSpec expected $(n_effectors_) effector ports, got $(length(effector_ports))",
        ))
        receptor_ids = Symbol[port.id for port in receptor_ports]
        effector_ids = Symbol[port.id for port in effector_ports]
        all_ids = (receptor_ids..., effector_ids...)
        length(unique(all_ids)) == length(all_ids) || throw(ArgumentError(
            "PortSpec port IDs must be unique across receptor and effector ports; got $(all_ids)",
        ))
        return new{RP,EP}(
            n_receptors_,
            n_effectors_,
            collect(receptor_ports),
            collect(effector_ports),
        )
    end
end

function _numbered_ports(prefix::Symbol, n::Integer)
    out = Vector{Port{NoPlacement}}(undef, Int(n))
    @inbounds for i in eachindex(out)
        out[i] = Port(Symbol(string(prefix), "_", i))
    end
    return out
end

function PortSpec(n_receptors::Integer, n_effectors::Integer)
    n_receptors_ = Int(n_receptors)
    n_effectors_ = Int(n_effectors)
    n_receptors_ >= 0 || throw(ArgumentError(
        "PortSpec receptor count must be non-negative, got $(n_receptors_)",
    ))
    n_effectors_ >= 0 || throw(ArgumentError(
        "PortSpec effector count must be non-negative, got $(n_effectors_)",
    ))
    return PortSpec(
        n_receptors_,
        n_effectors_,
        _numbered_ports(:receptor, n_receptors_),
        _numbered_ports(:effector, n_effectors_),
    )
end

# Extension bodies may expose only receptor/effector counts. Concrete bodies can
# specialize this method when they have stable IDs or physical placements.
portspec(body::AbstractBody) = PortSpec(n_receptors(body), n_effectors(body))
ports(body::AbstractBody) = ports(portspec(body))

# Ordinary extension bodies are viable and stateless unless they opt into the
# physiology/update protocol.
alive(::AbstractBody) = true
update!(::AbstractBody, effects=()) = nothing
inactive_command(body::AbstractBody) = zeros(Float64, n_effectors(body))

n_receptors(spec::PortSpec) = spec.n_receptors
n_effectors(spec::PortSpec) = spec.n_effectors
ports(spec::PortSpec) = (receptors=spec.receptor_ports, effectors=spec.effector_ports)
