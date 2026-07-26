using Random

import BrainlessLab
import BrainlessLab: NodeModel, Reservoir
import BrainlessLab: step!, effectors, n_nodes, n_receptors, n_effectors, reset!
import BrainlessLab: snapshot_state, load_state!, pack_params, unpack_params, paramdim
import BrainlessLab: plasticity, OnlinePlasticity
import BrainlessLab: NodeBuildContext, NodeSpec, ParameterSpec, DEFAULT_REGISTRY, register!

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

const MY_NODE_PARAM_RANGES = (
    leak=(0.0, 0.95),
    lrate_wmat=(1.0e-4, 1.0),
    lrate_targ=(1.0e-4, 0.5),
    threshold_mult=(0.1, 5.0),
    target_floor=(0.01, 3.0),
    input_gain=(0.0, 4.0),
    recurrent_scale=(0.0, 3.0),
    weight_limit=(0.1, 10.0),
)

paramdim(::Type{MyNodeParams}) = 8
paramdim(::MyNodeParams) = 8

pack_params(::Type{MyNodeParams}) = pack_params(MyNodeParams())

function _my_sigmoid(raw::Real)
    value = Float64(raw)
    if value >= 0.0
        z = exp(-value)
        return inv(1.0 + z)
    else
        z = exp(value)
        return z / (1.0 + z)
    end
end

function _my_logit(probability::Real)
    bounded = clamp(Float64(probability), 1.0e-12, 1.0 - 1.0e-12)
    return log(bounded / (1.0 - bounded))
end

_my_decode(raw::Real, range) =
    range[1] + (range[2] - range[1]) * _my_sigmoid(raw)

function _my_encode(value::Real, range)
    physical = Float64(value)
    range[1] <= physical <= range[2] || throw(ArgumentError(
        "parameter value $physical lies outside the supported range $range",
    ))
    return _my_logit((physical - range[1]) / (range[2] - range[1]))
end

_my_range_validator(range) =
    value -> value isa Float64 &&
        isfinite(value) &&
        range[1] <= value <= range[2]

_my_parameter(name::Symbol, default::Float64; sweep=nothing) = ParameterSpec(
    name,
    default;
    validator=_my_range_validator(getproperty(MY_NODE_PARAM_RANGES, name)),
    sweep=sweep,
)

# Model fields remain readable physical values. Pack and unpack map them to
# unconstrained optimiser coordinates through fixed bounded sigmoid bijections.
pack_params(p::MyNodeParams) = Float64[
    _my_encode(p.leak, MY_NODE_PARAM_RANGES.leak),
    _my_encode(p.lrate_wmat, MY_NODE_PARAM_RANGES.lrate_wmat),
    _my_encode(p.lrate_targ, MY_NODE_PARAM_RANGES.lrate_targ),
    _my_encode(p.threshold_mult, MY_NODE_PARAM_RANGES.threshold_mult),
    _my_encode(p.target_floor, MY_NODE_PARAM_RANGES.target_floor),
    _my_encode(p.input_gain, MY_NODE_PARAM_RANGES.input_gain),
    _my_encode(p.recurrent_scale, MY_NODE_PARAM_RANGES.recurrent_scale),
    _my_encode(p.weight_limit, MY_NODE_PARAM_RANGES.weight_limit),
]

function unpack_params(
    ::Type{MyNodeParams},
    raw::AbstractVector{<:Real};
    learn_on::Bool=true,
)
    length(raw) == paramdim(MyNodeParams) ||
        throw(ArgumentError("expected $(paramdim(MyNodeParams)) MyNode params, got $(length(raw))"))
    return MyNodeParams(
        leak=_my_decode(raw[1], MY_NODE_PARAM_RANGES.leak),
        lrate_wmat=_my_decode(raw[2], MY_NODE_PARAM_RANGES.lrate_wmat),
        lrate_targ=_my_decode(raw[3], MY_NODE_PARAM_RANGES.lrate_targ),
        threshold_mult=_my_decode(
            raw[4],
            MY_NODE_PARAM_RANGES.threshold_mult,
        ),
        target_floor=_my_decode(raw[5], MY_NODE_PARAM_RANGES.target_floor),
        input_gain=_my_decode(raw[6], MY_NODE_PARAM_RANGES.input_gain),
        recurrent_scale=_my_decode(
            raw[7],
            MY_NODE_PARAM_RANGES.recurrent_scale,
        ),
        weight_limit=_my_decode(raw[8], MY_NODE_PARAM_RANGES.weight_limit),
        learn_on=learn_on,
    )
end

unpack_params(p::MyNodeParams, raw::AbstractVector{<:Real}) =
    unpack_params(MyNodeParams, raw; learn_on=p.learn_on)

_as_my_params(p::MyNodeParams) = p
_as_my_params(raw::AbstractVector{<:Real}) = unpack_params(MyNodeParams, raw)

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

function build_my_node(context::NodeBuildContext, values)
    params = if context.model === nothing
        MyNodeParams(
            leak=values[:leak],
            lrate_wmat=values[:lrate_wmat],
            lrate_targ=values[:lrate_targ],
            threshold_mult=values[:threshold_mult],
            target_floor=values[:target_floor],
            input_gain=values[:input_gain],
            recurrent_scale=values[:recurrent_scale],
            weight_limit=values[:weight_limit],
            learn_on=values[:learn_on],
        )
    elseif context.model isa MyNodeParams
        context.model
    else
        throw(ArgumentError(
            "my_node model must be MyNodeParams, got $(typeof(context.model))",
        ))
    end
    seed = Int(mod(context.seeds.topology, UInt64(typemax(Int))))
    return MyNode(
        context.n_nodes,
        n_receptors(context.ports),
        n_effectors(context.ports);
        seed=seed,
        params=params,
        link_p=values[:link_p],
    )
end

const MY_NODE_SPEC = NodeSpec(
    :my_node,
    build_my_node;
    genome_type=MyNodeParams,
    stability=:experimental,
    tags=(:experimental,),
    capabilities=(:online_plasticity, :recurrent_weights, :homeostatic_target),
    parameters=(
        _my_parameter(:leak, 0.25; sweep=(0.1, 0.25, 0.5)),
        _my_parameter(:lrate_wmat, 0.04; sweep=(0.01, 0.04, 0.1)),
        _my_parameter(:lrate_targ, 0.01),
        _my_parameter(:threshold_mult, 2.0),
        _my_parameter(:target_floor, 1.0),
        _my_parameter(:input_gain, 1.4),
        _my_parameter(:recurrent_scale, 0.7),
        _my_parameter(:weight_limit, 3.0),
        ParameterSpec(:learn_on, true),
        ParameterSpec(
            :link_p,
            0.18;
            owner=:reservoir,
            validator=value -> value isa Float64 &&
                isfinite(value) &&
                0.0 <= value <= 1.0,
            sweep=(0.1, 0.18, 0.3),
        ),
    ),
    parameter_sets=Dict(
        :sweep => (:leak, :lrate_wmat),
        :connectivity => (:link_p,),
    ),
)

register!(DEFAULT_REGISTRY, MY_NODE_SPEC)
