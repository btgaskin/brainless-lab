using LinearAlgebra: norm
using Random
using StaticArrays: SVector

struct MetricSpace{D}
    lo::SVector{D,Float64}
    hi::SVector{D,Float64}
end

distance(::MetricSpace, a::SVector, b::SVector) = norm(a - b)

struct Embedding{D}
    node_pos::Vector{SVector{D,Float64}}
    receptor_anchor::Vector{SVector{D,Float64}}
    effector_anchor::Vector{SVector{D,Float64}}
end

struct ExpKernel
    p0::Float64
    lambda::Float64
end

connection_prob(k::ExpKernel, dist::Real) = k.p0 * exp(-Float64(dist) / k.lambda)

struct SpatialRule{D,K}
    space::MetricSpace{D}
    kernel::K
    link_p::Float64
    weight_init_std::Float64
end

struct SpatialConnectome{D} <: FalandaysConnectome
    recurrent_mask::BitMatrix
    input_wmat::Matrix{Float64}
    output_mask::Matrix{Float64}
    wmat0::Matrix{Float64}
    embedding::Embedding{D}
    regions::Vector{Int}
end

spatiality(::SpatialConnectome{D}) where {D} = Embedded{D}()

function _validate_spatial_dimensions(n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_nodes >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))
    return n_nodes, n_receptors_, n_effectors_
end

function _validate_spatial_rule(rule::SpatialRule{D}) where {D}
    D >= 1 || throw(ArgumentError("space dimension must be at least 1"))
    0.0 <= rule.link_p <= 1.0 || throw(ArgumentError("link_p must be in [0, 1]"))
    rule.weight_init_std >= 0.0 || throw(ArgumentError("weight_init_std must be non-negative"))
    @inbounds for i in 1:D
        rule.space.hi[i] >= rule.space.lo[i] ||
            throw(ArgumentError("space upper bounds must be greater than or equal to lower bounds"))
    end
    return rule
end

function _rand_position(space::MetricSpace{D}, rng::AbstractRNG) where {D}
    return SVector{D,Float64}(
        ntuple(i -> space.lo[i] + rand(rng) * (space.hi[i] - space.lo[i]), Val(D)),
    )
end

function build_spatial_connectome(
    N::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer,
    rule::SpatialRule{D,K},
    rng::AbstractRNG;
    input_weight::Real=_DEFAULT_SHARED_INPUT_WEIGHT,
) where {D,K}
    n_nodes, n_receptors_, n_effectors_ =
        _validate_spatial_dimensions(N, n_receptors_, n_effectors_)
    _validate_spatial_rule(rule)

    positions = Vector{SVector{D,Float64}}(undef, n_nodes)
    @inbounds for i in 1:n_nodes
        positions[i] = _rand_position(rule.space, rng)
    end

    recurrent_mask = falses(n_nodes, n_nodes)
    @inbounds for j in 1:n_nodes, i in 1:n_nodes
        if i != j
            dist = distance(rule.space, positions[i], positions[j])
            recurrent_mask[i, j] = rand(rng) < connection_prob(rule.kernel, dist)
        end
    end

    input_mask = bernoulli_mask(n_receptors_, n_nodes, rule.link_p, rng; diagonal=true)
    output_mask = bernoulli_mask(n_nodes, n_effectors_, rule.link_p, rng; diagonal=true)
    _ensure_unsigned_degree!(recurrent_mask, input_mask, rng)
    _ensure_output_mask!(output_mask, rng)

    input_wmat = Float64(input_weight) .* Float64.(input_mask)
    output_wmat = Float64.(output_mask)
    wmat0 = Float64.(recurrent_mask) .* (rule.weight_init_std .* randn(rng, n_nodes, n_nodes))
    embedding = Embedding(positions, SVector{D,Float64}[], SVector{D,Float64}[])
    regions = ones(Int, n_nodes)

    return SpatialConnectome{D}(recurrent_mask, input_wmat, output_wmat, wmat0, embedding, regions)
end

function _metric_space_extent(extent::Real, dims::Integer)
    D = Int(dims)
    D >= 1 || throw(ArgumentError("dims must be at least 1"))
    extent_ = Float64(extent)
    extent_ >= 0.0 || throw(ArgumentError("extent must be non-negative"))
    lo = SVector{D,Float64}(ntuple(_ -> 0.0, Val(D)))
    hi = SVector{D,Float64}(ntuple(_ -> extent_, Val(D)))
    return MetricSpace{D}(lo, hi)
end

function _spatial_native_options(params::FalandaysParams, kwargs)
    input_weight = params.input_weight
    inhibitory_frac = 0.25
    unknown = Symbol[]

    for (key, value) in pairs(kwargs)
        sym = Symbol(key)
        if sym === :input_weight
            input_weight = Float64(value)
        elseif sym === :inhibitory_frac
            inhibitory_frac = Float64(value)
        else
            push!(unknown, sym)
        end
    end

    isempty(unknown) ||
        throw(ArgumentError("unknown spatial Falandays keyword(s): $(join(string.(unknown), ", "))"))
    return input_weight, inhibitory_frac
end

function _falandays_spatial_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    p0::Real=0.5,
    lambda::Real=0.3,
    link_p::Real=0.1,
    extent::Real=1.0,
    dims::Integer=2,
    params=FalandaysParams(),
    drive::Drive=NoDrive(),
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
    space = _metric_space_extent(extent, dims)
    rule = SpatialRule(space, ExpKernel(Float64(p0), Float64(lambda)), Float64(link_p), params.weight_init_std)
    connectome = build_spatial_connectome(
        n_nodes,
        n_receptors_,
        n_effectors_,
        rule,
        rng;
        input_weight=input_weight,
    )

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source
    wmat = copy(connectome.wmat0)
    acts = zeros(Float64, n_nodes)
    targets = ones(Float64, n_nodes)
    spikes = zeros(Float64, n_nodes)
    errors = zeros(Float64, n_nodes)
    prev_spikes = zeros(Float64, n_nodes)

    return ReservoirInstance(
        FalandaysModel(params, drive, axis, Bool(rectify)),
        connectome,
        FalandaysConnState(wmat),
        FalandaysNeuronState(acts, targets, spikes, errors, prev_spikes, source),
        PortSpec(n_receptors_, n_effectors_),
    )
end
