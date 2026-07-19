using Random

mutable struct NullRandomReservoir <: Reservoir
    n_receptors_::Int
    n_effectors_::Int
    spikes::Vector{Float64}
    effector_buffer::Vector{Float64}
    seed::Union{Nothing,Int}
    rng::MersenneTwister
end

function NullRandomReservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    kwargs...,
)
    n_nodes_i = Int(n_nodes)
    n_receptors_i = Int(n_receptors_)
    n_effectors_i = Int(n_effectors_)
    n_nodes_i >= 0 || throw(ArgumentError("n_nodes must be non-negative"))
    n_receptors_i >= 0 || throw(ArgumentError("n_receptors must be non-negative"))
    n_effectors_i >= 1 || throw(ArgumentError("n_effectors must be at least 1"))
    seed_i = seed === nothing ? nothing : Int(seed)
    rng = seed_i === nothing ? MersenneTwister() : MersenneTwister(seed_i)
    return NullRandomReservoir(
        n_receptors_i,
        n_effectors_i,
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_effectors_i),
        seed_i,
        rng,
    )
end

function step!(r::NullRandomReservoir, R)
    fill!(r.spikes, 0.0)
    rand!(r.rng, r.effector_buffer)
    return copy(r.spikes)
end

effectors(r::NullRandomReservoir, spikes) = copy(r.effector_buffer)
effectors(r::NullRandomReservoir) = effectors(r, r.spikes)
n_receptors(r::NullRandomReservoir) = r.n_receptors_
n_effectors(r::NullRandomReservoir) = r.n_effectors_
n_nodes(r::NullRandomReservoir) = length(r.spikes)

function reset!(r::NullRandomReservoir)
    fill!(r.spikes, 0.0)
    fill!(r.effector_buffer, 0.0)
    r.seed === nothing || Random.seed!(r.rng, r.seed)
    return r
end

snapshot_state(r::NullRandomReservoir) = (
    spikes=copy(r.spikes),
    effectors=copy(r.effector_buffer),
)

function load_state!(r::NullRandomReservoir, state)
    copyto!(r.spikes, Float64.(state.spikes))
    copyto!(r.effector_buffer, Float64.(state.effectors))
    return r
end
