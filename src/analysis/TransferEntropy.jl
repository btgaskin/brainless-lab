using Random: MersenneTwister, randperm

# EXPERIMENTAL transfer-entropy analysis.
#
# Schreiber (2000) introduced transfer entropy as directional information flow.
# This implementation is intentionally simple: order-1, discrete/quantile-binned,
# plug-in histogram probabilities, and no bias correction. Short series are
# biased upward; a KSG/k-NN estimator is a documented future upgrade for serious
# continuous-valued information-flow estimates.

function _te_int(value, name::Symbol)
    out = Int(value)
    out >= 1 || throw(ArgumentError("$(name) must be >= 1"))
    return out
end

function _te_bins(value)
    out = Int(value)
    out >= 2 || throw(ArgumentError("transfer_entropy bins must be >= 2"))
    return out
end

function _te_values(series::AbstractVector, name::Symbol)
    values = Vector{Float64}(undef, length(series))
    @inbounds for i in eachindex(series)
        v = Float64(series[i])
        isfinite(v) || throw(ArgumentError("$(name) contains non-finite values"))
        values[i] = v
    end
    return values
end

function _te_is_binary(values::AbstractVector{Float64})
    isempty(values) && return false
    return all(v -> v == 0.0 || v == 1.0, values)
end

function _te_quantile_bins(values::AbstractVector{Float64}, bins::Integer)
    n = length(values)
    n == 0 && return Int[]

    if _te_is_binary(values)
        return [v > 0.0 ? 2 : 1 for v in values]
    end

    actual_bins = min(Int(bins), n)
    order = sortperm(values)
    out = Vector{Int}(undef, n)
    @inbounds for rank in 1:n
        out[order[rank]] = min(actual_bins, 1 + fld((rank - 1) * actual_bins, n))
    end
    return out
end

function _te_increment!(counts::Dict{K,Int}, key::K) where {K}
    counts[key] = get(counts, key, 0) + 1
    return counts
end

"""
    transfer_entropy(source, target; bins=2, lag=1)

Estimate EXPERIMENTAL order-1 transfer entropy `TE(source -> target)` in bits:
`sum p(y[t+lag], y[t], x[t]) * log2(p(y[t+lag] | y[t], x[t]) / p(y[t+lag] | y[t]))`.

Each series is binned independently into quantile bins; binary 0/1 series pass
through unchanged. This is a plug-in histogram estimator after Schreiber (2000):
it is useful as a lightweight directional-flow diagnostic, but biased for short
series and has no bias correction or higher-order history embedding.
"""
function transfer_entropy(source::AbstractVector, target::AbstractVector; bins=2, lag=1)
    length(source) == length(target) ||
        throw(DimensionMismatch("transfer_entropy source and target must have the same length"))

    lag_ = _te_int(lag, :lag)
    bins_ = _te_bins(bins)
    n = length(source)
    n > lag_ || return NaN

    x = _te_quantile_bins(_te_values(source, :source), bins_)
    y = _te_quantile_bins(_te_values(target, :target), bins_)

    xyz = Dict{Tuple{Int,Int,Int},Int}()
    yx = Dict{Tuple{Int,Int},Int}()
    yy = Dict{Tuple{Int,Int},Int}()
    y0 = Dict{Int,Int}()

    n_transitions = n - lag_
    @inbounds for t in 1:n_transitions
        yn = y[t + lag_]
        yt = y[t]
        xt = x[t]
        _te_increment!(xyz, (yn, yt, xt))
        _te_increment!(yx, (yt, xt))
        _te_increment!(yy, (yn, yt))
        _te_increment!(y0, yt)
    end

    te = 0.0
    n_float = Float64(n_transitions)
    for ((yn, yt, xt), c_xyz) in xyz
        p_xyz = c_xyz / n_float
        p_with_source = c_xyz / yx[(yt, xt)]
        p_without_source = yy[(yn, yt)] / y0[yt]
        if p_with_source > 0.0 && p_without_source > 0.0
            te += p_xyz * log2(p_with_source / p_without_source)
        end
    end

    return te > -1e-12 && te < 0.0 ? 0.0 : Float64(te)
end

function _te_pair_count(n_series::Integer)
    n = Int(n_series)
    return n < 2 ? 0 : div(n * (n - 1), 2)
end

function _te_all_pairs(n_series::Integer)
    total = _te_pair_count(n_series)
    pairs = Vector{Tuple{Int,Int}}(undef, total)
    k = 1
    for i in 1:(Int(n_series) - 1)
        for j in (i + 1):Int(n_series)
            pairs[k] = (i, j)
            k += 1
        end
    end
    return pairs
end

function _te_normalize_pair(pair, n_series::Integer)
    i, j =
        pair isa Pair ? (Int(pair.first), Int(pair.second)) :
        pair isa Tuple && length(pair) == 2 ? (Int(pair[1]), Int(pair[2])) :
        pair isa AbstractVector && length(pair) == 2 ? (Int(pair[1]), Int(pair[2])) :
        throw(ArgumentError("transfer-entropy pairs must be 2-tuples, pairs, or two-element vectors"))

    1 <= i <= n_series || throw(ArgumentError("pair index $(i) is outside 1:$(n_series)"))
    1 <= j <= n_series || throw(ArgumentError("pair index $(j) is outside 1:$(n_series)"))
    i != j || throw(ArgumentError("transfer-entropy pairs need distinct indices"))
    return i < j ? (i, j) : (j, i)
end

function _te_select_pairs(
    n_series::Integer;
    pairs=:all_or_sampled,
    max_pairs::Integer=512,
    seed=0,
    name::Symbol=:transfer_entropy,
)
    n = Int(n_series)
    total = _te_pair_count(n)
    total == 0 && return Tuple{Int,Int}[], false, total, :none

    max_pairs_ = _te_int(max_pairs, :max_pairs)

    if pairs isa Symbol
        if pairs == :all || (pairs == :all_or_sampled && total <= max_pairs_)
            return _te_all_pairs(n), false, total, :all
        elseif pairs == :sampled || pairs == :all_or_sampled
            all_pairs = _te_all_pairs(n)
            take = min(max_pairs_, total)
            rng = MersenneTwister(seed === nothing ? 0 : Int(seed))
            selected = all_pairs[randperm(rng, total)[1:take]]
            @info "$(name) sampled transfer-entropy pairs" n_series=n total_pairs=total sampled_pairs=take max_pairs=max_pairs_ seed=seed pairs=selected
            return selected, true, total, :sampled
        end
        throw(ArgumentError("unknown transfer-entropy pair mode :$(pairs); use :all_or_sampled, :all, :sampled, or explicit pairs"))
    elseif pairs isa AbstractVector
        selected = [_te_normalize_pair(pair, n) for pair in pairs]
        return selected, false, total, :explicit
    end

    throw(ArgumentError("pairs must be a Symbol or an explicit vector of pairs"))
end

function _te_pairwise_summary(
    series::AbstractMatrix{<:Real};
    level::Symbol,
    signal::Symbol,
    pairs=:all_or_sampled,
    bins=2,
    lag=1,
    max_pairs::Integer=512,
    seed=0,
)
    n_ticks, n_series = size(series)
    pair_list, sampled, total_pairs, pair_selection = _te_select_pairs(
        n_series;
        pairs=pairs,
        max_pairs=max_pairs,
        seed=seed,
        name=Symbol(level, "_transfer_entropy"),
    )

    te_total = 0.0
    asym_total = 0.0
    valid_pairs = 0

    @inbounds for (i, j) in pair_list
        forward = transfer_entropy(@view(series[:, i]), @view(series[:, j]); bins=bins, lag=lag)
        reverse = transfer_entropy(@view(series[:, j]), @view(series[:, i]); bins=bins, lag=lag)
        if isfinite(forward) && isfinite(reverse)
            te_total += forward + reverse
            asym_total += abs(forward - reverse)
            valid_pairs += 1
        end
    end

    return (;
        level=level,
        signal=signal,
        mean_pairwise_te=valid_pairs == 0 ? NaN : te_total / (2 * valid_pairs),
        net_directional_asymmetry=valid_pairs == 0 ? NaN : asym_total / valid_pairs,
        pairs_evaluated=length(pair_list),
        valid_pairs=valid_pairs,
        n_series=n_series,
        n_ticks=n_ticks,
        sampled=sampled,
        total_pairs=total_pairs,
        max_pairs=Int(max_pairs),
        bins=Int(bins),
        lag=Int(lag),
        pair_selection=pair_selection,
    )
end

"""
    node_transfer_entropy(sim; pairs=:all_or_sampled, bins=2, lag=1, max_pairs=512, seed=0)

Compute EXPERIMENTAL pairwise transfer entropy between recorded node spike
trains from the `:spikes` channel. Spike values are binarized as `spike > 0`.
The summary reports mean directed pairwise TE and mean absolute directional
asymmetry `|TE(i -> j) - TE(j -> i)|`.

For large node counts the default `pairs=:all_or_sampled` samples up to
`max_pairs` unordered pairs and logs the sampled pair indices with `@info`.
"""
function node_transfer_entropy(
    sim::SimResult;
    pairs=:all_or_sampled,
    bins=2,
    lag=1,
    max_pairs::Integer=512,
    seed=0,
)
    raw = getchannel(sim.recorder, :spikes)
    isempty(raw) && throw(ArgumentError("node_transfer_entropy needs the :spikes channel recorded; run simulate(...; record=(:spikes, ...))"))

    spikes = _analysis_sample_matrix(raw, :node_transfer_entropy)
    binary_spikes = Float64.(spikes .> 0.0)
    return _te_pairwise_summary(
        binary_spikes;
        level=:node,
        signal=:spikes,
        pairs=pairs,
        bins=bins,
        lag=lag,
        max_pairs=max_pairs,
        seed=seed,
    )
end

function _te_pose_matrices(raw, name::Symbol)
    isempty(raw) && throw(ArgumentError("$(name) needs the :poses channel recorded; run simulate(...; record=(:poses, ...))"))
    first_entry = raw[1]
    first_entry isa AbstractVector ||
        throw(ArgumentError("$(name) needs :poses entries shaped as vectors of (x, y, heading) tuples"))

    n_ticks = length(raw)
    n_agents = length(first_entry)
    n_agents > 0 || throw(ArgumentError("$(name) needs at least one recorded agent pose"))

    xs = Matrix{Float64}(undef, n_ticks, n_agents)
    ys = Matrix{Float64}(undef, n_ticks, n_agents)
    headings = Matrix{Float64}(undef, n_ticks, n_agents)

    @inbounds for t in 1:n_ticks
        entry = raw[t]
        entry isa AbstractVector ||
            throw(ArgumentError("$(name) needs :poses entries shaped as vectors of (x, y, heading) tuples"))
        length(entry) == n_agents ||
            throw(DimensionMismatch("$(name) sample $(t) has $(length(entry)) poses; expected $(n_agents)"))
        for i in 1:n_agents
            pose = entry[i]
            (pose isa Tuple || pose isa AbstractVector) && length(pose) >= 3 ||
                throw(ArgumentError("$(name) needs each pose shaped as (x, y, heading)"))
            xs[t, i] = Float64(pose[1])
            ys[t, i] = Float64(pose[2])
            headings[t, i] = Float64(pose[3])
        end
    end

    return xs, ys, headings
end

_te_wrap_to_pi(a) = atan(sin(a), cos(a))

function _te_heading_change_signal(headings::AbstractMatrix{<:Real})
    n_ticks, n_agents = size(headings)
    n_ticks >= 2 || return zeros(Float64, 0, n_agents)

    out = Matrix{Float64}(undef, n_ticks - 1, n_agents)
    @inbounds for t in 1:(n_ticks - 1), i in 1:n_agents
        out[t, i] = _te_wrap_to_pi(Float64(headings[t + 1, i]) - Float64(headings[t, i])) > 0.0 ? 1.0 : 0.0
    end
    return out
end

function _te_median(values::AbstractVector{<:Real})
    xs = sort!(Float64.(collect(values)))
    isempty(xs) && return NaN
    n = length(xs)
    mid = fld(n + 1, 2)
    return isodd(n) ? xs[mid] : 0.5 * (xs[mid] + xs[mid + 1])
end

function _te_environment_size(sim::SimResult)
    hasproperty(sim.config, :environment) || return nothing
    environment = getproperty(sim.config, :environment)
    if hasproperty(environment, :size)
        size = getproperty(environment, :size)
        size === nothing || return Float64(size)
    end
    return nothing
end

function _te_axis_delta(a::Real, b::Real, size)
    delta = Float64(b) - Float64(a)
    size === nothing && return delta
    s = Float64(size)
    return mod(delta + 0.5 * s, s) - 0.5 * s
end

function _te_speed_signal(xs::AbstractMatrix{<:Real}, ys::AbstractMatrix{<:Real}, sim::SimResult)
    n_ticks, n_agents = size(xs)
    n_ticks >= 2 || return zeros(Float64, 0, n_agents)

    torus_size = _te_environment_size(sim)
    speeds = Matrix{Float64}(undef, n_ticks - 1, n_agents)
    @inbounds for t in 1:(n_ticks - 1), i in 1:n_agents
        dx = _te_axis_delta(xs[t, i], xs[t + 1, i], torus_size)
        dy = _te_axis_delta(ys[t, i], ys[t + 1, i], torus_size)
        speeds[t, i] = hypot(dx, dy)
    end

    out = Matrix{Float64}(undef, size(speeds)...)
    @inbounds for i in 1:n_agents
        med = _te_median(@view speeds[:, i])
        for t in axes(speeds, 1)
            out[t, i] = speeds[t, i] > med ? 1.0 : 0.0
        end
    end
    return out
end

function _agent_signal_matrix(sim::SimResult, signal::Symbol)
    xs, ys, headings = _te_pose_matrices(getchannel(sim.recorder, :poses), :agent_transfer_entropy)
    if signal == :heading_change
        return _te_heading_change_signal(headings)
    elseif signal in (:speed, :speed_median, :above_median_speed)
        return _te_speed_signal(xs, ys, sim)
    end
    throw(ArgumentError("unknown agent_transfer_entropy signal :$(signal); use :heading_change or :speed"))
end

"""
    agent_transfer_entropy(sim; signal=:heading_change, pairs=:all_or_sampled, bins=2, lag=1, max_pairs=512, seed=0)

Compute EXPERIMENTAL pairwise transfer entropy between agents' recorded
behavioral signals from `:poses`. The default `signal=:heading_change` uses the
sign of each per-tick heading change; `signal=:speed` uses above/below-median
per-agent speed. The estimator and pair-sampling behavior match
`node_transfer_entropy`.
"""
function agent_transfer_entropy(
    sim::SimResult;
    signal::Symbol=:heading_change,
    pairs=:all_or_sampled,
    bins=2,
    lag=1,
    max_pairs::Integer=512,
    seed=0,
)
    series = _agent_signal_matrix(sim, signal)
    return _te_pairwise_summary(
        series;
        level=:agent,
        signal=signal,
        pairs=pairs,
        bins=bins,
        lag=lag,
        max_pairs=max_pairs,
        seed=seed,
    )
end
