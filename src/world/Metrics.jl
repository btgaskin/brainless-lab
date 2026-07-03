function _mean(values)
    isempty(values) && return 0.0
    total = 0.0
    @inbounds for value in values
        total += Float64(value)
    end
    return Float64(total / length(values))
end

function _positions_matrix(positions)
    if positions isa AbstractMatrix
        size(positions, 2) == 2 ||
            throw(DimensionMismatch("positions must have 2 columns"))
        return Matrix{Float64}(Float64.(positions))
    end

    n = length(positions)
    out = zeros(Float64, n, 2)
    @inbounds for i in 1:n
        out[i, 1] = Float64(positions[i][1])
        out[i, 2] = Float64(positions[i][2])
    end
    return out
end

function _history_matrix(hist)
    if hist isa AbstractMatrix
        return Matrix{Float64}(Float64.(hist))
    end

    n = length(hist)
    n == 0 && return zeros(Float64, 0, 0)

    first_row = Float64.(vec(collect(hist[1])))
    width = length(first_row)
    out = zeros(Float64, n, width)
    out[1, :] .= first_row

    @inbounds for i in 2:n
        row = Float64.(vec(collect(hist[i])))
        length(row) == width ||
            throw(DimensionMismatch("history row width $(length(row)) does not match $width"))
        out[i, :] .= row
    end

    return out
end

function polarization(headings)
    hs = Float64.(vec(collect(headings)))
    isempty(hs) && return 0.0

    x = 0.0
    y = 0.0
    @inbounds for h in hs
        x += cos(h)
        y += sin(h)
    end
    x /= length(hs)
    y /= length(hs)
    return Float64(hypot(x, y))
end

function _circular_axis_mean(values, torus::Torus)
    n = length(values)
    n == 0 && return 0.0

    scale = _TWO_PI / torus.size
    mean_sin = 0.0
    mean_cos = 0.0
    @inbounds for value in values
        theta = Float64(value) * scale
        mean_sin += sin(theta)
        mean_cos += cos(theta)
    end
    mean_sin /= n
    mean_cos /= n

    theta = atan(mean_sin, mean_cos)
    return Float64(mod(torus.size * theta / _TWO_PI, torus.size))
end

function circular_centroid(positions, torus::Torus)
    pos = _positions_matrix(positions)
    n = size(pos, 1)
    n == 0 && return (0.0, 0.0)

    return (
        _circular_axis_mean(@view(pos[:, 1]), torus),
        _circular_axis_mean(@view(pos[:, 2]), torus),
    )
end

function milling(positions, headings, centroid)
    pos = _positions_matrix(positions)
    hs = Float64.(vec(collect(headings)))
    cent = Float64.(vec(collect(centroid)))

    length(hs) == size(pos, 1) ||
        throw(DimensionMismatch("heading count $(length(hs)) does not match position count $(size(pos, 1))"))
    length(cent) == 2 || throw(DimensionMismatch("centroid must have length 2"))

    n = size(pos, 1)
    n == 0 && return 0.0

    total = 0.0
    @inbounds for i in 1:n
        relx = pos[i, 1] - cent[1]
        rely = pos[i, 2] - cent[2]
        norm = hypot(relx, rely)
        rx = norm > 0.0 ? relx / norm : 0.0
        ry = norm > 0.0 ? rely / norm : 0.0
        vx = cos(hs[i])
        vy = sin(hs[i])
        total += rx * vy - ry * vx
    end

    return Float64(abs(total / n))
end

function milling(positions, headings, centroid, torus::Torus)
    pos = _positions_matrix(positions)
    hs = Float64.(vec(collect(headings)))
    cent = Float64.(vec(collect(centroid)))

    length(hs) == size(pos, 1) ||
        throw(DimensionMismatch("heading count $(length(hs)) does not match position count $(size(pos, 1))"))
    length(cent) == 2 || throw(DimensionMismatch("centroid must have length 2"))

    n = size(pos, 1)
    n == 0 && return 0.0

    total = 0.0
    @inbounds for i in 1:n
        relx, rely = tdelta(torus, (cent[1], cent[2]), (pos[i, 1], pos[i, 2]))
        norm = hypot(relx, rely)
        rx = norm > 0.0 ? relx / norm : 0.0
        ry = norm > 0.0 ? rely / norm : 0.0
        vx = cos(hs[i])
        vy = sin(hs[i])
        total += rx * vy - ry * vx
    end

    return Float64(abs(total / n))
end

function mean_pairwise_distance(positions, torus::Torus)
    pos = _positions_matrix(positions)
    n = size(pos, 1)
    n < 2 && return 0.0

    total = 0.0
    count = 0
    @inbounds for i in 1:n
        for j in (i + 1):n
            total += tdistance(torus, (pos[i, 1], pos[i, 2]), (pos[j, 1], pos[j, 2]))
            count += 1
        end
    end

    return Float64(total / count)
end

function mean_nearest_neighbor_distance(positions, torus::Torus)
    pos = _positions_matrix(positions)
    n = size(pos, 1)
    n < 2 && return 0.0

    distances = zeros(Float64, n)
    @inbounds for i in 1:n
        best = Inf
        for j in 1:n
            i == j && continue
            d = tdistance(torus, (pos[i, 1], pos[i, 2]), (pos[j, 1], pos[j, 2]))
            if d < best
                best = d
            end
        end
        distances[i] = best
    end

    return _mean(distances)
end

function _input_histories(input_history)
    input_history === nothing && return nothing

    if input_history isa AbstractMatrix
        return Any[input_history]
    elseif input_history isa AbstractArray{<:Real,3}
        return Any[Matrix{Float64}(input_history[i, :, :]) for i in axes(input_history, 1)]
    end

    return input_history
end

function input_stability(input_history)
    histories = _input_histories(input_history)
    histories === nothing && return 0.0

    values = Float64[]
    for hist in histories
        arr = _history_matrix(hist)
        if ndims(arr) != 2 || size(arr, 1) < 2
            continue
        end

        sims = Float64[]
        @inbounds for t in 1:(size(arr, 1) - 1)
            dot_ab = 0.0
            norm_a = 0.0
            norm_b = 0.0
            for k in axes(arr, 2)
                a = arr[t, k]
                b = arr[t + 1, k]
                dot_ab += a * b
                norm_a += a * a
                norm_b += b * b
            end

            denom = sqrt(norm_a) * sqrt(norm_b)
            if denom > 0.0
                push!(sims, dot_ab / denom)
            end
        end

        isempty(sims) || push!(values, _mean(sims))
    end

    return _mean(values)
end

_empty_swarm_metrics() = (
    polarization=0.0,
    milling=0.0,
    mean_nearest_neighbor_distance=0.0,
    mean_pairwise_distance=0.0,
    cohesion=0.0,
    input_stability=0.0,
)

function swarm_metrics(m::AbstractTorusEnvironment, window::Integer)
    window = Int(window)
    if window <= 0 || isempty(m.history) || any(isempty, m.history)
        return _empty_swarm_metrics()
    end

    steps = min(window, minimum(length, m.history))
    steps <= 0 && return _empty_swarm_metrics()

    polarizations = Float64[]
    millings = Float64[]
    nearest = Float64[]
    pairwise = Float64[]

    n_agents = length(m.history)
    for k in 1:steps
        positions = zeros(Float64, n_agents, 2)
        headings = zeros(Float64, n_agents)

        @inbounds for i in 1:n_agents
            hist = m.history[i]
            pose = hist[length(hist) - steps + k]
            positions[i, 1] = pose[1]
            positions[i, 2] = pose[2]
            headings[i] = pose[3]
        end

        centroid = circular_centroid(positions, m.torus)

        push!(polarizations, polarization(headings))
        push!(millings, milling(positions, headings, centroid, m.torus))
        push!(nearest, mean_nearest_neighbor_distance(positions, m.torus))
        push!(pairwise, mean_pairwise_distance(positions, m.torus))
    end

    mean_nn = _mean(nearest)
    mean_pairwise = _mean(pairwise)

    input_histories = Any[]
    for hist in m.input_history
        take = min(steps, length(hist))
        start = length(hist) - take + 1
        push!(input_histories, hist[start:length(hist)])
    end

    return (
        polarization=_mean(polarizations),
        milling=_mean(millings),
        mean_nearest_neighbor_distance=mean_nn,
        mean_pairwise_distance=mean_pairwise,
        cohesion=mean_nn + mean_pairwise,
        input_stability=input_stability(input_histories),
    )
end

swarm_metrics(c::Ensemble, window::Integer) = swarm_metrics(c.environment, Int(window))

metrics(m::TorusEnvironment, window::Integer=_default_torus_window(m)) =
    swarm_metrics(m, Int(window))

_empty_forage_only_metrics(window::Integer=0) = (
    mean_distance_to_source=0.0,
    frac_within_capture=0.0,
    time_to_first_arrival=Float64(max(Int(window), 0)),
    forage_score=0.0,
)

function _forage_only_metrics(m::ForageEnvironment, window::Integer)
    window = Int(window)
    if window <= 0 || isempty(m.history) || any(isempty, m.history)
        return _empty_forage_only_metrics(window)
    end

    steps = min(window, minimum(length, m.history))
    steps <= 0 && return _empty_forage_only_metrics(window)

    total_distance = 0.0
    within_count = 0
    total_count = 0
    first_arrival = steps
    found_arrival = false
    capture_radius = Float64(m.config.capture_radius)

    @inbounds for k in 1:steps
        any_arrived = false
        for hist in m.history
            pose = hist[length(hist) - steps + k]
            d = tdistance(m.torus, (pose[1], pose[2]), m.source_position)
            total_distance += d
            total_count += 1
            if d <= capture_radius
                within_count += 1
                any_arrived = true
            end
        end
        if any_arrived && !found_arrival
            first_arrival = k
            found_arrival = true
        end
    end

    mean_distance = total_count == 0 ? 0.0 : total_distance / total_count
    max_d = max_dist(m.torus)
    forage_score = max_d <= 0.0 ? 0.0 : clamp(1.0 - mean_distance / max_d, 0.0, 1.0)

    return (
        mean_distance_to_source=Float64(mean_distance),
        frac_within_capture=total_count == 0 ? 0.0 : Float64(within_count / total_count),
        time_to_first_arrival=Float64(first_arrival),
        forage_score=Float64(forage_score),
    )
end

function forage_metrics(m::ForageEnvironment, window::Integer)
    return (;
        swarm_metrics(m, Int(window))...,
        _forage_only_metrics(m, Int(window))...,
    )
end

forage_metrics(c::Ensemble, window::Integer) = forage_metrics(c.environment, Int(window))

metrics(m::ForageEnvironment, window::Integer=_default_torus_window(m)) =
    forage_metrics(m, Int(window))

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
    min_spikes = max(5.0, 0.01 * last_n * n)
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
