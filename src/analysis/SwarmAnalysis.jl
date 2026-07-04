const _SWARM_REGIME_LABELS = (:polarized, :milling, :swarming, :static)

function _analysis_milling_series(sim::SimResult, name::Symbol)
    raw = getchannel(sim.recorder, :milling)
    if !isempty(raw)
        mat = _analysis_sample_matrix(raw, name)
        size(mat, 2) == 1 ||
            throw(DimensionMismatch("$(name) expected scalar :milling samples, got width $(size(mat, 2))"))
        return vec(copy(mat[:, 1]))
    end

    xs, ys, headings = _analysis_pose_matrices(getchannel(sim.recorder, :poses), name)
    torus_size = _analysis_environment_size(sim)
    torus = torus_size === nothing ? nothing : Torus(torus_size)
    out = Vector{Float64}(undef, size(headings, 1))
    positions = Matrix{Float64}(undef, size(headings, 2), 2)

    @inbounds for t in axes(headings, 1)
        for i in axes(headings, 2)
            positions[i, 1] = xs[t, i]
            positions[i, 2] = ys[t, i]
        end
        hs = @view headings[t, :]
        if torus === nothing
            centroid = (sum(@view(positions[:, 1])) / size(positions, 1), sum(@view(positions[:, 2])) / size(positions, 1))
            out[t] = milling(positions, hs, centroid)
        else
            centroid = circular_centroid(positions, torus)
            out[t] = milling(positions, hs, centroid, torus)
        end
    end
    return out
end

function _analysis_speed_series(sim::SimResult, name::Symbol)
    vx, vy, _, _, _ = _analysis_velocity_matrices(sim, name)
    speeds = Vector{Float64}(undef, size(vx, 1))
    @inbounds for t in axes(vx, 1)
        total = 0.0
        for i in axes(vx, 2)
            total += hypot(vx[t, i], vy[t, i])
        end
        speeds[t] = size(vx, 2) == 0 ? 0.0 : total / size(vx, 2)
    end
    return speeds
end

function _validate_regime_thresholds(polarized_threshold::Real, milling_threshold::Real, static_speed_threshold::Real)
    pol = Float64(polarized_threshold)
    mill = Float64(milling_threshold)
    static_speed = Float64(static_speed_threshold)
    0.0 <= pol <= 1.0 || throw(ArgumentError("polarized_threshold must be in [0, 1]"))
    0.0 <= mill <= 1.0 || throw(ArgumentError("milling_threshold must be in [0, 1]"))
    static_speed >= 0.0 && isfinite(static_speed) ||
        throw(ArgumentError("static_speed_threshold must be finite and non-negative"))
    return pol, mill, static_speed
end

function _swarm_regime_label(polarization_value::Real, milling_value::Real, speed_value::Real, pol_threshold::Real, mill_threshold::Real, static_speed_threshold::Real)
    speed_value <= static_speed_threshold && return :static
    if polarization_value >= pol_threshold && milling_value < mill_threshold
        return :polarized
    elseif milling_value >= mill_threshold && polarization_value < pol_threshold
        return :milling
    elseif polarization_value >= pol_threshold
        return :polarized
    elseif milling_value >= mill_threshold
        return :milling
    end
    return :swarming
end

"""
    swarm_regime(sim; polarized_threshold=0.65, milling_threshold=0.55, static_speed_threshold=1e-3)

Classify an EXPERIMENTAL swarm rollout into one of
`:polarized`, `:milling`, `:swarming`, or `:static`.

The classifier uses run-mean polarization, milling, and per-agent speed. A run
is `:static` when mean speed is at or below `static_speed_threshold`; otherwise
it is `:polarized` when polarization is at least `polarized_threshold`,
`:milling` when milling is at least `milling_threshold`, and `:swarming` when
neither ordered regime threshold is reached. If both ordered thresholds are
reached, polarization takes precedence.
"""
function swarm_regime(
    sim::SimResult;
    polarized_threshold::Real=0.65,
    milling_threshold::Real=0.55,
    static_speed_threshold::Real=1e-3,
)
    pol_threshold, mill_threshold, static_threshold =
        _validate_regime_thresholds(polarized_threshold, milling_threshold, static_speed_threshold)

    polarizations = _analysis_polarization_series(sim, :swarm_regime)
    millings = _analysis_milling_series(sim, :swarm_regime)
    speeds = _analysis_speed_series(sim, :swarm_regime)

    pol = _series_mean(polarizations)
    mill = _series_mean(millings)
    speed = isempty(speeds) ? 0.0 : _series_mean(speeds)
    label = _swarm_regime_label(pol, mill, speed, pol_threshold, mill_threshold, static_threshold)

    return (;
        label=label,
        polarization=pol,
        milling=mill,
        speed=speed,
        thresholds=(
            polarized=pol_threshold,
            milling=mill_threshold,
            static_speed=static_threshold,
        ),
        n_samples=(
            polarization=length(polarizations),
            milling=length(millings),
            speed=length(speeds),
        ),
    )
end

function _profile_correlation_length(distances::AbstractVector{<:Real}, correlations::AbstractVector{<:Real}, nbins::Integer, crossing::Symbol)
    length(distances) == length(correlations) ||
        throw(DimensionMismatch("distances and correlations must have the same length"))
    isempty(distances) && return 0.0

    crossing in (:zero, :inv_e) ||
        throw(ArgumentError("correlation_length crossing must be :zero or :inv_e"))
    n_bins = max(Int(nbins), 1)
    max_d = maximum(Float64.(distances))
    max_d > 0.0 || return 0.0

    corr_sums = zeros(Float64, n_bins)
    dist_sums = zeros(Float64, n_bins)
    counts = zeros(Int, n_bins)
    @inbounds for i in eachindex(distances, correlations)
        d = Float64(distances[i])
        c = Float64(correlations[i])
        isfinite(d) && isfinite(c) || continue
        bin = min(n_bins, max(1, floor(Int, d / max_d * n_bins) + 1))
        corr_sums[bin] += c
        dist_sums[bin] += d
        counts[bin] += 1
    end

    centers = Float64[]
    profile = Float64[]
    @inbounds for bin in 1:n_bins
        counts[bin] == 0 && continue
        push!(centers, dist_sums[bin] / counts[bin])
        push!(profile, corr_sums[bin] / counts[bin])
    end
    isempty(profile) && return 0.0

    threshold = crossing == :zero ? 0.0 : profile[1] * exp(-1.0)
    if profile[1] <= threshold
        return 0.0
    end

    @inbounds for i in 2:length(profile)
        if profile[i] <= threshold
            x0 = centers[i - 1]
            x1 = centers[i]
            y0 = profile[i - 1] - threshold
            y1 = profile[i] - threshold
            denom = y0 - y1
            denom == 0.0 && return x1
            return x0 + (x1 - x0) * (y0 / denom)
        end
    end

    return centers[end]
end

function _correlation_length_from_matrices(
    vx::AbstractMatrix{<:Real},
    vy::AbstractMatrix{<:Real},
    xs::AbstractMatrix{<:Real},
    ys::AbstractMatrix{<:Real},
    steps,
    torus,
    nbins::Integer,
    crossing::Symbol,
)
    n_agents = size(vx, 2)
    if isempty(steps) || n_agents < 2
        return 0.0
    end

    distances = Float64[]
    dot_products = Float64[]
    fluctuation_norm2 = 0.0
    fluctuation_count = 0

    @inbounds for t in steps
        mean_vx = _series_mean(@view vx[t, :])
        mean_vy = _series_mean(@view vy[t, :])
        for i in 1:n_agents
            uix = vx[t, i] - mean_vx
            uiy = vy[t, i] - mean_vy
            fluctuation_norm2 += uix * uix + uiy * uiy
            fluctuation_count += 1
        end
        for i in 1:(n_agents - 1)
            uix = vx[t, i] - mean_vx
            uiy = vy[t, i] - mean_vy
            for j in (i + 1):n_agents
                ujx = vx[t, j] - mean_vx
                ujy = vy[t, j] - mean_vy
                d = torus === nothing ?
                    hypot(xs[t, j] - xs[t, i], ys[t, j] - ys[t, i]) :
                    tdistance(torus, (xs[t, i], ys[t, i]), (xs[t, j], ys[t, j]))
                push!(distances, d)
                push!(dot_products, uix * ujx + uiy * ujy)
            end
        end
    end

    denom = fluctuation_count == 0 ? 0.0 : fluctuation_norm2 / fluctuation_count
    denom > 0.0 || return 0.0
    correlations = dot_products ./ denom
    return _profile_correlation_length(distances, correlations, nbins, crossing)
end

"""
    correlation_length(sim; nbins=12, crossing=:zero)

Estimate an EXPERIMENTAL spatial velocity-correlation length for a swarm.

For each recorded pose transition, velocities are computed with torus-aware
deltas when the simulation has a torus size. The velocity fluctuation for each
agent is its velocity minus the ensemble mean velocity at that transition. The
pairwise correlation follows Cavagna et al. (2010): binned
`<δv_i · δv_j>` is normalized once by the global `<δv_i · δv_i>`, not by each
pair's vector norms. The returned scalar is the first distance where the binned
mean correlation crosses zero (`crossing=:zero`, default) or drops below `1/e`
of the first occupied bin (`crossing=:inv_e`).
"""
function correlation_length(sim::SimResult; nbins::Integer=12, crossing::Symbol=:zero)
    vx, vy, xs, ys, _ = _analysis_velocity_matrices(sim, :correlation_length)
    n_steps, n_agents = size(vx)
    if n_steps == 0 || n_agents < 2
        return 0.0
    end

    torus_size = _analysis_environment_size(sim)
    torus = torus_size === nothing ? nothing : Torus(torus_size)
    return _correlation_length_from_matrices(vx, vy, xs, ys, 1:n_steps, torus, nbins, crossing)
end

"""
    correlation_length_windowed(sim; window, stride=window, nbins=12, crossing=:zero)

Compute the swarm velocity-correlation length over sliding windows of recorded
pose transitions. Returns `(; t_centers, correlation_length, window, stride)`.
"""
function correlation_length_windowed(sim::SimResult; window::Integer, stride::Integer=window, nbins::Integer=12, crossing::Symbol=:zero)
    window = Int(window)
    stride = Int(stride)
    _window_validate(:correlation_length_windowed, window, stride)
    vx, vy, xs, ys, _ = _analysis_velocity_matrices(sim, :correlation_length_windowed)
    starts, centers = _window_centers(size(vx, 1), window, stride)
    values = Vector{Float64}(undef, length(starts))
    torus_size = _analysis_environment_size(sim)
    torus = torus_size === nothing ? nothing : Torus(torus_size)

    @inbounds for idx in eachindex(starts)
        start = starts[idx]
        values[idx] = _correlation_length_from_matrices(vx, vy, xs, ys, start:(start + window - 1), torus, nbins, crossing)
    end
    return (; t_centers=centers, correlation_length=values, window=window, stride=stride, nbins=Int(nbins), crossing=crossing)
end

function _contact_components_at_tick(xs::AbstractMatrix{<:Real}, ys::AbstractMatrix{<:Real}, t::Integer, torus, radius::Real)
    n_agents = size(xs, 2)
    visited = falses(n_agents)
    stack = Int[]
    n_components = 0
    largest = 0

    @inbounds for seed in 1:n_agents
        visited[seed] && continue
        n_components += 1
        component_size = 0
        push!(stack, seed)
        visited[seed] = true
        while !isempty(stack)
            i = pop!(stack)
            component_size += 1
            for j in 1:n_agents
                visited[j] && continue
                d = torus === nothing ?
                    hypot(xs[t, j] - xs[t, i], ys[t, j] - ys[t, i]) :
                    tdistance(torus, (xs[t, i], ys[t, i]), (xs[t, j], ys[t, j]))
                if d <= radius
                    visited[j] = true
                    push!(stack, j)
                end
            end
        end
        largest = max(largest, component_size)
    end

    return n_components, largest
end

function _contact_graph_cluster_series(sim::SimResult, radius)
    xs, ys, _ = _analysis_pose_matrices(getchannel(sim.recorder, :poses), :contact_graph_clusters)
    radius_ = _analysis_neighbor_radius(sim, radius, :contact_graph_clusters)
    torus_size = _analysis_environment_size(sim)
    torus = torus_size === nothing ? nothing : Torus(torus_size)
    n_ticks, n_agents = size(xs)
    n_components = Vector{Float64}(undef, n_ticks)
    largest_component_frac = Vector{Float64}(undef, n_ticks)
    mean_component_size = Vector{Float64}(undef, n_ticks)

    @inbounds for t in 1:n_ticks
        n_comp, largest = _contact_components_at_tick(xs, ys, t, torus, radius_)
        n_components[t] = Float64(n_comp)
        largest_component_frac[t] = n_agents == 0 ? NaN : Float64(largest) / n_agents
        mean_component_size[t] = n_comp == 0 ? NaN : Float64(n_agents) / n_comp
    end
    return radius_, n_components, largest_component_frac, mean_component_size, n_agents
end

"""
    contact_graph_clusters(sim; radius=nothing)

Build the per-tick within-radius contact graph and summarize connected
components. `radius=nothing` reuses `sim.config.environment.vision_range`.
"""
function contact_graph_clusters(sim::SimResult; radius=nothing)
    radius_, n_components, largest_component_frac, mean_component_size, n_agents =
        _contact_graph_cluster_series(sim, radius)
    return (;
        radius=radius_,
        n_components=n_components,
        largest_component_frac=largest_component_frac,
        mean_component_size=mean_component_size,
        n_components_mean=_analysis_finite_mean(n_components),
        largest_component_frac_mean=_analysis_finite_mean(largest_component_frac),
        mean_component_size_mean=_analysis_finite_mean(mean_component_size),
        n_agents=n_agents,
    )
end

function _windowed_mean_series(series::AbstractVector{<:Real}, starts, window::Integer)
    out = Vector{Float64}(undef, length(starts))
    @inbounds for idx in eachindex(starts)
        start = starts[idx]
        out[idx] = _analysis_finite_mean(@view series[start:(start + window - 1)])
    end
    return out
end

"""
    contact_graph_clusters_windowed(sim; window, stride=window, radius=nothing)

Return sliding-window means of contact-graph component summaries.
"""
function contact_graph_clusters_windowed(sim::SimResult; window::Integer, stride::Integer=window, radius=nothing)
    window = Int(window)
    stride = Int(stride)
    _window_validate(:contact_graph_clusters_windowed, window, stride)
    radius_, n_components, largest_component_frac, mean_component_size, n_agents =
        _contact_graph_cluster_series(sim, radius)
    starts, centers = _window_centers(length(n_components), window, stride)
    return (;
        radius=radius_,
        t_centers=centers,
        n_components=_windowed_mean_series(n_components, starts, window),
        largest_component_frac=_windowed_mean_series(largest_component_frac, starts, window),
        mean_component_size=_windowed_mean_series(mean_component_size, starts, window),
        window=window,
        stride=stride,
        n_agents=n_agents,
    )
end
