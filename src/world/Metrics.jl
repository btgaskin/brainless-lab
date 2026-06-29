function liveness(rates::AbstractVector, N, window)
    n = Int(N)
    n >= 0 || throw(ArgumentError("N must be non-negative"))
    window = Int(window)

    len = length(rates)
    last_n = window <= 0 ? 0 : min(window, len)
    if last_n == 0
        return (
            rate_mean=0.0,
            rate_var=0.0,
            total_spikes_window=0.0,
            alive=false,
        )
    end

    first_i = len - last_n + 1
    total = 0.0
    @inbounds for i in first_i:len
        total += Float64(rates[i])
    end
    rate_mean = total / last_n

    sq = 0.0
    @inbounds for i in first_i:len
        delta = Float64(rates[i]) - rate_mean
        sq += delta * delta
    end
    rate_var = sq / last_n

    total_spikes_window = total * n
    min_spikes = max(5.0, 0.01 * window * n)
    alive = 0.01 < rate_mean < 0.99 &&
        rate_var > 1e-9 &&
        total_spikes_window >= min_spikes

    return (
        rate_mean=Float64(rate_mean),
        rate_var=Float64(rate_var),
        total_spikes_window=Float64(total_spikes_window),
        alive=alive,
    )
end
