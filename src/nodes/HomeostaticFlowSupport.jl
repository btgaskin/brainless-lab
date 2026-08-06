using Random

# Shared construction, genome, and state-loading helpers for HomeostaticFlow V2.
# Keep these transformations stable: stored genomes depend on their exact
# bijections.
const HFR_EPS = 1.0e-12

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
