module BrainlessLabMakieExt

import BrainlessLab
import Makie

const BL = BrainlessLab

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
    hasproperty(sim.config, :medium) || return nothing
    medium = sim.config.medium
    hasproperty(medium, :bounds) || return nothing
    return medium.bounds
end

function _draw_bounds!(ax, sim)
    bounds = _plot_bounds(sim)
    bounds === nothing && return ax

    x0, x1, y0, y1 = bounds
    Makie.lines!(ax, [x0, x1, x1, x0, x0], [y0, y0, y1, y1, y0]; color=:gray55, linewidth=1)
    Makie.xlims!(ax, x0, x1)
    Makie.ylims!(ax, y0, y1)
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
    Makie.scatter!(ax, xs, ys; markersize=2, color=:black)
    ax.xlabel = "tick"
    ax.ylabel = "node"
    ax.title = "Spike raster"
    return ax
end

function _draw_rate!(ax, sim)
    trace = _rate_trace(sim)
    Makie.lines!(ax, 1:length(trace), trace; color=:dodgerblue4, linewidth=2)
    ax.xlabel = "tick"
    ax.ylabel = "rate"
    ax.title = "Population firing rate"
    return ax
end

function _draw_trajectory!(ax, sim)
    _draw_bounds!(ax, sim)
    tracks = _pose_tracks(sim)
    for track in tracks
        isempty(track) && continue
        xs = [pose[1] for pose in track]
        ys = [pose[2] for pose in track]
        Makie.lines!(ax, xs, ys; linewidth=2)
        Makie.scatter!(ax, [xs[end]], [ys[end]]; markersize=8)
    end
    ax.xlabel = "x"
    ax.ylabel = "y"
    ax.title = "Trajectory"
    return ax
end

function _latest_pose_rows(sim)
    samples = _channel(sim, :poses)
    isempty(samples) && return NTuple{3,Float64}[]
    return _pose_rows(samples[end])
end

function _draw_swarm!(ax, sim)
    _draw_bounds!(ax, sim)
    poses = _latest_pose_rows(sim)
    xs = [pose[1] for pose in poses]
    ys = [pose[2] for pose in poses]
    Makie.scatter!(ax, xs, ys; markersize=10, color=:seagreen4)

    segments = Makie.Point2f[]
    for pose in poses
        len = 0.35
        push!(segments, Makie.Point2f(pose[1], pose[2]))
        push!(segments, Makie.Point2f(pose[1] + len * cos(pose[3]), pose[2] + len * sin(pose[3])))
    end
    isempty(segments) || Makie.linesegments!(ax, segments; color=:black, linewidth=1)

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
    isempty(segments) || Makie.linesegments!(ax, segments; color=(:gray45, 0.35), linewidth=0.5)

    Makie.scatter!(ax, xs, ys; color=_network_state(sim, n), colormap=:viridis, markersize=8)
    Makie.hidedecorations!(ax)
    Makie.hidespines!(ax)
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
    corr = _drift_matrix(sim; bin=bin)
    Makie.heatmap!(ax, corr; colormap=:viridis, colorrange=(0.0, 1.0))
    ax.xlabel = "time bin"
    ax.ylabel = "time bin"
    ax.title = "Spike-pattern autocorrelation"
    return ax
end

function _draw_fitness!(ax, curve)
    values = Float64.(curve)
    if ndims(values) == 1
        Makie.lines!(ax, 1:length(values), values; linewidth=2)
    else
        mat = Matrix{Float64}(values)
        for col in axes(mat, 2)
            Makie.lines!(ax, 1:size(mat, 1), mat[:, col]; linewidth=1.5)
        end
    end
    ax.xlabel = "generation"
    ax.ylabel = "fitness"
    ax.title = "Fitness"
    return ax
end

function _figure_axis(; size=(900, 320))
    fig = Makie.Figure(size=size)
    ax = Makie.Axis(fig[1, 1])
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
    throw(ArgumentError("unknown visualization panel :$(panel)"))
end

function BL.visualize(sim::BL.SimResult; panels=[:raster, :rate, :trajectory], size=nothing)
    panel_syms = Symbol.(collect(panels))
    fig_size = size === nothing ? (900, max(260, 260 * length(panel_syms))) : size
    fig = Makie.Figure(size=fig_size)
    for (row, panel) in enumerate(panel_syms)
        ax = Makie.Axis(fig[row, 1])
        _draw_panel!(ax, sim, panel)
    end
    return fig
end

BL.replay(sim::BL.SimResult; kwargs...) = BL.visualize(sim; kwargs...)

"""
    animate(sim; path="activity.gif", framerate=20, trail=40, maxframes=200)

Render a GIF/MP4 of the rollout: the agent(s) moving in the world (trail +
heading) with a synced firing-rate marker. Replays the recorder's per-tick
`:poses`/`:rate` channels. Returns the output path.
"""
function BL.animate(sim::BL.SimResult; path::AbstractString="activity.gif",
                    framerate::Integer=20, trail::Integer=40, maxframes::Integer=200)
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

    fig = Makie.Figure(size=(720, has_world ? 760 : 340))
    axw = has_world ? Makie.Axis(fig[1, 1]; xlabel="x", ylabel="y") : nothing
    axr = Makie.Axis(fig[has_world ? 2 : 1, 1]; xlabel="tick", ylabel="rate", title="firing rate")
    has_world && Makie.rowsize!(fig.layout, 2, Makie.Relative(0.22))

    Makie.record(fig, path, frames; framerate=framerate) do f
        if axw !== nothing
            Makie.empty!(axw)
            if bounds !== nothing
                x0, x1, y0, y1 = bounds
                Makie.lines!(axw, [x0, x1, x1, x0, x0], [y0, y0, y1, y1, y0]; color=:gray70, linewidth=1)
                Makie.xlims!(axw, x0, x1)
                Makie.ylims!(axw, y0, y1)
            end
            for tr in tracks
                isempty(tr) && continue
                ff = min(f, length(tr))
                lo = max(1, ff - trail)
                Makie.lines!(axw, [p[1] for p in tr[lo:ff]], [p[2] for p in tr[lo:ff]];
                             color=(:dodgerblue4, 0.55), linewidth=2)
                p = tr[ff]
                Makie.scatter!(axw, [p[1]], [p[2]]; markersize=13, color=:seagreen4)
                Makie.linesegments!(axw,
                    [Makie.Point2f(p[1], p[2]), Makie.Point2f(p[1] + 0.5cos(p[3]), p[2] + 0.5sin(p[3]))];
                    color=:black, linewidth=2)
            end
            ttl = "tick $f / $nt"
            if !isempty(pol)
                pf = Float64(pol[min(f, length(pol))]); mf = Float64(mill[min(f, length(mill))])
                ttl *= "    P=$(round(pf; digits=2))  M=$(round(mf; digits=2))"
            end
            axw.title = ttl
        end
        Makie.empty!(axr)
        Makie.lines!(axr, 1:nr, rate; color=:dodgerblue4, linewidth=1.5)
        Makie.vlines!(axr, [min(f, nr)]; color=:red, linewidth=1.5)
        Makie.xlims!(axr, 1, max(nr, 2))
        Makie.ylims!(axr, 0, rmax)
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
    fig = GLMakie.Figure(size=(900, 620))
    ax_path = GLMakie.Axis(fig[1, 1]; title="Trajectory")
    ax_rate = GLMakie.Axis(fig[2, 1]; title="Rate")
    controls = fig[3, 1] = GLMakie.GridLayout()
    play = GLMakie.Button(controls[1, 1]; label="Play")
    step_button = GLMakie.Button(controls[1, 2]; label="Step")
    speed = GLMakie.Slider(controls[1, 3]; range=1:20, startvalue=5)

    path_obs = GLMakie.Observable(Makie.Point2f[])
    rate_obs = GLMakie.Observable(Float64[])
    GLMakie.lines!(ax_path, path_obs; linewidth=2)
    GLMakie.lines!(ax_rate, rate_obs; linewidth=2)
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
