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
    end
    CairoMakie.hlines!(ax, [1.0]; color=_AMBER, linestyle=:dash, linewidth=1.5, label="σ = 1 (critical)")
    CairoMakie.xlims!(ax, 1, max(n, 2))
    CairoMakie.axislegend(ax; position=:rt, labelsize=10, framevisible=false)
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
recording `:rate`, over the task's default ticks. Returns a NamedTuple with
the seed-averaged branching-ratio series, mean/std sigma, mean/std score, and
the run parameters used (N, R, E, ticks).
"""
function task_profile(node_sym::Symbol, task::Symbol; n_seeds::Integer=8, canonical_N=CANONICAL_N)
    task_spec = resolve_task(task)
    N = canonical_N[task]
    ticks = task_spec.default_ticks

    per_tick_series = Vector{Vector{Float64}}(undef, n_seeds)
    sigmas = Vector{Float64}(undef, n_seeds)
    scores = Vector{Float64}(undef, n_seeds)

    for s in 1:n_seeds
        sim = simulate(task; node=node_sym, n_nodes=N, seed=s, record=(:rate,))
        br = branching_ratio(sim)
        per_tick_series[s] = br.per_tick
        sigmas[s] = br.sigma
        scores[s] = Float64(sim.metrics.score)
    end

    seed_mean, seed_lo, seed_hi = _seedwise_series(per_tick_series)

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
