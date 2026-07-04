struct ResetDendrites <: Intervention end
struct NoSomaBack <: Intervention end
struct NoHillockBack <: Intervention end
struct FreezePlasticity <: Intervention end
struct ZeroRecurrent <: Intervention end
struct ClampTarget <: Intervention end
struct DisableVision <: Intervention end

function _dense_with_zero_soma_back(g::DenseCompartmental)
    return DenseCompartmental(
        copy(g.w_aff_d),
        copy(g.W_dd),
        zeros(Float64, size(g.W_s_d)),
        copy(g.W_d_s),
        copy(g.W_ss),
        copy(g.b_d),
        copy(g.raw_tau_d),
        copy(g.tau_d),
        copy(g.b_s),
        copy(g.raw_tau_s),
        copy(g.tau_s),
        copy(g.w_s_drv),
        copy(g.w_s_thr),
        copy(g.w_h_s),
        g.thr_base,
        g.thr_gain,
    )
end

function _dense_with_zero_hillock_back(g::DenseCompartmental)
    return DenseCompartmental(
        copy(g.w_aff_d),
        copy(g.W_dd),
        copy(g.W_s_d),
        copy(g.W_d_s),
        copy(g.W_ss),
        copy(g.b_d),
        copy(g.raw_tau_d),
        copy(g.tau_d),
        copy(g.b_s),
        copy(g.raw_tau_s),
        copy(g.tau_s),
        copy(g.w_s_drv),
        copy(g.w_s_thr),
        zeros(Float64, length(g.w_h_s)),
        g.thr_base,
        g.thr_gain,
    )
end

function _dense_with_zero_recurrent(g::DenseCompartmental)
    return DenseCompartmental(
        copy(g.w_aff_d),
        copy(g.W_dd),
        copy(g.W_s_d),
        copy(g.W_d_s),
        zeros(Float64, size(g.W_ss)),
        copy(g.b_d),
        copy(g.raw_tau_d),
        copy(g.tau_d),
        copy(g.b_s),
        copy(g.raw_tau_s),
        copy(g.tau_s),
        copy(g.w_s_drv),
        copy(g.w_s_thr),
        copy(g.w_h_s),
        g.thr_base,
        g.thr_gain,
    )
end

function _structured_with_zero_soma_back(g::StructuredCompartmental)
    return StructuredCompartmental(
        g.w_aff,
        copy(g.W_dd),
        0.0,
        copy(g.W_ss),
        copy(g.b_d),
        copy(g.raw_tau_d),
        copy(g.tau_d),
        copy(g.b_s),
        copy(g.raw_tau_s),
        copy(g.tau_s),
        g.w_drv,
        g.w_hb,
    )
end

function _structured_with_zero_hillock_back(g::StructuredCompartmental)
    return StructuredCompartmental(
        g.w_aff,
        copy(g.W_dd),
        g.w_back,
        copy(g.W_ss),
        copy(g.b_d),
        copy(g.raw_tau_d),
        copy(g.tau_d),
        copy(g.b_s),
        copy(g.raw_tau_s),
        copy(g.tau_s),
        g.w_drv,
        0.0,
    )
end

function _structured_with_zero_recurrent(g::StructuredCompartmental)
    return StructuredCompartmental(
        g.w_aff,
        copy(g.W_dd),
        g.w_back,
        zeros(Float64, size(g.W_ss)),
        copy(g.b_d),
        copy(g.raw_tau_d),
        copy(g.tau_d),
        copy(g.b_s),
        copy(g.raw_tau_s),
        copy(g.tau_s),
        g.w_drv,
        g.w_hb,
    )
end

function _falandays_params_with(p::FalandaysParams; kwargs...)
    values = Dict{Symbol,Any}()
    for name in fieldnames(FalandaysParams)
        values[name] = getfield(p, name)
    end
    for (key, value) in pairs(kwargs)
        values[Symbol(key)] = value
    end
    return FalandaysParams(; values...)
end

function _replace_falandays_params!(r::FalandaysReservoir, params::FalandaysParams)
    r.model = FalandaysModel(params, r.drive, r.sign, r.rectify)
    return r
end

function apply!(::ResetDendrites, r::CompartmentalReservoir)
    fill!(r.dend_y, 0.0)
    return r
end

function apply!(::FreezePlasticity, r::FalandaysReservoir)
    return _replace_falandays_params!(r, _falandays_params_with(r.params; learn_on=false))
end

function apply!(::ClampTarget, r::FalandaysReservoir)
    return _replace_falandays_params!(r, _falandays_params_with(r.params; lrate_targ=0.0))
end

function apply!(::ZeroRecurrent, r::FalandaysReservoir)
    fill!(r.conn.wmat, 0.0)
    fill!(r.connectome.wmat0, 0.0)
    fill!(r.connectome.recurrent_mask, false)
    return r
end

function apply!(::NoSomaBack, r::CompartmentalReservoir{DenseCompartmental})
    r.genome = _dense_with_zero_soma_back(r.genome)
    return r
end

function apply!(::NoSomaBack, r::CompartmentalReservoir{StructuredCompartmental})
    r.genome = _structured_with_zero_soma_back(r.genome)
    return r
end

function apply!(::NoHillockBack, r::CompartmentalReservoir{DenseCompartmental})
    r.genome = _dense_with_zero_hillock_back(r.genome)
    return r
end

function apply!(::NoHillockBack, r::CompartmentalReservoir{StructuredCompartmental})
    r.genome = _structured_with_zero_hillock_back(r.genome)
    return r
end

function apply!(::ZeroRecurrent, r::CompartmentalReservoir{DenseCompartmental})
    r.genome = _dense_with_zero_recurrent(r.genome)
    return r
end

function apply!(::ZeroRecurrent, r::CompartmentalReservoir{StructuredCompartmental})
    r.genome = _structured_with_zero_recurrent(r.genome)
    return r
end

_compartmental_constructor_intervention!(i::NoSomaBack, r::CompartmentalReservoir) = apply!(i, r)
_compartmental_constructor_intervention!(i::NoHillockBack, r::CompartmentalReservoir) = apply!(i, r)
_compartmental_constructor_intervention!(i::ZeroRecurrent, r::CompartmentalReservoir) = apply!(i, r)
_compartmental_tick_intervention!(i::ResetDendrites, r::CompartmentalReservoir) = apply!(i, r)
