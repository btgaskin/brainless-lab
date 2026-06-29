mutable struct CompartmentalReservoir{G<:AbstractCompartmental} <: Reservoir
    genome::G
    wiring::Wiring
    dt::Float64
    hill_tau::Float64
    hill_reset::Float64
    dend_y::Array{Float64,3}
    soma_y::Matrix{Float64}
    V::Vector{Float64}
    prev_soma_y::Matrix{Float64}
    prev_spike::Vector{Float64}
    spike_buffer::Vector{Float64}
end

function CompartmentalReservoir(
    genome::G,
    wiring::Wiring;
    dt::Real=1.0,
    hill_tau::Real=HILL_TAU,
    hill_reset::Real=HILL_RESET,
) where {G<:AbstractCompartmental}
    expected_mode = _compartmental_mode(genome)
    wiring.mode == expected_mode ||
        throw(ArgumentError("genome mode $expected_mode does not match wiring mode $(wiring.mode)"))

    return CompartmentalReservoir{G}(
        genome,
        wiring,
        Float64(dt),
        Float64(hill_tau),
        Float64(hill_reset),
        zeros(Float64, wiring.N, wiring.K, COMPARTMENTAL_D),
        zeros(Float64, wiring.N, COMPARTMENTAL_S),
        zeros(Float64, wiring.N),
        zeros(Float64, wiring.N, COMPARTMENTAL_S),
        zeros(Float64, wiring.N),
        zeros(Float64, wiring.N),
    )
end

function CompartmentalReservoir(
    ::Type{DenseCompartmental},
    raw::AbstractVector{<:Real},
    wiring::Wiring;
    kwargs...,
)
    return CompartmentalReservoir(unpack_params(DenseCompartmental, raw), wiring; kwargs...)
end

function CompartmentalReservoir(
    ::Type{StructuredCompartmental},
    raw::AbstractVector{<:Real},
    wiring::Wiring;
    kwargs...,
)
    return CompartmentalReservoir(unpack_params(StructuredCompartmental, raw), wiring; kwargs...)
end

function _compartmental_dendrite_signals(w::Wiring, spike_buffer::Vector{Float64}, receptor_c::Vector{Float64})
    s_d = zeros(Float64, w.N, w.K)
    @inbounds for n in 1:w.N, k in 1:w.K
        src = w.dend_source[n, k]
        if 0 <= src < w.N
            s_d[n, k] = spike_buffer[src + 1]
        elseif w.N <= src < w.N + w.n_receptors
            s_d[n, k] = receptor_c[src - w.N + 1]
        else
            throw(BoundsError("dend_source[$n,$k] = $src is outside [0, $(w.N + w.n_receptors - 1)]"))
        end
    end
    return s_d
end

function step!(r::CompartmentalReservoir, receptor_currents)
    receptor_c = _compartmental_float_vector(receptor_currents, "receptor_currents")
    length(receptor_c) == r.wiring.n_receptors ||
        throw(DimensionMismatch("expected $(r.wiring.n_receptors) receptor currents, got $(length(receptor_c))"))

    if r.genome isa DenseCompartmental
        return _step_compartmental!(r, receptor_c, r.genome)
    end
    return _step_compartmental!(r, receptor_c, r.genome)
end

function _step_compartmental!(r::CompartmentalReservoir, receptor_c::Vector{Float64}, g::DenseCompartmental)
    w = r.wiring
    s_d = _compartmental_dendrite_signals(w, r.spike_buffer, receptor_c)
    o_d = _compartmental_sigmoid.(r.dend_y)
    prev_soma_out = _compartmental_sigmoid.(r.prev_soma_y)

    back = zeros(Float64, w.N, COMPARTMENTAL_D)
    @inbounds for n in 1:w.N, d in 1:COMPARTMENTAL_D
        total = 0.0
        for s in 1:COMPARTMENTAL_S
            total += prev_soma_out[n, s] * g.W_s_d[s, d]
        end
        back[n, d] = total
    end

    @inbounds for n in 1:w.N, k in 1:w.K, d in 1:COMPARTMENTAL_D
        rec = 0.0
        for j in 1:COMPARTMENTAL_D
            rec += o_d[n, k, j] * g.W_dd[d, j]
        end
        dy = (-r.dend_y[n, k, d] + rec + s_d[n, k] * g.w_aff_d[d] + back[n, d] + g.b_d[d]) / g.tau_d[d]
        r.dend_y[n, k, d] += r.dt * dy
    end

    dend_out = _compartmental_sigmoid.(r.dend_y)
    conv = zeros(Float64, w.N, COMPARTMENTAL_S)
    @inbounds for n in 1:w.N, s in 1:COMPARTMENTAL_S
        total = 0.0
        for k in 1:w.K, d in 1:COMPARTMENTAL_D
            total += dend_out[n, k, d] * g.W_d_s[d, s]
        end
        conv[n, s] = total / Float64(w.K)
    end

    return _update_soma_and_hillock!(r, g, conv)
end

function _step_compartmental!(r::CompartmentalReservoir, receptor_c::Vector{Float64}, g::StructuredCompartmental)
    w = r.wiring
    fwd_unit = w.fwd_unit
    back_src = w.back_src
    fwd_count = w.fwd_count
    fwd_unit !== nothing || throw(ArgumentError("structured reservoir requires fwd_unit wiring"))
    back_src !== nothing || throw(ArgumentError("structured reservoir requires back_src wiring"))
    fwd_count !== nothing || throw(ArgumentError("structured reservoir requires fwd_count wiring"))

    s_d = _compartmental_dendrite_signals(w, r.spike_buffer, receptor_c)
    o_d = _compartmental_sigmoid.(r.dend_y)
    prev_soma_out = _compartmental_sigmoid.(r.prev_soma_y)

    in_idx = IN_UNIT + 1
    out_idx = OUT_UNIT + 1
    fb_idx = FB_UNIT + 1

    @inbounds for n in 1:w.N, k in 1:w.K, d in 1:COMPARTMENTAL_D
        rec = 0.0
        for j in 1:COMPARTMENTAL_D
            rec += o_d[n, k, j] * g.W_dd[d, j]
        end
        aff = d == in_idx ? g.w_aff * s_d[n, k] : 0.0
        back = d == fb_idx ? g.w_back * prev_soma_out[n, back_src[n, k] + 1] : 0.0
        dy = (-r.dend_y[n, k, d] + rec + aff + back + g.b_d[d]) / g.tau_d[d]
        r.dend_y[n, k, d] += r.dt * dy
    end

    dend_out = _compartmental_sigmoid.(r.dend_y)
    conv_sum = zeros(Float64, w.N, COMPARTMENTAL_S)
    @inbounds for n in 1:w.N, k in 1:w.K
        unit = fwd_unit[n, k] + 1
        conv_sum[n, unit] += dend_out[n, k, out_idx]
    end

    conv = zeros(Float64, w.N, COMPARTMENTAL_S)
    @inbounds for n in 1:w.N, s in 1:COMPARTMENTAL_S
        count = fwd_count[n, s]
        conv[n, s] = count > 0.0 ? conv_sum[n, s] / count : 0.0
    end

    return _update_soma_and_hillock!(r, g, conv)
end

function _update_soma_and_hillock!(r::CompartmentalReservoir, g::DenseCompartmental, conv::Matrix{Float64})
    w = r.wiring
    soma_out_old = _compartmental_sigmoid.(r.soma_y)

    @inbounds for n in 1:w.N, s_out in 1:COMPARTMENTAL_S
        rec = 0.0
        for s_in in 1:COMPARTMENTAL_S
            rec += soma_out_old[n, s_in] * g.W_ss[s_out, s_in]
        end
        hill_back = r.prev_spike[n] * g.w_h_s[s_out]
        dy = (-r.soma_y[n, s_out] + rec + conv[n, s_out] + hill_back + g.b_s[s_out]) / g.tau_s[s_out]
        r.soma_y[n, s_out] += r.dt * dy
    end

    soma_out = _compartmental_sigmoid.(r.soma_y)
    spike = zeros(Float64, w.N)
    @inbounds for n in 1:w.N
        drive = 0.0
        thr_readout = 0.0
        for s in 1:COMPARTMENTAL_S
            drive += soma_out[n, s] * g.w_s_drv[s]
            thr_readout += soma_out[n, s] * g.w_s_thr[s]
        end
        phi = g.thr_base + g.thr_gain * thr_readout
        v_after = r.V[n] + r.dt * (-r.V[n] + drive) / r.hill_tau
        if v_after >= phi
            spike[n] = 1.0
            r.V[n] = r.hill_reset
        else
            spike[n] = 0.0
            r.V[n] = v_after
        end
    end

    copyto!(r.prev_soma_y, r.soma_y)
    copyto!(r.prev_spike, spike)
    copyto!(r.spike_buffer, spike)
    return copy(spike)
end

function _update_soma_and_hillock!(r::CompartmentalReservoir, g::StructuredCompartmental, conv::Matrix{Float64})
    w = r.wiring
    soma_out_old = _compartmental_sigmoid.(r.soma_y)
    hb_idx = HB_UNIT + 1
    drive_idx = DRIVE_UNIT + 1
    thr_idx = THR_UNIT + 1

    @inbounds for n in 1:w.N, s_out in 1:COMPARTMENTAL_S
        rec = 0.0
        for s_in in 1:COMPARTMENTAL_S
            rec += soma_out_old[n, s_in] * g.W_ss[s_out, s_in]
        end
        hill_back = s_out == hb_idx ? g.w_hb * r.prev_spike[n] : 0.0
        dy = (-r.soma_y[n, s_out] + rec + conv[n, s_out] + hill_back + g.b_s[s_out]) / g.tau_s[s_out]
        r.soma_y[n, s_out] += r.dt * dy
    end

    soma_out = _compartmental_sigmoid.(r.soma_y)
    spike = zeros(Float64, w.N)
    @inbounds for n in 1:w.N
        drive = g.w_drv * soma_out[n, drive_idx]
        phi = soma_out[n, thr_idx]
        v_after = r.V[n] + r.dt * (-r.V[n] + drive) / r.hill_tau
        if v_after >= phi
            spike[n] = 1.0
            r.V[n] = r.hill_reset
        else
            spike[n] = 0.0
            r.V[n] = v_after
        end
    end

    copyto!(r.prev_soma_y, r.soma_y)
    copyto!(r.prev_spike, spike)
    copyto!(r.spike_buffer, spike)
    return copy(spike)
end

function effectors(r::CompartmentalReservoir, spikes)
    spikes = _compartmental_float_vector(spikes, "spikes")
    length(spikes) == r.wiring.N ||
        throw(DimensionMismatch("expected $(r.wiring.N) spikes, got $(length(spikes))"))

    out = zeros(Float64, r.wiring.n_effectors)
    @inbounds for k in 1:r.wiring.n_effectors
        count = 0
        total = 0.0
        for n in 1:r.wiring.N
            if r.wiring.M_ne[n, k]
                count += 1
                total += spikes[n]
            end
        end
        out[k] = count > 0 ? total / Float64(count) : 0.0
    end
    return out
end

effectors(r::CompartmentalReservoir) = effectors(r, r.spike_buffer)

function reset!(r::CompartmentalReservoir)
    fill!(r.dend_y, 0.0)
    fill!(r.soma_y, 0.0)
    fill!(r.V, 0.0)
    fill!(r.prev_soma_y, 0.0)
    fill!(r.prev_spike, 0.0)
    fill!(r.spike_buffer, 0.0)
    return r
end

n_receptors(r::CompartmentalReservoir) = r.wiring.n_receptors
n_effectors(r::CompartmentalReservoir) = r.wiring.n_effectors

function snapshot_state(r::CompartmentalReservoir)
    return (
        dend_y=copy(r.dend_y),
        soma_y=copy(r.soma_y),
        V=copy(r.V),
        prev_soma_y=copy(r.prev_soma_y),
        prev_spike=copy(r.prev_spike),
        spike_buffer=copy(r.spike_buffer),
    )
end

function _compartmental_state_get(state, key::Symbol)
    return state isa AbstractDict ? state[key] : getproperty(state, key)
end

function _compartmental_load_array!(dest, value, name::AbstractString)
    src = Float64.(value)
    size(src) == size(dest) ||
        throw(DimensionMismatch("$name size $(size(src)) must be $(size(dest))"))
    copyto!(dest, src)
    return dest
end

function _compartmental_load_vector!(dest, value, name::AbstractString)
    src = vec(Float64.(value))
    length(src) == length(dest) ||
        throw(DimensionMismatch("$name length $(length(src)) must be $(length(dest))"))
    copyto!(dest, src)
    return dest
end

function load_state!(r::CompartmentalReservoir, state)
    _compartmental_load_array!(r.dend_y, _compartmental_state_get(state, :dend_y), "state.dend_y")
    _compartmental_load_array!(r.soma_y, _compartmental_state_get(state, :soma_y), "state.soma_y")
    _compartmental_load_vector!(r.V, _compartmental_state_get(state, :V), "state.V")
    _compartmental_load_array!(r.prev_soma_y, _compartmental_state_get(state, :prev_soma_y), "state.prev_soma_y")
    _compartmental_load_vector!(r.prev_spike, _compartmental_state_get(state, :prev_spike), "state.prev_spike")
    _compartmental_load_vector!(r.spike_buffer, _compartmental_state_get(state, :spike_buffer), "state.spike_buffer")
    return r
end

plasticity(::CompartmentalReservoir) = NoPlasticity()
