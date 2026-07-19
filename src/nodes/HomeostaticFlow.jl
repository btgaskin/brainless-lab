using Random

const HFR_PARAM_DIM = 11
const HFR_EPS = 1.0e-12
const HFR_GAIN_MIN = 0.05
const HFR_GAIN_MAX = 10.0

function _hfr_sigmoid(x::Real)
    xf = Float64(x)
    if xf >= 0.0
        z = exp(-xf)
        return inv(1.0 + z)
    else
        z = exp(xf)
        return z / (1.0 + z)
    end
end

function _hfr_logit01(p::Real)
    pf = clamp(Float64(p), HFR_EPS, 1.0 - HFR_EPS)
    return log(pf / (1.0 - pf))
end

_hfr_range(raw::Real, lo::Real, hi::Real) = Float64(lo) + (Float64(hi) - Float64(lo)) * _hfr_sigmoid(raw)
_hfr_invrange(x::Real, lo::Real, hi::Real) = _hfr_logit01((Float64(x) - Float64(lo)) / (Float64(hi) - Float64(lo)))

"""
    HomeostaticFlowParams(; kwargs...)

Raw-genome parameter bundle for `HomeostaticFlowReservoir`. The stored fields are
unconstrained raw values; accessors map them through fixed monotone bijections into
physical ranges. This makes `pack_params(unpack_params(T, raw))` exactly preserve
the raw Float64 genome.
"""
struct HomeostaticFlowParams <: NodeModel
    leak_raw::Float64
    rho_target_raw::Float64
    input_gain_raw::Float64
    weight_scale_raw::Float64
    eta_flow_raw::Float64
    eta_bias_raw::Float64
    eta_gain_raw::Float64
    ema_rate_raw::Float64
    target_var_raw::Float64
    target_mean_raw::Float64
    weight_limit_raw::Float64
end

function HomeostaticFlowParams(;
    leak::Real=0.35,
    rho_target::Real=0.95,
    input_gain::Real=1.0,
    weight_scale::Real=0.35,
    eta_flow::Real=0.005,
    eta_bias::Real=0.002,
    eta_gain::Real=0.002,
    ema_rate::Real=0.02,
    target_var::Real=0.20,
    target_mean::Real=0.0,
    weight_limit::Real=3.0,
)
    return HomeostaticFlowParams(
        _hfr_invrange(leak, 0.01, 0.99),
        _hfr_invrange(rho_target, 0.10, 1.50),
        _hfr_invrange(input_gain, 0.05, 4.00),
        _hfr_invrange(weight_scale, 0.001, 2.00),
        _hfr_invrange(eta_flow, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_bias, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_gain, 1.0e-6, 5.0e-2),
        _hfr_invrange(ema_rate, 0.001, 0.20),
        _hfr_invrange(target_var, 0.01, 0.50),
        _hfr_invrange(target_mean, -0.50, 0.50),
        _hfr_invrange(weight_limit, 0.05, 5.00),
    )
end

paramdim(::Type{HomeostaticFlowParams}) = HFR_PARAM_DIM
paramdim(::HomeostaticFlowParams) = HFR_PARAM_DIM

function pack_params(p::HomeostaticFlowParams)
    return Float64[
        p.leak_raw,
        p.rho_target_raw,
        p.input_gain_raw,
        p.weight_scale_raw,
        p.eta_flow_raw,
        p.eta_bias_raw,
        p.eta_gain_raw,
        p.ema_rate_raw,
        p.target_var_raw,
        p.target_mean_raw,
        p.weight_limit_raw,
    ]
end

pack_params(::Type{HomeostaticFlowParams}) = pack_params(HomeostaticFlowParams())

function unpack_params(::Type{HomeostaticFlowParams}, raw::AbstractVector{<:Real})::HomeostaticFlowParams
    length(raw) == HFR_PARAM_DIM ||
        throw(DimensionMismatch("HomeostaticFlowParams expects $HFR_PARAM_DIM raw parameters, got $(length(raw))"))
    return HomeostaticFlowParams(
        Float64(raw[1]),
        Float64(raw[2]),
        Float64(raw[3]),
        Float64(raw[4]),
        Float64(raw[5]),
        Float64(raw[6]),
        Float64(raw[7]),
        Float64(raw[8]),
        Float64(raw[9]),
        Float64(raw[10]),
        Float64(raw[11]),
    )
end

_hfr_as_params(p::HomeostaticFlowParams) = p
_hfr_as_params(raw::AbstractVector{<:Real}) = unpack_params(HomeostaticFlowParams, raw)

_hfr_leak(p::HomeostaticFlowParams) = _hfr_range(p.leak_raw, 0.01, 0.99)
_hfr_rho_target(p::HomeostaticFlowParams) = _hfr_range(p.rho_target_raw, 0.10, 1.50)
_hfr_input_gain(p::HomeostaticFlowParams) = _hfr_range(p.input_gain_raw, 0.05, 4.00)
_hfr_weight_scale(p::HomeostaticFlowParams) = _hfr_range(p.weight_scale_raw, 0.001, 2.00)
_hfr_eta_flow(p::HomeostaticFlowParams) = _hfr_range(p.eta_flow_raw, 1.0e-6, 5.0e-2)
_hfr_eta_bias(p::HomeostaticFlowParams) = _hfr_range(p.eta_bias_raw, 1.0e-6, 5.0e-2)
_hfr_eta_gain(p::HomeostaticFlowParams) = _hfr_range(p.eta_gain_raw, 1.0e-6, 5.0e-2)
_hfr_ema_rate(p::HomeostaticFlowParams) = _hfr_range(p.ema_rate_raw, 0.001, 0.20)
_hfr_target_var(p::HomeostaticFlowParams) = _hfr_range(p.target_var_raw, 0.01, 0.50)
_hfr_target_mean(p::HomeostaticFlowParams) = _hfr_range(p.target_mean_raw, -0.50, 0.50)
_hfr_weight_limit(p::HomeostaticFlowParams) = _hfr_range(p.weight_limit_raw, 0.05, 5.00)

function _hfr_probability(x::Real, name::AbstractString)
    p = Float64(x)
    0.0 <= p <= 1.0 || throw(ArgumentError("$name must be in [0, 1]"))
    return p
end

_hfr_rng(seed) = seed === nothing ? MersenneTwister() : MersenneTwister(Int(seed))

function _hfr_bernoulli_mask(rows::Integer, cols::Integer, p::Real, rng::AbstractRNG; diagonal::Bool=true)
    rows_i = Int(rows)
    cols_i = Int(cols)
    mask = falses(rows_i, cols_i)
    @inbounds for j in 1:cols_i, i in 1:rows_i
        if diagonal || i != j
            mask[i, j] = rand(rng) < p
        end
    end
    return mask
end

function _hfr_repair_recurrent!(mask::BitMatrix, rng::AbstractRNG)
    n = size(mask, 1)
    @inbounds for dst in 1:n
        has_in = false
        for src in 1:n
            if mask[src, dst]
                has_in = true
                break
            end
        end
        if !has_in
            src = n == 1 ? 1 : rand(rng, 1:(n - 1))
            if n > 1 && src >= dst
                src += 1
            end
            mask[src, dst] = true
        end
    end
    return mask
end

function _hfr_repair_inputs!(mask::BitMatrix, rng::AbstractRNG)
    n_receptors_, n_nodes = size(mask)
    @inbounds for dst in 1:n_nodes
        has_in = false
        for q in 1:n_receptors_
            if mask[q, dst]
                has_in = true
                break
            end
        end
        has_in || (mask[rand(rng, 1:n_receptors_), dst] = true)
    end
    @inbounds for q in 1:n_receptors_
        has_out = false
        for dst in 1:n_nodes
            if mask[q, dst]
                has_out = true
                break
            end
        end
        has_out || (mask[q, rand(rng, 1:n_nodes)] = true)
    end
    return mask
end

function _hfr_repair_outputs!(mask::BitMatrix, rng::AbstractRNG)
    n_nodes, n_effectors_ = size(mask)
    @inbounds for k in 1:n_effectors_
        has_in = false
        for i in 1:n_nodes
            if mask[i, k]
                has_in = true
                break
            end
        end
        has_in || (mask[rand(rng, 1:n_nodes), k] = true)
    end
    return mask
end

function _hfr_signs(n::Integer, inhibitory_frac::Real, rng::AbstractRNG, signs)
    n_i = Int(n)
    out = Vector{Int}(undef, n_i)
    if signs === nothing
        frac = _hfr_probability(inhibitory_frac, "inhibitory_frac")
        @inbounds for i in 1:n_i
            out[i] = rand(rng) < frac ? -1 : 1
        end
    else
        length(signs) == n_i ||
            throw(DimensionMismatch("sign vector length $(length(signs)) must match n_nodes $n_i"))
        @inbounds for i in 1:n_i
            s = Int(signs[i])
            (s == 1 || s == -1) || throw(ArgumentError("signs must contain only +1 or -1"))
            out[i] = s
        end
    end
    return out
end

function _hfr_init_recurrent(mask::BitMatrix, rng::AbstractRNG, scale::Real)
    n = size(mask, 1)
    w = zeros(Float64, n, n)
    scale_f = Float64(scale)
    @inbounds for dst in 1:n
        indeg = 0
        for src in 1:n
            mask[src, dst] && (indeg += 1)
        end
        s = scale_f / sqrt(Float64(max(indeg, 1)))
        for src in 1:n
            if mask[src, dst]
                w[src, dst] = s * (0.5 + rand(rng))
            end
        end
    end
    return w
end

function _hfr_init_input(mask::BitMatrix, rng::AbstractRNG, gain::Real)
    n_receptors_, n_nodes = size(mask)
    w = zeros(Float64, n_receptors_, n_nodes)
    gain_f = Float64(gain)
    @inbounds for dst in 1:n_nodes
        indeg = 0
        for q in 1:n_receptors_
            mask[q, dst] && (indeg += 1)
        end
        s = gain_f / sqrt(Float64(max(indeg, 1)))
        for q in 1:n_receptors_
            if mask[q, dst]
                w[q, dst] = s * (2.0 * rand(rng) - 1.0)
            end
        end
    end
    return w
end

mutable struct HomeostaticFlowReservoir <: Reservoir
    params::HomeostaticFlowParams
    n_nodes_::Int
    n_receptors_::Int
    n_effectors_::Int
    signs::Vector{Int}
    recurrent_mask::BitMatrix
    input_mask::BitMatrix
    output_mask::BitMatrix
    input_wmat::Matrix{Float64}
    wmat::Matrix{Float64}
    wmat0::Matrix{Float64}
    v::Vector{Float64}
    rates::Vector{Float64}
    prev_rates::Vector{Float64}
    input_current::Vector{Float64}
    recurrent_current::Vector{Float64}
    mean_rate::Vector{Float64}
    mean_sq_rate::Vector{Float64}
    bias::Vector{Float64}
    bias0::Vector{Float64}
    gain::Vector{Float64}
    gain0::Vector{Float64}
    effector_buffer::Vector{Float64}
    learn_on::Bool
end

function HomeostaticFlowReservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    params=HomeostaticFlowParams(),
    link_p::Real=0.1,
    input_p=nothing,
    output_p=nothing,
    inhibitory_frac::Real=0.25,
    signs=nothing,
    learn_on::Bool=true,
    kwargs...,
)
    n_nodes_i = Int(n_nodes)
    n_receptors_i = Int(n_receptors_)
    n_effectors_i = Int(n_effectors_)
    n_nodes_i >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_i >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_i >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    p = _hfr_as_params(params)
    link_p_ = _hfr_probability(link_p, "link_p")
    input_p_ = input_p === nothing ? link_p_ : _hfr_probability(input_p, "input_p")
    output_p_ = output_p === nothing ? link_p_ : _hfr_probability(output_p, "output_p")
    rng = _hfr_rng(seed)

    recurrent_mask = _hfr_bernoulli_mask(n_nodes_i, n_nodes_i, link_p_, rng; diagonal=false)
    input_mask = _hfr_bernoulli_mask(n_receptors_i, n_nodes_i, input_p_, rng; diagonal=true)
    output_mask = _hfr_bernoulli_mask(n_nodes_i, n_effectors_i, output_p_, rng; diagonal=true)
    _hfr_repair_recurrent!(recurrent_mask, rng)
    _hfr_repair_inputs!(input_mask, rng)
    _hfr_repair_outputs!(output_mask, rng)

    signs_ = _hfr_signs(n_nodes_i, inhibitory_frac, rng, signs)
    input_wmat = _hfr_init_input(input_mask, rng, _hfr_input_gain(p))
    wmat0 = _hfr_init_recurrent(recurrent_mask, rng, _hfr_weight_scale(p))
    bias0 = zeros(Float64, n_nodes_i)
    gain0 = ones(Float64, n_nodes_i)

    return HomeostaticFlowReservoir(
        p,
        n_nodes_i,
        n_receptors_i,
        n_effectors_i,
        signs_,
        recurrent_mask,
        input_mask,
        output_mask,
        input_wmat,
        copy(wmat0),
        wmat0,
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_nodes_i),
        zeros(Float64, n_nodes_i),
        copy(bias0),
        bias0,
        copy(gain0),
        gain0,
        zeros(Float64, n_effectors_i),
        Bool(learn_on),
    )
end

# The instance's own learn_on toggle decides adaptation, not the type family, so
# the trait is read off the field rather than declared once for the whole type.
plasticity(r::HomeostaticFlowReservoir) = r.learn_on ? OnlinePlasticity() : NoPlasticity()

function _hfr_intrinsic!(r::HomeostaticFlowReservoir, p::HomeostaticFlowParams)
    alpha = _hfr_ema_rate(p)
    keep = 1.0 - alpha
    eta_bias = _hfr_eta_bias(p)
    eta_gain = _hfr_eta_gain(p)
    target_mean = _hfr_target_mean(p)
    target_var = _hfr_target_var(p)

    @inbounds for i in 1:r.n_nodes_
        y = r.rates[i]
        m = keep * r.mean_rate[i] + alpha * y
        q = keep * r.mean_sq_rate[i] + alpha * y * y
        r.mean_rate[i] = m
        r.mean_sq_rate[i] = q

        var = q - m * m
        var < 0.0 && (var = 0.0)

        r.bias[i] += eta_bias * (m - target_mean)
        g = r.gain[i] * exp(eta_gain * (target_var - var))
        if g < HFR_GAIN_MIN
            r.gain[i] = HFR_GAIN_MIN
        elseif g > HFR_GAIN_MAX
            r.gain[i] = HFR_GAIN_MAX
        else
            r.gain[i] = g
        end
    end
    return r
end

function _hfr_flow_control!(r::HomeostaticFlowReservoir, p::HomeostaticFlowParams)
    eta = _hfr_eta_flow(p)
    rho = _hfr_rho_target(p)
    rho2 = rho * rho
    limit = _hfr_weight_limit(p)

    @inbounds for dst in 1:r.n_nodes_
        rec = r.recurrent_current[dst]
        y = r.rates[dst]
        rec2 = rec * rec
        target2 = rho2 * y * y
        denom = HFR_EPS + rec2 + target2
        scale = exp(eta * (target2 - rec2) / denom)

        for src in 1:r.n_nodes_
            if r.recurrent_mask[src, dst]
                w = r.wmat[src, dst] * scale
                r.wmat[src, dst] = w > limit ? limit : w
            else
                r.wmat[src, dst] = 0.0
            end
        end
    end
    return r
end

function step!(r::HomeostaticFlowReservoir, receptor_currents::AbstractVector)
    length(receptor_currents) == r.n_receptors_ ||
        throw(DimensionMismatch("expected $(r.n_receptors_) receptor currents, got $(length(receptor_currents))"))

    p = r.params
    leak = _hfr_leak(p)
    keep = 1.0 - leak
    copyto!(r.prev_rates, r.rates)

    @inbounds for dst in 1:r.n_nodes_
        input_current = 0.0
        for q in 1:r.n_receptors_
            input_current += Float64(receptor_currents[q]) * r.input_wmat[q, dst]
        end
        r.input_current[dst] = input_current

        recurrent_current = 0.0
        for src in 1:r.n_nodes_
            if r.recurrent_mask[src, dst]
                recurrent_current += r.prev_rates[src] * Float64(r.signs[src]) * r.wmat[src, dst]
            end
        end
        r.recurrent_current[dst] = recurrent_current
    end

    @inbounds for i in 1:r.n_nodes_
        drive = r.input_current[i] + r.recurrent_current[i] - r.bias[i]
        r.v[i] = keep * r.v[i] + leak * drive
        r.rates[i] = tanh(r.gain[i] * r.v[i])
    end

    if r.learn_on
        _hfr_intrinsic!(r, p)
        _hfr_flow_control!(r, p)
    end

    return copy(r.rates)
end

function effectors(r::HomeostaticFlowReservoir, state::AbstractVector)
    length(state) == r.n_nodes_ ||
        throw(DimensionMismatch("expected $(r.n_nodes_) node states, got $(length(state))"))

    fill!(r.effector_buffer, 0.0)
    @inbounds for k in 1:r.n_effectors_
        total = 0.0
        count = 0
        for i in 1:r.n_nodes_
            if r.output_mask[i, k]
                total += Float64(state[i])
                count += 1
            end
        end
        count > 0 && (r.effector_buffer[k] = total / Float64(count))
    end
    return copy(r.effector_buffer)
end

effectors(r::HomeostaticFlowReservoir) = effectors(r, r.rates)
n_receptors(r::HomeostaticFlowReservoir) = r.n_receptors_
n_effectors(r::HomeostaticFlowReservoir) = r.n_effectors_
n_nodes(r::HomeostaticFlowReservoir) = r.n_nodes_

function reset!(r::HomeostaticFlowReservoir)
    copyto!(r.wmat, r.wmat0)
    copyto!(r.bias, r.bias0)
    copyto!(r.gain, r.gain0)
    fill!(r.v, 0.0)
    fill!(r.rates, 0.0)
    fill!(r.prev_rates, 0.0)
    fill!(r.input_current, 0.0)
    fill!(r.recurrent_current, 0.0)
    fill!(r.mean_rate, 0.0)
    fill!(r.mean_sq_rate, 0.0)
    fill!(r.effector_buffer, 0.0)
    return r
end

function snapshot_state(r::HomeostaticFlowReservoir)
    return (
        wmat=copy(r.wmat),
        v=copy(r.v),
        rates=copy(r.rates),
        prev_rates=copy(r.prev_rates),
        input_current=copy(r.input_current),
        recurrent_current=copy(r.recurrent_current),
        mean_rate=copy(r.mean_rate),
        mean_sq_rate=copy(r.mean_sq_rate),
        bias=copy(r.bias),
        gain=copy(r.gain),
        effector_buffer=copy(r.effector_buffer),
    )
end

_hfr_state_get(state, key::Symbol) = state isa AbstractDict ? state[key] : getproperty(state, key)

function _hfr_load_vector!(dest::Vector{Float64}, value, name::AbstractString)
    length(value) == length(dest) ||
        throw(DimensionMismatch("$name length $(length(value)) must be $(length(dest))"))
    @inbounds for i in eachindex(dest)
        dest[i] = Float64(value[i])
    end
    return dest
end

function _hfr_load_matrix!(dest::Matrix{Float64}, value, name::AbstractString)
    size(value) == size(dest) ||
        throw(DimensionMismatch("$name size $(size(value)) must be $(size(dest))"))
    @inbounds for j in axes(dest, 2), i in axes(dest, 1)
        dest[i, j] = Float64(value[i, j])
    end
    return dest
end

function load_state!(r::HomeostaticFlowReservoir, state)
    _hfr_load_matrix!(r.wmat, _hfr_state_get(state, :wmat), "state.wmat")
    _hfr_load_vector!(r.v, _hfr_state_get(state, :v), "state.v")
    _hfr_load_vector!(r.rates, _hfr_state_get(state, :rates), "state.rates")
    _hfr_load_vector!(r.prev_rates, _hfr_state_get(state, :prev_rates), "state.prev_rates")
    _hfr_load_vector!(r.input_current, _hfr_state_get(state, :input_current), "state.input_current")
    _hfr_load_vector!(r.recurrent_current, _hfr_state_get(state, :recurrent_current), "state.recurrent_current")
    _hfr_load_vector!(r.mean_rate, _hfr_state_get(state, :mean_rate), "state.mean_rate")
    _hfr_load_vector!(r.mean_sq_rate, _hfr_state_get(state, :mean_sq_rate), "state.mean_sq_rate")
    _hfr_load_vector!(r.bias, _hfr_state_get(state, :bias), "state.bias")
    _hfr_load_vector!(r.gain, _hfr_state_get(state, :gain), "state.gain")
    _hfr_load_vector!(r.effector_buffer, _hfr_state_get(state, :effector_buffer), "state.effector_buffer")
    return r
end
