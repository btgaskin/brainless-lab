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
    _pearson(xs, ys)

Pearson correlation over paired points, ignoring pairs with any non-finite
value. Returns `NaN` if fewer than 2 valid pairs or zero variance.
"""
function _pearson(xs::AbstractVector, ys::AbstractVector)
    n = min(length(xs), length(ys))
    vx = Float64[]; vy = Float64[]
    @inbounds for i in 1:n
        x = Float64(xs[i]); y = Float64(ys[i])
        if isfinite(x) && isfinite(y)
            push!(vx, x); push!(vy, y)
        end
    end
    length(vx) < 2 && return NaN
    mx = mean(vx); my = mean(vy)
    sx = 0.0; sy = 0.0; sxy = 0.0
    @inbounds for i in eachindex(vx)
        dx = vx[i] - mx; dy = vy[i] - my
        sxy += dx * dy; sx += dx * dx; sy += dy * dy
    end
    (sx <= 0.0 || sy <= 0.0) && return NaN
    return sxy / sqrt(sx * sy)
end

"""
    _binned_means(xs, ys; nbins=12)

Bin `xs` into `nbins` equal-width bins over its finite range, returning bin
centers and the mean `y` per non-empty bin (NaN-aware).
"""
function _binned_means(xs::AbstractVector{<:Real}, ys::AbstractVector{<:Real}; nbins::Integer=12)
    lo, hi = extrema(xs)
    (isfinite(lo) && isfinite(hi) && hi > lo) || return (Float64[], Float64[])
    w = (hi - lo) / nbins
    centers = Float64[]
    means = Float64[]
    for b in 1:nbins
        blo = lo + (b - 1) * w
        bhi = b == nbins ? hi : lo + b * w
        acc = Float64[]
        @inbounds for i in eachindex(xs)
            x = xs[i]
            in_bin = b == nbins ? (x >= blo && x <= bhi) : (x >= blo && x < bhi)
            in_bin && push!(acc, ys[i])
        end
        if !isempty(acc)
            push!(centers, (blo + bhi) / 2)
            push!(means, mean(acc))
        end
    end
    return centers, means
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
    _factor_scatter_figure(factor_x, sigma_y, xlabel; title, r)

Pooled scatter of per-tick branching ratio σ (y) against a per-task
performance factor (x), with a binned-mean trend line and a σ=1 reference.
"""
function _factor_scatter_figure(factor_x::Vector{Float64}, sigma_y::Vector{Float64}, xlabel::String; title::String="")
    fig = CairoMakie.Figure(size=(820, 320), backgroundcolor=:white)
    ax = CairoMakie.Axis(
        fig[1, 1];
        xlabel=xlabel, ylabel="branching ratio  σ",
        title=title, titlesize=14, xlabelsize=12, ylabelsize=12,
        backgroundcolor=:white,
        xgridcolor=CairoMakie.RGBf(0.93, 0.92, 0.89), ygridcolor=CairoMakie.RGBf(0.93, 0.92, 0.89),
        leftspinevisible=true, rightspinevisible=false, topspinevisible=false,
    )
    if !isempty(factor_x)
        CairoMakie.scatter!(ax, factor_x, sigma_y; color=(_TEAL, 0.10), markersize=3, strokewidth=0, label="ticks (pooled)")
        cx, cy = _binned_means(factor_x, sigma_y; nbins=12)
        if !isempty(cx)
            CairoMakie.lines!(ax, cx, cy; color=_INK, linewidth=2.2, label="binned mean σ")
            CairoMakie.scatter!(ax, cx, cy; color=_INK, markersize=6)
        end
        # Robust y-limits: 1st–99th percentile of pooled σ so a single outlier
        # tick doesn't flatten the view. Keep the σ=1 reference inside.
        fin = _finite(sigma_y)
        if !isempty(fin)
            lo = _percentile(fin, 1.0)
            hi = _percentile(fin, 99.0)
            lo = min(lo, 1.0)
            hi = max(hi, 1.0)
            pad = 0.05 * max(hi - lo, eps())
            CairoMakie.ylims!(ax, lo - pad, hi + pad)
        end
    end
    CairoMakie.hlines!(ax, [1.0]; color=_AMBER, linestyle=:dash, linewidth=1.5, label="σ = 1 (critical)")
    CairoMakie.axislegend(ax; position=:rb, labelsize=10, framevisible=false)
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
one pooled (factor, branching σ) scatter + Pearson r per task-scoped analysis
registered for the task (empty when the task registers none).
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
    # For each factor sym: pooled (x=factor, y=branching σ) points across all
    # ticks and all seeds, NaN-branching pairs dropped.
    factor_x = Dict{Symbol,Vector{Float64}}(f => Float64[] for f in factors)
    factor_y = Dict{Symbol,Vector{Float64}}(f => Float64[] for f in factors)

    for s in 1:n_seeds
        sim = simulate(task; node=node_sym, n_nodes=N, seed=s, record=(:rate, :scene, :poses))
        br = branching_ratio(sim)
        per_tick_series[s] = br.per_tick
        sigmas[s] = br.sigma
        scores[s] = Float64(sim.metrics.score)

        for f in factors
            sig = resolve_analysis(f)(sim)          # length T
            bt = br.per_tick                          # length T-1
            m = min(length(sig), length(bt))
            xs = factor_x[f]; ys = factor_y[f]
            @inbounds for t in 1:m
                y = bt[t]
                isnan(y) && continue
                x = Float64(sig[t])
                isfinite(x) || continue
                push!(xs, x); push!(ys, y)
            end
        end
    end

    seed_mean, seed_lo, seed_hi = _seedwise_series(per_tick_series)

    factor_data = [
        (
            sym=f,
            label=analysis_meta(f).label,
            x=factor_x[f],
            y=factor_y[f],
            r=_pearson(factor_x[f], factor_y[f]),
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

function _task_card(res, task_note::String)
    prose = get(TASK_PROSE, res.task, (encoding="--", decode="--", scoring="--"))
    plot_uri = _fig_to_data_uri(_branching_figure(res.seed_mean, res.seed_lo, res.seed_hi; title=string(res.task)))
    live = res.sigma_mean >= 0.85 ? ("<span class=\"badge badge-ok\">self-sustaining</span>") :
           (isnan(res.sigma_mean) ? "<span class=\"badge badge-warn\">no activity</span>" :
            "<span class=\"badge badge-warn\">subcritical / decaying</span>")
    io = IOBuffer()
    println(io, "<div class=\"card\">")
    println(io, "<h3 id=\"task-$(res.task)\"><code>:$(res.task)</code> $live</h3>")
    println(io, "<table><thead><tr><th>N</th><th>R</th><th>E</th><th>ticks</th><th>sensory encoding</th><th>motor decode</th></tr></thead><tbody>")
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
    println(io, "<figure><img src=\"$plot_uri\" alt=\"branching ratio over time for :$(res.task)\">")
    println(io, "<figcaption>Seed-mean &sigma;(t) (teal line) &plusmn;1 std across $(res.n_seeds) seeds (shaded band); dashed amber line marks &sigma;=1, the self-sustaining/critical reference.</figcaption></figure>")

    # Additional panel(s): branching σ vs each registered per-task performance
    # factor. Gated by the task-scoped analysis registry -- tasks with no
    # registered factor (e.g. the cartpole family) get no scatter here.
    for fd in res.factor_data
        rtxt = isnan(fd.r) ? "n/a" : _fmt(fd.r)
        title = "Branching σ vs $(fd.label) (r = $rtxt)"
        npts = length(fd.x)
        uri = _fig_to_data_uri(_factor_scatter_figure(fd.x, fd.y, fd.label; title=title))
        println(io, "<figure><img src=\"$uri\" alt=\"branching ratio vs $(fd.label) for :$(res.task)\">")
        println(io, "<figcaption>Pooled per-tick points ($(npts) across $(res.n_seeds) seeds): x = <b>$(fd.label)</b> ",
                     "(the registered <code>:$(fd.sym)</code> performance factor), y = branching ratio &sigma;. ",
                     "Dark line = binned-mean &sigma; (12 bins); dashed amber line marks &sigma;=1. ",
                     "Pearson <b>r = $rtxt</b> &mdash; does the reservoir sit nearer criticality (&sigma;&asymp;1) when performing well?</figcaption></figure>")
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
)
    mkpath(out_dir)

    params = FalandaysParams()
    code_default_N = try
        BrainlessLab._default_node_count(node_sym)
    catch
        100
    end

    results = [task_profile(node_sym, t; n_seeds=n_seeds, canonical_N=canonical_N) for t in tasks]

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
                 "in the task-scoped analysis registry (<code>task_analyses(task)</code>), a second panel plots ",
                 "branching &sigma; <strong>against that factor</strong>, pooling every tick across every seed: it asks ",
                 "<em>does the reservoir sit nearer criticality (&sigma;&asymp;1) when it is performing well &mdash; small ",
                 "heading error, far from the wall, close ball&ndash;paddle tracking?</em> A Pearson <code>r</code> ",
                 "summarizes the pooled relationship. Tasks with no registered factor (the cartpole family) show only ",
                 "the over-time panel.</p>")
    for res in results
        note = get(CANONICAL_NOTE, res.task, "")
        println(io, _task_card(res, note))
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
