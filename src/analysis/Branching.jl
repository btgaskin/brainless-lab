"""
    _branching_from_rates(rates)

Compute per-tick branching ratios and the least-squares mean-field estimate
from population activity recorded at each tick.
"""
function _branching_from_rates(rates::AbstractVector{<:Real})
    n = length(rates)
    per_tick = fill(NaN, max(n - 1, 0))
    @inbounds for t in 1:(n - 1)
        prev = Float64(rates[t])
        per_tick[t] = prev > 0.0 ? Float64(rates[t + 1]) / prev : NaN
    end

    num = 0.0
    den = 0.0
    @inbounds for t in 1:(n - 1)
        a = Float64(rates[t])
        b = Float64(rates[t + 1])
        if a > 0.0
            num += a * b
            den += a * a
        end
    end
    sigma = den > 0.0 ? num / den : NaN
    return (per_tick=per_tick, sigma=sigma)
end

"""
    branching_ratio(sim)

Compute the per-tick branching ratio from a recorded rollout's `:rate` channel.
"""
function branching_ratio(sim::SimResult)
    raw = getchannel(sim.recorder, :rate)
    isempty(raw) && throw(ArgumentError("branching_ratio needs the :rate channel recorded; run simulate(...; record=(:rate, ...))"))

    pop = [
        v isa AbstractVector ? (isempty(v) ? 0.0 : sum(Float64, v) / length(v)) : Float64(v)
        for v in raw
    ]
    res = _branching_from_rates(pop)
    return (per_tick=res.per_tick, sigma=res.sigma, population_rate=pop)
end
