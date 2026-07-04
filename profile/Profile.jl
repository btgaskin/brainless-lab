module NodeProfile

using BrainlessLab
using Statistics: mean, std
using Printf: @sprintf
import Dates
import Random
import CairoMakie
import TOML

export node_profile, DEFAULT_TASKS, CANONICAL_N

# ---------------------------------------------------------------------------
# Task selection & canonical sizes
# ---------------------------------------------------------------------------

# Single-agent (agent-environment) tasks only -- :torus is multi-agent and is
# not a fit for a per-node branching-ratio profile.
const DEFAULT_TASKS = (:wall, :tracking, :pong, :cartpole, :cartpole_hard, :cartpole_swingup, :cartpole_long)

const _PROFILE_GIF_1X1 = UInt8[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
    0x00, 0xfb, 0xfa, 0xf7, 0x2f, 0x6f, 0x5e, 0x21, 0xf9, 0x04, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
]

_repo_root() = normpath(joinpath(@__DIR__, ".."))

function _pad2(x)
    return lpad(string(Int(x)), 2, '0')
end

function _timestamp_utc()
    t = Dates.now(Dates.UTC)
    return string(
        Dates.year(t),
        _pad2(Dates.month(t)),
        _pad2(Dates.day(t)),
        "T",
        _pad2(Dates.hour(t)),
        _pad2(Dates.minute(t)),
        _pad2(Dates.second(t)),
        "Z",
    )
end

function _sanitize_path_part(value)
    return replace(string(value), r"[^A-Za-z0-9_.+-]" => "_")
end

function _git_sha_full()
    try
        return readchomp(Cmd(`git rev-parse HEAD`; dir=_repo_root()))
    catch
        return "unknown"
    end
end

function _short_git(sha::AbstractString=_git_sha_full())
    sha == "unknown" && return "nogit"
    return sha[1:min(8, lastindex(sha))]
end

# The 2024 Falandays case-study author sizes for the tasks they used; the
# BrainlessLab-only cartpole family has no paper-canonical size.
const CANONICAL_N = Dict{Symbol,Int}(
    :wall              => 200,
    :tracking          => 200,
    :pong              => 500,
    :pong_hitrate      => 500,
    :cartpole          => 200,
    :cartpole_hard     => 200,
    :cartpole_swingup  => 200,
    :cartpole_long     => 200,
)

const CANONICAL_NOTE = Dict{Symbol,String}(
    :wall              => "paper-canonical (Falandays 2024 case study)",
    :tracking          => "paper-canonical (Falandays 2024 case study)",
    :pong              => "paper-canonical (Falandays 2024 case study)",
    :pong_hitrate      => "paper-canonical (shares :pong's env/size)",
    :cartpole          => "not paper-canonical -- BrainlessLab task; N chosen for this profile",
    :cartpole_hard     => "not paper-canonical -- BrainlessLab task; N chosen for this profile",
    :cartpole_swingup  => "not paper-canonical -- BrainlessLab task; N chosen for this profile",
    :cartpole_long     => "not paper-canonical -- BrainlessLab task; N chosen for this profile",
)

_profile_family(node::Symbol) = startswith(String(node), "compartmental") ? :compartmental : :falandays

function _profile_run_id(node_sym::Symbol, tasks, n_seeds::Integer)
    parts = vcat([String(node_sym), string(Int(n_seeds))], String.(collect(tasks)))
    return _sanitize_path_part(join(parts, "_")) * "_" * string(Random.rand(UInt32), base=16, pad=8)
end

function _make_run_dir(node_sym::Symbol, tasks, n_seeds::Integer; out_root::AbstractString, out_dir=nothing)
    if out_dir !== nothing
        dir = String(out_dir)
        mkpath(dir)
        return (dir=dir, timestamp_utc=_timestamp_utc(), git_sha=_git_sha_full(), short_git=_short_git(), run_id=basename(dir))
    end

    stamp = _timestamp_utc()
    sha = _git_sha_full()
    run_id = _profile_run_id(node_sym, tasks, n_seeds)
    base = joinpath(out_root, _sanitize_path_part(node_sym), "$(stamp)_$(_short_git(sha))_$(run_id)")
    dir = base
    suffix = 2
    while isdir(dir)
        dir = "$(base)_$(suffix)"
        suffix += 1
    end
    mkpath(dir)
    return (dir=dir, timestamp_utc=stamp, git_sha=sha, short_git=_short_git(sha), run_id=run_id)
end

function _tool_package_versions(project_dir::AbstractString)
    out = Dict{String,String}()
    project_path = joinpath(project_dir, "Project.toml")
    isfile(project_path) || return out

    try
        project = TOML.parsefile(project_path)
        direct = Set(keys(get(project, "deps", Dict{String,Any}())))
        manifest_path = joinpath(project_dir, "Manifest.toml")
        if !isfile(manifest_path)
            for name in direct
                out[name] = "unknown"
            end
            return out
        end

        manifest = TOML.parsefile(manifest_path)
        deps = get(manifest, "deps", Dict{String,Any}())
        for name in direct
            entries = get(deps, name, nothing)
            if entries === nothing
                out[name] = "unknown"
            else
                entry = entries isa AbstractVector ? first(entries) : entries
                out[name] = string(get(entry, "version", "stdlib"))
            end
        end
    catch err
        out["error"] = sprint(showerror, err)
    end
    return out
end

function _profile_run_config(node_sym::Symbol, tasks, n_seeds::Integer)
    return BrainlessLab.resolve(BrainlessLab.RunConfig(
        run=BrainlessLab.RunSection(
            name="profile_$(node_sym)",
            runner=:fixed,
            seed_base=1,
            suite_seed_base=100_001,
            profile=:none,
        ),
        model=BrainlessLab.ModelSection(
            family=_profile_family(node_sym),
            node=node_sym,
        ),
        task=BrainlessLab.TaskSection(
            train=Tuple(Symbol.(collect(tasks))),
            suite=Tuple(Symbol.(collect(tasks))),
            aggregator=:mean,
        ),
        evolve=BrainlessLab.EvolveSection(
            generations=1,
            popsize=2,
            k_trials=max(1, Int(n_seeds)),
            suite_every=0,
            k_suite=0,
            cma_seed=1,
            threaded=false,
        ),
    ))
end

function _profile_seed_manifest(n_seeds::Integer)
    return Dict{String,Any}(
        "seed_base" => 1,
        "resolved" => collect(1:Int(n_seeds)),
        "scheme" => "profile seed = 1:n_seeds independently for each task",
        "seeds_per_task" => Int(n_seeds),
    )
end

# Curated short prose mirroring docs/tasks.md, for the per-task cards.
const TASK_PROSE = Dict{Symbol,NamedTuple{(:encoding, :decode, :scoring),NTuple{3,String}}}(
    :wall => (
        encoding = "two ray-cast distance sensors at &plusmn;45&deg; to the nearest wall; c = 1 &minus; d/d_max, d_max = &radic;(2&middot;15&sup2;), clamped to (&epsilon;, 1]",
        decode   = "differential wheel-like speeds: v = (e<sub>L</sub>+e<sub>R</sub>)/2, heading change &Delta;&theta; = e<sub>R</sub>&minus;e<sub>L</sub>; wall hit &rarr; random &plusmn;45&deg; turn",
        scoring  = "distance travelled minus collision penalty over the scoring window",
    ),
    :tracking => (
        encoding = "two eyes offset &plusmn;30&deg;, each with 31 Gaussian-tuned sensors over &minus;60:4:60&deg;; sensor value exp(&minus;&delta;&sup2;/10), &delta; = angle to the rotating stimulus",
        decode   = "eye-rotation command &Delta;&theta; = 10&middot;(e<sub>1</sub>&minus;e<sub>2</sub>)&deg; per tick",
        scoring  = "mean cos alignment of gaze to the stimulus",
    ),
    :pong => (
        encoding = "bearing from paddle to ball over &minus;90:4:90&deg;; the matching angular bin is active when the ball is in front of the paddle",
        decode   = "paddle vote/differential command: paddle_y += 100&middot;(e<sub>1</sub>&minus;e<sub>2</sub>), clamped to the paddle range",
        scoring  = "mean_align (paddle tracks ball); floor &asymp; 0.33",
    ),
    :cartpole => (
        encoding = "Spike-FF-2: the 4 state dims (x, x&#775;, &theta;, &theta;&#775;) each normalized and split into 2 polarities (negative/positive channels) &rarr; 8",
        decode   = "binary force vote: e<sub>1</sub> &ge; e<sub>2</sub> applies negative force, otherwise positive force",
        scoring  = "fraction of ticks balanced",
    ),
    :cartpole_hard => (
        encoding = "same encoding as :cartpole",
        decode   = "same binary force vote, with tighter bounds / weaker actuation",
        scoring  = "fraction balanced",
    ),
    :cartpole_swingup => (
        encoding = "same encoding; pole starts hanging down",
        decode   = "same binary force vote; termination on angle disabled",
        scoring  = "mean uprightness: mean((cos&theta;+1)/2)",
    ),
    :cartpole_long => (
        encoding = "same encoding; 2&times; pole length",
        decode   = "same binary force vote",
        scoring  = "fraction balanced",
    ),
)

# ---------------------------------------------------------------------------
# Small stats helpers -- NaN-aware, since branching ratios can be NaN when
# population activity is zero at a tick.
# ---------------------------------------------------------------------------

_finite(xs) = filter(isfinite, xs)

function _nanmean(xs)
    f = _finite(xs)
    isempty(f) ? NaN : mean(f)
end

function _nanstd(xs)
    f = _finite(xs)
    length(f) < 2 ? NaN : std(f)
end

function _finite_or_nan(value)
    value === nothing && return NaN
    value isa Real || return NaN
    x = Float64(value)
    return isfinite(x) ? x : NaN
end

function _csv_cell(value)
    value === nothing && return ""
    value isa Missing && return ""
    if value isa AbstractFloat && !isfinite(value)
        return ""
    end
    text = value isa Symbol ? String(value) : string(value)
    if occursin("\"", text) || occursin(",", text) || occursin("\n", text) || occursin("\r", text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function _write_csv(path::AbstractString, header, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(_csv_cell.(header), ","))
        for row in rows
            println(io, join((_csv_cell(get(row, key, "")) for key in header), ","))
        end
    end
    return path
end

"""
    _over_time_ylims(mean_series)

Fit the branching-over-time y-axis to the seed-mean σ series' [min, max].
The switch-on transient is short (a handful of ticks) so percentile clipping
would hide it; instead we drop only the near-zero-denominator explosions
(where A(t)→0 makes σ = A(t+1)/A(t) blow up) by keeping mean values within a
log-symmetric plausibility band [median/3, median·3] of the series' own
median. Returns `(lo, hi)` with ~5% padding and σ=1 always inside the view;
falls back to a tight band around 1 if too little survives.
"""
function _over_time_ylims(mean_series::AbstractVector{<:Real})
    med = _percentile(mean_series, 50.0)
    if !isfinite(med) || med <= 0
        return (0.8, 1.2)
    end
    capL = med / 3
    capH = med * 3
    vals = [Float64(x) for x in mean_series if isfinite(x) && x >= capL && x <= capH]
    if length(vals) < 3
        return (0.8, 1.2)
    end
    lo = min(minimum(vals), 1.0)
    hi = max(maximum(vals), 1.0)
    pad = 0.05 * max(hi - lo, eps())
    return (lo - pad, hi + pad)
end

"""
    _percentile(xs, p)

Linear-interpolated `p`-th percentile (0..100) over finite values of `xs`.
"""
function _percentile(xs::AbstractVector{<:Real}, p::Real)
    v = sort(_finite(xs))
    isempty(v) && return NaN
    length(v) == 1 && return Float64(v[1])
    r = clamp(Float64(p) / 100, 0.0, 1.0) * (length(v) - 1) + 1
    lo = floor(Int, r); hi = ceil(Int, r)
    lo == hi && return Float64(v[lo])
    frac = r - lo
    return Float64(v[lo]) * (1 - frac) + Float64(v[hi]) * frac
end

"""
    _seedwise_series(mats::Vector{Vector{Float64}})

Given one per-tick branching-ratio series per seed (all seeds the same
length), return the NaN-aware per-tick mean, and lower/upper +/-1 std band.
"""
function _seedwise_series(series::Vector{Vector{Float64}})
    n = length(series[1])
    m = fill(NaN, n)
    lo = fill(NaN, n)
    hi = fill(NaN, n)
    @inbounds for t in 1:n
        vals = [s[t] for s in series]
        mu = _nanmean(vals)
        sd = _nanstd(vals)
        m[t] = mu
        if isnan(sd)
            lo[t] = mu
            hi[t] = mu
        else
            lo[t] = mu - sd
            hi[t] = mu + sd
        end
    end
    return m, lo, hi
end

# ---------------------------------------------------------------------------
# Figure rendering -> in-memory PNG -> base64 data URI (fully self-contained)
# ---------------------------------------------------------------------------

const _PAPER = CairoMakie.RGBf(BrainlessLab.BL_PAPER...)
const _INK = CairoMakie.RGBf(BrainlessLab.BL_INK...)
const _INKSOFT = CairoMakie.RGBf(BrainlessLab.BL_INKSOFT...)
const _GRID = CairoMakie.RGBf(BrainlessLab.BL_GRID...)
const _TEAL = CairoMakie.RGBf(BrainlessLab.BL_TEAL...)
const _AMBER = CairoMakie.RGBf(BrainlessLab.BL_AMBER...)

function _style_axis!(ax)
    ax.backgroundcolor = _PAPER
    ax.xgridcolor = (_GRID, 0.9);  ax.ygridcolor = (_GRID, 0.9)
    ax.xgridwidth = 0.8;           ax.ygridwidth = 0.8
    ax.topspinevisible = false;    ax.rightspinevisible = false
    ax.leftspinevisible = true;    ax.bottomspinevisible = true
    ax.leftspinecolor = _GRID;     ax.bottomspinecolor = _GRID
    ax.xtickcolor = _GRID;         ax.ytickcolor = _GRID
    ax.xticklabelcolor = _INKSOFT; ax.yticklabelcolor = _INKSOFT
    ax.xlabelcolor = _INKSOFT;     ax.ylabelcolor = _INKSOFT
    ax.xticklabelsize = 11;        ax.yticklabelsize = 11
    ax.xlabelsize = 12;            ax.ylabelsize = 12
    ax.titlecolor = _INK;          ax.titlesize = 14
    ax.titlealign = :left;         ax.titlegap = 8
    return ax
end

_profile_figure(sz) = CairoMakie.Figure(size=sz, backgroundcolor=_PAPER)

function _branching_figure(seed_mean, seed_lo, seed_hi; title::String="")
    n = length(seed_mean)
    xs = collect(1:n)
    fig = _profile_figure((820, 300))
    ax = CairoMakie.Axis(
        fig[1, 1];
        xlabel="tick", ylabel="branching ratio  σ(t)",
        title=title,
    )
    _style_axis!(ax)
    finite = isfinite.(seed_mean)
    if any(finite)
        fx = xs[finite]
        CairoMakie.band!(ax, fx, seed_lo[finite], seed_hi[finite]; color=(_TEAL, 0.18))
        CairoMakie.lines!(ax, fx, seed_mean[finite]; color=_TEAL, linewidth=2.0, label="seed mean")
        # Fit y-axis to the seed-MEAN σ series' [min,max] (with σ=1 kept in view),
        # dropping only near-zero-denominator switch-on explosions.
        ylo, yhi = _over_time_ylims(seed_mean)
        CairoMakie.ylims!(ax, ylo, yhi)
    end
    CairoMakie.hlines!(ax, [1.0]; color=_AMBER, linestyle=:dash, linewidth=1.5, label="σ = 1 (critical)")
    CairoMakie.xlims!(ax, 1, max(n, 2))
    CairoMakie.axislegend(ax; position=:rt, labelsize=10, framevisible=false)
    return fig
end

"""
    _situated_figure(sigma, factor, factor_label; title)

Situated per-run chart for a single representative rollout (seed 1): two
vertically-stacked, x-linked panels sharing the tick/time axis. Top: σ(t) with
a dashed σ=1 reference; bottom: the performance factor(t) over the same ticks.
Lets you read vertically whether σ moves as the factor (e.g. distance to the
nearest wall) rises and falls through the run. Both y-axes auto-fit the data.
"""
function _situated_figure(sigma::Vector{Float64}, factor::Vector{Float64}, factor_label::String; title::String="")
    n = length(sigma)                       # σ has length T-1
    ts = collect(1:n)
    fac = factor[1:min(length(factor), n)]  # align to σ's ticks (1:T-1)
    fts = collect(1:length(fac))

    fig = _profile_figure((820, 460))

    ax_top = CairoMakie.Axis(
        fig[1, 1];
        ylabel="branching ratio  σ", title=title,
        xticklabelsvisible=false, xticksvisible=false,
    )
    ax_bot = CairoMakie.Axis(
        fig[2, 1];
        xlabel="tick", ylabel=factor_label,
    )
    _style_axis!(ax_top)
    _style_axis!(ax_bot)

    # Top: σ(t), auto-fit y over finite values, with σ=1 reference in view.
    finite = isfinite.(sigma)
    if any(finite)
        CairoMakie.lines!(ax_top, ts[finite], sigma[finite]; color=_TEAL, linewidth=1.4, label="σ(t)")
        fv = sigma[finite]
        lo = min(minimum(fv), 1.0); hi = max(maximum(fv), 1.0)
        pad = 0.05 * max(hi - lo, eps())
        CairoMakie.ylims!(ax_top, lo - pad, hi + pad)
    end
    CairoMakie.hlines!(ax_top, [1.0]; color=_AMBER, linestyle=:dash, linewidth=1.5, label="σ = 1 (critical)")
    CairoMakie.axislegend(ax_top; position=:rt, labelsize=10, framevisible=false)

    # Bottom: factor(t) over the same ticks.
    CairoMakie.lines!(ax_bot, fts, fac; color=_INK, linewidth=1.4)

    CairoMakie.linkxaxes!(ax_top, ax_bot)
    CairoMakie.xlims!(ax_bot, 1, max(n, 2))
    CairoMakie.rowgap!(fig.layout, 6)
    return fig
end

"""
    _spectral_figure(xs, mean, lo, hi; title)

Seed-mean spectral radius ρ(W) trajectory over the run, with a ±1 std band.
Y-axis auto-fits the data (no σ=1 reference — this is a weight-scale plot, not
a branching plot).
"""
function _spectral_figure(xs::Vector{<:Integer}, smean, slo, shi; title::String="")
    fig = _profile_figure((820, 300))
    ax = CairoMakie.Axis(
        fig[1, 1];
        xlabel="tick", ylabel="spectral radius  ρ(W)",
        title=title,
    )
    _style_axis!(ax)
    fx = Float64.(xs)
    finite = isfinite.(smean)
    if any(finite)
        CairoMakie.band!(ax, fx[finite], slo[finite], shi[finite]; color=(_AMBER, 0.18))
        CairoMakie.lines!(ax, fx[finite], smean[finite]; color=_AMBER, linewidth=2.0, label="seed mean")
    end
    isempty(fx) || CairoMakie.xlims!(ax, minimum(fx), max(maximum(fx), 1.0))
    CairoMakie.axislegend(ax; position=:rt, labelsize=10, framevisible=false)
    return fig
end

"""
    _target_error_figure(target_error; title)

Representative rollout target-error panel. Left: across-node mean with the
node-wise IQR band through time. Right: final-tick across-node distribution.
"""
function _target_error_figure(target_error; title::String="")
    err = target_error.per_node_error
    n_nodes, n_ticks = size(err)
    xs = collect(1:n_ticks)
    mean_series = target_error.mean_over_nodes
    q25 = Vector{Float64}(undef, n_ticks)
    q75 = Vector{Float64}(undef, n_ticks)
    @inbounds for t in 1:n_ticks
        col = @view err[:, t]
        q25[t] = _percentile(col, 25.0)
        q75[t] = _percentile(col, 75.0)
    end

    fig = _profile_figure((820, 340))
    ax_time = CairoMakie.Axis(
        fig[1, 1];
        xlabel="tick", ylabel="|act - T|",
        title=title,
    )
    _style_axis!(ax_time)
    CairoMakie.band!(ax_time, xs, q25, q75; color=(_TEAL, 0.18), label="node IQR")
    CairoMakie.lines!(ax_time, xs, mean_series; color=_TEAL, linewidth=2.0, label="node mean")
    CairoMakie.xlims!(ax_time, 1, max(n_ticks, 2))
    CairoMakie.axislegend(ax_time; position=:rt, labelsize=10, framevisible=false)

    ax_hist = CairoMakie.Axis(
        fig[1, 2];
        xlabel="final |act - T|", ylabel="nodes",
    )
    _style_axis!(ax_hist)
    bins = max(8, min(40, ceil(Int, sqrt(max(n_nodes, 1)))))
    CairoMakie.hist!(ax_hist, target_error.final_distribution; bins=bins, color=(_AMBER, 0.45),
                     strokecolor=_AMBER, strokewidth=0.5)
    CairoMakie.colgap!(fig.layout, 18)
    return fig
end

# ---------------------------------------------------------------------------
# Core: run n_seeds rollouts per task, seed-average branching ratio & score.
# ---------------------------------------------------------------------------

"""
    task_profile(node_sym, task; n_seeds=8, canonical_N=CANONICAL_N)

Run `n_seeds` rollouts of `task` with `node_sym` at the task's canonical N,
recording `(:rate, :scene, :poses)`, over the task's default ticks. Returns a
NamedTuple with the seed-averaged branching-ratio series, mean/std sigma,
mean/std score, the run parameters used (N, R, E, ticks), and `factor_data`:
per task-scoped analysis registered for the task, the seed-1 σ(t) and
factor(t) series for the situated time chart (empty when the task registers none).
"""
function task_profile(node_sym::Symbol, task::Symbol; n_seeds::Integer=8, canonical_N=CANONICAL_N)
    task_spec = resolve_task(task)
    N = canonical_N[task]
    ticks = task_spec.default_ticks

    # Task-scoped per-tick "performance factors" registered for this task.
    factors = task_analyses(task)

    per_tick_series = Vector{Vector{Float64}}(undef, n_seeds)
    sigmas = Vector{Float64}(undef, n_seeds)
    sigma_mr = Vector{Float64}(undef, n_seeds)
    scores = Vector{Float64}(undef, n_seeds)
    liveness_values = Vector{Float64}(undef, n_seeds)
    rate_means = Vector{Float64}(undef, n_seeds)
    rate_vars = Vector{Float64}(undef, n_seeds)
    avalanche_tau = Vector{Float64}(undef, n_seeds)
    avalanche_alpha = Vector{Float64}(undef, n_seeds)
    avalanche_gamma_fit = Vector{Float64}(undef, n_seeds)
    avalanche_gamma_pred = Vector{Float64}(undef, n_seeds)
    avalanche_counts = Vector{Float64}(undef, n_seeds)
    # Situated chart uses a single representative run (seed 1): its per-tick σ
    # and the full factor(t) series, kept time-ordered (NOT pooled). We also keep
    # the seed-1 SimResult itself, to render the behaviour + σ(t) GIF.
    seed1_factor = Dict{Symbol,Vector{Float64}}()
    seed1_sim = nothing
    seed1_target_error = nothing

    for s in 1:n_seeds
        record_channels = s == 1 ? (:spikes, :rate, :scene, :poses, :acts, :targets) : (:spikes, :rate, :scene, :poses)
        sim = simulate(task; node=node_sym, n_nodes=N, seed=s, record=record_channels)
        br = branching_ratio(sim)
        per_tick_series[s] = br.per_tick
        sigmas[s] = br.sigma
        sigma_mr[s] = try
            kmax = max(2, min(20, Int(floor(ticks / 3))))
            _finite_or_nan(branching_ratio_mr(sim; kmax=kmax, transient=0).m_mr)
        catch
            NaN
        end
        scores[s] = Float64(sim.metrics.score)
        liveness_values[s] = hasproperty(sim.metrics, :alive) && Bool(sim.metrics.alive) ? 1.0 : 0.0
        rate_means[s] = hasproperty(sim.metrics, :rate_mean) ? _finite_or_nan(sim.metrics.rate_mean) : NaN
        rate_vars[s] = hasproperty(sim.metrics, :rate_var) ? _finite_or_nan(sim.metrics.rate_var) : NaN
        aval = try
            avalanches(sim)
        catch
            nothing
        end
        avalanche_tau[s] = aval === nothing ? NaN : _finite_or_nan(aval.tau)
        avalanche_alpha[s] = aval === nothing ? NaN : _finite_or_nan(aval.alpha)
        avalanche_gamma_fit[s] = aval === nothing ? NaN : _finite_or_nan(aval.gamma_fit)
        avalanche_gamma_pred[s] = aval === nothing ? NaN : _finite_or_nan(aval.gamma_pred)
        avalanche_counts[s] = aval === nothing ? NaN : _finite_or_nan(aval.n_avalanches)

        if s == 1
            seed1_sim = sim
            seed1_target_error = try
                node_target_error(sim)
            catch err
                err isa ArgumentError ? nothing : rethrow()
            end
            for f in factors
                seed1_factor[f] = Float64.(resolve_analysis(f)(sim))   # length T
            end
        end
    end

    seed_mean, seed_lo, seed_hi = _seedwise_series(per_tick_series)

    # Separate COARSE rollout per seed for spectral radius ρ(W): eigenvalues are
    # expensive, so this is downsample-only (every=K, ~60 samples), NOT part of
    # the every-tick branching run. Empty for nodes without a learned recurrent
    # matrix (e.g. compartmental) -> no spectral panel is rendered.
    K = max(1, cld(ticks, 60))
    spectral_series = Vector{Vector{Float64}}()
    for s in 1:n_seeds
        rho = try
            ssim = simulate(task; node=node_sym, n_nodes=N, seed=s, record=(:spectral_radius,), every=K)
            spectral_radius(ssim).series
        catch
            Float64[]
        end
        isempty(rho) && continue
        push!(spectral_series, rho)
    end
    if isempty(spectral_series)
        spectral_x = Int[]
        spectral_mean = Float64[]
        spectral_lo = Float64[]
        spectral_hi = Float64[]
    else
        # Same ticks/K per task -> same length; guard against any ragged tail.
        L = minimum(length.(spectral_series))
        trimmed = [r[1:L] for r in spectral_series]
        spectral_mean, spectral_lo, spectral_hi = _seedwise_series(trimmed)
        spectral_x = [(i - 1) * K for i in 1:L]
    end

    # Situated per-run data: seed-1 σ(t) (length T-1) paired with seed-1
    # factor(t) over the same ticks. Kept time-ordered for the stacked chart.
    factor_data = [
        (
            sym=f,
            label=analysis_meta(f).label,
            sigma=per_tick_series[1],       # σ(t), length T-1
            factor=seed1_factor[f],         # factor(t), length T
        )
        for f in factors
    ]

    return (
        task=task,
        n_nodes=N,
        n_receptors=task_spec.n_receptors,
        n_effectors=task_spec.n_effectors,
        ticks=ticks,
        n_seeds=Int(n_seeds),
        seed_mean=seed_mean,
        seed_lo=seed_lo,
        seed_hi=seed_hi,
        sigma_mean=_nanmean(sigmas),
        sigma_std=_nanstd(sigmas),
        sigmas=sigmas,
        sigma_mr_mean=_nanmean(sigma_mr),
        sigma_mr_std=_nanstd(sigma_mr),
        sigma_mr=sigma_mr,
        score_mean=_nanmean(scores),
        score_std=_nanstd(scores),
        score_norm_mean=_nanmean(normalized_score.(Ref(task_spec), scores)),
        scores=scores,
        liveness=_nanmean(liveness_values),
        alive_rate=_nanmean(liveness_values),
        rate_mean=_nanmean(rate_means),
        rate_var=_nanmean(rate_vars),
        avalanche_tau=_nanmean(avalanche_tau),
        avalanche_tau_std=_nanstd(avalanche_tau),
        avalanche_alpha=_nanmean(avalanche_alpha),
        avalanche_alpha_std=_nanstd(avalanche_alpha),
        avalanche_gamma_fit=_nanmean(avalanche_gamma_fit),
        avalanche_gamma_pred=_nanmean(avalanche_gamma_pred),
        avalanche_n=_nanmean(avalanche_counts),
        factor_data=factor_data,
        spectral_x=spectral_x,
        spectral_mean=spectral_mean,
        spectral_lo=spectral_lo,
        spectral_hi=spectral_hi,
        seed1_sim=seed1_sim,
        target_error=seed1_target_error,
    )
end

_fmt(x; digits=3) = isnan(x) ? "n/a" : @sprintf("%.*f", digits, x)

function _metric_row(res)
    spectral_start = isempty(res.spectral_mean) ? NaN : first(res.spectral_mean)
    spectral_end = isempty(res.spectral_mean) ? NaN : last(res.spectral_mean)
    return Dict{String,Any}(
        "task" => String(res.task),
        "n_nodes" => res.n_nodes,
        "ticks" => res.ticks,
        "n_seeds" => res.n_seeds,
        "score_mean" => res.score_mean,
        "score_std" => res.score_std,
        "score_norm_mean" => res.score_norm_mean,
        "sigma" => res.sigma_mean,
        "sigma_std" => res.sigma_std,
        "sigma_mr" => res.sigma_mr_mean,
        "sigma_mr_std" => res.sigma_mr_std,
        "spectral_radius" => spectral_end,
        "spectral_radius_start" => spectral_start,
        "spectral_radius_end" => spectral_end,
        "liveness" => res.liveness,
        "alive_rate" => res.alive_rate,
        "rate_mean" => res.rate_mean,
        "rate_var" => res.rate_var,
        "avalanche_tau" => res.avalanche_tau,
        "avalanche_tau_std" => res.avalanche_tau_std,
        "avalanche_alpha" => res.avalanche_alpha,
        "avalanche_alpha_std" => res.avalanche_alpha_std,
        "avalanche_gamma_fit" => res.avalanche_gamma_fit,
        "avalanche_gamma_pred" => res.avalanche_gamma_pred,
        "avalanche_n" => res.avalanche_n,
    )
end

function _write_metrics_csv(path::AbstractString, results)
    header = [
        "task", "n_nodes", "ticks", "n_seeds",
        "score_mean", "score_std", "score_norm_mean",
        "sigma", "sigma_std", "sigma_mr", "sigma_mr_std",
        "spectral_radius", "spectral_radius_start", "spectral_radius_end",
        "liveness", "alive_rate", "rate_mean", "rate_var",
        "avalanche_tau", "avalanche_tau_std", "avalanche_alpha", "avalanche_alpha_std",
        "avalanche_gamma_fit", "avalanche_gamma_pred", "avalanche_n",
    ]
    return _write_csv(path, header, [_metric_row(res) for res in results])
end

function _save_profile_figure(path::AbstractString, fig)
    mkpath(dirname(path))
    Base.invokelatest(CairoMakie.save, path, fig)
    return path
end

function _write_profile_figures(figures_dir::AbstractString, results)
    mkpath(figures_dir)
    paths = String[]
    for res in results
        task = _sanitize_path_part(res.task)
        push!(paths, _save_profile_figure(
            joinpath(figures_dir, "$(task)_branching.png"),
            _branching_figure(res.seed_mean, res.seed_lo, res.seed_hi; title=string(res.task)),
        ))
        if !isempty(res.spectral_mean)
            push!(paths, _save_profile_figure(
                joinpath(figures_dir, "$(task)_spectral_radius.png"),
                _spectral_figure(res.spectral_x, res.spectral_mean, res.spectral_lo, res.spectral_hi; title="$(res.task) - spectral radius rho(W)"),
            ))
        end
        if res.target_error !== nothing
            push!(paths, _save_profile_figure(
                joinpath(figures_dir, "$(task)_target_error.png"),
                _target_error_figure(res.target_error; title="$(res.task) - per-node distance to target"),
            ))
        end
        for fd in res.factor_data
            push!(paths, _save_profile_figure(
                joinpath(figures_dir, "$(task)_situated_$(String(fd.sym)).png"),
                _situated_figure(fd.sigma, fd.factor, fd.label; title="Situated: branching sigma and $(fd.label)"),
            ))
        end
    end
    return paths
end

function _write_placeholder_gif(path::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, _PROFILE_GIF_1X1)
    end
    return path
end

function _write_profile_gifs(gifs_dir::AbstractString, node_sym::Symbol, results; gif_ticks::Integer=400, gif_fps::Integer=20)
    mkpath(gifs_dir)
    out = Dict{Symbol,String}()
    for res in results
        vticks = min(res.ticks, Int(gif_ticks))
        path = joinpath(gifs_dir, "$(res.task).gif")
        try
            vsim = simulate(res.task; node=node_sym, n_nodes=res.n_nodes, seed=1,
                            record=(:rate, :scene, :poses), ticks=vticks)
            Base.invokelatest(BrainlessLab.animate, vsim; path=path, branching=true,
                              framerate=Int(gif_fps), maxframes=vticks)
        catch err
            @warn "profile GIF render failed; writing placeholder" task=res.task exception=(err, catch_backtrace())
            _write_placeholder_gif(path)
        end
        out[res.task] = relpath(path, dirname(gifs_dir))
    end
    return out
end

function _write_profile_manifest(path::AbstractString, node_sym::Symbol, tasks, n_seeds::Integer, canonical_N, run_info)
    cfg = _profile_run_config(node_sym, tasks, n_seeds)
    manifest = BrainlessLab.capture_manifest(cfg; seeds=_profile_seed_manifest(n_seeds), tool=:profile)
    manifest["timestamp_utc"] = run_info.timestamp_utc
    manifest["run_id"] = run_info.run_id
    manifest["short_git"] = run_info.short_git
    manifest["profile"] = Dict{String,Any}(
        "job" => "single-node characterization",
        "node" => String(node_sym),
        "tasks" => String.(collect(tasks)),
        "n_seeds" => Int(n_seeds),
        "canonical_N" => Dict{String,Any}(String(k) => v for (k, v) in canonical_N),
        "output_shape" => "manifest.toml + config.resolved.toml + metrics.csv + figures/*.png + gifs/*.gif + README.md; optional report.html behind report=true",
    )
    manifest["tool_packages"] = _tool_package_versions(@__DIR__)
    open(path, "w") do io
        TOML.print(io, manifest)
    end
    return path
end

function _write_profile_config(path::AbstractString, node_sym::Symbol, tasks, n_seeds::Integer, canonical_N; gifs::Bool, report::Bool)
    data = Dict{String,Any}(
        "profile" => Dict{String,Any}(
            "node" => String(node_sym),
            "tasks" => String.(collect(tasks)),
            "n_seeds" => Int(n_seeds),
            "gifs" => gifs,
            "report" => report,
            "canonical_N" => Dict{String,Any}(String(k) => v for (k, v) in canonical_N),
        ),
    )
    open(path, "w") do io
        TOML.print(io, data)
    end
    return path
end

function _signature_values(results)
    scores = [res.score_norm_mean for res in results]
    sigma = [res.sigma_mr_mean for res in results]
    live = [res.liveness for res in results]
    return (
        score=_nanmean(scores),
        sigma_mr=_nanmean(sigma),
        liveness=_nanmean(live),
    )
end

function _write_profile_readme(path::AbstractString, node_sym::Symbol, results; report_path=nothing)
    sig = _signature_values(results)
    open(path, "w") do io
        println(io, "# Profile `:$(node_sym)`")
        println(io)
        println(io, "> Signature: mean normalized score $(_fmt(sig.score)), sigma_mr $(_fmt(sig.sigma_mr)), liveness $(_fmt(sig.liveness)) across $(length(results)) task(s).")
        println(io)
        println(io, "Job: single-node characterization. This is the full analytic suite plus representative behaviour, not a cross-node ranking.")
        println(io)
        println(io, "Primary outputs:")
        println(io, "- `metrics.csv` -- per-task score, branching, spectral, liveness, rate, and avalanche metrics.")
        println(io, "- `figures/` -- house-palette per-task panels.")
        println(io, "- `gifs/` -- representative behaviour GIF per task.")
        println(io, "- `manifest.toml` -- git, Julia/package versions, seed scheme, and resolved profile metadata.")
        report_path === nothing || println(io, "- `$(basename(report_path))` -- opt-in HTML stub; CSV/figures/GIF remain authoritative.")
        println(io)
        println(io, "## Per-task Summary")
        println(io)
        println(io, "| task | score_norm | sigma_mr | spectral_radius | liveness | avalanche_tau |")
        println(io, "|---|---:|---:|---:|---:|---:|")
        for res in results
            spectral = isempty(res.spectral_mean) ? NaN : last(res.spectral_mean)
            println(io, "| `:$(res.task)` | $(_fmt(res.score_norm_mean)) | $(_fmt(res.sigma_mr_mean)) | $(_fmt(spectral)) | $(_fmt(res.liveness)) | $(_fmt(res.avalanche_tau)) |")
        end
        println(io)
        println(io, "HTML is intentionally off by default; the old rich report has been reduced to an opt-in stub and may be revived later.")
    end
    return path
end

function _write_html_stub(path::AbstractString, node_sym::Symbol, results)
    open(path, "w") do io
        println(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">")
        println(io, "<title>$(node_sym) profile</title></head><body>")
        println(io, "<h1>Profile <code>:$(node_sym)</code></h1>")
        println(io, "<p>HTML output is opt-in and secondary. Use <code>metrics.csv</code>, <code>figures/</code>, <code>gifs/</code>, and <code>README.md</code> as the primary profile outputs.</p>")
        println(io, "<ul>")
        for res in results
            println(io, "<li><code>:$(res.task)</code>: score_norm=$(_fmt(res.score_norm_mean)), sigma_mr=$(_fmt(res.sigma_mr_mean)), liveness=$(_fmt(res.liveness))</li>")
        end
        println(io, "</ul>")
        println(io, "<p>This stub keeps the report hook available for a future revived HTML profile.</p>")
        println(io, "</body></html>")
    end
    return path
end

"""
    node_profile(node_sym=:falandays_base; tasks=DEFAULT_TASKS, n_seeds=8,
                 out_root=joinpath(@__DIR__, "runs"), out_dir=nothing,
                 canonical_N=CANONICAL_N, gifs=true, report=false)

Build a timestamped per-node characterization run directory for `node_sym`.
For each task, run `n_seeds` rollouts at the task's canonical N, write
`metrics.csv`, house-palette PNG panels in `figures/`, a representative
behaviour GIF per task in `gifs/`, `manifest.toml`, `config.resolved.toml`,
and a short `README.md`. HTML is off by default; `report=true` writes only an
opt-in stub so the old rich report can be revived later. Returns a NamedTuple
with the run directory and primary artifact paths.
"""
function node_profile(
    node_sym::Symbol=:falandays_base;
    tasks=DEFAULT_TASKS,
    n_seeds::Integer=8,
    out_root::AbstractString=joinpath(@__DIR__, "runs"),
    out_dir=nothing,
    canonical_N=CANONICAL_N,
    gifs::Bool=true,
    report::Bool=false,
    gif_ticks::Integer=400,
    gif_fps::Integer=20,
)
    render_gifs = Bool(gifs)
    run_info = _make_run_dir(node_sym, tasks, n_seeds; out_root=out_root, out_dir=out_dir)
    run_dir = run_info.dir
    results = [task_profile(node_sym, t; n_seeds=n_seeds, canonical_N=canonical_N) for t in tasks]

    metrics_path = _write_metrics_csv(joinpath(run_dir, "metrics.csv"), results)
    figures = _write_profile_figures(joinpath(run_dir, "figures"), results)
    gif_paths = render_gifs ?
        _write_profile_gifs(joinpath(run_dir, "gifs"), node_sym, results; gif_ticks=gif_ticks, gif_fps=gif_fps) :
        Dict{Symbol,String}()
    manifest_path = _write_profile_manifest(joinpath(run_dir, "manifest.toml"), node_sym, tasks, n_seeds, canonical_N, run_info)
    config_path = _write_profile_config(joinpath(run_dir, BrainlessLab.resolved_config_filename()), node_sym, tasks, n_seeds, canonical_N; gifs=render_gifs, report=report)
    report_path = report ? _write_html_stub(joinpath(run_dir, "report.html"), node_sym, results) : nothing
    readme_path = _write_profile_readme(joinpath(run_dir, "README.md"), node_sym, results; report_path=report_path)

    return (
        dir=run_dir,
        metrics=metrics_path,
        figures=figures,
        gifs=gif_paths,
        manifest=manifest_path,
        config=config_path,
        readme=readme_path,
        report=report_path,
    )
end

end # module
