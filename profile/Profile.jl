module NodeProfile

using BrainlessLab
using Statistics: mean, std
using Printf: @sprintf
using Base64: base64encode
import CairoMakie
import TOML

export node_profile, DEFAULT_TASKS, CANONICAL_N

# ---------------------------------------------------------------------------
# Task selection & canonical sizes
# ---------------------------------------------------------------------------

# Single-agent (agent-environment) tasks only -- :torus is multi-agent and is
# not a fit for a per-node branching-ratio profile.
const DEFAULT_TASKS = (:wall, :tracking, :pong, :cartpole, :cartpole_hard, :cartpole_swingup, :cartpole_long)

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

const _TEAL  = CairoMakie.RGBf(47/255, 111/255, 94/255)
const _AMBER = CairoMakie.RGBf(156/255, 107/255, 31/255)
const _INK   = CairoMakie.RGBf(36/255, 40/255, 43/255)

function _branching_figure(seed_mean, seed_lo, seed_hi; title::String="")
    n = length(seed_mean)
    xs = collect(1:n)
    fig = CairoMakie.Figure(size=(820, 300), backgroundcolor=:white)
    ax = CairoMakie.Axis(
        fig[1, 1];
        xlabel="tick", ylabel="branching ratio  σ(t)",
        title=title, titlesize=14, xlabelsize=12, ylabelsize=12,
        backgroundcolor=:white,
        xgridcolor=CairoMakie.RGBf(0.93, 0.92, 0.89), ygridcolor=CairoMakie.RGBf(0.93, 0.92, 0.89),
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
    )
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

    fig = CairoMakie.Figure(size=(820, 460), backgroundcolor=:white)
    grid = CairoMakie.RGBf(0.93, 0.92, 0.89)

    ax_top = CairoMakie.Axis(
        fig[1, 1];
        ylabel="branching ratio  σ", title=title, titlesize=14, ylabelsize=12,
        backgroundcolor=:white, xgridcolor=grid, ygridcolor=grid,
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
        xticklabelsvisible=false, xticksvisible=false,
    )
    ax_bot = CairoMakie.Axis(
        fig[2, 1];
        xlabel="tick", ylabel=factor_label, xlabelsize=12, ylabelsize=12,
        backgroundcolor=:white, xgridcolor=grid, ygridcolor=grid,
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
    )

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
    fig = CairoMakie.Figure(size=(820, 300), backgroundcolor=:white)
    ax = CairoMakie.Axis(
        fig[1, 1];
        xlabel="tick", ylabel="spectral radius  ρ(W)",
        title=title, titlesize=14, xlabelsize=12, ylabelsize=12,
        backgroundcolor=:white,
        xgridcolor=CairoMakie.RGBf(0.93, 0.92, 0.89), ygridcolor=CairoMakie.RGBf(0.93, 0.92, 0.89),
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
    )
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

    grid = CairoMakie.RGBf(0.93, 0.92, 0.89)
    fig = CairoMakie.Figure(size=(820, 340), backgroundcolor=:white)
    ax_time = CairoMakie.Axis(
        fig[1, 1];
        xlabel="tick", ylabel="|act - T|",
        title=title, titlesize=14, xlabelsize=12, ylabelsize=12,
        backgroundcolor=:white, xgridcolor=grid, ygridcolor=grid,
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
    )
    CairoMakie.band!(ax_time, xs, q25, q75; color=(_TEAL, 0.18), label="node IQR")
    CairoMakie.lines!(ax_time, xs, mean_series; color=_TEAL, linewidth=2.0, label="node mean")
    CairoMakie.xlims!(ax_time, 1, max(n_ticks, 2))
    CairoMakie.axislegend(ax_time; position=:rt, labelsize=10, framevisible=false)

    ax_hist = CairoMakie.Axis(
        fig[1, 2];
        xlabel="final |act - T|", ylabel="nodes",
        backgroundcolor=:white, xgridcolor=grid, ygridcolor=grid,
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
    )
    bins = max(8, min(40, ceil(Int, sqrt(max(n_nodes, 1)))))
    CairoMakie.hist!(ax_hist, target_error.final_distribution; bins=bins, color=(_AMBER, 0.45),
                     strokecolor=_AMBER, strokewidth=0.5)
    CairoMakie.colgap!(fig.layout, 18)
    return fig
end

function _fig_to_data_uri(fig)
    path = tempname() * ".png"
    CairoMakie.save(path, fig)
    bytes = read(path)
    rm(path; force=true)
    return "data:image/png;base64," * base64encode(bytes)
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
    scores = Vector{Float64}(undef, n_seeds)
    # Situated chart uses a single representative run (seed 1): its per-tick σ
    # and the full factor(t) series, kept time-ordered (NOT pooled). We also keep
    # the seed-1 SimResult itself, to render the behaviour + σ(t) MP4.
    seed1_factor = Dict{Symbol,Vector{Float64}}()
    seed1_sim = nothing
    seed1_target_error = nothing

    for s in 1:n_seeds
        record_channels = s == 1 ? (:rate, :scene, :poses, :acts, :targets) : (:rate, :scene, :poses)
        sim = simulate(task; node=node_sym, n_nodes=N, seed=s, record=record_channels)
        br = branching_ratio(sim)
        per_tick_series[s] = br.per_tick
        sigmas[s] = br.sigma
        scores[s] = Float64(sim.metrics.score)

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
        score_mean=_nanmean(scores),
        score_std=_nanstd(scores),
        score_norm_mean=_nanmean(normalized_score.(Ref(task_spec), scores)),
        scores=scores,
        factor_data=factor_data,
        spectral_x=spectral_x,
        spectral_mean=spectral_mean,
        spectral_lo=spectral_lo,
        spectral_hi=spectral_hi,
        seed1_sim=seed1_sim,
        target_error=seed1_target_error,
    )
end

# ---------------------------------------------------------------------------
# HTML rendering
# ---------------------------------------------------------------------------

function _git_sha()
    try
        root = normpath(joinpath(@__DIR__, ".."))
        sha = readchomp(Cmd(`git rev-parse --short HEAD`; dir=root))
        dirty = !isempty(readchomp(Cmd(`git status --porcelain`; dir=root)))
        return sha * (dirty ? " (dirty)" : "")
    catch
        return "unknown"
    end
end

_fmt(x; digits=3) = isnan(x) ? "n/a" : @sprintf("%.*f", digits, x)

const _CSS = """
:root {
  --bg:            #fbfaf7;
  --bg-alt:        #f2efe8;
  --ink:           #24282b;
  --ink-soft:      #52585d;
  --ink-faint:     #82898f;
  --rule:          #dedad0;
  --accent:        #2f6f5e;
  --accent-soft:   #e5efe9;
  --accent-ink:    #1f4b3f;
  --amber:         #9c6b1f;
  --amber-soft:    #f6ecd8;
  --card-bg:       #ffffff;
  --shadow:        0 1px 2px rgba(30,30,25,0.06), 0 6px 20px -12px rgba(30,30,25,0.18);
  --radius:        10px;
  --maxw:          960px;
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  line-height: 1.6; font-size: 16px; -webkit-font-smoothing: antialiased;
}
h1, h2, h3, h4 {
  font-family: "Iowan Old Style", "Palatino Linotype", Palatino, Georgia, "Times New Roman", serif;
  color: var(--ink); line-height: 1.25; font-weight: 600;
}
code, .mono { font-family: "SFMono-Regular", Menlo, Consolas, "Liberation Mono", monospace; font-size: 0.9em; }
code { background: var(--bg-alt); border: 1px solid var(--rule); border-radius: 4px; padding: 0.1em 0.4em; color: var(--accent-ink); }
main { max-width: var(--maxw); margin: 0 auto; padding: 3rem 1.5rem 5rem; }
header.hero { padding-bottom: 2rem; border-bottom: 1px solid var(--rule); margin-bottom: 2.5rem; }
header.hero .kicker {
  display: inline-block; font-size: 0.72rem; letter-spacing: 0.09em; text-transform: uppercase;
  color: var(--accent-ink); background: var(--accent-soft); border-radius: 999px; padding: 0.3rem 0.75rem;
  margin-bottom: 1rem; font-weight: 600;
}
header.hero h1 { font-size: 2.2rem; margin: 0 0 0.6rem; }
header.hero .sub { font-size: 1.05rem; color: var(--ink-soft); max-width: 46em; margin-bottom: 1rem; }
.meta { font-size: 0.85rem; color: var(--ink-faint); }
.meta .mono { color: var(--ink-soft); }
section { margin-bottom: 3rem; }
section h2 { font-size: 1.5rem; border-bottom: 1px solid var(--rule); padding-bottom: 0.5rem; margin-bottom: 1.1rem; }
section h3 { font-size: 1.15rem; color: var(--accent-ink); margin: 1.6rem 0 0.6rem; }
p { color: var(--ink-soft); }
table { width: 100%; border-collapse: collapse; margin: 1rem 0 1.5rem; font-size: 0.9rem; background: var(--card-bg); box-shadow: var(--shadow); border-radius: var(--radius); overflow: hidden; }
th, td { text-align: left; padding: 0.55rem 0.8rem; border-bottom: 1px solid var(--rule); vertical-align: top; }
th { background: var(--bg-alt); font-size: 0.74rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--ink-soft); }
tr:last-child td { border-bottom: none; }
.table-scroll { overflow-x: auto; }
.card {
  background: var(--card-bg); border: 1px solid var(--rule); border-radius: var(--radius);
  padding: 1.4rem 1.5rem; box-shadow: var(--shadow); margin-bottom: 1.8rem;
}
.card h3 { margin-top: 0; }
.badge {
  display: inline-block; font-size: 0.66rem; font-weight: 700; letter-spacing: 0.03em;
  text-transform: uppercase; padding: 0.15rem 0.5rem; border-radius: 999px;
}
.badge-ok { background: var(--accent-soft); color: var(--accent-ink); }
.badge-warn { background: var(--amber-soft); color: var(--amber); }
.stat-row { display: flex; gap: 2rem; flex-wrap: wrap; margin: 1rem 0 1.2rem; }
.stat { min-width: 160px; }
.stat .label { font-size: 0.72rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--ink-faint); }
.stat .value { font-family: "SFMono-Regular", Menlo, Consolas, monospace; font-size: 1.15rem; color: var(--ink); margin-top: 0.15rem; }
.stat .value .pm { color: var(--ink-faint); font-size: 0.85em; }
figure { margin: 1rem 0 0; }
figure img { max-width: 100%; height: auto; border: 1px solid var(--rule); border-radius: 8px; background: #fff; }
figcaption { font-size: 0.78rem; color: var(--ink-faint); margin-top: 0.5rem; }
.callout {
  background: var(--card-bg); border: 1px solid var(--rule); border-left: 4px solid var(--accent);
  border-radius: 8px; padding: 1rem 1.25rem; margin: 1.2rem 0;
}
footer { max-width: var(--maxw); margin: 3rem auto 0; padding: 1.5rem; border-top: 1px solid var(--rule); font-size: 0.83rem; color: var(--ink-faint); }
footer code { font-size: 0.95em; }
"""

function _params_table(p::FalandaysParams)
    rows = [
        ("leak", p.leak, "membrane leak per tick (0.75 retained)"),
        ("threshold_mult", p.threshold_mult, "firing threshold T&prime; = threshold_mult &middot; T"),
        ("targ_min", p.targ_min, "homeostatic target floor T"),
        ("lrate_wmat", p.lrate_wmat, "online weight-learning rate"),
        ("lrate_targ", p.lrate_targ, "online target-learning rate"),
        ("input_weight", p.input_weight, "shared input (receptor &rarr; node) weight"),
        ("weight_init_std", p.weight_init_std, "recurrent weight init std, W&#8320; ~ N(0, weight_init_std)"),
    ]
    io = IOBuffer()
    println(io, "<table><thead><tr><th>parameter</th><th>value</th><th>meaning</th></tr></thead><tbody>")
    for (name, val, note) in rows
        println(io, "<tr><td><code>$name</code></td><td class=\"mono\">$(_fmt(Float64(val); digits=4))</td><td>$note</td></tr>")
    end
    println(io, "</tbody></table>")
    return String(take!(io))
end

function _task_card(res, task_note::String, mp4_name::AbstractString="")
    prose = get(TASK_PROSE, res.task, (encoding="--", decode="--", scoring="--"))
    plot_uri = _fig_to_data_uri(_branching_figure(res.seed_mean, res.seed_lo, res.seed_hi; title=string(res.task)))
    live = res.sigma_mean >= 0.85 ? ("<span class=\"badge badge-ok\">self-sustaining</span>") :
           (isnan(res.sigma_mean) ? "<span class=\"badge badge-warn\">no activity</span>" :
            "<span class=\"badge badge-warn\">subcritical / decaying</span>")
    io = IOBuffer()
    println(io, "<div class=\"card\">")
    println(io, "<h3 id=\"task-$(res.task)\"><code>:$(res.task)</code> $live</h3>")
    println(io, "<table><thead><tr><th>N</th><th>R</th><th>E</th><th>ticks</th><th>sensory encoding</th><th>effector decode</th></tr></thead><tbody>")
    println(io, "<tr><td class=\"mono\">$(res.n_nodes)<br><span style=\"color:var(--ink-faint);font-size:0.78em\">$task_note</span></td>",
                 "<td class=\"mono\">$(res.n_receptors)</td><td class=\"mono\">$(res.n_effectors)</td>",
                 "<td class=\"mono\">$(res.ticks)</td><td>$(prose.encoding)</td><td>$(prose.decode)</td></tr>")
    println(io, "</tbody></table>")
    println(io, "<div class=\"stat-row\">")
    println(io, "<div class=\"stat\"><div class=\"label\">mean score ($(prose.scoring))</div>",
                 "<div class=\"value\">$(_fmt(res.score_mean)) <span class=\"pm\">&plusmn; $(_fmt(res.score_std))</span></div></div>")
    println(io, "<div class=\"stat\"><div class=\"label\">normalized score</div>",
                 "<div class=\"value\">$(_fmt(res.score_norm_mean))</div></div>")
    println(io, "<div class=\"stat\"><div class=\"label\">mean branching &sigma;&#770;</div>",
                 "<div class=\"value\">$(_fmt(res.sigma_mean)) <span class=\"pm\">&plusmn; $(_fmt(res.sigma_std))</span></div></div>")
    println(io, "</div>")

    # Behaviour + branching-ratio MP4 (seed 1): the task animation with the σ(t)
    # trace below -- a swept marker and the current σ printed per frame.
    if !isempty(mp4_name)
        println(io, "<figure><video src=\"$mp4_name\" controls loop muted playsinline style=\"max-width:100%\"></video>")
        println(io, "<figcaption>Behaviour + branching ratio, one run (seed 1): the task animation (top) with the ",
                     "per-tick branching ratio &sigma;(t) below &mdash; the red marker sweeps in sync with the frame, ",
                     "the dashed line marks &sigma;=1, and the current &sigma; is printed on each frame. One frame per ",
                     "simulation tick.</figcaption></figure>")
    end

    println(io, "<figure><img src=\"$plot_uri\" alt=\"branching ratio over time for :$(res.task)\">")
    println(io, "<figcaption>Seed-mean &sigma;(t) (teal line) &plusmn;1 std across $(res.n_seeds) seeds (shaded band); dashed amber line marks &sigma;=1, the self-sustaining/critical reference.</figcaption></figure>")

    # Spectral radius ρ(W) over time -- the weight reorganization homeostasis
    # drives, which the rate-pinned branching ratio can't show. Gated: rendered
    # only for nodes with a learned recurrent matrix (series non-empty).
    if !isempty(res.spectral_mean)
        s0 = first(res.spectral_mean); s1 = last(res.spectral_mean)
        stride = length(res.spectral_x) >= 2 ? (res.spectral_x[2] - res.spectral_x[1]) : res.ticks
        suri = _fig_to_data_uri(_spectral_figure(res.spectral_x, res.spectral_mean, res.spectral_lo, res.spectral_hi; title="$(res.task) — spectral radius ρ(W)"))
        println(io, "<figure><img src=\"$suri\" alt=\"spectral radius over time for :$(res.task)\">")
        println(io, "<figcaption>Seed-mean spectral radius &rho;(W) &mdash; the largest |eigenvalue| of the learned recurrent ",
                     "matrix, sampled every $(stride) ticks over the run (amber line, &plusmn;1 std band across $(res.n_seeds) seeds). ",
                     "It tracks the weight reorganization the homeostatic learning drives (branching, rate-pinned, does not): ",
                     "for <code>falandays_base</code> &rho;(W) falls over the run as <code>W -= error/N</code> shrinks the ",
                     "recurrent weights &mdash; here $(_fmt(s0; digits=2)) &rarr; $(_fmt(s1; digits=2)).</figcaption></figure>")
    end

    # Falandays-family nodes expose homeostatic targets. Compartmental nodes do
    # not, so the analysis is absent and this panel is skipped.
    if res.target_error !== nothing
        turi = _fig_to_data_uri(_target_error_figure(res.target_error; title="$(res.task) — per-node distance to target"))
        println(io, "<figure><img src=\"$turi\" alt=\"per-node distance to target over time for :$(res.task)\">")
        println(io, "<figcaption>Representative run (seed 1): mean <code>|act - T|</code> across nodes (teal) ",
                     "with the across-node interquartile band, plus the final-tick node distribution. ",
                     "This is the primary per-node homeostatic workload signal because Falandays weight-update ",
                     "magnitude scales with <code>|error|</code>.</figcaption></figure>")
    end

    # Additional panel(s): SITUATED per-run chart -- branching σ(t) and the
    # registered per-task performance factor(t) over shared time, from a single
    # representative run (seed 1). Gated by the task-scoped analysis registry --
    # tasks with no registered factor (the cartpole family) get none.
    for fd in res.factor_data
        title = "Situated: branching σ and $(fd.label) — one run (seed 1)"
        uri = _fig_to_data_uri(_situated_figure(fd.sigma, fd.factor, fd.label; title=title))
        println(io, "<figure><img src=\"$uri\" alt=\"situated branching σ and $(fd.label) over time for :$(res.task)\">")
        println(io, "<figcaption>A single representative run (seed 1): <b>top</b> = branching ratio &sigma;(t) ",
                     "(dashed amber line marks &sigma;=1); <b>bottom</b> = <b>$(fd.label)</b> ",
                     "(the registered <code>:$(fd.sym)</code> performance factor) over the same ticks. ",
                     "Panels share the time axis &mdash; read vertically: does &sigma; move as the agent's ",
                     "situation (e.g. nearing a wall) changes?</figcaption></figure>")
    end
    println(io, "</div>")
    return String(take!(io))
end

"""
    node_profile(node_sym=:falandays_base; tasks=DEFAULT_TASKS, n_seeds=8,
                 out_dir=joinpath(@__DIR__, "output", string(node_sym)),
                 canonical_N=CANONICAL_N)

Build a per-node profile HTML report for `node_sym`: for each task in
`tasks`, run `n_seeds` rollouts at the task's canonical N, compute the
per-tick branching ratio (`branching_ratio`) and task score, seed-average
them, and render a self-contained HTML report (embedded PNG plots, no CDN)
to `out_dir/index.html`. Returns the output file path.
"""
function node_profile(
    node_sym::Symbol=:falandays_base;
    tasks=DEFAULT_TASKS,
    n_seeds::Integer=8,
    out_dir::AbstractString=joinpath(@__DIR__, "output", string(node_sym)),
    canonical_N=CANONICAL_N,
    render_videos::Bool=true,
    video_ticks::Integer=400,
    video_fps::Integer=60,
)
    mkpath(out_dir)

    params = FalandaysParams()
    code_default_N = try
        BrainlessLab._default_node_count(node_sym)
    catch
        100
    end

    results = [task_profile(node_sym, t; n_seeds=n_seeds, canonical_N=canonical_N) for t in tasks]

    # Per-task behaviour + branching-ratio MP4 (seed 1), capped to a watchable window
    # (video_ticks) so the per-tick render stays fast. Written to files (too big to embed)
    # and referenced from the HTML via <video>. maxframes = vticks keeps it one frame/tick.
    mp4_by_task = Dict{Symbol,String}()
    if render_videos
        for res in results
            vticks = min(res.ticks, Int(video_ticks))
            vsim = simulate(res.task; node=node_sym, n_nodes=res.n_nodes, seed=1,
                            record=(:rate, :scene, :poses), ticks=vticks)
            mp4 = "$(res.task).mp4"
            try
                Base.invokelatest(BrainlessLab.animate, vsim; path=joinpath(out_dir, mp4),
                                  branching=true, framerate=Int(video_fps), maxframes=vticks)
                mp4_by_task[res.task] = mp4
            catch err
                @warn "profile video render failed for $(res.task)" exception = (err, catch_backtrace())
            end
        end
    end

    io = IOBuffer()
    println(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"UTF-8\">")
    println(io, "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">")
    println(io, "<title>$(node_sym) &mdash; node profile</title>")
    println(io, "<style>", _CSS, "</style></head><body><main>")

    # --- header -------------------------------------------------------
    println(io, "<header class=\"hero\">")
    println(io, "<span class=\"kicker\">BrainlessLab.jl &middot; per-node profile</span>")
    println(io, "<h1><code>$(node_sym)</code></h1>")
    println(io, "<p class=\"sub\">The 2021 Falandays homeostatic leaky-integrate-and-fire reservoir, run untrained ",
                 "(default parameters, fresh random wiring per seed) across ", length(tasks),
                 " single-agent (agent&ndash;environment) tasks, with per-tick population branching ratio ",
                 "&sigma;(t) as the criticality diagnostic.</p>")
    println(io, "<p class=\"meta\">n_seeds = <span class=\"mono\">$n_seeds</span> per task &middot; ",
                 "git SHA <span class=\"mono\">$(_git_sha())</span> &middot; generated ",
                 Base.Libc.strftime("%Y-%m-%d %H:%M", time()), "</p>")
    println(io, "</header>")

    # --- node structure & initialization -------------------------------
    println(io, "<section id=\"structure\"><h2>Node structure &amp; initialization</h2>")
    println(io, "<p>Each node is a homeostatic leaky integrate-and-fire unit with an online-learned target ",
                 "and recurrent weight matrix. Per node: a homeostatic target <code>T</code> (floor ",
                 "<code>targ_min</code>) and firing threshold <code>T&prime; = threshold_mult &middot; T</code>; ",
                 "membrane activation leaks at rate <code>leak</code> each tick (<code>1-leak</code> retained), ",
                 "integrating receptor-weighted input and recurrent input from the previous tick's spikes. ",
                 "Recurrent wiring is Bernoulli at <code>link_p &asymp; 0.1</code> with no self-connections; ",
                 "initial recurrent weights are drawn <code>W&#8320; ~ N(0, weight_init_std)</code>. Online ",
                 "homeostatic learning runs every tick during the rollout: <code>W -= error/N</code> (mean over ",
                 "active presynaptic nodes) and <code>T += lrate_targ &middot; error</code>, where ",
                 "<code>error = act - T</code>. Because the model self-organizes online, it is fair to run ",
                 "<strong>untrained</strong>: default parameters plus a fresh random wiring, weight init, and ",
                 "noise stream <strong>per seed</strong>. Every task below is scored as a seed-average over ",
                 "$n_seeds independently-wired seeds.</p>")
    println(io, _params_table(params))
    println(io, "<p class=\"meta\">The code's own <code>simulate</code> default reservoir size for ",
                 "<code>:$node_sym</code> (no explicit <code>n_nodes</code>) is <span class=\"mono\">$code_default_N</span> ",
                 "&mdash; a &ldquo;standard setup&rdquo; convenience default, distinct from the task-specific ",
                 "canonical sizes used for the profile below.</p>")
    println(io, "</section>")

    # --- per-task sections ----------------------------------------------
    println(io, "<section id=\"tasks\"><h2>Per-task branching-ratio profile</h2>")
    println(io, "<p>Each task card carries the branching ratio <strong>over time</strong> (seed-mean &sigma;(t) ",
                 "with a &plusmn;1 std band). Where the task registers a per-tick <strong>performance factor</strong> ",
                 "in the task-scoped analysis registry (<code>task_analyses(task)</code>), a <strong>situated</strong> ",
                 "panel shows &mdash; for a single representative run (seed 1) &mdash; branching &sigma;(t) and that ",
                 "factor(t) as two time-aligned, x-linked panels. Reading vertically asks ",
                 "<em>does &sigma; move as the agent moves through its environment &mdash; when heading error grows, when it ",
                 "nears a wall, when the ball pulls away from the paddle?</em> (This keeps time, which a pooled scatter ",
                 "would have thrown away.) Tasks with no registered factor (the cartpole family) show only the over-time panel.</p>")
    println(io, "<p>Each card also carries <strong>spectral radius &rho;(W) over time</strong> &mdash; the largest ",
                 "|eigenvalue| of the learned recurrent matrix, sampled over the run (a separate coarse, downsample-only ",
                 "rollout, since eigenvalues are expensive). It tracks the <em>weight reorganization</em> the homeostatic ",
                 "learning drives, which the branching ratio cannot: branching is rate-pinned by homeostasis, whereas ",
                 "&rho;(W) reveals the underlying recurrent scale. For <code>falandays_base</code> &rho;(W) <strong>falls</strong> ",
                 "over the run as <code>W -= error/N</code> shrinks the recurrent weights. The panel is gated on availability ",
                 "&mdash; nodes without a learned recurrent matrix (e.g. compartmental) produce an empty series and no panel.</p>")
    for res in results
        note = get(CANONICAL_NOTE, res.task, "")
        println(io, _task_card(res, note, get(mp4_by_task, res.task, "")))
    end
    println(io, "</section>")

    # --- methods footer ---------------------------------------------------
    println(io, "<footer>")
    println(io, "<p><strong>Branching ratio.</strong> Population firing rate <code>A(t)</code> is the mean ",
                 "spike rate across nodes at tick <code>t</code> (the recorded <code>:rate</code> channel). ",
                 "Per-tick branching ratio <code>&sigma;(t) = A(t+1)/A(t)</code> (undefined / <code>NaN</code> ",
                 "when <code>A(t)=0</code>). The mean-field summary is the least-squares estimate ",
                 "<code>&sigma;&#770; = &Sigma; A<sub>t</sub>A<sub>t+1</sub> / &Sigma; A<sub>t</sub>&sup2;</code> ",
                 "(sum over ticks with <code>A(t)&gt;0</code>). <code>&sigma;&#770;&asymp;1</code> indicates ",
                 "self-sustaining/critical dynamics; <code>&lt;1</code> subcritical/decaying; <code>&gt;1</code> ",
                 "supercritical/growing.</p>")
    println(io, "<p><strong>Setup.</strong> n_seeds = $n_seeds per task; ticks = each task's default tick count; ",
                 "seed varies wiring topology, weight init, and the model's noise stream. Canonical N is the ",
                 "2024 Falandays case-study author size per task where it exists (wall/tracking = 200, ",
                 "pong/pong_hitrate = 500); the cartpole family has no paper-canonical size and uses N=200 here, ",
                 "labeled not-paper-canonical. This is a <strong>single-agent (agent&ndash;environment)</strong> ",
                 "profile; <code>:torus</code> (multi-agent) is not included.</p>")
    println(io, "</footer>")

    println(io, "</main></body></html>")

    out_path = joinpath(out_dir, "index.html")
    open(out_path, "w") do f
        write(f, String(take!(io)))
    end
    return out_path
end

end # module
