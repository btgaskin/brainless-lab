using Random

struct Unsigned end

struct Dale
    sign::Vector{Int}

    function Dale(sign::AbstractVector{<:Integer})
        s = Vector{Int}(sign)
        all(x -> x == 1 || x == -1, s) ||
            throw(ArgumentError("Dale signs must be +1 or -1"))
        return new(s)
    end
end

function recurrent_input(::Unsigned, wmat::AbstractMatrix{<:Real}, prev_spikes::AbstractVector{<:Real})
    return vec(transpose(prev_spikes) * wmat)
end

function recurrent_input(axis::Dale, wmat::AbstractMatrix{<:Real}, prev_spikes::AbstractVector{<:Real})
    length(axis.sign) == length(prev_spikes) ||
        throw(DimensionMismatch("Dale sign length $(length(axis.sign)) does not match spike length $(length(prev_spikes))"))
    signed_prev = prev_spikes .* axis.sign
    return vec(transpose(signed_prev) * wmat)
end

function _learn_counts(mask::BitMatrix, prev_spikes::AbstractVector{<:Real})
    n = size(mask, 2)
    counts = zeros(Float64, n)
    active_total = 0.0

    @inbounds for j in 1:n
        count = 0.0
        for i in 1:size(mask, 1)
            if mask[i, j] && prev_spikes[i] != 0.0
                count += 1.0
            end
        end
        counts[j] = count
        active_total += count
    end

    return counts, active_total
end

function _update_targets!(targets::Vector{Float64}, errors::AbstractVector{<:Real}, p)
    @inbounds for i in eachindex(targets)
        targets[i] += errors[i] * p.lrate_targ
        if targets[i] < p.targ_min
            targets[i] = p.targ_min
        end
    end
    return targets
end

function learn!(
    ::Unsigned,
    wmat::Matrix{Float64},
    targets::Vector{Float64},
    errors::Vector{Float64},
    mask::BitMatrix,
    prev_spikes::Vector{Float64},
    p,
)
    counts, active_total = _learn_counts(mask, prev_spikes)

    if active_total > 0.0
        @inbounds for j in 1:size(wmat, 2)
            if counts[j] > 0.0
                delta = errors[j] / counts[j] * p.lrate_wmat
                for i in 1:size(wmat, 1)
                    if mask[i, j] && prev_spikes[i] != 0.0
                        wmat[i, j] -= delta
                    end
                end
            end
        end
    end

    _update_targets!(targets, errors, p)
    return wmat
end

function learn!(
    axis::Dale,
    wmat::Matrix{Float64},
    targets::Vector{Float64},
    errors::Vector{Float64},
    mask::BitMatrix,
    prev_spikes::Vector{Float64},
    p,
)
    counts, active_total = _learn_counts(mask, prev_spikes)

    if active_total > 0.0
        @inbounds for j in 1:size(wmat, 2)
            if counts[j] > 0.0
                delta = errors[j] / counts[j] * p.lrate_wmat
                for i in 1:size(wmat, 1)
                    if mask[i, j] && prev_spikes[i] != 0.0
                        signed_delta = axis.sign[i] == -1 ? -delta : delta
                        wmat[i, j] -= signed_delta
                        if wmat[i, j] < 0.0
                            wmat[i, j] = 0.0
                        end
                    end
                end
            end
        end

        @inbounds for j in 1:size(wmat, 2), i in 1:size(wmat, 1)
            if !mask[i, j]
                wmat[i, j] = 0.0
            end
        end
    end

    _update_targets!(targets, errors, p)
    return wmat
end

function bernoulli_mask(rows::Integer, cols::Integer, p::Real, rng::AbstractRNG=Random.default_rng(); diagonal::Bool=false)
    rows >= 0 || throw(ArgumentError("rows must be non-negative"))
    cols >= 0 || throw(ArgumentError("cols must be non-negative"))
    0.0 <= p <= 1.0 || throw(ArgumentError("p must be in [0, 1]"))

    mask = falses(Int(rows), Int(cols))
    @inbounds for j in 1:Int(cols), i in 1:Int(rows)
        mask[i, j] = rand(rng) < p
    end

    if !diagonal && rows == cols
        @inbounds for i in 1:Int(rows)
            mask[i, i] = false
        end
    end

    return mask
end

function bernoulli_mask(probabilities::AbstractVector{<:Real}, cols::Integer, rng::AbstractRNG=Random.default_rng(); diagonal::Bool=true)
    cols_ = Int(cols)
    cols_ >= 0 || throw(ArgumentError("cols must be non-negative"))
    values = Float64.(probabilities)
    all(p -> 0.0 <= p <= 1.0, values) ||
        throw(ArgumentError("all receptor probabilities must lie in [0, 1]"))

    rows = length(values)
    mask = falses(rows, cols_)
    @inbounds for j in 1:cols_, i in 1:rows
        mask[i, j] = rand(rng) < values[i]
    end
    if !diagonal && rows == cols_
        @inbounds for i in 1:rows
            mask[i, i] = false
        end
    end
    return mask
end

function directed_watts_strogatz(n::Integer, k::Integer, beta::Real, rng::AbstractRNG=Random.default_rng())
    n = Int(n)
    k = Int(round(k))
    beta = Float64(beta)

    n >= 0 || throw(ArgumentError("n must be non-negative"))
    0.0 <= beta <= 1.0 || throw(ArgumentError("beta must be in [0, 1]"))

    link_mat = falses(n, n)
    if n <= 1 || k <= 0
        return link_mat
    end

    k = min(k, n - 1)
    @inbounds for source in 1:n
        for offset in 1:k
            link_mat[source, mod1(source + offset, n)] = true
        end
    end

    if beta == 0.0
        return link_mat
    end

    for source in 1:n
        original_targets = findall(@view link_mat[source, :])
        for old_target in original_targets
            if rand(rng) >= beta
                continue
            end

            link_mat[source, old_target] = false
            candidates = Int[]
            for candidate in 1:n
                if !link_mat[source, candidate] && candidate != source && candidate != old_target
                    push!(candidates, candidate)
                end
            end

            if isempty(candidates)
                link_mat[source, old_target] = true
                continue
            end

            link_mat[source, rand(rng, candidates)] = true
        end
    end

    return link_mat
end

function dale_signs(n::Integer, inhibitory_frac::Real, rng::AbstractRNG=Random.default_rng())
    n = Int(n)
    inhibitory_frac = Float64(inhibitory_frac)
    n >= 0 || throw(ArgumentError("n must be non-negative"))
    0.0 <= inhibitory_frac <= 1.0 ||
        throw(ArgumentError("inhibitory_frac must be in [0, 1]"))

    signs = Vector{Int}(undef, n)
    @inbounds for i in 1:n
        signs[i] = rand(rng) < inhibitory_frac ? -1 : 1
    end
    return signs
end
