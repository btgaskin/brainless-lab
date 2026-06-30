using StaticArrays: MVector, SMatrix, SVector

mutable struct CompartmentalReservoir{G<:AbstractCompartmental} <: Reservoir
    genome::G
    wiring::Wiring
    dt::Float64
    substeps::Int      # forward-Euler integration sub-steps per env update
    dt_sub::Float64    # = dt / substeps (the actual per-sub-step Euler dt)
    hill_tau::Float64
    hill_reset::Float64
    dend_y::Array{Float64,3}
    soma_y::Matrix{Float64}
    V::Vector{Float64}
    prev_soma_y::Matrix{Float64}
    prev_spike::Vector{Float64}
    spike_buffer::Vector{Float64}
    intervention::Union{Nothing,Intervention}
end

function CompartmentalReservoir(
    genome::G,
    wiring::Wiring;
    dt::Real=1.0,
    substeps::Integer=5,
    hill_tau::Real=HILL_TAU,
    hill_reset::Real=HILL_RESET,
    intervention=nothing,
) where {G<:AbstractCompartmental}
    expected_mode = _compartmental_mode(genome)
    wiring.mode == expected_mode ||
        throw(ArgumentError("genome mode $expected_mode does not match wiring mode $(wiring.mode)"))

    substeps_ = max(1, Int(substeps))
    intervention_ = _compartmental_intervention(intervention)
    reservoir = CompartmentalReservoir{G}(
        genome,
        wiring,
        Float64(dt),
        substeps_,
        Float64(dt) / substeps_,
        Float64(hill_tau),
        Float64(hill_reset),
        zeros(Float64, wiring.N, wiring.K, COMPARTMENTAL_D),
        zeros(Float64, wiring.N, COMPARTMENTAL_S),
        zeros(Float64, wiring.N),
        zeros(Float64, wiring.N, COMPARTMENTAL_S),
        zeros(Float64, wiring.N),
        zeros(Float64, wiring.N),
        intervention_,
    )

    return _compartmental_constructor_intervention!(intervention_, reservoir)
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

_compartmental_intervention(::Nothing) = nothing
_compartmental_intervention(i::Intervention) = i
_compartmental_intervention(::Type{T}) where {T<:Intervention} = T()
_compartmental_intervention(name::AbstractString) = _compartmental_intervention(Symbol(name))

function _compartmental_intervention(name::Symbol)
    name == :normal && return nothing
    return _compartmental_intervention(resolve_ablation(name))
end

_compartmental_constructor_intervention!(::Nothing, r::CompartmentalReservoir) = r
_compartmental_constructor_intervention!(::Intervention, r::CompartmentalReservoir) = r
_compartmental_tick_intervention!(::Nothing, r::CompartmentalReservoir) = r
_compartmental_tick_intervention!(::Intervention, r::CompartmentalReservoir) = r

@inline function _svector_d_from_state(r::CompartmentalReservoir, n::Int, k::Int)
    return SVector{COMPARTMENTAL_D,Float64}(
        ntuple(d -> r.dend_y[n, k, d], Val(COMPARTMENTAL_D)),
    )
end

@inline function _svector_s_from_soma(r::CompartmentalReservoir, n::Int)
    return SVector{COMPARTMENTAL_S,Float64}(
        ntuple(s -> r.soma_y[n, s], Val(COMPARTMENTAL_S)),
    )
end

@inline function _svector_s_from_prev_soma(r::CompartmentalReservoir, n::Int)
    return SVector{COMPARTMENTAL_S,Float64}(
        ntuple(s -> r.prev_soma_y[n, s], Val(COMPARTMENTAL_S)),
    )
end

@inline function _svector_s_from_mvector(v::MVector{COMPARTMENTAL_S,Float64})
    return SVector{COMPARTMENTAL_S,Float64}(
        ntuple(s -> v[s], Val(COMPARTMENTAL_S)),
    )
end

@inline function _sigmoid_svector(v::SVector{N,Float64}) where {N}
    return SVector{N,Float64}(ntuple(i -> _compartmental_sigmoid(v[i]), Val(N)))
end

@inline function _zero_mvector_s()
    out = MVector{COMPARTMENTAL_S,Float64}(undef)
    fill!(out, 0.0)
    return out
end

@inline function _dense_kernel(g::DenseCompartmental)
    return (
        w_aff_d=SVector{COMPARTMENTAL_D,Float64}(g.w_aff_d),
        W_dd=SMatrix{COMPARTMENTAL_D,COMPARTMENTAL_D,Float64,COMPARTMENTAL_D * COMPARTMENTAL_D}(g.W_dd),
        W_s_d=SMatrix{COMPARTMENTAL_S,COMPARTMENTAL_D,Float64,COMPARTMENTAL_S * COMPARTMENTAL_D}(g.W_s_d),
        W_d_s=SMatrix{COMPARTMENTAL_D,COMPARTMENTAL_S,Float64,COMPARTMENTAL_D * COMPARTMENTAL_S}(g.W_d_s),
        W_ss=SMatrix{COMPARTMENTAL_S,COMPARTMENTAL_S,Float64,COMPARTMENTAL_S * COMPARTMENTAL_S}(g.W_ss),
        b_d=SVector{COMPARTMENTAL_D,Float64}(g.b_d),
        tau_d=SVector{COMPARTMENTAL_D,Float64}(g.tau_d),
        b_s=SVector{COMPARTMENTAL_S,Float64}(g.b_s),
        tau_s=SVector{COMPARTMENTAL_S,Float64}(g.tau_s),
        w_s_drv=SVector{COMPARTMENTAL_S,Float64}(g.w_s_drv),
        w_s_thr=SVector{COMPARTMENTAL_S,Float64}(g.w_s_thr),
        w_h_s=SVector{COMPARTMENTAL_S,Float64}(g.w_h_s),
    )
end

@inline function _structured_kernel(g::StructuredCompartmental)
    return (
        W_dd=SMatrix{COMPARTMENTAL_D,COMPARTMENTAL_D,Float64,COMPARTMENTAL_D * COMPARTMENTAL_D}(g.W_dd),
        W_ss=SMatrix{COMPARTMENTAL_S,COMPARTMENTAL_S,Float64,COMPARTMENTAL_S * COMPARTMENTAL_S}(g.W_ss),
        b_d=SVector{COMPARTMENTAL_D,Float64}(g.b_d),
        tau_d=SVector{COMPARTMENTAL_D,Float64}(g.tau_d),
        b_s=SVector{COMPARTMENTAL_S,Float64}(g.b_s),
        tau_s=SVector{COMPARTMENTAL_S,Float64}(g.tau_s),
    )
end

@inline function _compartmental_dendrite_signal(w::Wiring, spike_buffer::Vector{Float64}, receptor_c::Vector{Float64}, n::Int, k::Int)
    src = w.dend_source[n, k]
    if 0 <= src < w.N
        return spike_buffer[src + 1]
    elseif w.N <= src < w.N + w.n_receptors
        return receptor_c[src - w.N + 1]
    end
    throw(BoundsError("dend_source[$n,$k] = $src is outside [0, $(w.N + w.n_receptors - 1)]"))
end

@inline function _dense_back(prev_soma_out, W_s_d)
    back = MVector{COMPARTMENTAL_D,Float64}(undef)
    @inbounds for d in 1:COMPARTMENTAL_D
        total = 0.0
        for s in 1:COMPARTMENTAL_S
            total += prev_soma_out[s] * W_s_d[s, d]
        end
        back[d] = total
    end
    return back
end

@inline function _dendrite_rec(o_d, W_dd, d::Int)
    total = 0.0
    @inbounds for j in 1:COMPARTMENTAL_D
        total += o_d[j] * W_dd[d, j]
    end
    return total
end

function _dense_conv(r::CompartmentalReservoir, n::Int, K::Int, W_d_s)
    conv = MVector{COMPARTMENTAL_S,Float64}(undef)
    @inbounds for s in 1:COMPARTMENTAL_S
        total = 0.0
        for k in 1:K, d in 1:COMPARTMENTAL_D
            total += _compartmental_sigmoid(r.dend_y[n, k, d]) * W_d_s[d, s]
        end
        conv[s] = total / Float64(K)
    end
    return conv
end

function _update_dense_soma_and_hillock!(r::CompartmentalReservoir, g::DenseCompartmental, kernel, conv, n::Int)
    soma_old = _svector_s_from_soma(r, n)
    soma_out_old = _sigmoid_svector(soma_old)
    soma_new = MVector{COMPARTMENTAL_S,Float64}(undef)
    prev_spike_n = r.prev_spike[n]

    @inbounds for s_out in 1:COMPARTMENTAL_S
        rec = 0.0
        for s_in in 1:COMPARTMENTAL_S
            rec += soma_out_old[s_in] * kernel.W_ss[s_out, s_in]
        end
        hill_back = prev_spike_n * kernel.w_h_s[s_out]
        dy = (-soma_old[s_out] + rec + conv[s_out] + hill_back + kernel.b_s[s_out]) / kernel.tau_s[s_out]
        soma_new[s_out] = soma_old[s_out] + r.dt_sub * dy
        r.soma_y[n, s_out] = soma_new[s_out]
    end

    soma_out = _sigmoid_svector(_svector_s_from_mvector(soma_new))
    drive = 0.0
    thr_readout = 0.0
    @inbounds for s in 1:COMPARTMENTAL_S
        drive += soma_out[s] * kernel.w_s_drv[s]
        thr_readout += soma_out[s] * kernel.w_s_thr[s]
    end

    phi = g.thr_base + g.thr_gain * thr_readout
    v_after = r.V[n] + r.dt_sub * (-r.V[n] + drive) / r.hill_tau
    if v_after >= phi
        r.prev_spike[n] = 1.0
        r.V[n] = r.hill_reset
    else
        r.prev_spike[n] = 0.0
        r.V[n] = v_after
    end

    @inbounds for s in 1:COMPARTMENTAL_S
        r.prev_soma_y[n, s] = soma_new[s]
    end

    return r
end

function _update_structured_soma_and_hillock!(r::CompartmentalReservoir, g::StructuredCompartmental, kernel, conv, n::Int)
    soma_old = _svector_s_from_soma(r, n)
    soma_out_old = _sigmoid_svector(soma_old)
    soma_new = MVector{COMPARTMENTAL_S,Float64}(undef)
    prev_spike_n = r.prev_spike[n]
    hb_idx = HB_UNIT + 1
    drive_idx = DRIVE_UNIT + 1
    thr_idx = THR_UNIT + 1

    @inbounds for s_out in 1:COMPARTMENTAL_S
        rec = 0.0
        for s_in in 1:COMPARTMENTAL_S
            rec += soma_out_old[s_in] * kernel.W_ss[s_out, s_in]
        end
        hill_back = s_out == hb_idx ? g.w_hb * prev_spike_n : 0.0
        dy = (-soma_old[s_out] + rec + conv[s_out] + hill_back + kernel.b_s[s_out]) / kernel.tau_s[s_out]
        soma_new[s_out] = soma_old[s_out] + r.dt_sub * dy
        r.soma_y[n, s_out] = soma_new[s_out]
    end

    soma_out = _sigmoid_svector(_svector_s_from_mvector(soma_new))
    drive = g.w_drv * soma_out[drive_idx]
    phi = soma_out[thr_idx]
    v_after = r.V[n] + r.dt_sub * (-r.V[n] + drive) / r.hill_tau
    if v_after >= phi
        r.prev_spike[n] = 1.0
        r.V[n] = r.hill_reset
    else
        r.prev_spike[n] = 0.0
        r.V[n] = v_after
    end

    @inbounds for s in 1:COMPARTMENTAL_S
        r.prev_soma_y[n, s] = soma_new[s]
    end

    return r
end

function step!(r::CompartmentalReservoir, receptor_currents)
    receptor_c = _compartmental_float_vector(receptor_currents, "receptor_currents")
    length(receptor_c) == r.wiring.n_receptors ||
        throw(DimensionMismatch("expected $(r.wiring.n_receptors) receptor currents, got $(length(receptor_c))"))

    # Integrate the CTRNN with `substeps` forward-Euler sub-steps of dt_sub per env
    # update (afferent input held constant; recurrence propagates per sub-step).
    # The env-step output is the per-node spike RATE over the sub-steps; at
    # substeps=1 this is the single-tick binary spike vector (== legacy behaviour).
    if r.substeps <= 1
        spikes = _step_compartmental!(r, receptor_c, r.genome)
    else
        acc = zeros(Float64, r.wiring.N)
        for _ in 1:r.substeps
            acc .+= _step_compartmental!(r, receptor_c, r.genome)
        end
        spikes = acc ./ r.substeps
    end
    _compartmental_tick_intervention!(r.intervention, r)
    return spikes
end

function _step_compartmental!(r::CompartmentalReservoir, receptor_c::Vector{Float64}, g::DenseCompartmental)
    w = r.wiring
    kernel = _dense_kernel(g)

    @inbounds for n in 1:w.N
        prev_soma_out = _sigmoid_svector(_svector_s_from_prev_soma(r, n))
        back = _dense_back(prev_soma_out, kernel.W_s_d)

        for k in 1:w.K
            y_old = _svector_d_from_state(r, n, k)
            o_d = _sigmoid_svector(y_old)
            s_d = _compartmental_dendrite_signal(w, r.spike_buffer, receptor_c, n, k)

            for d in 1:COMPARTMENTAL_D
                rec = _dendrite_rec(o_d, kernel.W_dd, d)
                dy = (-y_old[d] + rec + s_d * kernel.w_aff_d[d] + back[d] + kernel.b_d[d]) / kernel.tau_d[d]
                r.dend_y[n, k, d] = y_old[d] + r.dt_sub * dy
            end
        end

        conv = _dense_conv(r, n, w.K, kernel.W_d_s)
        _update_dense_soma_and_hillock!(r, g, kernel, conv, n)
    end

    copyto!(r.spike_buffer, r.prev_spike)
    return copy(r.prev_spike)
end

function _step_compartmental!(r::CompartmentalReservoir, receptor_c::Vector{Float64}, g::StructuredCompartmental)
    w = r.wiring
    fwd_unit = w.fwd_unit
    back_src = w.back_src
    fwd_count = w.fwd_count
    fwd_unit !== nothing || throw(ArgumentError("structured reservoir requires fwd_unit wiring"))
    back_src !== nothing || throw(ArgumentError("structured reservoir requires back_src wiring"))
    fwd_count !== nothing || throw(ArgumentError("structured reservoir requires fwd_count wiring"))

    kernel = _structured_kernel(g)
    in_idx = IN_UNIT + 1
    out_idx = OUT_UNIT + 1
    fb_idx = FB_UNIT + 1

    @inbounds for n in 1:w.N
        prev_soma_out = _sigmoid_svector(_svector_s_from_prev_soma(r, n))
        conv_sum = _zero_mvector_s()

        for k in 1:w.K
            y_old = _svector_d_from_state(r, n, k)
            o_d = _sigmoid_svector(y_old)
            s_d = _compartmental_dendrite_signal(w, r.spike_buffer, receptor_c, n, k)
            back_unit = back_src[n, k] + 1

            for d in 1:COMPARTMENTAL_D
                rec = _dendrite_rec(o_d, kernel.W_dd, d)
                aff = d == in_idx ? g.w_aff * s_d : 0.0
                back = d == fb_idx ? g.w_back * prev_soma_out[back_unit] : 0.0
                dy = (-y_old[d] + rec + aff + back + kernel.b_d[d]) / kernel.tau_d[d]
                r.dend_y[n, k, d] = y_old[d] + r.dt_sub * dy
            end

            unit = fwd_unit[n, k] + 1
            conv_sum[unit] += _compartmental_sigmoid(r.dend_y[n, k, out_idx])
        end

        conv = MVector{COMPARTMENTAL_S,Float64}(undef)
        for s in 1:COMPARTMENTAL_S
            count = fwd_count[n, s]
            conv[s] = count > 0.0 ? conv_sum[s] / count : 0.0
        end
        _update_structured_soma_and_hillock!(r, g, kernel, conv, n)
    end

    copyto!(r.spike_buffer, r.prev_spike)
    return copy(r.prev_spike)
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
        throw(DimensionMismatch("$name length $(length(src))"))
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
