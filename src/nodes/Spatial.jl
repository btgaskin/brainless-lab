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

# Bounded power-law decay: p0 at d=0, no singularity, heavier tail than
# ExpKernel for d >> d0 (power decay vs exponential decay).
struct PowerLawKernel
    p0::Float64
    d0::Float64
    alpha::Float64
end

connection_prob(k::PowerLawKernel, dist::Real) = k.p0 / (1.0 + Float64(dist) / k.d0)^k.alpha

function _spatial_kernel(kernel::Union{Symbol,AbstractString}, p0::Real, lambda::Real, d0::Real, alpha::Real)
    kernel_sym = Symbol(kernel)
    p0_ = _validate_spatial_probability("p0", p0)
    if kernel_sym === :exp
        lambda_ = Float64(lambda)
        lambda_ > 0.0 || throw(ArgumentError("lambda must be positive"))
        return ExpKernel(p0_, lambda_)
    elseif kernel_sym === :power_law
        d0_ = Float64(d0)
        d0_ > 0.0 || throw(ArgumentError("d0 must be positive"))
        alpha_ = Float64(alpha)
        alpha_ > 0.0 || throw(ArgumentError("alpha must be positive"))
        return PowerLawKernel(p0_, d0_, alpha_)
    else
        throw(ArgumentError("unknown spatial kernel :$(kernel_sym) (expected :exp or :power_law)"))
    end
end

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

function _validate_effector_wiring(effector_wiring::Union{Symbol,AbstractString})
    sym = Symbol(effector_wiring)
    sym in (:bernoulli, :spatial) ||
        throw(ArgumentError("unknown effector_wiring :$(sym) (expected :bernoulli or :spatial)"))
    return sym
end

# Node-effector link probability drawn from the same distance kernel used for
# recurrent (node-node) wiring, rather than a flat Bernoulli(link_p).
function _kernel_output_mask(kernel, space::MetricSpace{D}, node_positions, effector_positions, rng::AbstractRNG) where {D}
    n_nodes = length(node_positions)
    n_effectors_ = length(effector_positions)
    mask = falses(n_nodes, n_effectors_)
    @inbounds for k in 1:n_effectors_, i in 1:n_nodes
        dist = distance(space, node_positions[i], effector_positions[k])
        mask[i, k] = rand(rng) < connection_prob(kernel, dist)
    end
    return mask
end

function build_spatial_connectome(
    N::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer,
    rule::SpatialRule{D,K},
    rng::AbstractRNG;
    input_weight::Real=_DEFAULT_SHARED_INPUT_WEIGHT,
    effector_wiring::Union{Symbol,AbstractString}=:bernoulli,
) where {D,K}
    n_nodes, n_receptors_, n_effectors_ =
        _validate_spatial_dimensions(N, n_receptors_, n_effectors_)
    _validate_spatial_rule(rule)
    effector_wiring = _validate_effector_wiring(effector_wiring)

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

    effector_positions = SVector{D,Float64}[]
    if effector_wiring === :spatial
        effector_positions = [_rand_position(rule.space, rng) for _ in 1:n_effectors_]
        output_mask = _kernel_output_mask(rule.kernel, rule.space, positions, effector_positions, rng)
    else
        output_mask = bernoulli_mask(n_nodes, n_effectors_, rule.link_p, rng; diagonal=true)
    end
    _ensure_unsigned_degree!(recurrent_mask, input_mask, rng)
    _ensure_output_mask!(output_mask, rng)

    input_wmat = Float64(input_weight) .* Float64.(input_mask)
    output_wmat = Float64.(output_mask)
    wmat0 = Float64.(recurrent_mask) .* (rule.weight_init_std .* randn(rng, n_nodes, n_nodes))
    embedding = Embedding(positions, SVector{D,Float64}[], effector_positions)
    regions = ones(Int, n_nodes)

    return SpatialConnectome{D}(recurrent_mask, input_wmat, output_wmat, wmat0, embedding, regions)
end

function _validate_hemispheric_dimensions(
    N::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer,
)
    n_nodes, n_receptors_, n_effectors_ =
        _validate_spatial_dimensions(N, n_receptors_, n_effectors_)
    n_nodes >= 2 || throw(ArgumentError("hemispheric node needs >= 2 nodes"))
    n_receptors_ >= 2 || throw(ArgumentError("hemispheric node needs >= 2 receptors to split left/right"))
    n_effectors_ >= 2 || throw(ArgumentError("hemispheric node needs >= 2 effectors to split left/right"))
    return n_nodes, n_receptors_, n_effectors_
end

function _validate_spatial_probability(name::AbstractString, p::Real)
    p_ = Float64(p)
    0.0 <= p_ <= 1.0 || throw(ArgumentError("$name must be in [0, 1]"))
    return p_
end

function _body_target_nodes(index::Integer, left_count::Integer, na::Integer, n_nodes::Integer, contralateral::Bool)
    is_left_body = Int(index) <= Int(left_count)
    target_left_region = contralateral ? !is_left_body : is_left_body
    return target_left_region ? (1:Int(na)) : ((Int(na) + 1):Int(n_nodes))
end

function _node_source_receptors(node::Integer, left_receptors::Integer, na::Integer, n_receptors_::Integer, contralateral::Bool)
    is_left_region = Int(node) <= Int(na)
    source_left_body = contralateral ? !is_left_region : is_left_region
    return source_left_body ? (1:Int(left_receptors)) : ((Int(left_receptors) + 1):Int(n_receptors_))
end

function _effector_source_nodes(effector::Integer, left_effectors::Integer, na::Integer, n_nodes::Integer, contralateral::Bool)
    is_left_body = Int(effector) <= Int(left_effectors)
    source_left_region = contralateral ? !is_left_body : is_left_body
    return source_left_region ? (1:Int(na)) : ((Int(na) + 1):Int(n_nodes))
end

function _mask_hemispheric_input_blocks!(
    input_mask::BitMatrix,
    left_receptors::Integer,
    na::Integer,
    contralateral::Bool,
)
    n_receptors_, n_nodes = size(input_mask)
    left_receptor_rows = 1:Int(left_receptors)
    right_receptor_rows = (Int(left_receptors) + 1):n_receptors_
    left_nodes = 1:Int(na)
    right_nodes = (Int(na) + 1):n_nodes

    if contralateral
        input_mask[left_receptor_rows, left_nodes] .= false
        input_mask[right_receptor_rows, right_nodes] .= false
    else
        input_mask[left_receptor_rows, right_nodes] .= false
        input_mask[right_receptor_rows, left_nodes] .= false
    end
    return input_mask
end

function _mask_hemispheric_output_blocks!(
    output_mask::BitMatrix,
    left_effectors::Integer,
    na::Integer,
    contralateral::Bool,
)
    n_nodes, n_effectors_ = size(output_mask)
    left_nodes = 1:Int(na)
    right_nodes = (Int(na) + 1):n_nodes
    left_effector_cols = 1:Int(left_effectors)
    right_effector_cols = (Int(left_effectors) + 1):n_effectors_

    if contralateral
        output_mask[left_nodes, left_effector_cols] .= false
        output_mask[right_nodes, right_effector_cols] .= false
    else
        output_mask[left_nodes, right_effector_cols] .= false
        output_mask[right_nodes, left_effector_cols] .= false
    end
    return output_mask
end

function _ensure_hemispheric_input_mask!(
    input_mask::BitMatrix,
    recurrent_mask::BitMatrix,
    left_receptors::Integer,
    na::Integer,
    rng::AbstractRNG,
    contralateral::Bool,
)
    n_receptors_, n_nodes = size(input_mask)

    @inbounds for receptor in 1:n_receptors_
        targets = _body_target_nodes(receptor, left_receptors, na, n_nodes, contralateral)
        if !any(@view input_mask[receptor, targets])
            input_mask[receptor, rand(rng, targets)] = true
        end
    end

    @inbounds for node in 1:n_nodes
        degree = count(@view recurrent_mask[:, node]) + count(@view input_mask[:, node])
        if degree == 0
            sources = _node_source_receptors(node, left_receptors, na, n_receptors_, contralateral)
            input_mask[rand(rng, sources), node] = true
        end
    end

    return input_mask
end

function _ensure_hemispheric_output_mask!(
    output_mask::BitMatrix,
    left_effectors::Integer,
    na::Integer,
    rng::AbstractRNG,
    contralateral::Bool,
)
    n_nodes, n_effectors_ = size(output_mask)

    @inbounds for effector in 1:n_effectors_
        sources = _effector_source_nodes(effector, left_effectors, na, n_nodes, contralateral)
        if !any(@view output_mask[sources, effector])
            output_mask[rand(rng, sources), effector] = true
        end
    end

    return output_mask
end

"""
    build_hemispheric_connectome(N, n_receptors, n_effectors; rng, ...)

Build a two-region `SpatialConnectome{2}` with mirrored left/right node
positions. By default receptor and effector wiring is contralateral; set
`contralateral=false` for ipsilateral body-to-region and region-to-body wiring.
`callosum_density` controls bidirectional homotopic cross-region recurrent
links, with `0.0` yielding isolated hemispheres.

`kernel` selects the within-region node-node (and, with
`effector_wiring=:spatial`, node-effector) connection-probability decay:
`:exp` (default, `p0*exp(-d/lambda)`) or `:power_law`
(`p0/(1+d/d0)^alpha`, heavier-tailed). `callosum_density` is independent of
`kernel` -- it is always a flat cross-hemisphere coin flip per homotopic node
pair, not distance-decayed.
"""
function build_hemispheric_connectome(
    N::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    rng::AbstractRNG,
    kernel::Union{Symbol,AbstractString}=:exp,
    p0::Real=0.5,
    lambda::Real=0.3,
    d0::Real=0.3,
    alpha::Real=2.0,
    link_p::Real=0.1,
    extent::Real=1.0,
    callosum_density::Real=0.0,
    contralateral::Bool=true,
    effector_wiring::Union{Symbol,AbstractString}=:bernoulli,
    weight_init_std::Real,
    input_weight::Real,
)
    n_nodes, n_receptors_, n_effectors_ =
        _validate_hemispheric_dimensions(N, n_receptors_, n_effectors_)
    kernel_obj = _spatial_kernel(kernel, p0, lambda, d0, alpha)
    effector_wiring = _validate_effector_wiring(effector_wiring)
    link_p_ = _validate_spatial_probability("link_p", link_p)
    callosum_density_ = _validate_spatial_probability("callosum_density", callosum_density)
    extent_ = Float64(extent)
    extent_ >= 0.0 || throw(ArgumentError("extent must be non-negative"))
    weight_init_std_ = Float64(weight_init_std)
    weight_init_std_ >= 0.0 || throw(ArgumentError("weight_init_std must be non-negative"))
    input_weight_ = Float64(input_weight)

    na = cld(n_nodes, 2)
    nb = n_nodes - na
    regions = Vector{Int}(undef, n_nodes)
    regions[1:na] .= 1
    regions[(na + 1):n_nodes] .= 2

    gap = extent_ * 0.1
    left_x_hi = max(0.0, extent_ / 2.0 - gap)
    positions = Vector{SVector{2,Float64}}(undef, n_nodes)
    @inbounds for i in 1:na
        x = rand(rng) * left_x_hi
        y = rand(rng) * extent_
        positions[i] = SVector{2,Float64}(x, y)
        if i <= nb
            positions[na + i] = SVector{2,Float64}(extent_ - x, y)
        end
    end

    space = MetricSpace(SVector{2,Float64}(0.0, 0.0), SVector{2,Float64}(extent_, extent_))
    recurrent_mask = falses(n_nodes, n_nodes)
    @inbounds for j in 1:n_nodes, i in 1:n_nodes
        if i != j && regions[i] == regions[j]
            dist = distance(space, positions[i], positions[j])
            recurrent_mask[i, j] = rand(rng) < connection_prob(kernel_obj, dist)
        end
    end

    @inbounds for i in 1:min(na, nb)
        if rand(rng) < callosum_density_
            a = i
            b = na + i
            recurrent_mask[a, b] = true
            recurrent_mask[b, a] = true
        end
    end

    input_mask = bernoulli_mask(n_receptors_, n_nodes, link_p_, rng; diagonal=true)
    left_receptors = cld(n_receptors_, 2)
    left_effectors = cld(n_effectors_, 2)
    right_effectors = n_effectors_ - left_effectors

    effector_positions = SVector{2,Float64}[]
    if effector_wiring === :spatial
        effector_positions = Vector{SVector{2,Float64}}(undef, n_effectors_)
        @inbounds for i in 1:left_effectors
            x = rand(rng) * left_x_hi
            y = rand(rng) * extent_
            effector_positions[i] = SVector{2,Float64}(x, y)
            if i <= right_effectors
                effector_positions[left_effectors + i] = SVector{2,Float64}(extent_ - x, y)
            end
        end
        output_mask = _kernel_output_mask(kernel_obj, space, positions, effector_positions, rng)
    else
        output_mask = bernoulli_mask(n_nodes, n_effectors_, link_p_, rng; diagonal=true)
    end

    _mask_hemispheric_input_blocks!(input_mask, left_receptors, na, contralateral)
    _ensure_hemispheric_input_mask!(input_mask, recurrent_mask, left_receptors, na, rng, contralateral)
    _ensure_unsigned_degree!(recurrent_mask, input_mask, rng)

    _mask_hemispheric_output_blocks!(output_mask, left_effectors, na, contralateral)
    _ensure_hemispheric_output_mask!(output_mask, left_effectors, na, rng, contralateral)
    _ensure_output_mask!(output_mask, rng)

    input_wmat = input_weight_ .* Float64.(input_mask)
    output_wmat = Float64.(output_mask)
    wmat0 = Float64.(recurrent_mask) .* (weight_init_std_ .* randn(rng, n_nodes, n_nodes))
    embedding = Embedding(positions, SVector{2,Float64}[], effector_positions)

    return SpatialConnectome{2}(recurrent_mask, input_wmat, output_wmat, wmat0, embedding, regions)
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
    kernel::Union{Symbol,AbstractString}=:exp,
    p0::Real=0.5,
    lambda::Real=0.3,
    d0::Real=0.3,
    alpha::Real=2.0,
    link_p::Real=0.1,
    extent::Real=1.0,
    dims::Integer=2,
    effector_wiring::Union{Symbol,AbstractString}=:bernoulli,
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
    space = _metric_space_extent(extent, dims)
    kernel_obj = _spatial_kernel(kernel, p0, lambda, d0, alpha)
    rule = SpatialRule(space, kernel_obj, Float64(link_p), params.weight_init_std)
    connectome = build_spatial_connectome(
        n_nodes,
        n_receptors_,
        n_effectors_,
        rule,
        rng;
        input_weight=input_weight,
        effector_wiring=effector_wiring,
    )

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source
    wmat = copy(connectome.wmat0)
    acts = zeros(Float64, n_nodes)
    targets = ones(Float64, n_nodes)
    spikes = zeros(Float64, n_nodes)
    errors = zeros(Float64, n_nodes)
    prev_spikes = zeros(Float64, n_nodes)

    return ReservoirInstance(
        FalandaysModel(params, _resolve_drive_instance(drive), axis, Bool(rectify)),
        connectome,
        FalandaysConnState(wmat),
        FalandaysNodeState(acts, targets, spikes, errors, prev_spikes, source),
        PortSpec(n_receptors_, n_effectors_),
    )
end
