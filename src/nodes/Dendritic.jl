using Random
using LinearAlgebra: mul!

# Dendritic Falandays variant: per-dendrite eligibility-tag plasticity.
#
# Port of `v0.2/crho/node_dendritic.py` (`DendriticReservoir`). This is the base
# homeostatic Falandays neuron with two additions grounded in dendritic
# neuroscience (London & Häusser 2005; Poirazi & Papoutsi 2020; Gidon et al. 2020):
#
#   1. Recurrent synapses are partitioned across `n_dendrites` compartments. Each
#      dendrite integrates (with the shared membrane leak) only the presynaptic
#      current routed to it, and fires its own local dendritic spike when it
#      crosses `dend_threshold` (reset by subtraction).
#   2. A dendritic spike sets an *eligibility tag* on every recurrent synapse
#      routed to that dendrite. Plasticity is then gated on
#      `presynaptic-spike OR dendrite-tag` rather than presynaptic activity alone
#      — i.e. a local dendritic event can license a weight update even with no
#      somatic/presynaptic spike (cf. Urbanczik & Senn 2014; Payeur et al. 2021).
#
# The soma still receives the *full* recurrent sum (as in base Falandays); the
# dendrites are an additional parallel pathway. With `eligibility_only=true`
# (default) they influence *learning only*; with `false` each dendritic spike also
# injects unit somatic current. The endogenous drive here is a saturating
# *logistic* function of the one-sided target deficit (distinct from the Oosawa
# drive's linear firing-threshold-gap noise), applied to the dendrites (`dend_drive`)
# and/or the soma (`soma_drive`).
#
# This is NOT the biophysical `Compartmental*` node — that is a separate
# multi-compartment ODE model. This variant shares the Falandays discrete update.
#
# Fidelity note: dendrite assignment uses a separate RNG stream (`seed + 777`),
# mask wiring uses `seed`, and membrane noise uses `seed + 999983`, mirroring the
# Python reference's offsets. Julia's `MersenneTwister` differs from numpy's
# PCG64, so streams are not bit-identical across languages — the goal is
# structural fidelity (same update, gating, and defaults), not bit-exactness.

_logistic_drive(deficit, floor, smax, d0, w) =
    floor + (smax - floor) / (1.0 + exp(-(deficit - d0) / w))

struct DendriticModel{S} <: NodeModel
    params::FalandaysParams
    sign::S
    rectify::Bool
    n_dendrites::Int
    soma_drive::Float64
    dend_drive::Float64
    drive_floor::Float64
    drive_d0::Float64
    drive_w::Float64
    dend_threshold::Float64
    eligibility_only::Bool
end

struct DendriticConnectome <: Connectome
    recurrent_mask::BitMatrix
    input_wmat::Matrix{Float64}
    output_mask::Matrix{Float64}
    wmat0::Matrix{Float64}
    dend_id::Matrix{Int}   # (N_pre, N_post); 0 off-mask, 1..n_dendrites per edge (post-node's dendrite)
end

mutable struct DendriticConnState <: ConnState
    wmat::Matrix{Float64}
end

# Persistent state (acts…dend_acts) plus preallocated per-tick scratch so `step!`
# allocates nothing beyond the returned spike copy.
mutable struct DendriticNodeState{NS}
    acts::Vector{Float64}
    targets::Vector{Float64}
    spikes::Vector{Float64}
    errors::Vector{Float64}
    prev_spikes::Vector{Float64}
    dend_acts::Matrix{Float64}     # (N, D) persistent dendritic membrane
    dend_input::Matrix{Float64}    # (N, D) scratch: routed recurrent current
    dend_spike::BitMatrix          # (N, D) scratch: dendritic spikes this tick
    soma_rec::Vector{Float64}      # (N,)   scratch: full recurrent sum into soma
    node_deficit::Vector{Float64}  # (N,)   scratch: max(0, target - base_acts)
    input_current::Vector{Float64} # (N,)   scratch: receptor drive
    dend_noise::Matrix{Float64}    # (N, D) scratch: dendritic drive noise
    soma_noise::Vector{Float64}    # (N,)   scratch: somatic drive noise
    counts::Vector{Float64}        # (N,)   scratch: eligible presyn count per post
    noise::NS
end

const DendriticReservoir =
    ReservoirInstance{<:DendriticModel, <:DendriticConnectome, <:DendriticConnState}

# Online homeostatic + eligibility-gated plasticity (base default is NoPlasticity).
plasticity(::DendriticReservoir) = OnlinePlasticity()

function Base.getproperty(r::DendriticReservoir, s::Symbol)
    if s === :model || s === :connectome || s === :conn || s === :state || s === :io
        return getfield(r, s)
    elseif s === :acts || s === :targets || s === :spikes || s === :errors ||
           s === :prev_spikes || s === :dend_acts
        return getfield(getfield(r, :state), s)
    elseif s === :noise_source
        return getfield(getfield(r, :state), :noise)
    elseif s === :wmat
        return getfield(getfield(r, :conn), :wmat)
    elseif s === :recurrent_mask || s === :input_wmat || s === :output_mask ||
           s === :wmat0 || s === :dend_id
        return getfield(getfield(r, :connectome), s)
    elseif s === :params || s === :sign || s === :rectify || s === :n_dendrites ||
           s === :soma_drive || s === :dend_drive || s === :eligibility_only
        return getfield(getfield(r, :model), s)
    elseif s === :n_receptors
        return n_receptors(getfield(r, :io))
    elseif s === :n_effectors
        return n_effectors(getfield(r, :io))
    end
    return getfield(r, s)
end

_draw_noise!(source::RngNoise, buf::AbstractArray) = (randn!(source.rng, buf); buf)

function DendriticReservoir(;
    params=FalandaysParams(),
    sign=Unsigned(),
    recurrent_mask,
    input_wmat,
    output_mask,
    wmat0,
    dend_id,
    n_dendrites::Integer=4,
    soma_drive::Real=0.0,
    dend_drive::Real=0.0,
    drive_floor::Real=0.0,
    drive_d0::Real=1.0,
    drive_w::Real=0.4,
    dend_threshold::Real=1.0,
    eligibility_only::Bool=true,
    noise_source=nothing,
    rectify::Bool=true,
)
    params = _as_falandays_params(params)
    input_wmat = _float_matrix(input_wmat, "input_wmat")
    wmat0 = _float_matrix(wmat0, "wmat0")
    recurrent_mask = _bitmatrix(recurrent_mask, "recurrent_mask")
    output_mask = _float_matrix(output_mask, "output_mask")
    n_dendrites = Int(n_dendrites)
    n_dendrites >= 1 || throw(ArgumentError("n_dendrites must be at least 1"))

    n_nodes, n_receptors_, n_effectors_ =
        _validate_dimensions(input_wmat, wmat0, recurrent_mask, output_mask)
    axis = _normalize_axis(sign, n_nodes)

    size(dend_id) == (n_nodes, n_nodes) ||
        throw(DimensionMismatch("dend_id size $(size(dend_id)) must be ($n_nodes, $n_nodes)"))
    dend_id = Matrix{Int}(dend_id)
    @inbounds for j in 1:n_nodes, i in 1:n_nodes
        (0 <= dend_id[i, j] <= n_dendrites) ||
            throw(ArgumentError("dend_id entries must be in 0:$(n_dendrites)"))
        if recurrent_mask[i, j] && dend_id[i, j] == 0
            throw(ArgumentError("dend_id must assign a dendrite (1:$(n_dendrites)) to every recurrent edge"))
        end
    end

    source = noise_source === nothing ? RngNoise(0) : noise_source

    model = DendriticModel(
        params, axis, rectify, n_dendrites,
        Float64(soma_drive), Float64(dend_drive), Float64(drive_floor),
        Float64(drive_d0), Float64(drive_w), Float64(dend_threshold),
        eligibility_only,
    )
    connectome = DendriticConnectome(recurrent_mask, input_wmat, output_mask, copy(wmat0), dend_id)
    conn = DendriticConnState(copy(wmat0))
    state = DendriticNodeState(
        zeros(Float64, n_nodes),  # acts
        ones(Float64, n_nodes),   # targets
        zeros(Float64, n_nodes),  # spikes
        zeros(Float64, n_nodes),  # errors
        zeros(Float64, n_nodes),  # prev_spikes
        zeros(Float64, n_nodes, n_dendrites),  # dend_acts
        zeros(Float64, n_nodes, n_dendrites),  # dend_input
        falses(n_nodes, n_dendrites),          # dend_spike
        zeros(Float64, n_nodes),  # soma_rec
        zeros(Float64, n_nodes),  # node_deficit
        zeros(Float64, n_nodes),  # input_current
        zeros(Float64, n_nodes, n_dendrites),  # dend_noise
        zeros(Float64, n_nodes),  # soma_noise
        zeros(Float64, n_nodes),  # counts
        source,
    )
    return ReservoirInstance(model, connectome, conn, state, PortSpec(n_receptors_, n_effectors_))
end

function DendriticReservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    params=FalandaysParams(),
    seed=nothing,
    input_weight=nothing,
    link_p::Real=0.1,
    n_dendrites::Integer=4,
    soma_drive::Real=0.0,
    dend_drive::Real=0.6,
    drive_floor::Real=0.0,
    drive_d0::Real=1.0,
    drive_w::Real=0.4,
    dend_threshold::Real=1.0,
    eligibility_only::Bool=true,
    noise_source=nothing,
    rectify::Bool=true,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_nodes >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))
    n_dendrites = Int(n_dendrites)
    n_dendrites >= 1 || throw(ArgumentError("n_dendrites must be at least 1"))

    params = _as_falandays_params(params)
    link_p = Float64(link_p)
    0.0 <= link_p <= 1.0 || throw(ArgumentError("link_p must be in [0, 1]"))

    # Base Falandays wiring, same rng call order (recurrent, input, output, degree
    # repair, weight draw), so the substrate matches `:falandays_base` at a seed.
    rng = _rng_from_seed(seed)
    recurrent_mask = bernoulli_mask(n_nodes, n_nodes, link_p, rng; diagonal=false)
    input_mask = bernoulli_mask(n_receptors_, n_nodes, link_p, rng; diagonal=true)
    output_mask = bernoulli_mask(n_nodes, n_effectors_, link_p, rng; diagonal=true)
    _ensure_unsigned_degree!(recurrent_mask, input_mask, rng)
    _ensure_output_mask!(output_mask, rng)

    input_weight = input_weight === nothing ? params.input_weight : Float64(input_weight)
    input_wmat = input_weight .* Float64.(input_mask)
    output_wmat = Float64.(output_mask)
    wmat0 = Float64.(recurrent_mask) .* (params.weight_init_std .* randn(rng, n_nodes, n_nodes))

    # Dendrite assignment on its own stream so it is independent of the substrate.
    dend_rng = _rng_from_seed(seed === nothing ? nothing : Int(seed) + 777)
    dend_id = zeros(Int, n_nodes, n_nodes)
    @inbounds for j in 1:n_nodes, i in 1:n_nodes
        if recurrent_mask[i, j]
            dend_id[i, j] = rand(dend_rng, 1:n_dendrites)
        end
    end

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source

    return DendriticReservoir(
        params=params,
        sign=Unsigned(),
        recurrent_mask=recurrent_mask,
        input_wmat=input_wmat,
        output_mask=output_wmat,
        wmat0=wmat0,
        dend_id=dend_id,
        n_dendrites=n_dendrites,
        soma_drive=soma_drive,
        dend_drive=dend_drive,
        drive_floor=drive_floor,
        drive_d0=drive_d0,
        drive_w=drive_w,
        dend_threshold=dend_threshold,
        eligibility_only=eligibility_only,
        noise_source=source,
        rectify=rectify,
    )
end

function step!(
    m::DendriticModel,
    c::DendriticConnectome,
    cs::DendriticConnState,
    ns::DendriticNodeState,
    receptor_currents,
)
    receptor_currents = _float_vector(receptor_currents, "receptor_currents")
    n_receptors_ = size(c.input_wmat, 1)
    length(receptor_currents) == n_receptors_ ||
        throw(DimensionMismatch("expected $(n_receptors_) receptor currents, got $(length(receptor_currents))"))

    params = m.params
    leak = params.leak
    N = length(ns.acts)
    D = m.n_dendrites
    wmat = cs.wmat
    copyto!(ns.prev_spikes, ns.spikes)

    mul!(ns.input_current, transpose(c.input_wmat), receptor_currents)

    # Single pass over recurrent edges: full recurrent sum into the soma AND the
    # per-dendrite routed current. Avoids the reference's N×N-per-dendrite temporary.
    fill!(ns.dend_input, 0.0)
    fill!(ns.soma_rec, 0.0)
    @inbounds for j in 1:N
        for i in 1:N
            if c.recurrent_mask[i, j]
                s = ns.prev_spikes[i]
                if s != 0.0
                    w = wmat[i, j] * s
                    ns.soma_rec[j] += w
                    ns.dend_input[j, c.dend_id[i, j]] += w
                end
            end
        end
    end

    # Dendritic membranes leak and integrate their routed current.
    @inbounds for d in 1:D, j in 1:N
        ns.dend_acts[j, d] = ns.dend_acts[j, d] * (1.0 - leak) + ns.dend_input[j, d]
    end

    # Somatic base membrane (leaky-integrate of input + full recurrent), and the
    # one-sided deficit toward the target set-point that gates the endogenous drive.
    @inbounds for j in 1:N
        ns.acts[j] = ns.acts[j] * (1.0 - leak) + ns.input_current[j] + ns.soma_rec[j]
        ns.node_deficit[j] = max(0.0, ns.targets[j] - ns.acts[j])
    end

    # Dendritic drive + spikes (logistic in the node deficit; broadcast across
    # a node's dendrites), reset by subtraction. No drive ⇒ no dendritic spikes.
    if m.dend_drive > 0.0
        _draw_noise!(ns.noise, ns.dend_noise)
        @inbounds for d in 1:D, j in 1:N
            sig = _logistic_drive(ns.node_deficit[j], m.drive_floor, m.dend_drive, m.drive_d0, m.drive_w)
            ns.dend_acts[j, d] += ns.dend_noise[j, d] * sig
            if ns.dend_acts[j, d] >= m.dend_threshold
                ns.dend_spike[j, d] = true
                ns.dend_acts[j, d] -= m.dend_threshold
            else
                ns.dend_spike[j, d] = false
            end
        end
    else
        fill!(ns.dend_spike, false)
    end

    # Optionally, dendritic spikes inject unit current into the soma. When
    # `eligibility_only` (default) they touch learning only, not the membrane.
    if !m.eligibility_only
        @inbounds for j in 1:N
            extra = 0.0
            for d in 1:D
                extra += ns.dend_spike[j, d] ? 1.0 : 0.0
            end
            ns.acts[j] += extra
        end
    end

    # Optional somatic drive (same logistic gate on the somatic deficit).
    if m.soma_drive > 0.0
        _draw_noise!(ns.noise, ns.soma_noise)
        @inbounds for j in 1:N
            soma_def = max(0.0, ns.targets[j] - ns.acts[j])
            sig = _logistic_drive(soma_def, m.drive_floor, m.soma_drive, m.drive_d0, m.drive_w)
            ns.acts[j] += ns.soma_noise[j] * sig
        end
    end

    if m.rectify
        @inbounds for j in 1:N
            if ns.acts[j] < 0.0
                ns.acts[j] = 0.0
            end
        end
    end

    @inbounds for j in 1:N
        threshold = ns.targets[j] * params.threshold_mult
        ns.spikes[j] = ns.acts[j] >= threshold ? 1.0 : 0.0
        if ns.spikes[j] == 1.0
            ns.acts[j] -= threshold
        end
        ns.errors[j] = ns.acts[j] - ns.targets[j]
    end

    params.learn_on && _dendritic_learn!(c, cs, ns, m)

    return copy(ns.spikes)
end

# Eligibility-gated homeostatic weight update. A synapse i→j is plastic when its
# presynaptic node fired OR the post-node dendrite it routes to spiked; the error
# is shared over the eligible presynaptic count, exactly as in base Falandays but
# with the widened gate. Targets update with the standard homeostatic rule.
function _dendritic_learn!(c::DendriticConnectome, cs::DendriticConnState, ns::DendriticNodeState, m::DendriticModel)
    params = m.params
    wmat = cs.wmat
    N = length(ns.acts)

    fill!(ns.counts, 0.0)
    total = 0.0
    @inbounds for j in 1:N
        cnt = 0.0
        for i in 1:N
            if c.recurrent_mask[i, j] &&
               (ns.prev_spikes[i] > 0.0 || ns.dend_spike[j, c.dend_id[i, j]])
                cnt += 1.0
            end
        end
        ns.counts[j] = cnt
        total += cnt
    end

    if total > 0.0
        @inbounds for j in 1:N
            if ns.counts[j] > 0.0
                delta = ns.errors[j] / ns.counts[j] * params.lrate_wmat
                for i in 1:N
                    if c.recurrent_mask[i, j] &&
                       (ns.prev_spikes[i] > 0.0 || ns.dend_spike[j, c.dend_id[i, j]])
                        wmat[i, j] -= delta
                    end
                end
            end
        end
    end

    _update_targets!(ns.targets, ns.errors, params)
    return wmat
end

function effectors(m::DendriticModel, c::DendriticConnectome, spikes, n_eff)
    spikes = _float_vector(spikes, "spikes")
    n_nodes = size(c.output_mask, 1)
    length(spikes) == n_nodes ||
        throw(DimensionMismatch("expected $(n_nodes) spikes, got $(length(spikes))"))

    out = zeros(Float64, n_eff)
    @inbounds for k in 1:n_eff
        count = 0.0
        total = 0.0
        for i in eachindex(spikes)
            count += c.output_mask[i, k]
            total += spikes[i] * c.output_mask[i, k]
        end
        if count > 0.0
            out[k] = total / count
        end
    end
    return out
end

function reset!(r::DendriticReservoir)
    cs = r.conn
    c = r.connectome
    ns = r.state
    cs.wmat .= c.wmat0
    fill!(ns.acts, 0.0)
    fill!(ns.targets, 1.0)
    fill!(ns.spikes, 0.0)
    fill!(ns.errors, 0.0)
    fill!(ns.prev_spikes, 0.0)
    fill!(ns.dend_acts, 0.0)
    fill!(ns.dend_input, 0.0)
    fill!(ns.dend_spike, false)
    reset_noise!(ns.noise)
    return r
end

function snapshot_state(r::DendriticReservoir)
    ns = r.state
    cs = r.conn
    return (
        acts=copy(ns.acts),
        targets=copy(ns.targets),
        spikes=copy(ns.spikes),
        errors=copy(ns.errors),
        prev_spikes=copy(ns.prev_spikes),
        dend_acts=copy(ns.dend_acts),
        wmat=copy(cs.wmat),
        noise_idx=noise_index(ns.noise),
    )
end

function load_state!(r::DendriticReservoir, state)
    ns = r.state
    cs = r.conn
    copyto!(ns.acts, _float_vector(_state_get(state, :acts), "state.acts"))
    copyto!(ns.targets, _float_vector(_state_get(state, :targets), "state.targets"))
    copyto!(ns.spikes, _float_vector(_state_get(state, :spikes), "state.spikes"))
    copyto!(ns.errors, _float_vector(_state_get(state, :errors), "state.errors"))
    copyto!(ns.prev_spikes, _float_vector(_state_get(state, :prev_spikes), "state.prev_spikes"))
    if _state_has(state, :dend_acts)
        ns.dend_acts .= _float_matrix(_state_get(state, :dend_acts), "state.dend_acts")
    end
    cs.wmat .= _float_matrix(_state_get(state, :wmat), "state.wmat")
    return r
end
