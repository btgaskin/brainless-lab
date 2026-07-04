module Pipeline

using BrainlessLab
import CairoMakie
using Dates
using Random
using Statistics
using TOML

using ..Stats
using ..Store

export BenchConfig,
    read_bench_config,
    run_benchmark,
    parse_symbol_list,
    print_short_summary

const RECORD_CHANNELS = [:spikes, :rate, :poses, :polarization, :milling, :scene]

const _PAPER = CairoMakie.RGBf(BrainlessLab.BL_PAPER...)
const _INK = CairoMakie.RGBf(BrainlessLab.BL_INK...)
const _INKSOFT = CairoMakie.RGBf(BrainlessLab.BL_INKSOFT...)
const _GRID = CairoMakie.RGBf(BrainlessLab.BL_GRID...)
const _TEAL = CairoMakie.RGBf(BrainlessLab.BL_TEAL...)
const _AMBER = CairoMakie.RGBf(BrainlessLab.BL_AMBER...)
const _BRAND_RAMP = CairoMakie.cgrad([_PAPER, _TEAL, _INK])

_bench_figure(size) = CairoMakie.Figure(size=size, backgroundcolor=_PAPER)

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

const PANELS = Dict(
    :wall => [:raster, :rate, :trajectory],
    :tracking => [:raster, :rate],
    :pong => [:raster, :rate],
    :pong_hitrate => [:raster, :rate],
    :cartpole => [:raster, :rate],
    :cartpole_hard => [:raster, :rate],
    :cartpole_swingup => [:raster, :rate],
    :cartpole_long => [:raster, :rate],
    :torus => [:raster, :rate, :swarm],
)

Base.@kwdef struct BenchConfig
    neurons::Vector{Symbol}
    tasks::Vector{Symbol}
    n_trials::Int
    n_nodes::Int
    ticks::Int
    seed_base::Int
    baseline::Symbol
    alpha::Float64
    prep::Dict{Symbol,Symbol}
    gifs::Bool
end

struct CellMeta
    neuron::Symbol
    task::Symbol
    requested_prep::Symbol
    prep::Symbol
    flagged::String
    genome::Any
    tag::String
    store_entry::Any
end

struct TrialRow
    neuron::Symbol
    task::Symbol
    trial::Int
    seed::Int
    prep::Symbol
    flagged::String
    score::Float64
    norm_score::Float64
    alive::Bool
    rate_mean::Float64
end

default_config_path() = joinpath(Store.bench_dir(), "configs", "core.toml")

function parse_symbol_list(text)
    text === nothing && return nothing
    out = Symbol[]
    for part in split(String(text), ",")
        value = strip(part)
        isempty(value) || push!(out, Symbol(value))
    end
    return out
end

function _default_tasks()
    preferred = [:wall, :tracking, :pong, :cartpole, :cartpole_swingup]
    registered = Set(BrainlessLab.tasks())
    return [task for task in preferred if task in registered]
end

_default_neurons() = Symbol.(BrainlessLab.variants())

function default_prep(neuron::Symbol)
    name = String(neuron)
    startswith(name, "falandays") && return :untrained
    startswith(name, "compartmental") && return :trained
    occursin("ctrnn", lowercase(name)) && return :trained
    return :untrained
end

function _default_prep_map(neurons)
    return Dict{Symbol,Symbol}(neuron => default_prep(neuron) for neuron in neurons)
end

function _as_symbols(value, default)
    value === nothing && return copy(default)
    if value isa AbstractString
        parsed = parse_symbol_list(value)
        return isempty(parsed) ? copy(default) : parsed
    end
    values = collect(value)
    isempty(values) && return copy(default)
    return [Symbol(v) for v in values]
end

function _as_bool(value)
    value isa Bool && return value
    s = lowercase(strip(String(value)))
    s in ("true", "1", "yes", "y") && return true
    s in ("false", "0", "no", "n") && return false
    throw(ArgumentError("cannot parse boolean value $value"))
end

_get(data, key::String, default) = haskey(data, key) ? data[key] : default

function _prep_value(value)
    prep = Symbol(value)
    prep in (:untrained, :trained) || throw(ArgumentError("prep must be untrained or trained, got $value"))
    return prep
end

function read_bench_config(path::AbstractString=default_config_path();
        neurons_override=nothing, tasks_override=nothing, gifs_override=nothing)
    isfile(path) || throw(ArgumentError("benchmark config not found: $path"))
    data = TOML.parsefile(path)

    neurons = neurons_override === nothing ?
        _as_symbols(_get(data, "neurons", Symbol[]), _default_neurons()) :
        _as_symbols(neurons_override, _default_neurons())

    tasks = tasks_override === nothing ?
        _as_symbols(_get(data, "tasks", Symbol[]), _default_tasks()) :
        _as_symbols(tasks_override, _default_tasks())

    prep = _default_prep_map(neurons)
    prep_table = _get(data, "prep", Dict{String,Any}())
    for (key, value) in prep_table
        prep[Symbol(key)] = _prep_value(value)
    end
    prep = Dict{Symbol,Symbol}(neuron => get(prep, neuron, default_prep(neuron)) for neuron in neurons)

    gifs_value = gifs_override === nothing ? _as_bool(_get(data, "gifs", true)) : Bool(gifs_override)

    return BenchConfig(
        neurons=neurons,
        tasks=tasks,
        n_trials=Int(_get(data, "n_trials", 20)),
        n_nodes=Int(_get(data, "n_nodes", 120)),
        ticks=Int(_get(data, "ticks", 300)),
        seed_base=Int(_get(data, "seed_base", 1000)),
        baseline=Symbol(_get(data, "baseline", "falandays_base")),
        alpha=Float64(_get(data, "alpha", 0.05)),
        prep=prep,
        gifs=gifs_value,
    )
end

function _config_dict(cfg::BenchConfig)
    prep_pairs = sort(collect(cfg.prep); by=pair -> String(pair.first))
    return Dict{String,Any}(
        "neurons" => String.(cfg.neurons),
        "tasks" => String.(cfg.tasks),
        "n_trials" => cfg.n_trials,
        "n_nodes" => cfg.n_nodes,
        "ticks" => cfg.ticks,
        "seed_base" => cfg.seed_base,
        "baseline" => String(cfg.baseline),
        "alpha" => cfg.alpha,
        "gifs" => cfg.gifs,
        "prep" => Dict{String,Any}(String(k) => String(v) for (k, v) in prep_pairs),
    )
end

_is_falandays(neuron::Symbol) = startswith(String(neuron), "falandays")
_is_compartmental(neuron::Symbol) = startswith(String(neuron), "compartmental")
_model_family(neuron::Symbol) = _is_compartmental(neuron) ? :compartmental : :falandays

function _default_model(neuron::Symbol)
    _is_falandays(neuron) && return BrainlessLab.FalandaysParams()
    neuron == :compartmental_dense && return zeros(Float64, BrainlessLab.paramdim(BrainlessLab.DenseCompartmental))
    neuron == :compartmental_structured && return zeros(Float64, BrainlessLab.paramdim(BrainlessLab.StructuredCompartmental))
    return BrainlessLab.FalandaysParams()
end

function _genome_kwargs(neuron::Symbol, genome)
    if _is_falandays(neuron)
        return Dict{Symbol,Any}(:params => genome)
    end
    return Dict{Symbol,Any}(:raw => genome)
end

function _cell_meta(cfg::BenchConfig, neuron::Symbol, task::Symbol)
    requested = get(cfg.prep, neuron, default_prep(neuron))
    if requested == :trained
        entry = Store.load_genome_entry(Store.bench_dir(), neuron, task)
        if entry === nothing
            return CellMeta(neuron, task, requested, :untrained, "trained-required-but-untrained", nothing, "", nothing)
        end
        genome = Vector{Float64}(Float64.(entry.genome))
        return CellMeta(neuron, task, requested, :trained, "", genome, String(entry.tag), entry)
    end

    return CellMeta(neuron, task, requested, :untrained, "", nothing, "", nothing)
end

function _run_cell(cfg::BenchConfig, meta::CellMeta)
    task_spec = BrainlessLab.resolve_task(meta.task)
    model = meta.prep == :trained ? meta.genome : _default_model(meta.neuron)

    rows = BrainlessLab.parallel_map(1:cfg.n_trials) do trial
        seed = cfg.seed_base + trial
        out = BrainlessLab.rollout(
            task_spec,
            model,
            seed;
            model_sym=meta.neuron,
            N=cfg.n_nodes,
            ticks=cfg.ticks,
        )
        return TrialRow(
            meta.neuron,
            meta.task,
            trial,
            seed,
            meta.prep,
            meta.flagged,
            Float64(out.score),
            Float64(out.norm_score),
            Bool(out.alive),
            Float64(out.rate_mean),
        )
    end

    return rows
end

function _csv_field(value)
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
        println(io, join(_csv_field.(header), ","))
        for row in rows
            println(io, join(_csv_field.(row), ","))
        end
    end
    return path
end

function _write_results_raw(path::AbstractString, rows::Vector{TrialRow})
    header = [:neuron, :task, :trial, :seed, :prep, :flagged, :score, :norm_score, :alive, :rate_mean]
    body = [
        (
            row.neuron,
            row.task,
            row.trial,
            row.seed,
            row.prep,
            row.flagged,
            row.score,
            row.norm_score,
            row.alive,
            row.rate_mean,
        )
        for row in rows
    ]
    return _write_csv(path, header, body)
end

function _rows_for(rows::Vector{TrialRow}, neuron::Symbol, task::Symbol)
    return [row for row in rows if row.neuron == neuron && row.task == task]
end

function _summary_for(meta::CellMeta, rows::Vector{TrialRow}, rng::AbstractRNG)
    xs = [row.norm_score for row in rows]
    n = length(xs)
    ci_lo, ci_hi = Stats.bootstrap_ci(xs; rng=rng)
    return (
        neuron=meta.neuron,
        task=meta.task,
        prep=meta.prep,
        tag_or_blank=meta.tag,
        flagged=meta.flagged,
        n=n,
        mean=n == 0 ? NaN : Statistics.mean(xs),
        std=n >= 2 ? Statistics.std(xs) : 0.0,
        ci_lo=ci_lo,
        ci_hi=ci_hi,
        median=n == 0 ? NaN : Statistics.median(xs),
        min=n == 0 ? NaN : minimum(xs),
        max=n == 0 ? NaN : maximum(xs),
    )
end

function _summary_rows(cfg::BenchConfig, rows::Vector{TrialRow}, metas, rng::AbstractRNG)
    summaries = NamedTuple[]
    for task in cfg.tasks
        for neuron in cfg.neurons
            meta = metas[(neuron, task)]
            push!(summaries, _summary_for(meta, _rows_for(rows, neuron, task), rng))
        end
    end
    return summaries
end

function _write_summary_csv(path::AbstractString, summaries)
    header = [:neuron, :task, :prep, :tag_or_blank, :flagged, :n, :mean, :std, :ci_lo, :ci_hi, :median, :min, :max]
    body = [
        (
            row.neuron,
            row.task,
            row.prep,
            row.tag_or_blank,
            row.flagged,
            row.n,
            row.mean,
            row.std,
            row.ci_lo,
            row.ci_hi,
            row.median,
            row.min,
            row.max,
        )
        for row in summaries
    ]
    return _write_csv(path, header, body)
end

function _write_cell_scores(path::AbstractString, rows::Vector{TrialRow})
    header = [:trial, :seed, :prep, :flagged, :score, :norm_score, :alive, :rate_mean]
    body = [
        (row.trial, row.seed, row.prep, row.flagged, row.score, row.norm_score, row.alive, row.rate_mean)
        for row in rows
    ]
    return _write_csv(path, header, body)
end

function _trial_picks(rows::Vector{TrialRow})
    sorted = sort(rows; by=row -> row.norm_score)
    isempty(sorted) && throw(ArgumentError("cannot pick artifacts from an empty cell"))
    return Dict(
        :best => sorted[end],
        :representative => sorted[cld(length(sorted), 2)],
        :worst => sorted[1],
    )
end

_panels_for_task(task::Symbol) = get(PANELS, task, [:raster, :rate])

function _simulate_kwargs(meta::CellMeta, cfg::BenchConfig, seed::Integer)
    kwargs = Dict{Symbol,Any}(
        :node => meta.neuron,
        :seed => Int(seed),
        :n_nodes => cfg.n_nodes,
        :ticks => cfg.ticks,
        :record => RECORD_CHANNELS,
    )

    if meta.prep == :trained && meta.genome !== nothing
        for (key, value) in _genome_kwargs(meta.neuron, meta.genome)
            kwargs[key] = value
        end
    end

    return kwargs
end

function _simulate_trial(meta::CellMeta, cfg::BenchConfig, row::TrialRow)
    kwargs = _simulate_kwargs(meta, cfg, row.seed)
    return BrainlessLab.simulate(meta.task; kwargs...)
end

function _write_cell_artifacts(run_dir::AbstractString, cfg::BenchConfig, meta::CellMeta, rows::Vector{TrialRow})
    cell_dir = joinpath(run_dir, "cells", Store.genome_key(meta.neuron, meta.task))
    mkpath(cell_dir)
    _write_cell_scores(joinpath(cell_dir, "scores.csv"), rows)

    if meta.prep == :trained && meta.store_entry !== nothing
        Store.copy_entry_to_cell(meta.store_entry, cell_dir)
    end

    picks = _trial_picks(rows)
    representative_sim = nothing

    if cfg.gifs
        sims = BrainlessLab.parallel_map((:best, :representative, :worst)) do label
            return (label=label, sim=_simulate_trial(meta, cfg, picks[label]))
        end
        for item in sims
            item.label == :representative && (representative_sim = item.sim)
            Base.invokelatest(
                BrainlessLab.animate,
                item.sim;
                path=joinpath(cell_dir, "$(String(item.label)).gif"),
                framerate=20,
            )
        end
    end

    if representative_sim === nothing
        representative_sim = _simulate_trial(meta, cfg, picks[:representative])
    end

    fig = Base.invokelatest(BrainlessLab.visualize, representative_sim; panels=_panels_for_task(meta.task))
    Base.invokelatest(CairoMakie.save, joinpath(cell_dir, "figure.png"), fig)
    return cell_dir
end

function _finite_max(values; default=1.0)
    best = Float64(default)
    for value in values
        if value isa Real && isfinite(Float64(value))
            best = max(best, Float64(value))
        end
    end
    return best
end

function _summary_lookup(summaries)
    return Dict{Tuple{Symbol,Symbol},Any}((row.neuron, row.task) => row for row in summaries)
end

function _write_plots(run_dir::AbstractString, cfg::BenchConfig, summaries)
    figures_dir = joinpath(run_dir, "figures")
    mkpath(figures_dir)
    lookup = _summary_lookup(summaries)

    z = Matrix{Float64}(undef, length(cfg.tasks), length(cfg.neurons))
    for (i, task) in enumerate(cfg.tasks)
        for (j, neuron) in enumerate(cfg.neurons)
            row = lookup[(neuron, task)]
            z[i, j] = Float64(row.mean)
        end
    end

    heatmap_fig = _bench_figure((max(700, 110 * length(cfg.tasks) + 220), max(420, 28 * length(cfg.neurons) + 140)))
    heatmap_ax = CairoMakie.Axis(
        heatmap_fig[1, 1];
        xlabel="task",
        ylabel="neuron",
        xticks=(collect(1:length(cfg.tasks)), String.(cfg.tasks)),
        yticks=(collect(1:length(cfg.neurons)), String.(cfg.neurons)),
        xticklabelrotation=pi / 4,
    )
    _style_axis!(heatmap_ax)
    hm = CairoMakie.heatmap!(heatmap_ax, collect(1:length(cfg.tasks)), collect(1:length(cfg.neurons)), z; colormap=_BRAND_RAMP)
    CairoMakie.Colorbar(heatmap_fig[1, 2], hm; label="mean normalized score", labelcolor=_INKSOFT, ticklabelcolor=_INKSOFT)
    Base.invokelatest(CairoMakie.save, joinpath(figures_dir, "heatmap.png"), heatmap_fig)

    for task in cfg.tasks
        rows = [lookup[(neuron, task)] for neuron in cfg.neurons]
        xs = collect(1:length(rows))
        means = [Float64(row.mean) for row in rows]
        lows = [max(0.0, Float64(row.mean) - Float64(row.ci_lo)) for row in rows]
        highs = [max(0.0, Float64(row.ci_hi) - Float64(row.mean)) for row in rows]

        fig = _bench_figure((max(760, 95 * length(rows) + 220), 460))
        ax = CairoMakie.Axis(
            fig[1, 1];
            xlabel="neuron",
            ylabel="normalized score",
            title=String(task),
            xticks=(xs, String.(cfg.neurons)),
            xticklabelrotation=pi / 4,
        )
        _style_axis!(ax)
        CairoMakie.barplot!(ax, xs, means; color=_TEAL)
        CairoMakie.errorbars!(ax, xs, means, lows, highs; color=_INK, whiskerwidth=8)
        CairoMakie.hlines!(ax, [0.0]; color=(_AMBER, 0.45), linewidth=1.0)
        CairoMakie.ylims!(ax, 0.0, max(1.0, 1.08 * _finite_max(vcat(means, means .+ highs))))
        Base.invokelatest(CairoMakie.save, joinpath(figures_dir, "$(String(task))_bars.png"), fig)
    end

    return figures_dir
end

function _task_groups(cfg::BenchConfig, rows::Vector{TrialRow}, task::Symbol)
    groups = Dict{Symbol,Vector{Float64}}()
    for neuron in cfg.neurons
        groups[neuron] = [row.norm_score for row in rows if row.task == task && row.neuron == neuron]
    end
    return groups
end

function _rowdict(row)
    out = Dict{String,Any}()
    for (key, value) in pairs(row)
        out[String(key)] = value isa Symbol ? String(value) : value
    end
    return out
end

function _apply_bh!(stats_data::Dict{String,Any})
    refs = Dict{String,Any}[]
    pvals = Float64[]

    for task_stats in values(stats_data["tasks"])
        for table_name in ("pairwise", "baseline")
            for row in task_stats[table_name]
                p = get(row, "p", NaN)
                if p isa Real && isfinite(Float64(p))
                    push!(refs, row)
                    push!(pvals, Float64(p))
                else
                    row["bh_q"] = nothing
                end
            end
        end
    end

    qvals = Stats.benjamini_hochberg(pvals)
    for (row, q) in zip(refs, qvals)
        row["bh_q"] = q
    end

    return stats_data
end

function _build_stats_json(cfg::BenchConfig, rows::Vector{TrialRow}, summaries, rng::AbstractRNG)
    task_stats = Dict{String,Any}()

    for task in cfg.tasks
        analysis = Stats.analyze_task(
            _task_groups(cfg, rows, task);
            baseline=cfg.baseline,
            alpha=cfg.alpha,
            rng=rng,
        )
        task_stats[String(task)] = Dict{String,Any}(
            "omnibus_kw_p" => analysis.omnibus_kw_p,
            "pairwise" => [_rowdict(row) for row in analysis.pairwise],
            "baseline" => [_rowdict(row) for row in analysis.baseline],
        )
    end

    flagged = [
        Dict{String,Any}("neuron" => String(row.neuron), "task" => String(row.task), "flagged" => row.flagged)
        for row in summaries if !isempty(row.flagged)
    ]

    stats_data = Dict{String,Any}(
        "alpha" => cfg.alpha,
        "baseline" => String(cfg.baseline),
        "tasks" => task_stats,
        "flagged_cells" => flagged,
    )
    return _apply_bh!(stats_data)
end

function _json_escape(text::AbstractString)
    escaped = replace(text, "\\" => "\\\\")
    escaped = replace(escaped, "\"" => "\\\"")
    escaped = replace(escaped, "\n" => "\\n")
    escaped = replace(escaped, "\r" => "\\r")
    escaped = replace(escaped, "\t" => "\\t")
    return escaped
end

function _write_json(io, value)
    if value === nothing || value isa Missing
        print(io, "null")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa AbstractString
        print(io, "\"", _json_escape(value), "\"")
    elseif value isa Symbol
        print(io, "\"", _json_escape(String(value)), "\"")
    elseif value isa Integer
        print(io, value)
    elseif value isa AbstractFloat
        print(io, isfinite(value) ? string(value) : "null")
    elseif value isa Real
        print(io, string(value))
    elseif value isa NamedTuple
        _write_json(io, Dict{String,Any}(String(k) => v for (k, v) in pairs(value)))
    elseif value isa AbstractDict
        print(io, "{")
        items = sort(collect(pairs(value)); by=pair -> string(pair.first))
        for (i, pair) in enumerate(items)
            i > 1 && print(io, ",")
            _write_json(io, string(pair.first))
            print(io, ":")
            _write_json(io, pair.second)
        end
        print(io, "}")
    elseif value isa Tuple || value isa AbstractVector
        print(io, "[")
        for (i, item) in enumerate(value)
            i > 1 && print(io, ",")
            _write_json(io, item)
        end
        print(io, "]")
    else
        _write_json(io, string(value))
    end
end

function _write_json_file(path::AbstractString, data)
    mkpath(dirname(path))
    open(path, "w") do io
        _write_json(io, data)
        println(io)
    end
    return path
end

function _fmt(value; digits::Integer=3)
    value === nothing && return "NA"
    if value isa Real && isfinite(Float64(value))
        return string(round(Float64(value); digits=digits))
    end
    return "NA"
end

function _summary_markdown_table(cfg::BenchConfig, summaries)
    lookup = _summary_lookup(summaries)
    lines = String[]
    push!(lines, "| neuron | " * join(String.(cfg.tasks), " | ") * " |")
    push!(lines, "|---|" * join(fill("---", length(cfg.tasks)), "|") * "|")
    for neuron in cfg.neurons
        cells = String[]
        for task in cfg.tasks
            row = lookup[(neuron, task)]
            push!(cells, "$(_fmt(row.mean)) [$(_fmt(row.ci_lo)), $(_fmt(row.ci_hi))]")
        end
        push!(lines, "| $(String(neuron)) | " * join(cells, " | ") * " |")
    end
    return lines
end

function _is_significant(row, alpha::Real)
    p = get(row, "holm_p", Inf)
    return p isa Real && isfinite(Float64(p)) && Float64(p) < alpha
end

function _write_report(path::AbstractString, cfg::BenchConfig, summaries, stats_data)
    flagged = [row for row in summaries if !isempty(row.flagged)]

    open(path, "w") do io
        println(io, "# BrainlessLab core benchmark")
        println(io)
        println(io, "Normalized scores are reported as mean with 95% bootstrap CI.")
        println(io)
        for line in _summary_markdown_table(cfg, summaries)
            println(io, line)
        end

        println(io)
        println(io, "## Significant baseline-relative findings")
        any_sig = false
        for task in cfg.tasks
            task_data = stats_data["tasks"][String(task)]
            sig_rows = [row for row in task_data["baseline"] if _is_significant(row, cfg.alpha)]
            isempty(sig_rows) && continue
            any_sig = true
            println(io)
            println(io, "### $(String(task))")
            println(io, "| neuron | delta_mean | CI | p | holm_p | bh_q | cliffs_delta | power | min_n_for_080 |")
            println(io, "|---|---:|---:|---:|---:|---:|---:|---:|---:|")
            for row in sig_rows
                ci = "[$(_fmt(row["delta_ci_lo"])), $(_fmt(row["delta_ci_hi"]))]"
                println(io, "| $(row["neuron"]) | $(_fmt(row["delta_mean"])) | $ci | $(_fmt(row["p"])) | $(_fmt(row["holm_p"])) | $(_fmt(row["bh_q"])) | $(_fmt(row["cliffs_delta"])) | $(_fmt(row["achieved_power"])) | $(row["min_n_for_080"] === nothing ? "NA" : string(row["min_n_for_080"])) |")
            end
        end
        any_sig || println(io, "No Holm-significant baseline-relative findings at alpha=$(cfg.alpha).")

        println(io)
        println(io, "## Flagged cells")
        if isempty(flagged)
            println(io, "None.")
        else
            println(io, "| neuron | task | flag |")
            println(io, "|---|---|---|")
            for row in flagged
                println(io, "| $(String(row.neuron)) | $(String(row.task)) | $(row.flagged) |")
            end
        end

        println(io)
        println(io, "## Caveat")
        println(io, "Falandays-family cells default to untrained online-plastic rollouts, where wiring is seeded per trial and learning occurs during the rollout. Compartmental or other non-plastic cells default to trained genomes because untrained weights are not a meaningful fair baseline. If a trained-required genome was missing, the cell was run with the untrained fallback and flagged.")
    end

    return path
end

function _run_id(cfg::BenchConfig)
    parts = String[]
    append!(parts, String.(cfg.neurons))
    append!(parts, String.(cfg.tasks))
    append!(parts, string.([cfg.n_trials, cfg.n_nodes, cfg.ticks, cfg.seed_base, cfg.alpha, cfg.gifs]))
    append!(parts, [String(cfg.baseline)])
    for pair in sort(collect(cfg.prep); by=pair -> String(pair.first))
        push!(parts, "$(String(pair.first))=$(String(pair.second))")
    end
    return Store.text_tag(join(parts, "|"); n=8)
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

function _manifest_run_config(cfg::BenchConfig)
    return BrainlessLab.resolve(BrainlessLab.RunConfig(
        run=BrainlessLab.RunSection(
            name="bench_grid",
            runner=:fixed,
            seed_base=cfg.seed_base,
            suite_seed_base=cfg.seed_base + 100_000,
            profile=:none,
        ),
        model=BrainlessLab.ModelSection(
            family=_model_family(cfg.baseline),
            node=cfg.baseline,
        ),
        task=BrainlessLab.TaskSection(
            train=Tuple(cfg.tasks),
            suite=Tuple(cfg.tasks),
            aggregator=:mean,
            N=cfg.n_nodes,
            ticks=cfg.ticks,
            window=cfg.ticks,
        ),
        evolve=BrainlessLab.EvolveSection(
            generations=1,
            popsize=2,
            k_trials=max(1, cfg.n_trials),
            suite_every=0,
            k_suite=0,
            cma_seed=cfg.seed_base,
            threaded=false,
        ),
    ))
end

function _seed_manifest(cfg::BenchConfig)
    return Dict{String,Any}(
        "seed_base" => cfg.seed_base,
        "trials_per_cell" => cfg.n_trials,
        "resolved" => [cfg.seed_base + trial for trial in 1:cfg.n_trials],
        "scheme" => "bench eval_seed = seed_base + trial_index for every neuron x task cell",
    )
end

function _make_run_dir(cfg::BenchConfig, out_root::AbstractString)
    git = Store.git_sha(Store.repo_root())
    short = Store.short_git(git)
    stamp = Store.timestamp_utc()
    run_id = _run_id(cfg)
    base = joinpath(out_root, "$(stamp)_$(short)_$(run_id)")
    dir = base
    suffix = 2
    while isdir(dir)
        dir = "$(base)_$(suffix)"
        suffix += 1
    end
    mkpath(dir)
    return (dir=dir, timestamp_utc=stamp, git_sha=git, short_git=short, run_id=run_id)
end

function _manifest_dict(cfg::BenchConfig, run_info)
    manifest = BrainlessLab.capture_manifest(_manifest_run_config(cfg); seeds=_seed_manifest(cfg), tool=:bench)
    manifest["timestamp_utc"] = run_info.timestamp_utc
    manifest["run_id"] = run_info.run_id
    manifest["short_git"] = run_info.short_git
    manifest["bench"] = merge(
        _config_dict(cfg),
        Dict{String,Any}(
            "job" => "cross-node comparison",
            "output_shape" => "manifest.toml + config.resolved.toml + summary.csv + results_raw.csv + stats.json + figures/*.png + cells/*/{scores.csv,figure.png,*.gif} + README.md",
        ),
    )
    manifest["tool_packages"] = _tool_package_versions(Store.bench_dir())
    return manifest
end

function _overall_ranking(cfg::BenchConfig, summaries)
    lookup = _summary_lookup(summaries)
    rows = NamedTuple[]
    for neuron in cfg.neurons
        values = Float64[]
        for task in cfg.tasks
            row = lookup[(neuron, task)]
            isfinite(Float64(row.mean)) && push!(values, Float64(row.mean))
        end
        push!(rows, (
            neuron=neuron,
            mean=isempty(values) ? NaN : Statistics.mean(values),
            n_tasks=length(values),
        ))
    end
    return sort(rows; by=row -> (isfinite(row.mean) ? row.mean : -Inf), rev=true)
end

function _write_readme(path::AbstractString, cfg::BenchConfig, summaries, stats_data)
    ranking = _overall_ranking(cfg, summaries)
    top = isempty(ranking) ? nothing : first(ranking)
    flagged = [row for row in summaries if !isempty(row.flagged)]

    open(path, "w") do io
        println(io, "# Benchmark run")
        println(io)
        if top === nothing || !isfinite(top.mean)
            println(io, "> Ranking: no finite benchmark scores were produced.")
        else
            println(io, "> Ranking: `:$(top.neuron)` leads across $(top.n_tasks) task(s) with mean normalized score $(_fmt(top.mean)).")
        end
        println(io)
        println(io, "Job: cross-node comparison. Scores are baseline-relative/statistical evidence inputs, not a single-node analytic profile.")
        println(io)
        println(io, "Primary outputs:")
        println(io, "- `summary.csv` -- per-neuron x task summary statistics.")
        println(io, "- `results_raw.csv` -- raw per-trial scores.")
        println(io, "- `stats.json` -- omnibus, pairwise, and baseline-relative nonparametric tests.")
        println(io, "- `figures/` -- house-palette comparison heatmap and task bars.")
        println(io, "- `cells/` -- per-cell scores, representative figure, and best/representative/worst GIFs when enabled.")
        println(io)
        println(io, "## Overall Ranking")
        println(io)
        println(io, "| rank | neuron | mean normalized score | tasks |")
        println(io, "|---:|---|---:|---:|")
        for (i, row) in enumerate(ranking)
            println(io, "| $(i) | `:$(row.neuron)` | $(_fmt(row.mean)) | $(row.n_tasks) |")
        end
        println(io)
        println(io, "Baseline: `:$(cfg.baseline)`; alpha = $(cfg.alpha); trials per cell = $(cfg.n_trials).")
        println(io)
        println(io, "Flagged cells: $(length(flagged)).")
        if !isempty(flagged)
            println(io)
            println(io, "| neuron | task | flag |")
            println(io, "|---|---|---|")
            for row in flagged
                println(io, "| `:$(row.neuron)` | `:$(row.task)` | $(row.flagged) |")
            end
        end
    end
    return path
end

function run_benchmark(cfg::BenchConfig; out_root::AbstractString=joinpath(Store.bench_dir(), "runs"))
    BrainlessLab.init_parallelism!(verbose=true)

    run_info = _make_run_dir(cfg, out_root)
    run_dir = run_info.dir

    Store.write_toml(joinpath(run_dir, BrainlessLab.resolved_config_filename()), _config_dict(cfg))
    Store.write_toml(joinpath(run_dir, "manifest.toml"), _manifest_dict(cfg, run_info))

    metas = Dict{Tuple{Symbol,Symbol},CellMeta}()
    ordered_metas = CellMeta[]

    for task in cfg.tasks
        BrainlessLab.resolve_task(task)
        for neuron in cfg.neurons
            meta = _cell_meta(cfg, neuron, task)
            metas[(neuron, task)] = meta
            push!(ordered_metas, meta)
        end
    end

    cell_rows = BrainlessLab.parallel_map(meta -> _run_cell(cfg, meta), ordered_metas)
    rows = TrialRow[]
    for chunk in cell_rows
        append!(rows, chunk)
    end

    _write_results_raw(joinpath(run_dir, "results_raw.csv"), rows)

    summaries = _summary_rows(cfg, rows, metas, Random.Xoshiro(cfg.seed_base + 1))
    _write_summary_csv(joinpath(run_dir, "summary.csv"), summaries)

    stats_data = _build_stats_json(cfg, rows, summaries, Random.Xoshiro(cfg.seed_base + 2))
    _write_json_file(joinpath(run_dir, "stats.json"), stats_data)

    for task in cfg.tasks
        for neuron in cfg.neurons
            meta = metas[(neuron, task)]
            _write_cell_artifacts(run_dir, cfg, meta, _rows_for(rows, neuron, task))
        end
    end

    _write_plots(run_dir, cfg, summaries)
    _write_report(joinpath(run_dir, "report.md"), cfg, summaries, stats_data)
    _write_readme(joinpath(run_dir, "README.md"), cfg, summaries, stats_data)

    return (dir=run_dir, summaries=summaries, stats=stats_data)
end

function print_short_summary(summaries; io=stdout)
    tasks = Symbol[]
    neurons = Symbol[]
    for row in summaries
        row.task in tasks || push!(tasks, row.task)
        row.neuron in neurons || push!(neurons, row.neuron)
    end

    lookup = _summary_lookup(summaries)
    println(io, "neuron\t", join(String.(tasks), "\t"))
    for neuron in neurons
        cells = String[]
        for task in tasks
            push!(cells, _fmt(lookup[(neuron, task)].mean))
        end
        println(io, String(neuron), "\t", join(cells, "\t"))
    end
end

end
