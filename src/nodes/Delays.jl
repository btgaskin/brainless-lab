struct DelayedConnectome{D} <: FalandaysConnectome
    recurrent_mask::BitMatrix
    input_wmat::Matrix{Float64}
    output_mask::Matrix{Float64}
    wmat0::Matrix{Float64}
    embedding::Embedding{D}
    regions::Vector{Int}
    delays::Matrix{Int}
    maxdelay::Int
    all_unit::Bool
end

spatiality(::DelayedConnectome{D}) where {D} = Embedded{D}()
delaykind(c::DelayedConnectome) = c.all_unit ? UnitDelay() : HeteroDelay()

function _delay_metric_space(::Embedding{D}) where {D}
    lo = SVector{D,Float64}(ntuple(_ -> 0.0, Val(D)))
    hi = SVector{D,Float64}(ntuple(_ -> 0.0, Val(D)))
    return MetricSpace{D}(lo, hi)
end

function _validate_delay_parameters(conduction_velocity, dt)
    velocity = Float64(conduction_velocity)
    dt_ = Float64(dt)
    isfinite(dt_) && dt_ > 0.0 ||
        throw(ArgumentError("dt must be positive and finite"))
    (!isnan(velocity) && (velocity > 0.0 || velocity == Inf)) ||
        throw(ArgumentError("conduction_velocity must be positive or Inf"))
    return velocity, dt_
end

function delays_from_embedding(
    embedding::Embedding{D},
    mask::AbstractMatrix,
    conduction_velocity,
    dt,
) where {D}
    n = length(embedding.node_pos)
    size(mask) == (n, n) ||
        throw(DimensionMismatch("delay mask size $(size(mask)) must be ($n, $n)"))

    velocity, dt_ = _validate_delay_parameters(conduction_velocity, dt)
    delays = ones(Int, n, n)
    if velocity == Inf
        return delays, 1, true
    end

    space = _delay_metric_space(embedding)
    denom = velocity * dt_
    maxdelay = 1
    all_unit = true
    @inbounds for j in 1:n, i in 1:n
        if mask[i, j] != 0
            dist = distance(space, embedding.node_pos[i], embedding.node_pos[j])
            d = max(1, ceil(Int, dist / denom))
            delays[i, j] = d
            if d > maxdelay
                maxdelay = d
            end
            if d != 1
                all_unit = false
            end
        end
    end

    return delays, maxdelay, all_unit
end

function _require_spike_history(c::DelayedConnectome, cs::FalandaysConnState)
    h = cs.history
    h !== nothing ||
        throw(ArgumentError("heterogeneous delayed connectomes require FalandaysConnState history"))
    size(h.buffer, 2) == size(c.recurrent_mask, 1) ||
        throw(DimensionMismatch("spike history width $(size(h.buffer, 2)) does not match connectome size $(size(c.recurrent_mask, 1))"))
    h.maxdelay >= c.maxdelay ||
        throw(DimensionMismatch("spike history maxdelay $(h.maxdelay) is less than connectome maxdelay $(c.maxdelay)"))
    return h
end

function recurrent_input(
    c::DelayedConnectome,
    sign::Unsigned,
    cs::FalandaysConnState,
    prev_spikes::AbstractVector{<:Real},
)
    if c.all_unit
        return recurrent_input(sign, cs.wmat, prev_spikes)
    end

    h = _require_spike_history(c, cs)
    push_spikes!(h, prev_spikes)
    n = size(cs.wmat, 2)
    out = zeros(Float64, n)
    @inbounds for j in 1:n
        total = 0.0
        for i in 1:size(cs.wmat, 1)
            if c.recurrent_mask[i, j]
                total += cs.wmat[i, j] * _delayed_spike(h, i, c.delays[i, j])
            end
        end
        out[j] = total
    end
    return out
end

function recurrent_input(
    c::DelayedConnectome,
    sign::Dale,
    cs::FalandaysConnState,
    prev_spikes::AbstractVector{<:Real},
)
    length(sign.sign) == length(prev_spikes) ||
        throw(DimensionMismatch("Dale sign length $(length(sign.sign)) does not match spike length $(length(prev_spikes))"))
    if c.all_unit
        return recurrent_input(sign, cs.wmat, prev_spikes)
    end

    h = _require_spike_history(c, cs)
    push_spikes!(h, prev_spikes)
    n = size(cs.wmat, 2)
    out = zeros(Float64, n)
    @inbounds for j in 1:n
        total = 0.0
        for i in 1:size(cs.wmat, 1)
            if c.recurrent_mask[i, j]
                total += sign.sign[i] * cs.wmat[i, j] * _delayed_spike(h, i, c.delays[i, j])
            end
        end
        out[j] = total
    end
    return out
end

function _delayed_learn_counts(c::DelayedConnectome, h::SpikeHistory)
    n = size(c.recurrent_mask, 2)
    counts = zeros(Float64, n)
    active_total = 0.0

    @inbounds for j in 1:n
        count = 0.0
        for i in 1:size(c.recurrent_mask, 1)
            if c.recurrent_mask[i, j] && _delayed_spike(h, i, c.delays[i, j]) != 0.0
                count += 1.0
            end
        end
        counts[j] = count
        active_total += count
    end

    return counts, active_total
end

function learn_connectome!(
    c::DelayedConnectome,
    sign::Unsigned,
    cs::FalandaysConnState,
    ns::FalandaysNodeState,
    params,
)
    if c.all_unit
        return learn!(sign, cs.wmat, ns.targets, ns.errors, c.recurrent_mask, ns.prev_spikes, params)
    end

    h = _require_spike_history(c, cs)
    counts, active_total = _delayed_learn_counts(c, h)

    if active_total > 0.0
        @inbounds for j in 1:size(cs.wmat, 2)
            if counts[j] > 0.0
                delta = ns.errors[j] / counts[j] * params.lrate_wmat
                for i in 1:size(cs.wmat, 1)
                    if c.recurrent_mask[i, j] && _delayed_spike(h, i, c.delays[i, j]) != 0.0
                        cs.wmat[i, j] -= delta
                    end
                end
            end
        end
    end

    _update_targets!(ns.targets, ns.errors, params)
    return cs.wmat
end

function learn_connectome!(
    c::DelayedConnectome,
    sign::Dale,
    cs::FalandaysConnState,
    ns::FalandaysNodeState,
    params,
)
    if c.all_unit
        return learn!(sign, cs.wmat, ns.targets, ns.errors, c.recurrent_mask, ns.prev_spikes, params)
    end

    h = _require_spike_history(c, cs)
    counts, active_total = _delayed_learn_counts(c, h)

    if active_total > 0.0
        @inbounds for j in 1:size(cs.wmat, 2)
            if counts[j] > 0.0
                delta = ns.errors[j] / counts[j] * params.lrate_wmat
                for i in 1:size(cs.wmat, 1)
                    if c.recurrent_mask[i, j] && _delayed_spike(h, i, c.delays[i, j]) != 0.0
                        signed_delta = sign.sign[i] == -1 ? -delta : delta
                        cs.wmat[i, j] -= signed_delta
                        if cs.wmat[i, j] < 0.0
                            cs.wmat[i, j] = 0.0
                        end
                    end
                end
            end

            @inbounds for j in 1:size(cs.wmat, 2), i in 1:size(cs.wmat, 1)
                if !c.recurrent_mask[i, j]
                    cs.wmat[i, j] = 0.0
                end
            end
        end
    end

    _update_targets!(ns.targets, ns.errors, params)
    return cs.wmat
end

function build_delayed_connectome(
    N::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    rng::AbstractRNG,
    p0::Real=0.5,
    lambda::Real=0.3,
    link_p::Real=0.1,
    extent::Real=1.0,
    dims::Integer=2,
    conduction_velocity=Inf,
    dt::Real=1.0,
    weight_init_std::Real,
    input_weight::Real,
)
    space = _metric_space_extent(extent, dims)
    rule = SpatialRule(
        space,
        ExpKernel(Float64(p0), Float64(lambda)),
        Float64(link_p),
        Float64(weight_init_std),
    )
    base = build_spatial_connectome(
        N,
        n_receptors_,
        n_effectors_,
        rule,
        rng;
        input_weight=input_weight,
    )
    delays, maxdelay, all_unit =
        delays_from_embedding(base.embedding, base.recurrent_mask, conduction_velocity, dt)
    return DelayedConnectome{length(space.lo)}(
        base.recurrent_mask,
        base.input_wmat,
        base.output_mask,
        base.wmat0,
        base.embedding,
        base.regions,
        delays,
        maxdelay,
        all_unit,
    )
end

function _falandays_delayed_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    conduction_velocity=Inf,
    p0::Real=0.5,
    lambda::Real=0.3,
    link_p::Real=0.1,
    extent::Real=1.0,
    dims::Integer=2,
    dt::Real=1.0,
    params=FalandaysParams(),
    drive=NoDrive(),
    sign=Unsigned(),
    rectify=true,
    noise_source=nothing,
    kwargs...,
)
    n_nodes, n_receptors_, n_effectors_ =
        _validate_spatial_dimensions(n_nodes, n_receptors_, n_effectors_)
    params = _as_falandays_params(params)
    input_weight, inhibitory_frac = _spatial_native_options(params, kwargs)

    rng = _rng_from_seed(seed)
    axis = _native_axis(sign, n_nodes, rng, inhibitory_frac)
    connectome = build_delayed_connectome(
        n_nodes,
        n_receptors_,
        n_effectors_;
        rng=rng,
        p0=p0,
        lambda=lambda,
        link_p=link_p,
        extent=extent,
        dims=dims,
        conduction_velocity=conduction_velocity,
        dt=dt,
        weight_init_std=params.weight_init_std,
        input_weight=input_weight,
    )

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source
    wmat = copy(connectome.wmat0)
    acts = zeros(Float64, n_nodes)
    targets = ones(Float64, n_nodes)
    spikes = zeros(Float64, n_nodes)
    errors = zeros(Float64, n_nodes)
    prev_spikes = zeros(Float64, n_nodes)
    conn = connectome.all_unit ?
        FalandaysConnState(wmat) :
        FalandaysConnState(wmat, SpikeHistory(n_nodes, connectome.maxdelay))

    return ReservoirInstance(
        FalandaysModel(params, _resolve_drive_instance(drive), axis, Bool(rectify)),
        connectome,
        conn,
        FalandaysNodeState(acts, targets, spikes, errors, prev_spikes, source),
        PortSpec(n_receptors_, n_effectors_),
    )
end
