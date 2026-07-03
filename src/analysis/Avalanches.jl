# EXPERIMENTAL neuronal-avalanche analysis.
#
# Beggs & Plenz (2003) defined neuronal avalanches as contiguous excursions of
# population activity above a quiet baseline. The exponent estimates here use a
# simple continuous MLE over xmin = the smallest positive observed value. That is
# a pragmatic first-pass estimator for recorded BrainlessLab activity, but it has
# no xmin search, no goodness-of-fit test, and is unreliable for short rollouts
# or small avalanche counts.

const _AVALANCHE_MIN_FIT_COUNT = 5

function _analysis_numeric_vector(entry, name::Symbol, t::Integer)
    if entry isa Number
        return [Float64(entry)]
    elseif entry isa AbstractArray
        if all(x -> x isa Number, entry)
            return [Float64(x) for x in entry]
        end

        out = Float64[]
        for x in entry
            append!(out, _analysis_numeric_vector(x, name, t))
        end
        return out
    elseif entry isa Tuple
        out = Float64[]
        for x in entry
            append!(out, _analysis_numeric_vector(x, name, t))
        end
        return out
    end

    throw(ArgumentError("$(name) needs numeric recorder entries; bad entry at tick $(t)"))
end

function _analysis_sample_matrix(raw, name::Symbol)
    isempty(raw) && throw(ArgumentError("$(name) needs a recorded channel with at least one sample"))

    n_ticks = length(raw)
    rows = Vector{Vector{Float64}}(undef, n_ticks)
    @inbounds for t in 1:n_ticks
        rows[t] = _analysis_numeric_vector(raw[t], name, t)
    end

    width = length(rows[1])
    width > 0 || throw(ArgumentError("$(name) needs non-empty numeric recorder entries"))

    out = Matrix{Float64}(undef, n_ticks, width)
    @inbounds for t in 1:n_ticks
        length(rows[t]) == width ||
            throw(DimensionMismatch("$(name) sample $(t) has width $(length(rows[t])); expected $(width)"))
        out[t, :] .= rows[t]
    end
    return out
end

function _analysis_config_int(sim::SimResult, field::Symbol, default::Integer)
    if hasproperty(sim.config, field)
        return Int(getproperty(sim.config, field))
    end
    return Int(default)
end

function _median_positive(values::AbstractVector{<:Real})
    positives = Float64[x for x in values if isfinite(Float64(x)) && Float64(x) > 0.0]
    isempty(positives) && return 0.0

    sort!(positives)
    n = length(positives)
    mid = fld(n + 1, 2)
    return isodd(n) ? positives[mid] : 0.5 * (positives[mid] + positives[mid + 1])
end

function _population_activity_from_spikes(raw)
    mat = _analysis_sample_matrix(raw, :avalanches)
    activity = Vector{Float64}(undef, size(mat, 1))
    @inbounds for t in axes(mat, 1)
        activity[t] = sum(@view mat[t, :])
    end
    return activity
end

function _population_activity_from_rates(sim::SimResult, raw)
    isempty(raw) && throw(ArgumentError("avalanches needs :spikes recorded, or :rate recorded for the rate*N fallback"))

    n_nodes = _analysis_config_int(sim, :n_nodes, 1)
    n_agents = _analysis_config_int(sim, :n_agents, 1)
    activity = Vector{Float64}(undef, length(raw))

    @inbounds for t in eachindex(raw)
        rates = _analysis_numeric_vector(raw[t], :avalanches, t)
        multiplier = length(rates) == 1 ? n_nodes * n_agents : n_nodes
        activity[t] = multiplier * sum(rates)
    end
    return activity
end

function _population_activity(sim::SimResult)
    spikes = getchannel(sim.recorder, :spikes)
    isempty(spikes) || return _population_activity_from_spikes(spikes)
    return _population_activity_from_rates(sim, getchannel(sim.recorder, :rate))
end

function _avalanche_runs(activity::AbstractVector{<:Real}, threshold::Real)
    sizes = Float64[]
    durations = Int[]

    size = 0.0
    duration = 0
    theta = Float64(threshold)

    @inbounds for value in activity
        a = Float64(value)
        if isfinite(a) && a > theta
            size += a
            duration += 1
        elseif duration > 0
            push!(sizes, size)
            push!(durations, duration)
            size = 0.0
            duration = 0
        end
    end

    if duration > 0
        push!(sizes, size)
        push!(durations, duration)
    end

    return sizes, durations
end

function _continuous_powerlaw_exponent(values::AbstractVector{<:Real}; min_count::Integer=_AVALANCHE_MIN_FIT_COUNT)
    xs = Float64[x for x in values if isfinite(Float64(x)) && Float64(x) > 0.0]
    length(xs) >= min_count || return NaN

    xmin = minimum(xs)
    xmin > 0.0 || return NaN

    denom = 0.0
    @inbounds for x in xs
        denom += log(x / xmin)
    end

    return denom > 0.0 ? 1.0 + length(xs) / denom : NaN
end

function _mean_size_duration_exponent(sizes::AbstractVector{<:Real}, durations::AbstractVector{<:Integer})
    length(sizes) == length(durations) ||
        throw(DimensionMismatch("sizes and durations must have the same length"))

    unique_durations = sort!(unique(Int.(durations)))
    xs = Float64[]
    ys = Float64[]

    for duration in unique_durations
        duration > 0 || continue
        total = 0.0
        count = 0
        @inbounds for i in eachindex(sizes, durations)
            if Int(durations[i]) == duration
                s = Float64(sizes[i])
                if isfinite(s) && s > 0.0
                    total += s
                    count += 1
                end
            end
        end
        count == 0 && continue
        push!(xs, log(Float64(duration)))
        push!(ys, log(total / count))
    end

    length(xs) >= 2 || return NaN
    return _intercept_corrected_slope(xs, ys)
end

"""
    avalanches(sim; threshold=nothing)

Compute EXPERIMENTAL neuronal-avalanche size and duration statistics from a
recorded rollout. Population activity `A(t)` is the total recorded spike count
per tick from `:spikes`; if `:spikes` is absent, `:rate` is multiplied by the
configured node count as a rate*N fallback.

An avalanche is a maximal run of ticks with `A(t) > threshold`, bounded by
sub-threshold ticks. The default threshold is the median nonzero population
activity. Returns `(sizes, durations, tau, alpha, gamma_fit, gamma_pred,
n_avalanches, threshold)`.

`tau` and `alpha` are first-pass continuous power-law MLE estimates using
xmin = the smallest positive observed size/duration. `gamma_fit` is the slope of
`log(<S>(D)) ~ log(D)`, and `gamma_pred = (alpha - 1) / (tau - 1)` is the
crackling-noise scaling prediction. These fits need long runs and adequate
avalanche counts; tiny samples return `NaN` exponents.
"""
function avalanches(sim::SimResult; threshold=nothing)
    activity = _population_activity(sim)
    theta = threshold === nothing ? _median_positive(activity) : Float64(threshold)
    isfinite(theta) || throw(ArgumentError("avalanches threshold must be finite"))

    sizes, durations = _avalanche_runs(activity, theta)
    n_avalanches = length(sizes)

    tau = _continuous_powerlaw_exponent(sizes)
    alpha = _continuous_powerlaw_exponent(durations)
    gamma_fit = n_avalanches >= _AVALANCHE_MIN_FIT_COUNT ?
        _mean_size_duration_exponent(sizes, durations) :
        NaN
    gamma_pred = isfinite(tau) && isfinite(alpha) && tau != 1.0 ?
        (alpha - 1.0) / (tau - 1.0) :
        NaN

    return (;
        sizes=sizes,
        durations=durations,
        tau=tau,
        alpha=alpha,
        gamma_fit=gamma_fit,
        gamma_pred=gamma_pred,
        n_avalanches=n_avalanches,
        threshold=theta,
    )
end
