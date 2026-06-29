using Random

const FALANDAYS_PARAM_DIM = 7
const _DEFAULT_SHARED_INPUT_WEIGHT = 1.875

Base.@kwdef struct FalandaysParams <: NodeModel
    leak::Float64 = 0.25
    lrate_wmat::Float64 = 0.1
    lrate_targ::Float64 = 0.01
    threshold_mult::Float64 = 2.0
    targ_min::Float64 = 1.0
    input_weight::Float64 = _DEFAULT_SHARED_INPUT_WEIGHT
    weight_init_std::Float64 = 1.0
    learn_on::Bool = true
end

paramdim(::Type{FalandaysParams}) = FALANDAYS_PARAM_DIM
paramdim(::FalandaysParams) = FALANDAYS_PARAM_DIM

_sigmoid_clipped(x) = sigmoid(clamp(Float64(x), -60.0, 60.0))

function _inverse_sigmoid(p)
    p = clamp(Float64(p), 1e-12, 1.0 - 1e-12)
    return log(p / (1.0 - p))
end

function _inverse_softplus(y)
    y = max(Float64(y), 1e-12)
    if y > 50.0
        return y
    end
    return log(expm1(y))
end

function unpack_params(::Type{FalandaysParams}, raw::AbstractVector{<:Real})::FalandaysParams
    length(raw) == FALANDAYS_PARAM_DIM ||
        throw(ArgumentError("expected raw vector of length $(FALANDAYS_PARAM_DIM), got $(length(raw))"))

    return FalandaysParams(
        leak=_sigmoid_clipped(raw[1]),
        lrate_wmat=softplus(Float64(raw[2])),
        lrate_targ=softplus(Float64(raw[3])),
        threshold_mult=0.1 + softplus(Float64(raw[4])),
        targ_min=0.1 + softplus(Float64(raw[5])),
        input_weight=softplus(Float64(raw[6])),
        weight_init_std=softplus(Float64(raw[7])),
        learn_on=true,
    )
end

function pack_params(p::FalandaysParams)
    return Float64[
        _inverse_sigmoid(p.leak),
        _inverse_softplus(p.lrate_wmat),
        _inverse_softplus(p.lrate_targ),
        _inverse_softplus(p.threshold_mult - 0.1),
        _inverse_softplus(p.targ_min - 0.1),
        _inverse_softplus(p.input_weight),
        _inverse_softplus(p.weight_init_std),
    ]
end

pack_params(::Type{FalandaysParams}) = pack_params(FalandaysParams())

mutable struct RngNoise
    rng::AbstractRNG
    seed::Union{Nothing,Int}
end

RngNoise(rng::AbstractRNG) = RngNoise(rng, nothing)
RngNoise(seed::Integer) = RngNoise(MersenneTwister(Int(seed)), Int(seed))
RngNoise(; seed::Integer=0) = RngNoise(seed)

mutable struct RecordedNoise
    draws::Matrix{Float64}
    idx::Int
end

RecordedNoise(draws::AbstractMatrix{<:Real}, idx::Integer=1) =
    RecordedNoise(Matrix{Float64}(Float64.(draws)), Int(idx))

function next_noise!(source::RngNoise, n::Integer)
    return randn(source.rng, Int(n))
end

function next_noise!(source::RecordedNoise, n::Integer)
    n = Int(n)
    size(source.draws, 2) == n ||
        throw(DimensionMismatch("recorded noise width $(size(source.draws, 2)) does not match requested length $n"))
    source.idx <= size(source.draws, 1) ||
        throw(BoundsError(source.draws, (source.idx, :)))

    noise = copy(vec(@view source.draws[source.idx, :]))
    source.idx += 1
    return noise
end

function reset_noise!(source::RngNoise)
    if source.seed !== nothing
        source.rng = MersenneTwister(source.seed)
    end
    return source
end

function reset_noise!(source::RecordedNoise)
    source.idx = 1
    return source
end

reset_noise!(source) = source

noise_index(source::RecordedNoise) = source.idx
noise_index(source) = nothing

mutable struct FalandaysReservoir{D<:Drive,S} <: Reservoir
    params::FalandaysParams
    drive::D
    sign::S
    rectify::Bool
    recurrent_mask::BitMatrix
    input_wmat::Matrix{Float64}
    output_mask::Matrix{Float64}
    wmat::Matrix{Float64}
    wmat0::Matrix{Float64}
    acts::Vector{Float64}
    targets::Vector{Float64}
    spikes::Vector{Float64}
    errors::Vector{Float64}
    prev_spikes::Vector{Float64}
    noise_source::Any
    n_receptors::Int
    n_effectors::Int
end

_as_falandays_params(p::FalandaysParams) = p
_as_falandays_params(raw::AbstractVector{<:Real}) = unpack_params(FalandaysParams, raw)

function _float_matrix(x, name::AbstractString)
    ndims(x) == 2 || throw(ArgumentError("$name must be a matrix"))
    return Matrix{Float64}(Float64.(x))
end

function _float_vector(x, name::AbstractString)
    v = vec(Float64.(x))
    return Vector{Float64}(v)
end

function _bitmatrix(x, name::AbstractString)
    ndims(x) == 2 || throw(ArgumentError("$name must be a matrix"))
    mask = falses(size(x, 1), size(x, 2))
    @inbounds for j in axes(mask, 2), i in axes(mask, 1)
        mask[i, j] = x[i, j] != 0
    end
    return mask
end

function _normalize_axis(axis::Unsigned, n::Integer)
    return axis
end

function _normalize_axis(axis::Dale, n::Integer)
    length(axis.sign) == Int(n) ||
        throw(DimensionMismatch("Dale sign length $(length(axis.sign)) does not match reservoir size $(Int(n))"))
    return axis
end

function _normalize_axis(sign::AbstractVector{<:Real}, n::Integer)
    length(sign) == Int(n) ||
        throw(DimensionMismatch("sign length $(length(sign)) does not match reservoir size $(Int(n))"))
    all(x -> x == 1 || x == -1, sign) ||
        throw(ArgumentError("sign entries must be +1 or -1"))

    s = Int.(sign)
    if all(==(1), s)
        return Unsigned()
    end
    return Dale(s)
end

function _native_axis(axis::Unsigned, n::Integer, rng::AbstractRNG, inhibitory_frac::Real)
    return axis
end

function _native_axis(axis::Dale, n::Integer, rng::AbstractRNG, inhibitory_frac::Real)
    return _normalize_axis(axis, n)
end

function _native_axis(sign::AbstractVector{<:Real}, n::Integer, rng::AbstractRNG, inhibitory_frac::Real)
    return _normalize_axis(sign, n)
end

function _native_axis(sign::Symbol, n::Integer, rng::AbstractRNG, inhibitory_frac::Real)
    if sign == :unsigned
        return Unsigned()
    elseif sign == :dale
        return Dale(dale_signs(n, inhibitory_frac, rng))
    end
    throw(ArgumentError("unknown sign axis :$sign"))
end

function _validate_dimensions(input_wmat, wmat0, recurrent_mask, output_mask)
    n_receptors, n_nodes = size(input_wmat)
    size(wmat0) == (n_nodes, n_nodes) ||
        throw(DimensionMismatch("wmat0 size $(size(wmat0)) must be ($n_nodes, $n_nodes)"))
    size(recurrent_mask) == (n_nodes, n_nodes) ||
        throw(DimensionMismatch("recurrent_mask size $(size(recurrent_mask)) must be ($n_nodes, $n_nodes)"))
    size(output_mask, 1) == n_nodes ||
        throw(DimensionMismatch("output_mask row count $(size(output_mask, 1)) must be $n_nodes"))
    return n_nodes, n_receptors, size(output_mask, 2)
end

function FalandaysReservoir(;
    params=FalandaysParams(),
    drive::Drive=NoDrive(),
    sign=Unsigned(),
    recurrent_mask,
    input_wmat,
    output_mask,
    wmat0,
    noise_source=nothing,
    rectify::Bool=true,
)
    params = _as_falandays_params(params)
    input_wmat = _float_matrix(input_wmat, "input_wmat")
    wmat0 = _float_matrix(wmat0, "wmat0")
    recurrent_mask = _bitmatrix(recurrent_mask, "recurrent_mask")
    output_mask = _float_matrix(output_mask, "output_mask")

    n_nodes, n_receptors_, n_effectors_ =
        _validate_dimensions(input_wmat, wmat0, recurrent_mask, output_mask)
    axis = _normalize_axis(sign, n_nodes)
    source = noise_source === nothing ? RngNoise(0) : noise_source

    return FalandaysReservoir(
        params,
        drive,
        axis,
        rectify,
        recurrent_mask,
        input_wmat,
        output_mask,
        copy(wmat0),
        copy(wmat0),
        zeros(Float64, n_nodes),
        ones(Float64, n_nodes),
        zeros(Float64, n_nodes),
        zeros(Float64, n_nodes),
        zeros(Float64, n_nodes),
        source,
        n_receptors_,
        n_effectors_,
    )
end

function _rng_from_seed(seed)
    if seed === nothing
        return MersenneTwister()
    end
    return MersenneTwister(Int(seed))
end

function _noise_source_from_seed(seed)
    if seed === nothing
        return RngNoise(MersenneTwister())
    end
    return RngNoise(Int(seed) + 999983)
end

function _ensure_output_mask!(output_mask::BitMatrix, rng::AbstractRNG)
    n_nodes, n_effectors_ = size(output_mask)
    for k in 1:n_effectors_
        if !any(@view output_mask[:, k])
            output_mask[rand(rng, 1:n_nodes), k] = true
        end
    end
    return output_mask
end

function _ensure_unsigned_degree!(recurrent_mask::BitMatrix, input_mask::BitMatrix, rng::AbstractRNG)
    n_receptors_, n_nodes = size(input_mask)
    @inbounds for node in 1:n_nodes
        degree = count(@view recurrent_mask[:, node]) + count(@view input_mask[:, node])
        if degree == 0
            input_mask[rand(rng, 1:n_receptors_), node] = true
        end
    end
    return input_mask
end

function FalandaysReservoir(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    params=FalandaysParams(),
    seed=nothing,
    input_weight=nothing,
    link_p::Real=0.1,
    drive::Drive=NoDrive(),
    sign=Unsigned(),
    rectify=nothing,
    noise_source=nothing,
    topology=nothing,
    inhibitory_frac::Real=0.25,
    sw_beta::Real=0.1,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_nodes >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    params = _as_falandays_params(params)
    link_p = Float64(link_p)
    0.0 <= link_p <= 1.0 || throw(ArgumentError("link_p must be in [0, 1]"))

    rng = _rng_from_seed(seed)
    axis = _native_axis(sign, n_nodes, rng, inhibitory_frac)
    rectify = rectify === nothing ? !(axis isa Dale) : Bool(rectify)
    topology = topology === nothing ? (axis isa Dale ? :watts_strogatz : :bernoulli) : topology

    recurrent_mask =
        topology == :watts_strogatz ?
        directed_watts_strogatz(n_nodes, round(Int, n_nodes * link_p), sw_beta, rng) :
        topology == :bernoulli ?
        bernoulli_mask(n_nodes, n_nodes, link_p, rng; diagonal=false) :
        throw(ArgumentError("unknown topology :$topology"))

    input_mask = bernoulli_mask(n_receptors_, n_nodes, link_p, rng; diagonal=true)
    output_mask = bernoulli_mask(n_nodes, n_effectors_, link_p, rng; diagonal=true)

    if !(axis isa Dale)
        _ensure_unsigned_degree!(recurrent_mask, input_mask, rng)
    end
    _ensure_output_mask!(output_mask, rng)

    input_weight = input_weight === nothing ? params.input_weight : Float64(input_weight)
    input_wmat = input_weight .* Float64.(input_mask)
    output_wmat = Float64.(output_mask)

    if axis isa Dale
        weights = 1.0 .+ 0.2 .* randn(rng, n_nodes, n_nodes)
        @inbounds for j in 1:n_nodes, i in 1:n_nodes
            if weights[i, j] < 0.0
                weights[i, j] = 0.0
            end
        end
        wmat0 = Float64.(recurrent_mask) .* weights
    else
        wmat0 = Float64.(recurrent_mask) .* (params.weight_init_std .* randn(rng, n_nodes, n_nodes))
    end

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source

    return FalandaysReservoir(
        params=params,
        drive=drive,
        sign=axis,
        recurrent_mask=recurrent_mask,
        input_wmat=input_wmat,
        output_mask=output_wmat,
        wmat0=wmat0,
        noise_source=source,
        rectify=rectify,
    )
end

function step!(r::FalandaysReservoir, receptor_currents)
    receptor_currents = _float_vector(receptor_currents, "receptor_currents")
    length(receptor_currents) == r.n_receptors ||
        throw(DimensionMismatch("expected $(r.n_receptors) receptor currents, got $(length(receptor_currents))"))

    params = r.params
    n = length(r.acts)
    copyto!(r.prev_spikes, r.spikes)

    input_current = vec(transpose(receptor_currents) * r.input_wmat)
    recurrent_current = recurrent_input(r.sign, r.wmat, r.prev_spikes)

    @inbounds for i in 1:n
        r.acts[i] = r.acts[i] * (1.0 - params.leak) + input_current[i] + recurrent_current[i]
    end

    apply_drive!(r.drive, r.acts, r.targets, params, next_noise!(r.noise_source, n))

    if r.rectify
        @inbounds for i in 1:n
            if r.acts[i] < 0.0
                r.acts[i] = 0.0
            end
        end
    end

    thresholds = r.targets .* params.threshold_mult

    @inbounds for i in 1:n
        r.spikes[i] = r.acts[i] >= thresholds[i] ? 1.0 : 0.0
        if r.spikes[i] == 1.0
            r.acts[i] -= thresholds[i]
        end
        r.errors[i] = r.acts[i] - r.targets[i]
    end

    if params.learn_on
        learn!(r.sign, r.wmat, r.targets, r.errors, r.recurrent_mask, r.prev_spikes, params)
    end

    return copy(r.spikes)
end

function effectors(r::FalandaysReservoir, spikes)
    spikes = _float_vector(spikes, "spikes")
    length(spikes) == length(r.spikes) ||
        throw(DimensionMismatch("expected $(length(r.spikes)) spikes, got $(length(spikes))"))

    out = zeros(Float64, r.n_effectors)
    @inbounds for k in 1:r.n_effectors
        count = 0.0
        total = 0.0
        for i in eachindex(spikes)
            count += r.output_mask[i, k]
            total += spikes[i] * r.output_mask[i, k]
        end
        if count > 0.0
            out[k] = total / count
        end
    end
    return out
end

effectors(r::FalandaysReservoir) = effectors(r, r.spikes)

function reset!(r::FalandaysReservoir)
    r.wmat .= r.wmat0
    fill!(r.acts, 0.0)
    fill!(r.targets, 1.0)
    fill!(r.spikes, 0.0)
    fill!(r.errors, 0.0)
    fill!(r.prev_spikes, 0.0)
    reset_noise!(r.noise_source)
    return r
end

n_receptors(r::FalandaysReservoir) = r.n_receptors
n_effectors(r::FalandaysReservoir) = r.n_effectors

function snapshot_state(r::FalandaysReservoir)
    return (
        acts=copy(r.acts),
        targets=copy(r.targets),
        spikes=copy(r.spikes),
        errors=copy(r.errors),
        prev_spikes=copy(r.prev_spikes),
        wmat=copy(r.wmat),
        noise_idx=noise_index(r.noise_source),
    )
end

function _state_has(state, key::Symbol)
    return state isa AbstractDict ? haskey(state, key) : hasproperty(state, key)
end

function _state_get(state, key::Symbol)
    return state isa AbstractDict ? state[key] : getproperty(state, key)
end

function load_state!(r::FalandaysReservoir, state)
    copyto!(r.acts, _float_vector(_state_get(state, :acts), "state.acts"))
    copyto!(r.targets, _float_vector(_state_get(state, :targets), "state.targets"))
    copyto!(r.spikes, _float_vector(_state_get(state, :spikes), "state.spikes"))
    copyto!(r.errors, _float_vector(_state_get(state, :errors), "state.errors"))
    copyto!(r.prev_spikes, _float_vector(_state_get(state, :prev_spikes), "state.prev_spikes"))
    r.wmat .= _float_matrix(_state_get(state, :wmat), "state.wmat")

    if _state_has(state, :noise_idx) && r.noise_source isa RecordedNoise
        idx = _state_get(state, :noise_idx)
        if idx !== nothing
            r.noise_source.idx = Int(idx)
        end
    end

    return r
end

function falandays_oosawa(args...; membrane_noise::Real=0.0, noise_gain::Real=0.0, kwargs...)
    return FalandaysReservoir(
        args...;
        drive=OosawaDrive(membrane_noise=Float64(membrane_noise), noise_gain=Float64(noise_gain)),
        kwargs...,
    )
end

function falandays_dale(args...; kwargs...)
    return FalandaysReservoir(
        args...;
        sign=:dale,
        topology=:watts_strogatz,
        rectify=false,
        kwargs...,
    )
end
