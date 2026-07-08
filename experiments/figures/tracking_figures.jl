# Figures for the tracking parameter-sweep + leak×lrate_wmat factorial.
# Reads a run's results.json (no simulation) and writes static, theme-neutral
# figures for the Experiments docs section.
#
#   julia --project=experiments/figures experiments/figures/tracking_figures.jl \
#         [sweep_results.json] [factorial_results.json] [out_dir]
# Defaults: newest run of each experiment; out_dir = site/src/assets/experiments/tracking-sweep.

using CairoMakie
using JSON3
using Statistics
using Random

# ---------- palette (CVD-safe; readable on light & dark) ----------
const C_VIABLE   = RGBf(0.29, 0.55, 0.32)   # green
const C_MARGINAL = RGBf(0.76, 0.49, 0.10)   # amber
const C_DEGEN    = RGBf(0.69, 0.29, 0.25)   # red
const C_LINE     = RGBf(0.30, 0.43, 0.71)   # blue
const INK        = RGBf(0.42, 0.46, 0.52)   # mid-gray axes/text (reads on both themes)
const CHANCE30   = 1/6                       # frac_within_30deg chance floor
const VIABLE_CUT = 0.25                      # "reliably beats chance"

theme_neutral() = Theme(
    fontsize = 13, figure_padding = 10,
    Axis = (; backgroundcolor = :transparent, xgridcolor = (INK, 0.15), ygridcolor = (INK, 0.15),
            leftspinecolor = INK, bottomspinecolor = INK, topspinevisible = false, rightspinevisible = false,
            xticklabelcolor = INK, yticklabelcolor = INK, xlabelcolor = INK, ylabelcolor = INK,
            titlecolor = INK, xtickcolor = INK, ytickcolor = INK),
)

readjson(p) = JSON3.read(read(p, String))
fin(v) = collect(skipmissing(Float64(x) for x in v if x !== nothing && isfinite(Float64(x))))

function newest(exp)
    dir = joinpath(@__DIR__, "..", "runs", exp)
    isdir(dir) || error("no runs for $exp")
    runs = filter(d -> isfile(joinpath(dir, d, "results.json")), readdir(dir))
    isempty(runs) && error("no results.json for $exp")
    return joinpath(dir, sort(runs)[end], "results.json")
end

regime_color(f) = f > VIABLE_CUT ? C_VIABLE : (f > CHANCE30 ? C_MARGINAL : C_DEGEN)

function boot_frac(vals; cut=VIABLE_CUT, nboot=2000, rng=MersenneTwister(1))
    v = fin(vals); isempty(v) && return (NaN, NaN, NaN)
    n = length(v); pt = count(>(cut), v) / n
    bs = Vector{Float64}(undef, nboot)
    @inbounds for b in 1:nboot
        c = 0; for _ in 1:n; c += v[rand(rng, 1:n)] > cut; end; bs[b] = c / n
    end
    return (pt, quantile(bs, 0.1), quantile(bs, 0.9))
end

# ---------- Fig 1: viability strips (per-seed frac_within_30deg per axis) ----------
function fig_strips(sweep, out)
    axes_ = collect(keys(sweep.sweeps))
    fig = Figure(size = (960, 560)); rng = MersenneTwister(0)
    Label(fig[0, :], "Viability by parameter — fraction of ticks within 30° of target (per random-init seed)";
          fontsize = 15, color = INK, font = :bold)
    for (k, name) in enumerate(axes_)
        s = sweep.sweeps[name]; vals = Float64.(s.values); ps = s.frac_within_30deg.per_seed
        r, c = fldmod1(k, 3)
        ax = Axis(fig[r, c]; title = String(name), xlabel = "value", ylabel = c == 1 ? "frac<30°" : "")
        hlines!(ax, [CHANCE30]; color = (INK, 0.6), linestyle = :dash, linewidth = 1)
        gap = length(vals) > 1 ? minimum(diff(sort(vals))) : (maximum(vals) - minimum(vals) + 1.0)
        jit = gap * 0.32
        for (vi, v) in enumerate(vals)
            seeds = fin(ps[vi])
            for y in seeds
                scatter!(ax, [v + jit * (2 * rand(rng) - 1)], [y];
                         color = (regime_color(y), 0.45), markersize = 4, strokewidth = 0)
            end
            isempty(seeds) || lines!(ax, [v - jit, v + jit], fill(median(seeds), 2); color = C_LINE, linewidth = 2.5)
        end
        ylims!(ax, 0, 1)
    end
    save(joinpath(out, "viability_strips.png"), fig; px_per_unit = 2)
    return fig
end

# ---------- Fig 2: frac-beats-chance curves + bootstrap CI + boundary ----------
function fig_fracviable(sweep, out)
    axes_ = collect(keys(sweep.sweeps))
    fig = Figure(size = (960, 520))
    Label(fig[0, :], "Fraction of inits that reliably track  (frac<30° > $(VIABLE_CUT))  with 10–90% bootstrap CI";
          fontsize = 15, color = INK, font = :bold)
    for (k, name) in enumerate(axes_)
        s = sweep.sweeps[name]; vals = Float64.(s.values); ps = s.frac_within_30deg.per_seed
        r, c = fldmod1(k, 3)
        ax = Axis(fig[r, c]; title = String(name), xlabel = "value", ylabel = k % 3 == 1 ? "frac viable" : "")
        pts = Float64[]; los = Float64[]; his = Float64[]
        for vi in eachindex(vals)
            p, lo, hi = boot_frac(ps[vi]); push!(pts, p); push!(los, lo); push!(his, hi)
        end
        band!(ax, vals, los, his; color = (C_LINE, 0.18))
        lines!(ax, vals, pts; color = C_LINE, linewidth = 2.5)
        scatter!(ax, vals, pts; color = C_LINE, markersize = 7)
        ylims!(ax, -0.02, 1.02)
    end
    save(joinpath(out, "frac_viable.png"), fig; px_per_unit = 2)
    return fig
end

# ---------- Fig 3: leak×lrate_wmat viability heatmap ----------
function fig_heatmap(fact, out)
    leaks = Float64.(fact.leaks); lrs = Float64.(fact.lrate_wmats)
    Z = [ (fact.frac_viable[i][j] === nothing ? NaN : Float64(fact.frac_viable[i][j])) for i in eachindex(leaks), j in eachindex(lrs) ]
    fig = Figure(size = (620, 460))
    ax = Axis(fig[1, 1]; title = "Joint viability landscape — leak × lrate_wmat  (fraction of inits tracking)",
              xlabel = "lrate_wmat", ylabel = "leak", xticks = (1:length(lrs), string.(lrs)), yticks = (1:length(leaks), string.(leaks)))
    hm = heatmap!(ax, 1:length(lrs), 1:length(leaks), permutedims(Z); colormap = :viridis, colorrange = (0, 1))
    Colorbar(fig[1, 2], hm; label = "frac viable")
    # mark joint optimum
    bi = argmax(replace(Z, NaN => -1.0))
    scatter!(ax, [bi[2]], [bi[1]]; marker = :star5, color = :white, strokecolor = :black, strokewidth = 1, markersize = 18)
    text!(ax, bi[2], bi[1]; text = "  opt", color = :white, align = (:left, :center), fontsize = 11)
    save(joinpath(out, "factorial_heatmap.png"), fig; px_per_unit = 2)
    return fig
end

# ---------- Fig 4: signature scatter (pooled seeds) ----------
function fig_signature(sweep, out)
    xs = Float64[]; ys = Float64[]; cs = RGBAf[]
    for (name, s) in pairs(sweep.sweeps)
        nte = s.nte_p90.per_seed; tsc = s.track_score.per_seed; fwd = s.frac_within_30deg.per_seed
        for vi in eachindex(s.values), si in eachindex(nte[vi])
            x = nte[vi][si]; y = tsc[vi][si]; f = fwd[vi][si]
            (x === nothing || y === nothing || f === nothing) && continue
            col = regime_color(Float64(f))
            push!(xs, Float64(x)); push!(ys, Float64(y)); push!(cs, RGBAf(col.r, col.g, col.b, 0.45))
        end
    end
    fig = Figure(size = (620, 460))
    ax = Axis(fig[1, 1]; title = "Signature vs performance (each point = one seed, all cells pooled)",
              xlabel = "node_target_error tail (p90)  — homeostatic set-point error", ylabel = "track_score  (mean cos err)")
    scatter!(ax, xs, ys; color = cs, markersize = 5, strokewidth = 0)
    # legend
    elems = [MarkerElement(color = c, marker = :circle, markersize = 10) for c in (C_VIABLE, C_MARGINAL, C_DEGEN)]
    axislegend(ax, elems, ["viable (>$(VIABLE_CUT))", "marginal", "≈chance"]; position = :rt, framevisible = false, labelcolor = INK)
    save(joinpath(out, "signature_scatter.png"), fig; px_per_unit = 2)
    return fig
end

function main(args)
    sweep_path = length(args) >= 1 ? args[1] : newest("tracking_param_sweep")
    fact_path  = length(args) >= 2 ? args[2] : newest("tracking_leak_lrate_factorial")
    out = length(args) >= 3 ? args[3] : normpath(joinpath(@__DIR__, "..", "..", "site", "src", "assets", "experiments", "tracking-sweep"))
    mkpath(out)
    set_theme!(theme_neutral())
    sweep = readjson(sweep_path); fact = readjson(fact_path)
    println("sweep: ", sweep_path, "  (nseeds=", sweep.nseeds, ")")
    println("factorial: ", fact_path, "  (nseeds=", fact.nseeds, ")")
    fig_strips(sweep, out)
    fig_fracviable(sweep, out)
    fig_heatmap(fact, out)
    fig_signature(sweep, out)
    println("wrote figures to ", out)
end

main(ARGS)
