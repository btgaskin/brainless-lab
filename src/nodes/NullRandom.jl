using Random

const NULL_RANDOM_DEFAULT_RATE = 0.035

mutable struct NullRandomReservoir <: Reservoir
    n_receptors_::Int
    n_effectors_::Int
    spikes::Vector{Float64}
    effector_buffer::Vector{Float64}
    target_rate::Float64
    seed::Union{Nothing,Int}
    rng::MersenneTwister
end

"""
    NullRandomReservoir(n_nodes, n_receptors, n_effectors; target_rate=0.035, seed=0)

Construct an input-independent rate-matched control. Each step draws a
Bernoulli spike train at `target_rate`, then reports effector spike fractions
from disjoint node groups. The `0.035` default reflects the approximate
reference activity measured for the canonical Falandays node. Use an explicit
rate when a different reference protocol defines the control.
"""
function NullRandomReservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    target_rate::Real=NULL_RANDOM_DEFAULT_RATE,
    seed=0,
    kwargs...,
)
    n_nodes_i = Int(n_nodes)
    n_receptors_i = Int(n_receptors_)
    n_effectors_i = Int(n_effectors_)
    n_nodes_i >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_i >= 0 || throw(ArgumentError("n_receptors must be non-negative"))
    n_effectors_i >= 1 || throw(ArgumentError("n_effectors must be at least 1"))
    target_rate_f = Float64(target_rate)
    isfinite(target_rate_f) && 0.0 <= target_rate_f <= 1.0 ||
        throw(ArgumentError("target_rate must be finite and in [0, 1]"))
    seed_i = seed === nothing ? nothing : Int(seed)
    rng = seed_i === nothing ? MersenneTwister() : MersenneTwister(seed_i)
    return NullRandomReservoir(
        n_receptors_i,
        n_effectors_i,
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_effectors_i),
        target_rate_f,
        seed_i,
        rng,
    )
end

function _update_null_effectors!(r::NullRandomReservoir)
    n_nodes_ = length(r.spikes)
    @inbounds for effector in eachindex(r.effector_buffer)
        total = 0.0
        count = 0
        for node in effector:r.n_effectors_:n_nodes_
            total += r.spikes[node]
            count += 1
        end
        if count == 0
            node = mod1(effector, n_nodes_)
            total = r.spikes[node]
            count = 1
        end
        r.effector_buffer[effector] = total / count
    end
    return r.effector_buffer
end

function step!(r::NullRandomReservoir, R)
    @inbounds for node in eachindex(r.spikes)
        r.spikes[node] = rand(r.rng) < r.target_rate ? 1.0 : 0.0
    end
    _update_null_effectors!(r)
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
    target_rate=r.target_rate,
    rng=deepcopy(r.rng),
)

function load_state!(r::NullRandomReservoir, state)
    length(state.spikes) == length(r.spikes) || throw(DimensionMismatch(
        "state spike width $(length(state.spikes)) does not match $(length(r.spikes))",
    ))
    length(state.effectors) == length(r.effector_buffer) || throw(DimensionMismatch(
        "state effector width $(length(state.effectors)) does not match " *
        "$(length(r.effector_buffer))",
    ))
    state.rng isa MersenneTwister || throw(ArgumentError(
        "state.rng must be a MersenneTwister",
    ))
    target_rate = Float64(state.target_rate)
    isfinite(target_rate) && 0.0 <= target_rate <= 1.0 || throw(ArgumentError(
        "state.target_rate must be finite and in [0, 1]",
    ))
    copyto!(r.spikes, Float64.(state.spikes))
    copyto!(r.effector_buffer, Float64.(state.effectors))
    r.target_rate = target_rate
    r.rng = deepcopy(state.rng)
    return r
end
