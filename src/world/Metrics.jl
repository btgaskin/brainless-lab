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

function circular_centroid(positions, ::WalledArena)
    pos = _positions_matrix(positions)
    size(pos, 1) == 0 && return (0.0, 0.0)
    return (Float64(sum(@view(pos[:, 1])) / size(pos, 1)),
            Float64(sum(@view(pos[:, 2])) / size(pos, 1)))
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

milling(positions, headings, centroid, ::WalledArena) =
    milling(positions, headings, centroid)

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


function mean_pairwise_distance(positions, arena::WalledArena)
    pos = _positions_matrix(positions)
    n = size(pos, 1)
    n < 2 && return 0.0
    total = 0.0
    count = 0
    @inbounds for i in 1:n, j in (i + 1):n
        total += arena_distance(arena, (pos[i, 1], pos[i, 2]), (pos[j, 1], pos[j, 2]))
        count += 1
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


function mean_nearest_neighbor_distance(positions, arena::WalledArena)
    pos = _positions_matrix(positions)
    n = size(pos, 1)
    n < 2 && return 0.0
    distances = zeros(Float64, n)
    @inbounds for i in 1:n
        best = Inf
        for j in 1:n
            i == j && continue
            best = min(best, arena_distance(
                arena,
                (pos[i, 1], pos[i, 2]),
                (pos[j, 1], pos[j, 2]),
            ))
        end
        distances[i] = best
    end
    return _mean(distances)
end

"""
    segregation(positions, colours, torus)

Colour assortativity of a single snapshot. Returns
`(; same_dist, cross_dist, assortativity)` where `assortativity =
(cross_dist - same_dist) / (cross_dist + same_dist)` in [-1, 1]: `>0` means
same-colour agents sit closer than cross-colour (colour-sorted), `~0` means
well-mixed, `<0` means anti-sorted. The colour-blind run (colours still assigned
but `colour_sensing=false`) is the natural ~chance null.
"""
function segregation(positions, colours, arena::Union{Torus,WalledArena})
    pos = _positions_matrix(positions)
    cols = Int[Int(c) for c in vec(collect(colours))]
    n = size(pos, 1)
    length(cols) == n ||
        throw(DimensionMismatch("colour count $(length(cols)) does not match position count $(n)"))

    same_total = 0.0
    same_count = 0
    cross_total = 0.0
    cross_count = 0
    @inbounds for i in 1:n
        for j in (i + 1):n
            d = arena_distance(arena, (pos[i, 1], pos[i, 2]), (pos[j, 1], pos[j, 2]))
            if cols[i] == cols[j]
                same_total += d
                same_count += 1
            else
                cross_total += d
                cross_count += 1
            end
        end
    end

    same_d = same_count == 0 ? 0.0 : same_total / same_count
    cross_d = cross_count == 0 ? 0.0 : cross_total / cross_count
    # Assortativity is only defined when BOTH within- and cross-colour pairs exist.
    # With one colour class (e.g. the default n_colours=1) there are no cross pairs,
    # so return neutral 0.0 rather than the spurious -1/+1 the ratio would give.
    denom = same_d + cross_d
    assortativity = (same_count > 0 && cross_count > 0 && denom > 0.0) ?
        (cross_d - same_d) / denom : 0.0
    return (same_dist=Float64(same_d), cross_dist=Float64(cross_d), assortativity=Float64(assortativity))
end

_empty_segregation() = (same_dist=0.0, cross_dist=0.0, assortativity=0.0)

function _situated_history_window(m::AbstractSituatedEnvironment, window::Integer)
    isempty(m.history) && return (start=1, stop=0, steps=0)
    available = minimum(length, m.history)
    steps = min(max(Int(window), 0), available)
    return (start=available - steps + 1, stop=available, steps=steps)
end

function _activity_at(m::AbstractSituatedEnvironment, tick::Integer)
    index = Int(tick)
    if 1 <= index <= length(m.activity_history)
        return m.activity_history[index]
    end
    return m.active_agents
end

"""
    segregation(m::AbstractSituatedEnvironment, window)

Window-averaged colour assortativity over the last `window` recorded poses, using
the per-agent `m.colours`. Registered as the `:segregation` swarm metric.
"""
function segregation(m::AbstractSituatedEnvironment, window::Integer)
    span = _situated_history_window(m, window)
    span.steps <= 0 && return _empty_segregation()

    same = Float64[]
    cross = Float64[]
    assort = Float64[]
    for tick in span.start:span.stop
        active = findall(_activity_at(m, tick))
        if isempty(active)
            push!(same, 0.0)
            push!(cross, 0.0)
            push!(assort, 0.0)
            continue
        end
        positions = zeros(Float64, length(active), 2)
        @inbounds for (row, i) in enumerate(active)
            pose = m.history[i][tick]
            positions[row, 1] = pose[1]
            positions[row, 2] = pose[2]
        end
        snap = segregation(positions, m.colours[active], m.arena)
        push!(same, snap.same_dist)
        push!(cross, snap.cross_dist)
        push!(assort, snap.assortativity)
    end

    return (same_dist=_mean(same), cross_dist=_mean(cross), assortativity=_mean(assort))
end

segregation(c::Ensemble, window::Integer) = segregation(c.environment, Int(window))

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

function _activity_input_stability(m::AbstractSituatedEnvironment, span)
    span.steps < 2 && return 0.0
    similarities = Float64[]
    for tick in max(span.start + 1, 2):span.stop
        previous_activity = _activity_at(m, tick - 1)
        current_activity = _activity_at(m, tick)
        @inbounds for agent in eachindex(m.input_history)
            previous_activity[agent] && current_activity[agent] || continue
            history = m.input_history[agent]
            length(history) >= tick || continue
            a = history[tick - 1]
            b = history[tick]
            dot_ab = 0.0
            norm_a = 0.0
            norm_b = 0.0
            for index in eachindex(a, b)
                av = Float64(a[index])
                bv = Float64(b[index])
                dot_ab += av * bv
                norm_a += av * av
                norm_b += bv * bv
            end
            denom = sqrt(norm_a) * sqrt(norm_b)
            denom > 0.0 && push!(similarities, dot_ab / denom)
        end
    end
    return _mean(similarities)
end

_activity_summary(active_agents) = (
    active_count=count(identity, active_agents),
    active_fraction=_active_fraction(active_agents),
)

_empty_swarm_metrics(active_agents=Bool[]) = (;
    polarization=0.0,
    milling=0.0,
    mean_nearest_neighbor_distance=0.0,
    mean_pairwise_distance=0.0,
    cohesion=0.0,
    input_stability=0.0,
    _activity_summary(active_agents)...,
)

function swarm_metrics(m::AbstractSituatedEnvironment, window::Integer)
    span = _situated_history_window(m, window)
    span.steps <= 0 && return _empty_swarm_metrics(m.active_agents)

    polarizations = Float64[]
    millings = Float64[]
    nearest = Float64[]
    pairwise = Float64[]

    for tick in span.start:span.stop
        active = findall(_activity_at(m, tick))
        if isempty(active)
            push!(polarizations, 0.0)
            push!(millings, 0.0)
            push!(nearest, 0.0)
            push!(pairwise, 0.0)
            continue
        end
        positions = zeros(Float64, length(active), 2)
        headings = zeros(Float64, length(active))

        @inbounds for (row, i) in enumerate(active)
            pose = m.history[i][tick]
            positions[row, 1] = pose[1]
            positions[row, 2] = pose[2]
            headings[row] = pose[3]
        end

        centroid = circular_centroid(positions, m.torus)

        push!(polarizations, polarization(headings))
        push!(millings, milling(positions, headings, centroid, m.torus))
        push!(nearest, mean_nearest_neighbor_distance(positions, m.torus))
        push!(pairwise, mean_pairwise_distance(positions, m.torus))
    end

    mean_nn = _mean(nearest)
    mean_pairwise = _mean(pairwise)

    return (;
        polarization=_mean(polarizations),
        milling=_mean(millings),
        mean_nearest_neighbor_distance=mean_nn,
        mean_pairwise_distance=mean_pairwise,
        cohesion=mean_nn + mean_pairwise,
        input_stability=_activity_input_stability(m, span),
        _activity_summary(m.active_agents)...,
    )
end

swarm_metrics(c::Ensemble, window::Integer) = swarm_metrics(c.environment, Int(window))

metrics(m::TorusEnvironment, window::Integer=_default_situated_window(m)) =
    swarm_metrics(m, Int(window))

metrics(m::SituatedEnvironment{CollectiveMode}, window::Integer=_default_situated_window(m)) =
    swarm_metrics(m, Int(window))

_empty_forage_only_metrics(window::Integer=0) = (
    mean_distance_to_source=0.0,
    frac_within_capture=0.0,
    time_to_first_arrival=Float64(max(Int(window), 0)),
    forage_score=0.0,
)

function _forage_only_metrics(m::Union{ForageEnvironment,SituatedEnvironment{ForageMode}}, window::Integer)
    span = _situated_history_window(m, window)
    span.steps <= 0 && return _empty_forage_only_metrics(window)

    total_distance = 0.0
    within_count = 0
    total_count = 0
    first_arrival = span.steps
    found_arrival = false
    capture_radius = Float64(m.config.capture_radius)

    # Goal competence retains the full initial cohort. Activity-aware filtering is
    # appropriate for collective descriptors, but removing failed agents from this
    # denominator would let mortality improve the task score.
    cohort = eachindex(m.history)
    @inbounds for (offset, tick) in enumerate(span.start:span.stop)
        any_arrived = false
        for i in cohort
            pose = m.history[i][tick]
            d = tdistance(m.torus, (pose[1], pose[2]), m.source_position)
            total_distance += d
            total_count += 1
            if d <= capture_radius
                within_count += 1
                any_arrived = true
            end
        end
        if any_arrived && !found_arrival
            first_arrival = offset
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

function forage_metrics(m::SituatedEnvironment{ForageMode}, window::Integer)
    return (;
        swarm_metrics(m, Int(window))...,
        _forage_only_metrics(m, Int(window))...,
    )
end

forage_metrics(c::Ensemble, window::Integer) = forage_metrics(c.environment, Int(window))

metrics(m::ForageEnvironment, window::Integer=_default_situated_window(m)) =
    forage_metrics(m, Int(window))

metrics(m::SituatedEnvironment{ForageMode}, window::Integer=_default_situated_window(m)) =
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
