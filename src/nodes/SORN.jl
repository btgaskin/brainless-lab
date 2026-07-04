using Random

Base.@kwdef struct SORNParams <: NodeModel
    inhibitory_fraction::Float64 = 0.2
    p_ee::Float64 = 0.1
    p_ei::Float64 = 0.2
    p_ie::Float64 = 0.2
    p_input::Float64 = 0.2
    p_output::Float64 = 0.1
    ee_row_sum::Float64 = 1.0
    ei_row_sum::Float64 = 1.0
    ie_row_sum::Float64 = 1.0
    input_row_sum::Float64 = 1.0
    T_E_max::Float64 = 0.5
    T_I_max::Float64 = 1.0
    eta_stdp::Float64 = 0.004
    eta_ip::Float64 = 0.001
    H_ip::Float64 = 0.1
end

const SORN_PARAM_DIM = 15

paramdim(::Type{SORNParams}) = SORN_PARAM_DIM
paramdim(::SORNParams) = SORN_PARAM_DIM

function unpack_params(::Type{SORNParams}, raw::AbstractVector{<:Real})::SORNParams
    length(raw) == SORN_PARAM_DIM ||
        throw(DimensionMismatch("SORNParams expects $SORN_PARAM_DIM raw parameters, got $(length(raw))"))
    return SORNParams(
        inhibitory_fraction=_sigmoid_clipped(raw[1]),
        p_ee=_sigmoid_clipped(raw[2]),
        p_ei=_sigmoid_clipped(raw[3]),
        p_ie=_sigmoid_clipped(raw[4]),
        p_input=_sigmoid_clipped(raw[5]),
        p_output=_sigmoid_clipped(raw[6]),
        ee_row_sum=softplus(Float64(raw[7])),
        ei_row_sum=softplus(Float64(raw[8])),
        ie_row_sum=softplus(Float64(raw[9])),
        input_row_sum=softplus(Float64(raw[10])),
        T_E_max=softplus(Float64(raw[11])),
        T_I_max=softplus(Float64(raw[12])),
        eta_stdp=softplus(Float64(raw[13])),
        eta_ip=softplus(Float64(raw[14])),
        H_ip=_sigmoid_clipped(raw[15]),
    )
end

function pack_params(p::SORNParams)
    return Float64[
        _inverse_sigmoid(p.inhibitory_fraction),
        _inverse_sigmoid(p.p_ee),
        _inverse_sigmoid(p.p_ei),
        _inverse_sigmoid(p.p_ie),
        _inverse_sigmoid(p.p_input),
        _inverse_sigmoid(p.p_output),
        _inverse_softplus(p.ee_row_sum),
        _inverse_softplus(p.ei_row_sum),
        _inverse_softplus(p.ie_row_sum),
        _inverse_softplus(p.input_row_sum),
        _inverse_softplus(p.T_E_max),
        _inverse_softplus(p.T_I_max),
        _inverse_softplus(p.eta_stdp),
        _inverse_softplus(p.eta_ip),
        _inverse_sigmoid(p.H_ip),
    ]
end

pack_params(::Type{SORNParams}) = pack_params(SORNParams())

_as_sorn_params(p::SORNParams) = p
_as_sorn_params(raw::AbstractVector{<:Real}) = unpack_params(SORNParams, raw)

"""
    SORNReservoir(n_nodes, n_receptors, n_effectors; seed=0, kwargs...)

Experimental research node implementing a Self-Organizing Recurrent Network
(SORN) after Lazar, Pipa, and Triesch (2009), with binary threshold excitatory
and inhibitory populations and online STDP, intrinsic plasticity, and synaptic
normalization on the E->E weights.

This node is intended as an experimental criticality positive-control. It is
algorithmically faithful to the Lazar/Pipa/Triesch update rules, but this
BrainlessLab implementation has not yet been validated to reproduce
avalanche-scaling criticality.

Defaults are deliberately small and tunable: `inhibitory_fraction=0.2`,
`p_ee=0.1`, `p_ei=0.2`, `p_ie=0.2`, `p_input=0.2`, `p_output=0.1`,
row-normalized E->E/E->I/I->E/input weights with unit row sums,
`T_E_i ~ Uniform(0, 0.5)`, `T_I_k ~ Uniform(0, 1.0)`,
`eta_stdp=0.004`, `eta_ip=0.001`, and `H_ip=0.1`. Set
`learn_on=false` to freeze STDP, intrinsic plasticity, and synaptic
normalization while keeping the binary dynamics active.
"""
mutable struct SORNReservoir <: Reservoir
    n_receptors_::Int
    n_effectors_::Int
    N_E::Int
    N_I::Int
    W_EE::Matrix{Float64}
    W_EE0::Matrix{Float64}
    EE_mask::BitMatrix
    C_E::Vector{Float64}
    W_EI::Matrix{Float64}
    W_IE::Matrix{Float64}
    W_EU::Matrix{Float64}
    output_mask::BitMatrix
    T_E::Vector{Float64}
    T_E0::Vector{Float64}
    T_I::Vector{Float64}
    T_I0::Vector{Float64}
    x::Vector{Float64}
    y::Vector{Float64}
    prev_x::Vector{Float64}
    prev_y::Vector{Float64}
    eta_stdp::Float64
    eta_ip::Float64
    H_ip::Float64
    learn_on::Bool
end

function _sorn_float_vector(x, name::AbstractString)
    v = vec(Float64.(x))
    return Vector{Float64}(v)
end

function _sorn_validate_probability(value::Real, name::AbstractString)
    p = Float64(value)
    0.0 <= p <= 1.0 || throw(ArgumentError("$name must be in [0, 1]"))
    return p
end

function _sorn_validate_nonnegative(value::Real, name::AbstractString)
    x = Float64(value)
    x >= 0.0 || throw(ArgumentError("$name must be non-negative"))
    return x
end

function _sorn_rng(seed)
    return seed === nothing ? MersenneTwister() : MersenneTwister(Int(seed))
end

function _sorn_ensure_each_row!(mask::BitMatrix, rng::AbstractRNG; no_self::Bool=false)
    rows, cols = size(mask)
    cols == 0 && return mask

    @inbounds for i in 1:rows
        any(@view mask[i, :]) && continue

        if no_self && rows == cols
            cols <= 1 && continue
            candidates = Int[j for j in 1:cols if j != i]
            mask[i, rand(rng, candidates)] = true
        else
            mask[i, rand(rng, 1:cols)] = true
        end
    end
    return mask
end

function _sorn_ensure_each_col!(mask::BitMatrix, rng::AbstractRNG)
    rows, cols = size(mask)
    rows == 0 && return mask

    @inbounds for j in 1:cols
        any(@view mask[:, j]) || (mask[rand(rng, 1:rows), j] = true)
    end
    return mask
end

function _sorn_row_normalized_weights(mask::BitMatrix, rng::AbstractRNG, row_sum::Real)
    target = Float64(row_sum)
    target >= 0.0 || throw(ArgumentError("row_sum must be non-negative"))

    rows, cols = size(mask)
    weights = zeros(Float64, rows, cols)
    target == 0.0 && return weights

    @inbounds for i in 1:rows
        total = 0.0
        for j in 1:cols
            if mask[i, j]
                w = rand(rng)
                weights[i, j] = w
                total += w
            end
        end
        if total > 0.0
            scale = target / total
            for j in 1:cols
                weights[i, j] *= scale
            end
        end
    end

    return weights
end

function _sorn_init_masks(
    N_E::Integer,
    N_I::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer,
    rng::AbstractRNG;
    p_ee::Real,
    p_ei::Real,
    p_ie::Real,
    p_input::Real,
    p_output::Real,
)
    ee_mask = bernoulli_mask(N_E, N_E, p_ee, rng; diagonal=false)
    ei_mask = bernoulli_mask(N_E, N_I, p_ei, rng; diagonal=true)
    ie_mask = bernoulli_mask(N_I, N_E, p_ie, rng; diagonal=true)
    input_mask = bernoulli_mask(N_E, n_receptors_, p_input, rng; diagonal=true)
    output_mask = bernoulli_mask(N_E, n_effectors_, p_output, rng; diagonal=true)

    _sorn_ensure_each_row!(ee_mask, rng; no_self=true)
    _sorn_ensure_each_row!(ei_mask, rng)
    _sorn_ensure_each_row!(ie_mask, rng)
    _sorn_ensure_each_row!(input_mask, rng)
    _sorn_ensure_each_col!(output_mask, rng)

    return ee_mask, ei_mask, ie_mask, input_mask, output_mask
end

function SORNReservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    inhibitory_fraction::Real=0.2,
    p_ee::Real=0.1,
    p_ei::Real=0.2,
    p_ie::Real=0.2,
    p_input::Real=0.2,
    p_output::Real=0.1,
    ee_row_sum::Real=1.0,
    ei_row_sum::Real=1.0,
    ie_row_sum::Real=1.0,
    input_row_sum::Real=1.0,
    T_E_max::Real=0.5,
    T_I_max::Real=1.0,
    eta_stdp::Real=0.004,
    eta_ip::Real=0.001,
    H_ip::Real=0.1,
    learn_on::Bool=true,
    kwargs...,
)
    N_E = Int(n_nodes)
    n_receptors_i = Int(n_receptors_)
    n_effectors_i = Int(n_effectors_)
    N_E >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_i >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_i >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    inhibitory_fraction = _sorn_validate_probability(inhibitory_fraction, "inhibitory_fraction")
    N_I = round(Int, inhibitory_fraction * N_E)

    p_ee = _sorn_validate_probability(p_ee, "p_ee")
    p_ei = _sorn_validate_probability(p_ei, "p_ei")
    p_ie = _sorn_validate_probability(p_ie, "p_ie")
    p_input = _sorn_validate_probability(p_input, "p_input")
    p_output = _sorn_validate_probability(p_output, "p_output")

    ee_row_sum = _sorn_validate_nonnegative(ee_row_sum, "ee_row_sum")
    ei_row_sum = _sorn_validate_nonnegative(ei_row_sum, "ei_row_sum")
    ie_row_sum = _sorn_validate_nonnegative(ie_row_sum, "ie_row_sum")
    input_row_sum = _sorn_validate_nonnegative(input_row_sum, "input_row_sum")
    T_E_max = _sorn_validate_nonnegative(T_E_max, "T_E_max")
    T_I_max = _sorn_validate_nonnegative(T_I_max, "T_I_max")
    eta_stdp = _sorn_validate_nonnegative(eta_stdp, "eta_stdp")
    eta_ip = _sorn_validate_nonnegative(eta_ip, "eta_ip")
    H_ip = _sorn_validate_probability(H_ip, "H_ip")

    rng = _sorn_rng(seed)
    ee_mask, ei_mask, ie_mask, input_mask, output_mask = _sorn_init_masks(
        N_E,
        N_I,
        n_receptors_i,
        n_effectors_i,
        rng;
        p_ee=p_ee,
        p_ei=p_ei,
        p_ie=p_ie,
        p_input=p_input,
        p_output=p_output,
    )

    W_EE0 = _sorn_row_normalized_weights(ee_mask, rng, ee_row_sum)
    W_EE = copy(W_EE0)
    C_E = vec(sum(W_EE0; dims=2))
    W_EI = _sorn_row_normalized_weights(ei_mask, rng, ei_row_sum)
    W_IE = _sorn_row_normalized_weights(ie_mask, rng, ie_row_sum)
    W_EU = _sorn_row_normalized_weights(input_mask, rng, input_row_sum)
    T_E0 = T_E_max .* rand(rng, N_E)
    T_I0 = T_I_max .* rand(rng, N_I)

    return SORNReservoir(
        n_receptors_i,
        n_effectors_i,
        N_E,
        N_I,
        W_EE,
        W_EE0,
        ee_mask,
        C_E,
        W_EI,
        W_IE,
        W_EU,
        output_mask,
        copy(T_E0),
        T_E0,
        copy(T_I0),
        T_I0,
        zeros(Float64, N_E),
        zeros(Float64, N_I),
        zeros(Float64, N_E),
        zeros(Float64, N_I),
        Float64(eta_stdp),
        Float64(eta_ip),
        Float64(H_ip),
        Bool(learn_on),
    )
end

function _sorn_stdp!(r::SORNReservoir)
    eta = r.eta_stdp
    @inbounds for j in 1:r.N_E, i in 1:r.N_E
        if r.EE_mask[i, j]
            delta = eta * (r.x[i] * r.prev_x[j] - r.prev_x[i] * r.x[j])
            w = r.W_EE[i, j] + delta
            r.W_EE[i, j] = w > 0.0 ? w : 0.0
        else
            r.W_EE[i, j] = 0.0
        end
    end
    return r
end

function _sorn_intrinsic_plasticity!(r::SORNReservoir)
    eta = r.eta_ip
    target = r.H_ip
    @inbounds for i in 1:r.N_E
        r.T_E[i] += eta * (r.x[i] - target)
    end
    return r
end

function _sorn_synaptic_normalization!(r::SORNReservoir)
    @inbounds for i in 1:r.N_E
        target = r.C_E[i]
        target > 0.0 || continue

        total = 0.0
        for j in 1:r.N_E
            total += r.W_EE[i, j]
        end
        total > 0.0 || continue

        scale = target / total
        for j in 1:r.N_E
            r.W_EE[i, j] *= scale
        end
    end
    return r
end

function _sorn_apply_plasticity!(r::SORNReservoir)
    _sorn_stdp!(r)
    _sorn_intrinsic_plasticity!(r)
    _sorn_synaptic_normalization!(r)
    return r
end

function step!(r::SORNReservoir, receptor_currents)
    R = _sorn_float_vector(receptor_currents, "receptor_currents")
    length(R) == r.n_receptors_ ||
        throw(DimensionMismatch("expected $(r.n_receptors_) receptor currents, got $(length(R))"))

    copyto!(r.prev_x, r.x)
    copyto!(r.prev_y, r.y)

    @inbounds for i in 1:r.N_E
        exc = 0.0
        for j in 1:r.N_E
            exc += r.W_EE[i, j] * r.prev_x[j]
        end

        inh = 0.0
        for k in 1:r.N_I
            inh += r.W_EI[i, k] * r.prev_y[k]
        end

        input = 0.0
        for q in 1:r.n_receptors_
            input += r.W_EU[i, q] * R[q]
        end

        r.x[i] = (exc - inh + input - r.T_E[i]) >= 0.0 ? 1.0 : 0.0
    end

    @inbounds for k in 1:r.N_I
        exc = 0.0
        for j in 1:r.N_E
            exc += r.W_IE[k, j] * r.prev_x[j]
        end
        r.y[k] = (exc - r.T_I[k]) >= 0.0 ? 1.0 : 0.0
    end

    r.learn_on && _sorn_apply_plasticity!(r)
    return copy(r.x)
end

function effectors(r::SORNReservoir, spikes)
    values = _sorn_float_vector(spikes, "spikes")
    length(values) == r.N_E ||
        throw(DimensionMismatch("expected $(r.N_E) spikes, got $(length(values))"))

    out = zeros(Float64, r.n_effectors_)
    @inbounds for k in 1:r.n_effectors_
        count = 0
        total = 0.0
        for i in 1:r.N_E
            if r.output_mask[i, k]
                count += 1
                total += values[i]
            end
        end
        out[k] = count > 0 ? total / Float64(count) : 0.0
    end
    return out
end

effectors(r::SORNReservoir) = effectors(r, r.x)
n_receptors(r::SORNReservoir) = r.n_receptors_
n_effectors(r::SORNReservoir) = r.n_effectors_
plasticity(::SORNReservoir) = OnlinePlasticity()

function reset!(r::SORNReservoir)
    r.W_EE .= r.W_EE0
    r.T_E .= r.T_E0
    r.T_I .= r.T_I0
    fill!(r.x, 0.0)
    fill!(r.y, 0.0)
    fill!(r.prev_x, 0.0)
    fill!(r.prev_y, 0.0)
    return r
end

function snapshot_state(r::SORNReservoir)
    return (
        W_EE=copy(r.W_EE),
        T_E=copy(r.T_E),
        T_I=copy(r.T_I),
        x=copy(r.x),
        y=copy(r.y),
        prev_x=copy(r.prev_x),
        prev_y=copy(r.prev_y),
    )
end

function _sorn_state_get(state, key::Symbol)
    return state isa AbstractDict ? state[key] : getproperty(state, key)
end

function _sorn_load_matrix!(dest::Matrix{Float64}, value, name::AbstractString)
    src = Matrix{Float64}(Float64.(value))
    size(src) == size(dest) ||
        throw(DimensionMismatch("$name size $(size(src)) must be $(size(dest))"))
    copyto!(dest, src)
    return dest
end

function _sorn_load_vector!(dest::Vector{Float64}, value, name::AbstractString)
    src = vec(Float64.(value))
    length(src) == length(dest) ||
        throw(DimensionMismatch("$name length $(length(src)) must be $(length(dest))"))
    copyto!(dest, src)
    return dest
end

function load_state!(r::SORNReservoir, state)
    _sorn_load_matrix!(r.W_EE, _sorn_state_get(state, :W_EE), "state.W_EE")
    _sorn_load_vector!(r.T_E, _sorn_state_get(state, :T_E), "state.T_E")
    _sorn_load_vector!(r.T_I, _sorn_state_get(state, :T_I), "state.T_I")
    _sorn_load_vector!(r.x, _sorn_state_get(state, :x), "state.x")
    _sorn_load_vector!(r.y, _sorn_state_get(state, :y), "state.y")
    _sorn_load_vector!(r.prev_x, _sorn_state_get(state, :prev_x), "state.prev_x")
    _sorn_load_vector!(r.prev_y, _sorn_state_get(state, :prev_y), "state.prev_y")
    return r
end
