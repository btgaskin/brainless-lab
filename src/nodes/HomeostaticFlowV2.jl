using Random

const HFR2_PARAM_DIM = 28
const HFR2_EPS = 1.0e-12
const HFR2_GAIN_MIN = 0.05
const HFR2_GAIN_MAX = 10.0

"""
    HomeostaticFlowV2Params(; kwargs...)

Raw-genome parameter bundle for `HomeostaticFlowV2Reservoir`. Same unconstrained-raw /
monotone-bijection convention as `HomeostaticFlowParams`: `pack_params(unpack_params(T, raw))`
exactly preserves the raw `Float64` genome.
"""
struct HomeostaticFlowV2Params <: NodeModel
    leak_mean_raw::Float64
    leak_std_raw::Float64
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
    eta_in_raw::Float64
    receptor_ema_rate_raw::Float64
    input_weight_limit_raw::Float64
    eta_rec_raw::Float64
    eta_decay_raw::Float64
    eta_inh_raw::Float64
    target_rate_raw::Float64
    novelty_ema_rate_raw::Float64
    gate_max_raw::Float64
    eta_out_bias_raw::Float64
    eta_out_gain_raw::Float64
    target_E_var_raw::Float64
    output_tonic_raw::Float64
    output_contrast_raw::Float64
    readout_var_floor_raw::Float64
    readout_clip_raw::Float64
end

function HomeostaticFlowV2Params(;
    leak_mean::Real=0.35,
    leak_std::Real=0.05,
    rho_target::Real=0.95,
    input_gain::Real=1.0,
    weight_scale::Real=0.35,
    eta_flow::Real=0.005,
    eta_bias::Real=0.002,
    eta_gain::Real=0.002,
    ema_rate::Real=0.02,
    target_var::Real=0.05,
    target_mean::Real=0.2,
    weight_limit::Real=3.0,
    eta_in::Real=0.01,
    receptor_ema_rate::Real=0.02,
    input_weight_limit::Real=2.0,
    eta_rec::Real=0.01,
    eta_decay::Real=0.001,
    eta_inh::Real=0.01,
    target_rate::Real=0.2,
    novelty_ema_rate::Real=0.02,
    gate_max::Real=3.0,
    eta_out_bias::Real=0.002,
    eta_out_gain::Real=0.002,
    target_E_var::Real=0.05,
    output_tonic::Real=1.0,
    output_contrast::Real=0.35,
    readout_var_floor::Real=0.01,
    readout_clip::Real=3.0,
)
    return HomeostaticFlowV2Params(
        _hfr_invrange(leak_mean, 0.01, 0.99),
        _hfr_invrange(leak_std, 0.0, 0.4),
        _hfr_invrange(rho_target, 0.10, 1.50),
        _hfr_invrange(input_gain, 0.05, 4.00),
        _hfr_invrange(weight_scale, 0.001, 2.00),
        _hfr_invrange(eta_flow, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_bias, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_gain, 1.0e-6, 5.0e-2),
        _hfr_invrange(ema_rate, 0.001, 0.20),
        _hfr_invrange(target_var, 0.001, 0.25),
        _hfr_invrange(target_mean, 0.02, 0.60),
        _hfr_invrange(weight_limit, 0.05, 5.00),
        _hfr_invrange(eta_in, 1.0e-6, 5.0e-2),
        _hfr_invrange(receptor_ema_rate, 0.001, 0.20),
        _hfr_invrange(input_weight_limit, 0.05, 5.00),
        _hfr_invrange(eta_rec, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_decay, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_inh, 1.0e-6, 5.0e-2),
        _hfr_invrange(target_rate, 0.02, 0.60),
        _hfr_invrange(novelty_ema_rate, 0.001, 0.20),
        _hfr_invrange(gate_max, 0.1, 5.0),
        _hfr_invrange(eta_out_bias, 1.0e-6, 5.0e-2),
        _hfr_invrange(eta_out_gain, 1.0e-6, 5.0e-2),
        _hfr_invrange(target_E_var, 0.01, 1.00),
        _hfr_invrange(output_tonic, 0.0, 2.0),
        _hfr_invrange(output_contrast, 0.05, 1.50),
        _hfr_invrange(readout_var_floor, 1.0e-4, 0.10),
        _hfr_invrange(readout_clip, 1.0, 6.0),
    )
end

paramdim(::Type{HomeostaticFlowV2Params}) = HFR2_PARAM_DIM
paramdim(::HomeostaticFlowV2Params) = HFR2_PARAM_DIM

function pack_params(p::HomeostaticFlowV2Params)
    return Float64[
        p.leak_mean_raw, p.leak_std_raw, p.rho_target_raw, p.input_gain_raw,
        p.weight_scale_raw, p.eta_flow_raw, p.eta_bias_raw, p.eta_gain_raw,
        p.ema_rate_raw, p.target_var_raw, p.target_mean_raw, p.weight_limit_raw,
        p.eta_in_raw, p.receptor_ema_rate_raw, p.input_weight_limit_raw,
        p.eta_rec_raw, p.eta_decay_raw, p.eta_inh_raw, p.target_rate_raw,
        p.novelty_ema_rate_raw, p.gate_max_raw, p.eta_out_bias_raw,
        p.eta_out_gain_raw, p.target_E_var_raw,
        p.output_tonic_raw, p.output_contrast_raw, p.readout_var_floor_raw, p.readout_clip_raw,
    ]
end

pack_params(::Type{HomeostaticFlowV2Params}) = pack_params(HomeostaticFlowV2Params())

function unpack_params(::Type{HomeostaticFlowV2Params}, raw::AbstractVector{<:Real})::HomeostaticFlowV2Params
    length(raw) == HFR2_PARAM_DIM ||
        throw(DimensionMismatch("HomeostaticFlowV2Params expects $HFR2_PARAM_DIM raw parameters, got $(length(raw))"))
    return HomeostaticFlowV2Params((Float64(raw[i]) for i in 1:HFR2_PARAM_DIM)...)
end

_hfr2_as_params(p::HomeostaticFlowV2Params) = p
_hfr2_as_params(raw::AbstractVector{<:Real}) = unpack_params(HomeostaticFlowV2Params, raw)

_hfr2_leak_mean(p::HomeostaticFlowV2Params) = _hfr_range(p.leak_mean_raw, 0.01, 0.99)
_hfr2_leak_std(p::HomeostaticFlowV2Params) = _hfr_range(p.leak_std_raw, 0.0, 0.4)
_hfr2_rho_target(p::HomeostaticFlowV2Params) = _hfr_range(p.rho_target_raw, 0.10, 1.50)
_hfr2_input_gain(p::HomeostaticFlowV2Params) = _hfr_range(p.input_gain_raw, 0.05, 4.00)
_hfr2_weight_scale(p::HomeostaticFlowV2Params) = _hfr_range(p.weight_scale_raw, 0.001, 2.00)
_hfr2_eta_flow(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_flow_raw, 1.0e-6, 5.0e-2)
_hfr2_eta_bias(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_bias_raw, 1.0e-6, 5.0e-2)
_hfr2_eta_gain(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_gain_raw, 1.0e-6, 5.0e-2)
_hfr2_ema_rate(p::HomeostaticFlowV2Params) = _hfr_range(p.ema_rate_raw, 0.001, 0.20)
_hfr2_target_var(p::HomeostaticFlowV2Params) = _hfr_range(p.target_var_raw, 0.001, 0.25)
_hfr2_target_mean(p::HomeostaticFlowV2Params) = _hfr_range(p.target_mean_raw, 0.02, 0.60)
_hfr2_weight_limit(p::HomeostaticFlowV2Params) = _hfr_range(p.weight_limit_raw, 0.05, 5.00)
_hfr2_eta_in(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_in_raw, 1.0e-6, 5.0e-2)
_hfr2_receptor_ema_rate(p::HomeostaticFlowV2Params) = _hfr_range(p.receptor_ema_rate_raw, 0.001, 0.20)
_hfr2_input_weight_limit(p::HomeostaticFlowV2Params) = _hfr_range(p.input_weight_limit_raw, 0.05, 5.00)
_hfr2_eta_rec(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_rec_raw, 1.0e-6, 5.0e-2)
_hfr2_eta_decay(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_decay_raw, 1.0e-6, 5.0e-2)
_hfr2_eta_inh(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_inh_raw, 1.0e-6, 5.0e-2)
_hfr2_target_rate(p::HomeostaticFlowV2Params) = _hfr_range(p.target_rate_raw, 0.02, 0.60)
_hfr2_novelty_ema_rate(p::HomeostaticFlowV2Params) = _hfr_range(p.novelty_ema_rate_raw, 0.001, 0.20)
_hfr2_gate_max(p::HomeostaticFlowV2Params) = _hfr_range(p.gate_max_raw, 0.1, 5.0)
_hfr2_eta_out_bias(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_out_bias_raw, 1.0e-6, 5.0e-2)
_hfr2_eta_out_gain(p::HomeostaticFlowV2Params) = _hfr_range(p.eta_out_gain_raw, 1.0e-6, 5.0e-2)
_hfr2_target_E_var(p::HomeostaticFlowV2Params) = _hfr_range(p.target_E_var_raw, 0.01, 1.00)
_hfr2_output_tonic(p::HomeostaticFlowV2Params) = _hfr_range(p.output_tonic_raw, 0.0, 2.0)
_hfr2_output_contrast(p::HomeostaticFlowV2Params) = _hfr_range(p.output_contrast_raw, 0.05, 1.50)
_hfr2_readout_var_floor(p::HomeostaticFlowV2Params) = _hfr_range(p.readout_var_floor_raw, 1.0e-4, 0.10)
_hfr2_readout_clip(p::HomeostaticFlowV2Params) = _hfr_range(p.readout_clip_raw, 1.0, 6.0)

function _hfr2_leaks(n::Integer, leak_mean::Real, leak_std::Real, rng::AbstractRNG, heterogeneous::Bool)
    n_i = Int(n)
    out = fill(Float64(leak_mean), n_i)
    if heterogeneous && leak_std > 0.0
        @inbounds for i in 1:n_i
            out[i] = clamp(Float64(leak_mean) + Float64(leak_std) * randn(rng), 0.01, 0.99)
        end
    end
    return out
end

# Balanced output matrix: every effector column gets an equal fan-in (from the
# structural mask), signs split as evenly as possible and shuffled per column,
# and entries scaled by 1/sqrt(fan_in). This is not orthogonalization, but it
# rules out the systematic near-identical-columns collapse a naive masked
# average is prone to -- cheap, structural, and not task-directed.
function _hfr2_balanced_output_matrix(mask::BitMatrix, rng::AbstractRNG)
    n_nodes, n_eff = size(mask)
    w = zeros(Float64, n_nodes, n_eff)
    @inbounds for k in 1:n_eff
        idx = findall(@view mask[:, k])
        isempty(idx) && continue
        m = length(idx)
        n_pos = cld(m, 2)
        col_signs = vcat(fill(1.0, n_pos), fill(-1.0, m - n_pos))
        shuffle!(rng, col_signs)
        scale = 1.0 / sqrt(Float64(m))
        for (j, i) in enumerate(idx)
            w[i, k] = col_signs[j] * scale * (0.75 + 0.5 * rand(rng))
        end
    end
    return w
end

function _hfr2_masked_average_matrix(mask::BitMatrix)
    n_nodes, n_eff = size(mask)
    w = zeros(Float64, n_nodes, n_eff)
    @inbounds for k in 1:n_eff
        count = 0
        for i in 1:n_nodes
            mask[i, k] && (count += 1)
        end
        count == 0 && continue
        share = 1.0 / Float64(count)
        for i in 1:n_nodes
            mask[i, k] && (w[i, k] = share)
        end
    end
    return w
end

mutable struct HomeostaticFlowV2Reservoir <: Reservoir
    params::HomeostaticFlowV2Params
    n_nodes_::Int
    n_receptors_::Int
    n_effectors_::Int
    signs::Vector{Int}
    recurrent_mask::BitMatrix
    input_mask::BitMatrix
    output_mask::BitMatrix
    input_wmat::Matrix{Float64}
    input_wmat0::Matrix{Float64}
    wmat::Matrix{Float64}
    wmat0::Matrix{Float64}
    output_wmat::Matrix{Float64}
    leak::Vector{Float64}
    v::Vector{Float64}
    a::Vector{Float64}
    prev_a::Vector{Float64}
    input_current::Vector{Float64}
    prev_input_current::Vector{Float64}
    recurrent_current::Vector{Float64}
    rec_gain::Vector{Float64}
    mean_a::Vector{Float64}
    mean_sq_a::Vector{Float64}
    mean_a0::Vector{Float64}
    mean_sq_a0::Vector{Float64}
    bias::Vector{Float64}
    bias0::Vector{Float64}
    gain::Vector{Float64}
    gain0::Vector{Float64}
    centered::Vector{Float64}
    receptor_mean::Vector{Float64}
    mean_abs_delta_input::Vector{Float64}
    gate::Vector{Float64}
    out_bias::Vector{Float64}
    out_gain::Vector{Float64}
    mean_E::Vector{Float64}
    mean_sq_E::Vector{Float64}
    last_E::Vector{Float64}
    effector_buffer::Vector{Float64}
    heterogeneous_leaks::Bool
    input_plasticity::Bool
    recurrent_plasticity::Bool
    novelty_gate::Bool
    output_mode::Symbol
    learn_on::Bool
end

function HomeostaticFlowV2Reservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    params=HomeostaticFlowV2Params(),
    link_p::Real=0.1,
    input_p=nothing,
    output_p=nothing,
    inhibitory_frac::Real=0.25,
    signs=nothing,
    learn_on::Bool=true,
    heterogeneous_leaks::Bool=true,
    input_plasticity::Bool=true,
    recurrent_plasticity::Bool=true,
    novelty_gate::Bool=true,
    output_mode::Union{Symbol,AbstractString}=:tonic_balanced,
    kwargs...,
)
    n_nodes_i = Int(n_nodes)
    n_receptors_i = Int(n_receptors_)
    n_effectors_i = Int(n_effectors_)
    n_nodes_i >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_i >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_i >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    output_mode_sym = Symbol(output_mode)
    output_mode_sym in (:balanced, :masked_average, :tonic_balanced) ||
        throw(ArgumentError("unknown output_mode :$(output_mode_sym) (expected :balanced, :masked_average, or :tonic_balanced)"))

    p = _hfr2_as_params(params)
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
    input_wmat = _hfr_init_input(input_mask, rng, _hfr2_input_gain(p))
    wmat0 = _hfr_init_recurrent(recurrent_mask, rng, _hfr2_weight_scale(p))
    output_wmat = output_mode_sym === :masked_average ?
        _hfr2_masked_average_matrix(output_mask) :
        _hfr2_balanced_output_matrix(output_mask, rng)

    leak = _hfr2_leaks(n_nodes_i, _hfr2_leak_mean(p), _hfr2_leak_std(p), rng, heterogeneous_leaks)

    target_mean0 = _hfr2_target_mean(p)
    mean_a0 = fill(target_mean0, n_nodes_i)
    mean_sq_a0 = fill(target_mean0^2, n_nodes_i)
    bias0 = zeros(Float64, n_nodes_i)
    gain0 = ones(Float64, n_nodes_i)

    return HomeostaticFlowV2Reservoir(
        p, n_nodes_i, n_receptors_i, n_effectors_i, signs_,
        recurrent_mask, input_mask, output_mask,
        input_wmat, copy(input_wmat), copy(wmat0), wmat0, output_wmat,
        leak,
        zeros(Float64, n_nodes_i),                # v
        copy(mean_a0),                            # a (start at target, not 0 -- avoids a cold silent start)
        copy(mean_a0),                            # prev_a
        zeros(Float64, n_nodes_i),                # input_current
        zeros(Float64, n_nodes_i),                # prev_input_current
        zeros(Float64, n_nodes_i),                # recurrent_current
        ones(Float64, n_nodes_i),                 # rec_gain
        copy(mean_a0), copy(mean_sq_a0), mean_a0, mean_sq_a0,
        copy(bias0), bias0, copy(gain0), gain0,
        zeros(Float64, n_nodes_i),                 # centered
        zeros(Float64, n_receptors_i),              # receptor_mean
        zeros(Float64, n_nodes_i),                  # mean_abs_delta_input
        ones(Float64, n_nodes_i),                   # gate
        zeros(Float64, n_effectors_i),               # out_bias
        ones(Float64, n_effectors_i),                # out_gain
        zeros(Float64, n_effectors_i),                # mean_E
        zeros(Float64, n_effectors_i),                # mean_sq_E
        zeros(Float64, n_effectors_i),                # last_E
        zeros(Float64, n_effectors_i),                # effector_buffer
        heterogeneous_leaks, input_plasticity, recurrent_plasticity, novelty_gate,
        output_mode_sym, Bool(learn_on),
    )
end

# The instance's own learn_on toggle decides whether any of the online loops
# (intrinsic homeostasis, flow control, input/recurrent plasticity, output
# homeostasis) run, so the trait is read off the field rather than fixed per type.
plasticity(r::HomeostaticFlowV2Reservoir) = r.learn_on ? OnlinePlasticity() : NoPlasticity()

# Output-channel homeostasis runs here, at the top of the *next* step!, reading
# last tick's `last_E` -- not inside `effectors` -- so that `effectors` stays a
# pure read+shape function and every mutation of persistent learning state
# happens inside step!, matching the rest of the node's design.
#
# For :tonic_balanced this is a no-op: the z-scored contrast readout already
# gives out_gain=1 the correct analytic scale (unit-variance z times a
# unit-norm output column), and the tonic term is a deliberate nonzero-mean
# drive, not a homeostatic target of zero -- letting out_bias chase mean(E)
# toward zero here would fight the tonic term it is supposed to preserve.
# Equalization stays available for the legacy :balanced/:masked_average modes,
# where there is no tonic term to protect.
function _hfr2_output_homeostasis!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params)
    r.output_mode === :tonic_balanced && return r

    alpha = _hfr2_novelty_ema_rate(p)
    keep = 1.0 - alpha
    eta_bias = _hfr2_eta_out_bias(p)
    eta_gain = _hfr2_eta_out_gain(p)
    target_var = _hfr2_target_E_var(p)

    @inbounds for k in 1:r.n_effectors_
        e = r.last_E[k]
        m = keep * r.mean_E[k] + alpha * e
        q = keep * r.mean_sq_E[k] + alpha * e * e
        r.mean_E[k] = m
        r.mean_sq_E[k] = q
        var = q - m * m
        var < 0.0 && (var = 0.0)

        r.out_bias[k] += eta_bias * m
        g = r.out_gain[k] * exp(eta_gain * (target_var - var))
        r.out_gain[k] = clamp(g, HFR2_GAIN_MIN, HFR2_GAIN_MAX)
    end
    return r
end

function _hfr2_intrinsic!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params)
    alpha = _hfr2_ema_rate(p)
    keep = 1.0 - alpha
    eta_bias = _hfr2_eta_bias(p)
    eta_gain = _hfr2_eta_gain(p)
    target_mean = _hfr2_target_mean(p)
    target_var = _hfr2_target_var(p)

    @inbounds for i in 1:r.n_nodes_
        act = r.a[i]
        m = keep * r.mean_a[i] + alpha * act
        q = keep * r.mean_sq_a[i] + alpha * act * act
        r.mean_a[i] = m
        r.mean_sq_a[i] = q

        var = q - m * m
        var < 0.0 && (var = 0.0)

        r.bias[i] += eta_bias * (m - target_mean)
        g = r.gain[i] * exp(eta_gain * (target_var - var))
        r.gain[i] = clamp(g, HFR2_GAIN_MIN, HFR2_GAIN_MAX)
    end
    return r
end

function _hfr2_flow_control!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params)
    eta = _hfr2_eta_flow(p)
    rho2 = _hfr2_rho_target(p)^2
    @inbounds for dst in 1:r.n_nodes_
        gated_rec = r.rec_gain[dst] * r.recurrent_current[dst]
        target2 = rho2 * r.a[dst] * r.a[dst]
        rec2 = gated_rec * gated_rec
        denom = HFR2_EPS + target2 + rec2
        scale = exp(eta * (target2 - rec2) / denom)
        r.rec_gain[dst] = clamp(r.rec_gain[dst] * scale, HFR2_GAIN_MIN, HFR2_GAIN_MAX)
    end
    return r
end

function _hfr2_novelty!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params)
    alpha = _hfr2_novelty_ema_rate(p)
    keep = 1.0 - alpha
    gate_max = _hfr2_gate_max(p)
    @inbounds for dst in 1:r.n_nodes_
        delta = abs(r.input_current[dst] - r.prev_input_current[dst])
        r.mean_abs_delta_input[dst] = keep * r.mean_abs_delta_input[dst] + alpha * delta
        r.gate[dst] = r.novelty_gate ?
            clamp(delta / (r.mean_abs_delta_input[dst] + HFR2_EPS), 0.0, gate_max) :
            1.0
    end
    return r
end

function _hfr2_input_plasticity!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params, receptor_currents)
    alpha = _hfr2_receptor_ema_rate(p)
    keep = 1.0 - alpha
    @inbounds for q in 1:r.n_receptors_
        r.receptor_mean[q] = keep * r.receptor_mean[q] + alpha * Float64(receptor_currents[q])
    end

    eta = _hfr2_eta_in(p)
    limit = _hfr2_input_weight_limit(p)
    @inbounds for dst in 1:r.n_nodes_
        act = r.a[dst]
        eta_eff = eta * r.gate[dst]
        for q in 1:r.n_receptors_
            if r.input_mask[q, dst]
                r_hat = Float64(receptor_currents[q]) - r.receptor_mean[q]
                w = r.input_wmat[q, dst]
                dw = eta_eff * act * (r_hat - act * w)
                w2 = w + dw
                r.input_wmat[q, dst] = clamp(w2, -limit, limit)
            end
        end
    end
    return r
end

function _hfr2_recurrent_plasticity!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params)
    eta_rec = _hfr2_eta_rec(p)
    eta_decay = _hfr2_eta_decay(p)
    eta_inh = _hfr2_eta_inh(p)
    target_rate = _hfr2_target_rate(p)
    limit = _hfr2_weight_limit(p)

    @inbounds for dst in 1:r.n_nodes_
        theta = r.mean_sq_a[dst] / (r.mean_a[dst] + HFR2_EPS)
        act = r.a[dst]
        eta_eff_scale = r.gate[dst]
        for src in 1:r.n_nodes_
            r.recurrent_mask[src, dst] || continue
            w = r.wmat[src, dst]
            if r.signs[src] == 1
                dw = eta_eff_scale * (eta_rec * r.prev_a[src] * act * (act - theta) - eta_decay * w)
            else
                dw = eta_eff_scale * eta_inh * r.prev_a[src] * (act - target_rate)
            end
            r.wmat[src, dst] = clamp(w + dw, 0.0, limit)
        end
    end
    return r
end

function step!(r::HomeostaticFlowV2Reservoir, receptor_currents::AbstractVector)
    length(receptor_currents) == r.n_receptors_ ||
        throw(DimensionMismatch("expected $(r.n_receptors_) receptor currents, got $(length(receptor_currents))"))

    p = r.params
    r.learn_on && _hfr2_output_homeostasis!(r, p)

    copyto!(r.prev_a, r.a)
    copyto!(r.prev_input_current, r.input_current)

    @inbounds for dst in 1:r.n_nodes_
        input_current = 0.0
        for q in 1:r.n_receptors_
            input_current += Float64(receptor_currents[q]) * r.input_wmat[q, dst]
        end
        r.input_current[dst] = input_current

        rec = 0.0
        for src in 1:r.n_nodes_
            if r.recurrent_mask[src, dst]
                rec += r.prev_a[src] * Float64(r.signs[src]) * r.wmat[src, dst]
            end
        end
        r.recurrent_current[dst] = rec
    end

    @inbounds for i in 1:r.n_nodes_
        drive = r.input_current[i] + r.rec_gain[i] * r.recurrent_current[i]
        r.v[i] = (1.0 - r.leak[i]) * r.v[i] + r.leak[i] * drive
        r.a[i] = _hfr_sigmoid(r.gain[i] * (r.v[i] - r.bias[i]))
    end

    _hfr2_intrinsic!(r, p)
    _hfr2_flow_control!(r, p)
    _hfr2_novelty!(r, p)

    if r.learn_on
        r.input_plasticity && _hfr2_input_plasticity!(r, p, receptor_currents)
        r.recurrent_plasticity && _hfr2_recurrent_plasticity!(r, p)
    end

    @inbounds for i in 1:r.n_nodes_
        r.centered[i] = r.a[i] - r.mean_a[i]
    end

    return copy(r.centered)
end

# :masked_average / :balanced: a single linear readout of the state vector
# (centered activity), unchanged from the first V2 cut.
function _hfr2_effectors_linear!(r::HomeostaticFlowV2Reservoir, state::AbstractVector)
    @inbounds for k in 1:r.n_effectors_
        total = 0.0
        for i in 1:r.n_nodes_
            total += r.output_wmat[i, k] * Float64(state[i])
        end
        r.effector_buffer[k] = r.out_gain[k] * total - r.out_bias[k]
    end
    return r
end

# :tonic_balanced: a positive tonic term (the raw population activity, over
# the same fan-in as the contrast readout) plus a z-scored differential term.
# z-scoring is the fix for the amplitude problem: `state[i]` (a[i]-mean_a[i])
# is deliberately small because intrinsic homeostasis regulates it there, so
# dividing by each unit's own std before the weighted sum restores a
# unit-scale signal *at the port*, without touching the internal dynamical
# target that keeps the reservoir stable. `output_tonic`/`output_contrast` are
# fixed scalars (not evolved against a task score) that set how much of each
# component reaches the effector; out_gain/out_bias are frozen at their
# analytic values (1.0 / 0.0) rather than crawling from a flat start, since a
# unit-norm output column times a unit-variance z already has O(1) RMS.
function _hfr2_effectors_tonic_balanced!(r::HomeostaticFlowV2Reservoir, p::HomeostaticFlowV2Params, state::AbstractVector)
    var_floor = _hfr2_readout_var_floor(p)
    clip = _hfr2_readout_clip(p)
    tonic_gain = _hfr2_output_tonic(p)
    contrast_gain = _hfr2_output_contrast(p)

    @inbounds for k in 1:r.n_effectors_
        tonic_sum = 0.0
        tonic_count = 0
        contrast_sum = 0.0
        for i in 1:r.n_nodes_
            r.output_mask[i, k] || continue
            tonic_sum += r.a[i]
            tonic_count += 1
            w = r.output_wmat[i, k]
            if w != 0.0
                var_a = r.mean_sq_a[i] - r.mean_a[i] * r.mean_a[i]
                var_a = max(var_a, var_floor)
                z = clamp(Float64(state[i]) / sqrt(var_a), -clip, clip)
                contrast_sum += w * z
            end
        end
        tonic_term = tonic_count > 0 ? tonic_sum / tonic_count : 0.0
        r.effector_buffer[k] = tonic_gain * tonic_term + contrast_gain * r.out_gain[k] * contrast_sum - r.out_bias[k]
    end
    return r
end

function effectors(r::HomeostaticFlowV2Reservoir, state::AbstractVector)
    length(state) == r.n_nodes_ ||
        throw(DimensionMismatch("expected $(r.n_nodes_) node states, got $(length(state))"))

    if r.output_mode === :tonic_balanced
        _hfr2_effectors_tonic_balanced!(r, r.params, state)
    else
        _hfr2_effectors_linear!(r, state)
    end
    copyto!(r.last_E, r.effector_buffer)
    return copy(r.effector_buffer)
end

effectors(r::HomeostaticFlowV2Reservoir) = effectors(r, r.centered)
n_receptors(r::HomeostaticFlowV2Reservoir) = r.n_receptors_
n_effectors(r::HomeostaticFlowV2Reservoir) = r.n_effectors_

function reset!(r::HomeostaticFlowV2Reservoir)
    copyto!(r.wmat, r.wmat0)
    copyto!(r.input_wmat, r.input_wmat0)
    copyto!(r.bias, r.bias0)
    copyto!(r.gain, r.gain0)
    copyto!(r.mean_a, r.mean_a0)
    copyto!(r.mean_sq_a, r.mean_sq_a0)
    copyto!(r.a, r.mean_a0)
    copyto!(r.prev_a, r.mean_a0)
    fill!(r.v, 0.0)
    fill!(r.input_current, 0.0)
    fill!(r.prev_input_current, 0.0)
    fill!(r.recurrent_current, 0.0)
    fill!(r.rec_gain, 1.0)
    fill!(r.centered, 0.0)
    fill!(r.receptor_mean, 0.0)
    fill!(r.mean_abs_delta_input, 0.0)
    fill!(r.gate, 1.0)
    fill!(r.out_bias, 0.0)
    fill!(r.out_gain, 1.0)
    fill!(r.mean_E, 0.0)
    fill!(r.mean_sq_E, 0.0)
    fill!(r.last_E, 0.0)
    fill!(r.effector_buffer, 0.0)
    return r
end

function snapshot_state(r::HomeostaticFlowV2Reservoir)
    return (
        wmat=copy(r.wmat), input_wmat=copy(r.input_wmat),
        v=copy(r.v), a=copy(r.a), prev_a=copy(r.prev_a),
        input_current=copy(r.input_current), prev_input_current=copy(r.prev_input_current),
        recurrent_current=copy(r.recurrent_current), rec_gain=copy(r.rec_gain),
        mean_a=copy(r.mean_a), mean_sq_a=copy(r.mean_sq_a),
        bias=copy(r.bias), gain=copy(r.gain), centered=copy(r.centered),
        receptor_mean=copy(r.receptor_mean), mean_abs_delta_input=copy(r.mean_abs_delta_input),
        gate=copy(r.gate), out_bias=copy(r.out_bias), out_gain=copy(r.out_gain),
        mean_E=copy(r.mean_E), mean_sq_E=copy(r.mean_sq_E), last_E=copy(r.last_E),
        effector_buffer=copy(r.effector_buffer),
    )
end

function load_state!(r::HomeostaticFlowV2Reservoir, state)
    _hfr_load_matrix!(r.wmat, _hfr_state_get(state, :wmat), "state.wmat")
    _hfr_load_matrix!(r.input_wmat, _hfr_state_get(state, :input_wmat), "state.input_wmat")
    _hfr_load_vector!(r.v, _hfr_state_get(state, :v), "state.v")
    _hfr_load_vector!(r.a, _hfr_state_get(state, :a), "state.a")
    _hfr_load_vector!(r.prev_a, _hfr_state_get(state, :prev_a), "state.prev_a")
    _hfr_load_vector!(r.input_current, _hfr_state_get(state, :input_current), "state.input_current")
    _hfr_load_vector!(r.prev_input_current, _hfr_state_get(state, :prev_input_current), "state.prev_input_current")
    _hfr_load_vector!(r.recurrent_current, _hfr_state_get(state, :recurrent_current), "state.recurrent_current")
    _hfr_load_vector!(r.rec_gain, _hfr_state_get(state, :rec_gain), "state.rec_gain")
    _hfr_load_vector!(r.mean_a, _hfr_state_get(state, :mean_a), "state.mean_a")
    _hfr_load_vector!(r.mean_sq_a, _hfr_state_get(state, :mean_sq_a), "state.mean_sq_a")
    _hfr_load_vector!(r.bias, _hfr_state_get(state, :bias), "state.bias")
    _hfr_load_vector!(r.gain, _hfr_state_get(state, :gain), "state.gain")
    _hfr_load_vector!(r.centered, _hfr_state_get(state, :centered), "state.centered")
    _hfr_load_vector!(r.receptor_mean, _hfr_state_get(state, :receptor_mean), "state.receptor_mean")
    _hfr_load_vector!(r.mean_abs_delta_input, _hfr_state_get(state, :mean_abs_delta_input), "state.mean_abs_delta_input")
    _hfr_load_vector!(r.gate, _hfr_state_get(state, :gate), "state.gate")
    _hfr_load_vector!(r.out_bias, _hfr_state_get(state, :out_bias), "state.out_bias")
    _hfr_load_vector!(r.out_gain, _hfr_state_get(state, :out_gain), "state.out_gain")
    _hfr_load_vector!(r.mean_E, _hfr_state_get(state, :mean_E), "state.mean_E")
    _hfr_load_vector!(r.mean_sq_E, _hfr_state_get(state, :mean_sq_E), "state.mean_sq_E")
    _hfr_load_vector!(r.last_E, _hfr_state_get(state, :last_E), "state.last_E")
    _hfr_load_vector!(r.effector_buffer, _hfr_state_get(state, :effector_buffer), "state.effector_buffer")
    return r
end
