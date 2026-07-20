using Random

import BrainlessLab
import BrainlessLab: NodeModel, Reservoir
import BrainlessLab: step!, effectors, n_nodes, n_receptors, n_effectors, reset!
import BrainlessLab: snapshot_state, load_state!, pack_params, unpack_params, paramdim
import BrainlessLab: plasticity, OnlinePlasticity, register_node!

Base.@kwdef struct MyNodeParams <: NodeModel
    leak::Float64 = 0.25
    lrate_wmat::Float64 = 0.04
    lrate_targ::Float64 = 0.01
    threshold_mult::Float64 = 2.0
    target_floor::Float64 = 1.0
    input_gain::Float64 = 1.4
    recurrent_scale::Float64 = 0.7
    weight_limit::Float64 = 3.0
    learn_on::Bool = true
end

paramdim(::Type{MyNodeParams}) = 8
paramdim(::MyNodeParams) = 8

pack_params(::Type{MyNodeParams}) = pack_params(MyNodeParams())

pack_params(p::MyNodeParams) = Float64[
    p.leak,
    p.lrate_wmat,
    p.lrate_targ,
    p.threshold_mult,
    p.target_floor,
    p.input_gain,
    p.recurrent_scale,
    p.weight_limit,
]

function unpack_params(::Type{MyNodeParams}, raw::AbstractVector{<:Real})
    length(raw) == paramdim(MyNodeParams) ||
        throw(ArgumentError("expected $(paramdim(MyNodeParams)) MyNode params, got $(length(raw))"))
    return MyNodeParams(
        leak=clamp(Float64(raw[1]), 0.0, 0.95),
        lrate_wmat=max(0.0, Float64(raw[2])),
        lrate_targ=max(0.0, Float64(raw[3])),
        threshold_mult=max(0.1, Float64(raw[4])),
        target_floor=max(0.01, Float64(raw[5])),
        input_gain=max(0.0, Float64(raw[6])),
        recurrent_scale=max(0.0, Float64(raw[7])),
        weight_limit=max(0.1, Float64(raw[8])),
        learn_on=true,
    )
end

_as_my_params(p::MyNodeParams) = p
_as_my_params(raw::AbstractVector{<:Real}) = unpack_params(MyNodeParams, raw)

function _as_my_params(p::BrainlessLab.FalandaysParams)
    return MyNodeParams(
        leak=p.leak,
        lrate_wmat=p.lrate_wmat,
        lrate_targ=p.lrate_targ,
        threshold_mult=p.threshold_mult,
        target_floor=p.targ_min,
        input_gain=p.input_weight,
        recurrent_scale=p.weight_init_std,
        weight_limit=max(1.0, 3.0 * p.weight_init_std),
        learn_on=p.learn_on,
    )
end

function _float_vector(x, name::AbstractString)
    values = Float64.(vec(collect(x)))
    all(isfinite, values) || throw(ArgumentError("$name contains non-finite values"))
    return values
end

function _bernoulli_mask(rng::AbstractRNG, rows::Integer, cols::Integer, p::Real; diagonal::Bool=false)
    rows = Int(rows)
    cols = Int(cols)
    p = clamp(Float64(p), 0.0, 1.0)
    mask = falses(rows, cols)
    @inbounds for j in 1:cols, i in 1:rows
        if diagonal || i != j
            mask[i, j] = rand(rng) < p
        end
    end
    return mask
end

function _ensure_node_input!(input_mask::BitMatrix, recurrent_mask::BitMatrix, rng::AbstractRNG)
    n_receptors_, n_nodes = size(input_mask)
    @inbounds for node in 1:n_nodes
        has_input = any(@view input_mask[:, node]) || any(@view recurrent_mask[:, node])
        has_input || (input_mask[rand(rng, 1:n_receptors_), node] = true)
    end
    return input_mask
end

function _ensure_outputs!(output_mask::BitMatrix, rng::AbstractRNG)
    n_nodes, n_effectors_ = size(output_mask)
    @inbounds for effector in 1:n_effectors_
        any(@view output_mask[:, effector]) || (output_mask[rand(rng, 1:n_nodes), effector] = true)
    end
    return output_mask
end

mutable struct MyNode <: Reservoir
    params::MyNodeParams
    input_wmat::Matrix{Float64}
    recurrent_mask::BitMatrix
    output_mask::BitMatrix
    wmat::Matrix{Float64}
    wmat0::Matrix{Float64}
    acts::Vector{Float64}
    targets::Vector{Float64}
    spikes::Vector{Float64}
    errors::Vector{Float64}
    prev_spikes::Vector{Float64}
    n_receptors::Int
    n_effectors::Int
end

function MyNode(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    params=MyNodeParams(),
    link_p::Real=0.18,
    kwargs...,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_nodes >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    p = _as_my_params(params)
    rng = seed === nothing ? MersenneTwister() : MersenneTwister(Int(seed))

    recurrent_mask = _bernoulli_mask(rng, n_nodes, n_nodes, link_p; diagonal=false)
    input_mask = _bernoulli_mask(rng, n_receptors_, n_nodes, link_p; diagonal=true)
    output_mask = _bernoulli_mask(rng, n_nodes, n_effectors_, link_p; diagonal=true)
    _ensure_node_input!(input_mask, recurrent_mask, rng)
    _ensure_outputs!(output_mask, rng)

    input_wmat = p.input_gain .* Float64.(input_mask)
    wmat0 = p.recurrent_scale .* randn(rng, n_nodes, n_nodes) .* Float64.(recurrent_mask)

    return MyNode(
        p,
        input_wmat,
        recurrent_mask,
        output_mask,
        copy(wmat0),
        wmat0,
        zeros(Float64, n_nodes),
        fill(p.target_floor, n_nodes),
        zeros(Float64, n_nodes),
        zeros(Float64, n_nodes),
        zeros(Float64, n_nodes),
        n_receptors_,
        n_effectors_,
    )
end

plasticity(::MyNode) = OnlinePlasticity()

function step!(r::MyNode, receptor_currents)
    receptors = _float_vector(receptor_currents, "receptor_currents")
    length(receptors) == r.n_receptors ||
        throw(DimensionMismatch("expected $(r.n_receptors) receptors, got $(length(receptors))"))

    p = r.params
    n_nodes = length(r.acts)
    copyto!(r.prev_spikes, r.spikes)

    @inbounds for dst in 1:n_nodes
        input_current = 0.0
        for receptor in eachindex(receptors)
            input_current += receptors[receptor] * r.input_wmat[receptor, dst]
        end

        recurrent_current = 0.0
        for src in 1:n_nodes
            recurrent_current += r.prev_spikes[src] * r.wmat[src, dst]
        end

        r.acts[dst] = max(0.0, (1.0 - p.leak) * r.acts[dst] + input_current + recurrent_current)
    end

    @inbounds for i in 1:n_nodes
        threshold = p.threshold_mult * r.targets[i]
        if r.acts[i] >= threshold
            r.spikes[i] = 1.0
            r.acts[i] -= threshold
        else
            r.spikes[i] = 0.0
        end
        r.errors[i] = r.acts[i] - r.targets[i]
    end

    if p.learn_on
        active = max(1.0, sum(r.prev_spikes))
        @inbounds for dst in 1:n_nodes
            r.targets[dst] = max(p.target_floor, r.targets[dst] + p.lrate_targ * r.errors[dst])
            delta = p.lrate_wmat * r.errors[dst] / active
            for src in 1:n_nodes
                if r.recurrent_mask[src, dst] && r.prev_spikes[src] > 0.0
                    r.wmat[src, dst] = clamp(r.wmat[src, dst] - delta, -p.weight_limit, p.weight_limit)
                end
            end
        end
    end

    return copy(r.spikes)
end

function effectors(r::MyNode, spikes)
    values = _float_vector(spikes, "spikes")
    length(values) == length(r.spikes) ||
        throw(DimensionMismatch("expected $(length(r.spikes)) spikes, got $(length(values))"))

    out = zeros(Float64, r.n_effectors)
    @inbounds for effector in 1:r.n_effectors
        total = 0.0
        count = 0
        for node in eachindex(values)
            if r.output_mask[node, effector]
                total += values[node]
                count += 1
            end
        end
        out[effector] = count == 0 ? 0.0 : total / count
    end
    return out
end

effectors(r::MyNode) = effectors(r, r.spikes)

function reset!(r::MyNode)
    r.wmat .= r.wmat0
    fill!(r.acts, 0.0)
    fill!(r.targets, r.params.target_floor)
    fill!(r.spikes, 0.0)
    fill!(r.errors, 0.0)
    fill!(r.prev_spikes, 0.0)
    return r
end

n_receptors(r::MyNode) = r.n_receptors
n_effectors(r::MyNode) = r.n_effectors
n_nodes(r::MyNode) = length(r.spikes)

function snapshot_state(r::MyNode)
    return (
        acts=copy(r.acts),
        targets=copy(r.targets),
        spikes=copy(r.spikes),
        errors=copy(r.errors),
        prev_spikes=copy(r.prev_spikes),
        wmat=copy(r.wmat),
    )
end

_state_get(state, key::Symbol) = state isa AbstractDict ? state[key] : getproperty(state, key)

function load_state!(r::MyNode, state)
    copyto!(r.acts, _float_vector(_state_get(state, :acts), "state.acts"))
    copyto!(r.targets, _float_vector(_state_get(state, :targets), "state.targets"))
    copyto!(r.spikes, _float_vector(_state_get(state, :spikes), "state.spikes"))
    copyto!(r.errors, _float_vector(_state_get(state, :errors), "state.errors"))
    copyto!(r.prev_spikes, _float_vector(_state_get(state, :prev_spikes), "state.prev_spikes"))
    r.wmat .= Float64.(_state_get(state, :wmat))
    return r
end

register_node!(:my_node, MyNode; genome_type=MyNodeParams)
