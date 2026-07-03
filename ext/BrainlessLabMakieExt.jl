module BrainlessLabMakieExt

import BrainlessLab
import Makie

const BL = BrainlessLab

# ─── Visual identity ──────────────────────────────────────────────────────────
# One warm editorial palette across every figure and GIF. Each entity has a
# canonical glyph: agents are teal boids that point where they head; the source
# is an amber target with its capture ring; spikes are ink, population rate is
# teal. Core palette triples live in src/viz/Style.jl.
const _PAPER     = Makie.RGBf(BL.BL_PAPER...)
const _INK       = Makie.RGBf(BL.BL_INK...)
const _INKSOFT   = Makie.RGBf(BL.BL_INKSOFT...)
const _GRID      = Makie.RGBf(BL.BL_GRID...)
const _TEAL      = Makie.RGBf(BL.BL_TEAL...)
const _TEALSOFT  = Makie.RGBf(BL.BL_TEALSOFT...)
const _AMBER     = Makie.RGBf(BL.BL_AMBER...)
const _AMBERSOFT = Makie.RGBf(BL.BL_AMBERSOFT...)
const _INKMUTED  = Makie.RGBf(BL.BL_INKMUTED...)
const _BRAND_RAMP = Makie.cgrad([_PAPER, _TEAL, _INK])
const _CATEGORICAL = (_TEAL, _AMBER, _INKSOFT, _TEALSOFT, _AMBERSOFT, _INKMUTED)

_series_color(i::Integer) = i <= length(_CATEGORICAL) ? _CATEGORICAL[i] : _INKMUTED

function _style_axis!(ax)
    ax.backgroundcolor = _PAPER
    ax.xgridcolor = (_GRID, 0.9);  ax.ygridcolor = (_GRID, 0.9)
    ax.xgridwidth = 0.8;           ax.ygridwidth = 0.8
    ax.topspinevisible = false;    ax.rightspinevisible = false
    ax.leftspinecolor = _GRID;     ax.bottomspinecolor = _GRID
    ax.xtickcolor = _GRID;         ax.ytickcolor = _GRID
    ax.xticklabelcolor = _INKSOFT; ax.yticklabelcolor = _INKSOFT
    ax.xlabelcolor = _INKSOFT;     ax.ylabelcolor = _INKSOFT
    ax.xticklabelsize = 11;        ax.yticklabelsize = 11
    ax.titlecolor = _INK;          ax.titlesize = 15
    ax.titlealign = :left;         ax.titlegap = 8
    return ax
end

_bl_figure(sz) = Makie.Figure(size=sz, backgroundcolor=_PAPER)

function _capture_radius(sim)
    sim isa BL.SimResult || return nothing
    hasproperty(sim.config, :environment) || return nothing
    environment = sim.config.environment
    hasproperty(environment, :capture_radius) || return nothing
    r = environment.capture_radius
    return r === nothing ? nothing : Float64(r)
end

_recorder(sim::BL.SimResult) = sim.recorder
_recorder(rec::BL.Recorder) = rec
_channel(x, channel::Symbol) = BL.getchannel(_recorder(x), channel)

function _flatten_numeric!(out::Vector{Float64}, x)
    if x isa Number
        push!(out, Float64(x))
    elseif x isa AbstractArray
        if eltype(x) <: Number
            append!(out, Float64.(vec(x)))
        else
            for item in x
                _flatten_numeric!(out, item)
            end
        end
    elseif x isa Tuple
        for item in x
            _flatten_numeric!(out, item)
        end
    end
    return out
end

function _flat_sample(x)
    out = Float64[]
    _flatten_numeric!(out, x)
    return out
end

function _sample_matrix(samples)
    vectors = [_flat_sample(sample) for sample in samples]
    width = isempty(vectors) ? 0 : maximum(length, vectors)
    mat = zeros(Float64, width, length(vectors))
    @inbounds for t in eachindex(vectors)
        v = vectors[t]
        isempty(v) && continue
        mat[1:length(v), t] .= v
    end
    return mat
end

function _mean(values::AbstractVector{Float64})
    isempty(values) && return 0.0
    return sum(values) / length(values)
end

function _rate_trace(sim)
    samples = _channel(sim, :rate)
    isempty(samples) && (samples = _channel(sim, :rates))
    if !isempty(samples)
        return [_mean(_flat_sample(sample)) for sample in samples]
    end

    spikes = _channel(sim, :spikes)
    return [_mean(_flat_sample(sample)) for sample in spikes]
end

# Per-tick branching ratio σ(t) = A(t+1)/A(t) from the recorded :rate channel.
# Returns an empty vector when :rate isn't recorded (so callers can gate).
function _branching_trace(sim)
    try
        return Float64.(BL.branching_ratio(sim).per_tick)
    catch
        return Float64[]
    end
end

# Simple linear-interpolated percentile over finite values (0..100).
function _pctl(sorted::Vector{Float64}, p::Real)
    isempty(sorted) && return NaN
    length(sorted) == 1 && return sorted[1]
    r = clamp(p / 100, 0.0, 1.0) * (length(sorted) - 1) + 1
    lo = floor(Int, r); hi = ceil(Int, r)
    lo == hi && return sorted[lo]
    frac = r - lo
    return sorted[lo] * (1 - frac) + sorted[hi] * frac
end

# Robust y-limits for a σ(t) panel: 2nd–98th percentile of finite σ so the
# switch-on spike (dividing by the near-zero initial rate) can't flatten the
# view, with σ=1 kept inside and small padding.
function _sigma_limits(sigma::Vector{Float64})
    fin = sort!(filter(isfinite, sigma))
    isempty(fin) && return (0.8, 1.2)
    lo = min(_pctl(fin, 2.0), 1.0)
    hi = max(_pctl(fin, 98.0), 1.0)
    pad = 0.05 * max(hi - lo, eps())
    return (lo - pad, hi + pad)
end

# Draw the branching-ratio σ(t) panel for animation frame f: the σ trace, a
# swept marker at f, a dashed σ=1 reference, and the current σ printed as text.
function _draw_branching!(axb, sigma::Vector{Float64}, f::Integer, lims::Tuple{Float64,Float64})
    Makie.empty!(axb)
    nsig = length(sigma)
    nsig == 0 && return axb
    Makie.lines!(axb, 1:nsig, sigma; color=_TEAL, linewidth=1.2)
    Makie.hlines!(axb, [1.0]; color=(_AMBER, 0.9), linestyle=:dash, linewidth=1.2)
    fi = clamp(f, 1, nsig)
    Makie.vlines!(axb, [fi]; color=(_INK, 0.8), linewidth=1.5)
    cur = sigma[fi]
    # Fall back to the nearest earlier finite σ for the readout if this tick is NaN.
    if !isfinite(cur)
        j = fi
        while j >= 1 && !isfinite(sigma[j]); j -= 1; end
        cur = j >= 1 ? sigma[j] : NaN
    end
    label = isfinite(cur) ? "σ = $(round(cur; digits=2))" : "σ = n/a"
    Makie.text!(axb, 0.015, 0.92; text=label, space=:relative, align=(:left, :top),
                color=_INK, fontsize=15, font=:bold)
    Makie.xlims!(axb, 1, max(nsig, 2))
    Makie.ylims!(axb, lims[1], lims[2])
    return axb
end

function _draw_rate_frame!(ax, rate::Vector{Float64}, f::Integer, rmax::Float64)
    Makie.empty!(ax)
    nr = length(rate)
    if nr > 0
        xs = 1:nr
        Makie.band!(ax, xs, fill(0.0, nr), rate; color=(_TEAL, 0.10))
        Makie.lines!(ax, xs, rate; color=_TEAL, linewidth=1.5)
        Makie.vlines!(ax, [min(f, nr)]; color=(_INK, 0.75), linewidth=1.4)
    end
    Makie.xlims!(ax, 1, max(nr, 2))
    Makie.ylims!(ax, 0, rmax)
    return ax
end

function _collect_poses!(out::Vector{NTuple{3,Float64}}, x)
    if x isa Tuple && length(x) >= 2 && x[1] isa Number && x[2] isa Number
        theta = length(x) >= 3 && x[3] isa Number ? Float64(x[3]) : 0.0
        push!(out, (Float64(x[1]), Float64(x[2]), theta))
    elseif x isa AbstractVector
        if eltype(x) <: Number && length(x) >= 2
            theta = length(x) >= 3 ? Float64(x[3]) : 0.0
            push!(out, (Float64(x[1]), Float64(x[2]), theta))
        else
            for item in x
                _collect_poses!(out, item)
            end
        end
    elseif x isa NamedTuple && (:x in keys(x)) && (:y in keys(x))
        theta = (:theta in keys(x)) ? Float64(x.theta) : 0.0
        push!(out, (Float64(x.x), Float64(x.y), theta))
    end
    return out
end

function _pose_rows(sample)
    out = NTuple{3,Float64}[]
    _collect_poses!(out, sample)
    return out
end

function _pose_tracks(sim)
    samples = _channel(sim, :poses)
    rows = [_pose_rows(sample) for sample in samples]
    n_agents = isempty(rows) ? 0 : maximum(length, rows)
    tracks = [NTuple{3,Float64}[] for _ in 1:n_agents]

    for sample_rows in rows
        for i in eachindex(sample_rows)
            push!(tracks[i], sample_rows[i])
        end
    end

    return tracks
end

function _plot_bounds(sim)
    sim isa BL.SimResult || return nothing
    hasproperty(sim.config, :environment) || return nothing
    environment = sim.config.environment
    hasproperty(environment, :bounds) || return nothing
    return environment.bounds
end

function _source_position(sim)
    sim isa BL.SimResult || return nothing
    hasproperty(sim.config, :environment) || return nothing
    environment = sim.config.environment
    hasproperty(environment, :source_position) || return nothing
    source = environment.source_position
    source === nothing && return nothing
    return (Float64(source[1]), Float64(source[2]))
end

function _draw_source!(ax, sim)
    source = _source_position(sim)
    source === nothing && return ax
    r = _capture_radius(sim)
    if r !== nothing && r > 0.0
        ts = range(0.0, 2pi; length=72)
        ring = [Makie.Point2f(source[1] + r * cos(t), source[2] + r * sin(t)) for t in ts]
        Makie.poly!(ax, ring; color=(_AMBER, 0.08), strokecolor=(_AMBER, 0.45), strokewidth=1.0)
    end
    # amber target: filled disc with a paper center reads as a soft ring
    Makie.scatter!(ax, [source[1]], [source[2]]; marker=:circle, markersize=18,
                   color=_AMBER, strokecolor=_PAPER, strokewidth=1.5)
    Makie.scatter!(ax, [source[1]], [source[2]]; marker=:circle, markersize=7, color=_PAPER)
    return ax
end

function _draw_bounds!(ax, sim)
    bounds = _plot_bounds(sim)
    bounds === nothing && return ax

    x0, x1, y0, y1 = bounds
    Makie.lines!(ax, [x0, x1, x1, x0, x0], [y0, y0, y1, y1, y0]; color=(_INKSOFT, 0.30), linewidth=1.0)
    Makie.xlims!(ax, x0, x1)
    Makie.ylims!(ax, y0, y1)
    ax.aspect = Makie.DataAspect()  # spatial worlds are square; keeps rings circular
    return ax
end

function _draw_raster!(ax, sim)
    mat = _sample_matrix(_channel(sim, :spikes))
    xs = Float64[]
    ys = Float64[]
    @inbounds for t in axes(mat, 2), n in axes(mat, 1)
        if mat[n, t] > 0.5
            push!(xs, Float64(t))
            push!(ys, Float64(n))
        end
    end
    Makie.scatter!(ax, xs, ys; markersize=1.6, color=(_INK, 0.85))
    ax.xlabel = "tick"
    ax.ylabel = "node"
    ax.title = "Spike raster"
    return ax
end

function _draw_rate!(ax, sim)
    trace = _rate_trace(sim)
    xs = collect(1:length(trace))
    isempty(trace) || Makie.band!(ax, xs, fill(0.0, length(trace)), trace; color=(_TEAL, 0.12))
    Makie.lines!(ax, xs, trace; color=_TEAL, linewidth=2)
    ax.xlabel = "tick"
    ax.ylabel = "rate"
    ax.title = "Population firing rate"
    return ax
end

# On a periodic torus, a seam crossing jumps the raw coordinate by ~L, which
# lines! would draw as a segment straight across the world. Break the polyline
# (insert NaN, which Makie renders as a gap) wherever a step exceeds half the
# world extent — a legitimate per-tick move is never that large.
function _wrap_break(xs::Vector{Float64}, ys::Vector{Float64}, bounds)
    bounds === nothing && return xs, ys
    x0, x1, y0, y1 = bounds
    halfx = 0.5 * (Float64(x1) - Float64(x0))
    halfy = 0.5 * (Float64(y1) - Float64(y0))
    ox = Float64[]
    oy = Float64[]
    @inbounds for i in eachindex(xs)
        if i > 1 && ((halfx > 0.0 && abs(xs[i] - xs[i - 1]) > halfx) ||
                     (halfy > 0.0 && abs(ys[i] - ys[i - 1]) > halfy))
            push!(ox, NaN)
            push!(oy, NaN)
        end
        push!(ox, xs[i])
        push!(oy, ys[i])
    end
    return ox, oy
end

function _draw_trajectory!(ax, sim)
    _draw_bounds!(ax, sim)
    bounds = _plot_bounds(sim)
    tracks = _pose_tracks(sim)
    for track in tracks
        isempty(track) && continue
        xs = [Float64(pose[1]) for pose in track]
        ys = [Float64(pose[2]) for pose in track]
        bx, by = _wrap_break(xs, ys, bounds)
        Makie.lines!(ax, bx, by; color=(_TEAL, 0.55), linewidth=2)
        Makie.scatter!(ax, [xs[end]], [ys[end]]; markersize=8, color=_TEAL,
                       strokecolor=_PAPER, strokewidth=0.6)
    end
    ax.xlabel = "x"
    ax.ylabel = "y"
    ax.title = "Trajectory"
    return ax
end

function _draw_agent_boids!(ax, poses; markersize=16)
    xs = [pose[1] for pose in poses]
    ys = [pose[2] for pose in poses]
    hd = [pose[3] for pose in poses]
    Makie.scatter!(ax, xs, ys; marker=:utriangle, rotation=(hd .- (pi / 2)),
                   markersize=markersize, color=_TEAL, strokecolor=_PAPER, strokewidth=0.8)
    return ax
end

function _latest_pose_rows(sim)
    samples = _channel(sim, :poses)
    isempty(samples) && return NTuple{3,Float64}[]
    return _pose_rows(samples[end])
end

function _draw_swarm!(ax, sim)
    _draw_bounds!(ax, sim)
    _draw_source!(ax, sim)
    poses = _latest_pose_rows(sim)
    # agents are teal boids: the glyph points along its heading (no separate tail)
    _draw_agent_boids!(ax, poses)

    pol = _channel(sim, :polarization)
    mill = _channel(sim, :milling)
    suffix = isempty(pol) && isempty(mill) ? "" :
        "  P=$(round(isempty(pol) ? 0.0 : Float64(pol[end]); digits=2))  M=$(round(isempty(mill) ? 0.0 : Float64(mill[end]); digits=2))"
    ax.title = "Swarm$(suffix)"
    return ax
end

function _network_info(sim)
    sim isa BL.SimResult || return nothing
    hasproperty(sim.config, :network) || return nothing
    return sim.config.network
end

function _network_state(sim, n::Integer)
    spikes = _channel(sim, :spikes)
    if !isempty(spikes)
        state = _flat_sample(spikes[end])
        length(state) >= n && return state[1:n]
    end

    net = _network_info(sim)
    if net !== nothing && hasproperty(net, :state)
        state = Float64.(vec(net.state))
        length(state) >= n && return state[1:n]
    end

    return zeros(Float64, n)
end

function _draw_network!(ax, sim)
    net = _network_info(sim)
    adjacency = net === nothing || !hasproperty(net, :adjacency) ?
        zeros(Float64, 0, 0) :
        Matrix{Float64}(net.adjacency)
    n = size(adjacency, 1)
    if n == 0
        ax.title = "Network"
        return ax
    end

    angles = range(0.0, 2.0 * pi; length=n + 1)[1:n]
    xs = cos.(angles)
    ys = sin.(angles)

    segments = Makie.Point2f[]
    @inbounds for i in 1:n, j in 1:n
        adjacency[i, j] == 0.0 && continue
        push!(segments, Makie.Point2f(xs[i], ys[i]))
        push!(segments, Makie.Point2f(xs[j], ys[j]))
    end
    isempty(segments) || Makie.linesegments!(ax, segments; color=(_INKSOFT, 0.28), linewidth=0.5)

    Makie.scatter!(ax, xs, ys; color=_network_state(sim, n), colormap=_BRAND_RAMP,
                   markersize=8, strokecolor=_PAPER, strokewidth=0.35)
    Makie.hidedecorations!(ax)
    Makie.hidespines!(ax)
    ax.aspect = Makie.DataAspect()
    ax.title = "Reservoir network"
    return ax
end

function _cosine_columns(mat, i::Integer, j::Integer)
    dot_ab = 0.0
    norm_a = 0.0
    norm_b = 0.0
    @inbounds for n in axes(mat, 1)
        a = mat[n, i]
        b = mat[n, j]
        dot_ab += a * b
        norm_a += a * a
        norm_b += b * b
    end
    denom = sqrt(norm_a) * sqrt(norm_b)
    return denom == 0.0 ? 0.0 : dot_ab / denom
end

function _drift_matrix(sim; bin::Integer=5)
    spikes = _sample_matrix(_channel(sim, :spikes))
    if isempty(spikes)
        rates = _rate_trace(sim)
        spikes = reshape(Float64.(rates), 1, length(rates))
    end
    isempty(spikes) && return zeros(Float64, 0, 0)

    bin = max(1, Int(bin))
    n_bins = cld(size(spikes, 2), bin)
    patterns = zeros(Float64, size(spikes, 1), n_bins)
    @inbounds for b in 1:n_bins
        lo = (b - 1) * bin + 1
        hi = min(b * bin, size(spikes, 2))
        width = hi - lo + 1
        for n in axes(spikes, 1)
            total = 0.0
            for t in lo:hi
                total += spikes[n, t]
            end
            patterns[n, b] = total / width
        end
    end

    corr = zeros(Float64, n_bins, n_bins)
    @inbounds for i in 1:n_bins, j in 1:n_bins
        corr[i, j] = _cosine_columns(patterns, i, j)
    end
    return corr
end

function _draw_drift!(ax, sim; bin::Integer=5)
    _style_axis!(ax)
    corr = _drift_matrix(sim; bin=bin)
    Makie.heatmap!(ax, corr; colormap=_BRAND_RAMP, colorrange=(0.0, 1.0))
    ax.xlabel = "time bin"
    ax.ylabel = "time bin"
    ax.title = "Spike-pattern autocorrelation"
    return ax
end

function _draw_fitness!(ax, curve)
    values = Float64.(curve)
    if ndims(values) == 1
        Makie.lines!(ax, 1:length(values), values; color=_TEAL, linewidth=2)
    else
        mat = Matrix{Float64}(values)
        for col in axes(mat, 2)
            Makie.lines!(ax, 1:size(mat, 1), mat[:, col]; color=_series_color(col), linewidth=1.5)
        end
    end
    ax.xlabel = "generation"
    ax.ylabel = "fitness"
    ax.title = "Fitness"
    return ax
end

function _figure_axis(; size=(900, 320))
    fig = _bl_figure(size)
    ax = Makie.Axis(fig[1, 1])
    _style_axis!(ax)
    return fig, ax
end

function BL.rasterplot(sim::Union{BL.SimResult,BL.Recorder}; kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_raster!(ax, sim)
    return fig
end

function BL.rateplot(sim::Union{BL.SimResult,BL.Recorder}; kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_rate!(ax, sim)
    return fig
end

function BL.trajectoryplot(sim::Union{BL.SimResult,BL.Recorder}; kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_trajectory!(ax, sim)
    return fig
end

function BL.swarmplot(sim::Union{BL.SimResult,BL.Recorder}; kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_swarm!(ax, sim)
    return fig
end

function BL.networkplot(sim::BL.SimResult; kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_network!(ax, sim)
    return fig
end

function BL.driftplot(sim::Union{BL.SimResult,BL.Recorder}; bin::Integer=5, kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_drift!(ax, sim; bin=bin)
    return fig
end

function BL.fitnessplot(curve; kwargs...)
    fig, ax = _figure_axis(; kwargs...)
    _draw_fitness!(ax, curve)
    return fig
end

function _draw_panel!(ax, sim, panel::Symbol)
    if panel == :raster
        return _draw_raster!(ax, sim)
    elseif panel == :rate
        return _draw_rate!(ax, sim)
    elseif panel == :trajectory
        return _draw_trajectory!(ax, sim)
    elseif panel == :swarm
        return _draw_swarm!(ax, sim)
    elseif panel == :network
        return _draw_network!(ax, sim)
    elseif panel == :drift
        return _draw_drift!(ax, sim)
    end

    panel_view = BL.resolve_view(panel)
    if applicable(panel_view, ax, sim)
        return panel_view(ax, sim)
    elseif applicable(panel_view, sim, ax)
        return panel_view(sim, ax)
    end
    throw(ArgumentError("registered view :$(panel) cannot draw as a visualize panel; define a method accepting (axis, sim)"))
end

function BL.visualize(sim::BL.SimResult; panels=[:raster, :rate, :trajectory], size=nothing)
    panel_syms = Symbol.(collect(panels))
    fig_size = size === nothing ? (900, max(260, 260 * length(panel_syms))) : size
    fig = _bl_figure(fig_size)
    for (row, panel) in enumerate(panel_syms)
        ax = Makie.Axis(fig[row, 1])
        _style_axis!(ax)
        _draw_panel!(ax, sim, panel)
    end
    return fig
end

BL.replay(sim::BL.SimResult; kwargs...) = BL.visualize(sim; kwargs...)

# Draw one frame of a task-specific behaviour scene (tracking/pong/cartpole).
function _draw_scene_frame!(ax, s, f, nt)
    if s.kind === :tracking
        ts = range(0.0, 2pi; length=96)
        Makie.lines!(ax, cos.(ts), sin.(ts); color=(_GRID, 0.85), linewidth=1)
        Makie.xlims!(ax, -1.3, 1.3); Makie.ylims!(ax, -1.3, 1.3)
        Makie.scatter!(ax, [cos(s.phi)], [sin(s.phi)]; markersize=20, color=_AMBER,
                       strokecolor=_PAPER, strokewidth=1.0)                                  # stimulus
        Makie.linesegments!(ax, [Makie.Point2f(0, 0), Makie.Point2f(0.9cos(s.theta), 0.9sin(s.theta))];
                            color=_TEAL, linewidth=3)                                        # eye heading
        Makie.scatter!(ax, [0.0], [0.0]; markersize=9, color=_INKSOFT)
        err = rad2deg(abs(atan(sin(s.theta - s.phi), cos(s.theta - s.phi))))
        ax.title = "tracking   tick $f/$nt   error=$(round(err; digits=1))°"
    elseif s.kind === :pong
        Makie.lines!(ax, [0, s.width, s.width, 0, 0], [0, 0, s.height, s.height, 0];
                     color=(_GRID, 0.9))
        Makie.xlims!(ax, -0.03s.width, 1.03s.width); Makie.ylims!(ax, -0.03s.height, 1.03s.height)
        Makie.lines!(ax, [s.paddle_x, s.paddle_x], [s.paddle_y - s.paddle_h / 2, s.paddle_y + s.paddle_h / 2];
                     color=_TEAL, linewidth=7)                                                # paddle
        Makie.scatter!(ax, [s.ball_x], [s.ball_y]; markersize=16, color=_AMBER,
                       strokecolor=_PAPER, strokewidth=1.0)                                  # ball
        ax.title = "pong   tick $f/$nt"
    elseif s.kind === :cartpole
        L = 2.0 * s.pole_length
        Makie.lines!(ax, [-s.max_x, s.max_x], [0.0, 0.0]; color=(_GRID, 0.9))                # track
        Makie.xlims!(ax, -s.max_x - 0.5, s.max_x + 0.5); Makie.ylims!(ax, -0.4, L + 0.4)
        Makie.scatter!(ax, [s.x], [0.0]; marker=:rect, markersize=24, color=_TEALSOFT,
                       strokecolor=_TEAL, strokewidth=1.0)                                   # cart
        Makie.linesegments!(ax, [Makie.Point2f(s.x, 0.0), Makie.Point2f(s.x + L * sin(s.theta), L * cos(s.theta))];
                            color=_TEAL, linewidth=4)                                        # pole
        Makie.scatter!(ax, [s.x + L * sin(s.theta)], [L * cos(s.theta)];
                       markersize=12, color=_TEAL, strokecolor=_PAPER, strokewidth=0.8)
        ax.title = "cartpole   tick $f/$nt   θ=$(round(rad2deg(s.theta); digits=1))°"
    else
        ax.title = "tick $f/$nt"
    end
    return ax
end

# Animate a task that exposes a per-tick :scene (tracking/pong/cartpole).
function _animate_scenes(sim, scenes, path, framerate, maxframes; branching::Bool=false)
    nt = length(scenes)
    frames = unique(round.(Int, range(1, nt; length=min(nt, maxframes))))
    sigma = branching ? _branching_trace(sim) : Float64[]
    show_b = branching && !isempty(sigma)

    fig = _bl_figure((720, 720))
    axw = Makie.Axis(fig[1, 1]; aspect=Makie.DataAspect())
    _style_axis!(axw)
    if show_b
        slims = _sigma_limits(sigma)
        axb = Makie.Axis(fig[2, 1]; xlabel="tick", ylabel="σ", title="branching ratio")
        _style_axis!(axb)
        Makie.rowsize!(fig.layout, 2, Makie.Relative(0.24))
        Makie.record(fig, path, frames; framerate=framerate) do f
            Makie.empty!(axw)
            _draw_scene_frame!(axw, scenes[min(f, nt)], f, nt)
            _draw_branching!(axb, sigma, f, slims)
        end
    else
        rate = _rate_trace(sim)
        nr = length(rate)
        rmax = nr == 0 ? 1.0 : max(1e-6, maximum(rate)) * 1.05
        axr = Makie.Axis(fig[2, 1]; xlabel="tick", ylabel="rate", title="firing rate")
        _style_axis!(axr)
        Makie.rowsize!(fig.layout, 2, Makie.Relative(0.20))
        Makie.record(fig, path, frames; framerate=framerate) do f
            Makie.empty!(axw)
            _draw_scene_frame!(axw, scenes[min(f, nt)], f, nt)
            _draw_rate_frame!(axr, rate, f, rmax)
        end
    end
    return path
end

"""
    animate(sim; path="activity.gif", framerate=20, trail=40, maxframes=200, branching=false)

Render a GIF/MP4 of the rollout (output format follows the `path` extension —
`.gif` or `.mp4`). Tasks that expose a per-tick `:scene` (tracking/pong/cartpole)
get a task-specific behaviour view; embodied tasks (wall/torus) get the agent(s)
moving via `:poses`. A synced firing-rate marker runs underneath by default; with
`branching=true` (needs `:rate` recorded) the lower panel instead shows the
branching ratio σ(t) with a swept marker, a dashed σ=1 reference, and the current
σ printed on each frame. Returns the output path.
"""
function BL.animate(sim::BL.SimResult; path::AbstractString="activity.gif",
                    framerate::Integer=20, trail::Integer=40, maxframes::Integer=200,
                    branching::Bool=false)
    scenes = _channel(sim, :scene)
    isempty(scenes) || return _animate_scenes(sim, scenes, path, framerate, maxframes; branching=branching)
    tracks = _pose_tracks(sim)
    rate = _rate_trace(sim)
    nt = isempty(tracks) ? length(rate) : maximum(length, tracks)
    nt == 0 && throw(ArgumentError("animate: nothing recorded (need :poses or :rate)"))
    frames = unique(round.(Int, range(1, nt; length=min(nt, maxframes))))
    bounds = _plot_bounds(sim)
    pol = _channel(sim, :polarization)
    mill = _channel(sim, :milling)
    has_world = !isempty(tracks)
    nr = length(rate)
    rmax = nr == 0 ? 1.0 : max(1e-6, maximum(rate)) * 1.05

    sigma = branching ? _branching_trace(sim) : Float64[]
    show_b = branching && !isempty(sigma)
    slims = show_b ? _sigma_limits(sigma) : (0.0, 1.0)

    fig = _bl_figure((720, has_world ? 760 : 340))
    axw = has_world ? Makie.Axis(fig[1, 1]; xlabel="x", ylabel="y") : nothing
    axlow = show_b ?
        Makie.Axis(fig[has_world ? 2 : 1, 1]; xlabel="tick", ylabel="σ", title="branching ratio") :
        Makie.Axis(fig[has_world ? 2 : 1, 1]; xlabel="tick", ylabel="rate", title="firing rate")
    axw !== nothing && (_style_axis!(axw); axw.aspect = Makie.DataAspect())
    _style_axis!(axlow)
    has_world && Makie.rowsize!(fig.layout, 2, Makie.Relative(show_b ? 0.24 : 0.22))

    Makie.record(fig, path, frames; framerate=framerate) do f
        if axw !== nothing
            Makie.empty!(axw)
            bounds === nothing || _draw_bounds!(axw, sim)
            _draw_source!(axw, sim)
            frame_poses = NTuple{3,Float64}[]
            for tr in tracks
                isempty(tr) && continue
                ff = min(f, length(tr))
                lo = max(1, ff - trail)
                tx = [Float64(p[1]) for p in tr[lo:ff]]
                ty = [Float64(p[2]) for p in tr[lo:ff]]
                bx, by = _wrap_break(tx, ty, bounds)
                Makie.lines!(axw, bx, by; color=(_TEAL, 0.45), linewidth=2)
                push!(frame_poses, tr[ff])
            end
            _draw_agent_boids!(axw, frame_poses)
            ttl = "tick $f / $nt"
            if !isempty(pol)
                pf = Float64(pol[min(f, length(pol))]); mf = Float64(mill[min(f, length(mill))])
                ttl *= "    P=$(round(pf; digits=2))  M=$(round(mf; digits=2))"
            end
            axw.title = ttl
        end
        if show_b
            _draw_branching!(axlow, sigma, f, slims)
        else
            _draw_rate_frame!(axlow, rate, f, rmax)
        end
    end
    return path
end

function _require_glmakie()
    isdefined(Main, :GLMakie) && return getproperty(Main, :GLMakie)
    throw(ArgumentError("explore requires `using GLMakie` before calling explore."))
end

function _explorer_points(sim)
    tracks = _pose_tracks(sim)
    isempty(tracks) && return Makie.Point2f[]
    return [Makie.Point2f(pose[1], pose[2]) for pose in tracks[1]]
end

function BL.explore(task::Symbol; node::Symbol=:falandays, kwargs...)
    GLMakie = _require_glmakie()
    setup = BL._build_collective(
        task,
        node;
        record=[:spikes, :rate, :poses, :polarization, :milling],
        every=1,
        kwargs...,
    )
    fig = GLMakie.Figure(size=(900, 620), backgroundcolor=_PAPER)
    ax_path = GLMakie.Axis(fig[1, 1]; title="Trajectory")
    ax_rate = GLMakie.Axis(fig[2, 1]; title="Rate")
    _style_axis!(ax_path)
    _style_axis!(ax_rate)
    controls = fig[3, 1] = GLMakie.GridLayout()
    play = GLMakie.Button(controls[1, 1]; label="Play")
    step_button = GLMakie.Button(controls[1, 2]; label="Step")
    speed = GLMakie.Slider(controls[1, 3]; range=1:20, startvalue=5)

    path_obs = GLMakie.Observable(Makie.Point2f[])
    rate_obs = GLMakie.Observable(Float64[])
    GLMakie.lines!(ax_path, path_obs; color=_TEAL, linewidth=2)
    GLMakie.lines!(ax_rate, rate_obs; color=_TEAL, linewidth=2)
    initial_sim = BL.SimResult(
        setup.recorder,
        NamedTuple(),
        setup.task,
        setup.node,
        BL._simulation_config(
            setup.collective;
            ticks=0,
            seed=setup.seed,
            record=setup.record,
            every=setup.every,
            window=1,
            n_nodes=setup.n_nodes,
        ),
    )
    _draw_bounds!(ax_path, initial_sim)

    running = GLMakie.Observable(false)

    function refresh!()
        BL.step!(setup.collective)
        sim = BL.SimResult(
            setup.recorder,
            NamedTuple(),
            setup.task,
            setup.node,
            BL._simulation_config(
                setup.collective;
                ticks=setup.collective.t,
                seed=setup.seed,
                record=setup.record,
                every=setup.every,
                window=max(1, setup.collective.t),
                n_nodes=setup.n_nodes,
            ),
        )
        path_obs[] = _explorer_points(sim)
        rate_obs[] = _rate_trace(sim)
        return nothing
    end

    GLMakie.on(step_button.clicks) do _
        refresh!()
    end

    GLMakie.on(play.clicks) do _
        running[] = !running[]
        play.label[] = running[] ? "Pause" : "Play"
        if running[]
            @async while running[]
                refresh!()
                sleep(1.0 / Float64(speed.value[]))
            end
        end
    end

    return fig
end

for (name, fn) in (
    :raster => BL.rasterplot,
    :rate => BL.rateplot,
    :trajectory => BL.trajectoryplot,
    :swarm => BL.swarmplot,
    :network => BL.networkplot,
    :drift => BL.driftplot,
    :fitness => BL.fitnessplot,
    :visualize => BL.visualize,
    :explore => BL.explore,
    :replay => BL.replay,
)
    BL.register_view!(name, fn)
end

end
