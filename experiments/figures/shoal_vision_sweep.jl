# Figures for the exploratory moving-shoal vision sweep.
#
#   julia --project=experiments/figures \
#     experiments/figures/shoal_vision_sweep.jl [run_directory]

using CairoMakie
using Statistics

const INK = RGBf(0.38, 0.42, 0.48)
const VERIDICAL = RGBf(0.12, 0.47, 0.71)
const SHAM = RGBf(0.90, 0.45, 0.13)
const BLIND = RGBf(0.42, 0.42, 0.42)

set_theme!(Theme(
    fontsize=13,
    figure_padding=12,
    Axis=(;
        backgroundcolor=:transparent,
        xgridcolor=(INK, 0.14),
        ygridcolor=(INK, 0.14),
        topspinevisible=false,
        rightspinevisible=false,
        xlabelcolor=INK,
        ylabelcolor=INK,
        titlecolor=INK,
        xticklabelcolor=INK,
        yticklabelcolor=INK,
    ),
))

function read_simple_csv(path)
    lines = readlines(path)
    isempty(lines) && return NamedTuple[]
    names = Symbol.(split(first(lines), ','))
    return [NamedTuple{Tuple(names)}(Tuple(split(line, ','))) for line in lines[2:end] if !isempty(line)]
end

asbool(value) = value == "true"
asfloat(value) = parse(Float64, value)
asint(value) = parse(Int, value)

function parsed_rows(path)
    return [(
        block=asint(row.block),
        association_need=asbool(row.association_need),
        mode=Symbol(row.mode),
        range=asfloat(row.conspecific_range),
        material=asfloat(row.mean_material_satisfaction),
        balanced=asfloat(row.balanced_material_satisfaction),
        nearest=asfloat(row.mean_nearest_neighbor_distance),
        proximity_component=asfloat(row.largest_proximity_component_fraction),
        coherence=asfloat(row.movement_coherence),
        translation=asfloat(row.group_translation_speed),
        degree=asfloat(row.perceptual_graph_mean_degree),
        component=asfloat(row.perceptual_graph_largest_weak_component),
    ) for row in read_simple_csv(path)]
end

subset(rows, association, mode) =
    [row for row in rows if row.association_need == association && row.mode === mode]

function plot_condition!(ax, rows, association, mode, color; label, linestyle=:solid)
    selected = subset(rows, association, mode)
    ranges = sort!(unique(row.range for row in selected))
    for block in sort!(unique(row.block for row in selected))
        block_rows = sort!([row for row in selected if row.block == block]; by=row -> row.range)
        lines!(ax, getfield.(block_rows, :range), getfield.(block_rows, :material);
            color=(color, 0.24), linewidth=1)
        scatter!(ax, getfield.(block_rows, :range), getfield.(block_rows, :material);
            color=(color, 0.35), markersize=5)
    end
    means = [mean(row.material for row in selected if row.range == range) for range in ranges]
    lines!(ax, ranges, means; color, linewidth=3, linestyle, label)
    scatter!(ax, ranges, means; color, markersize=8)
end

function satisfaction_figure(rows, output)
    fig = Figure(size=(960, 420))
    Label(fig[0, :], "Exploratory material-need satisfaction across conspecific sight range";
        color=INK, fontsize=16, font=:bold)
    for (column, association) in enumerate((false, true))
        ax = Axis(fig[1, column];
            title=association ? "Association need on" : "Association need off",
            xlabel="conspecific sight range",
            ylabel=column == 1 ? "mean material satisfaction" : "",
        )
        plot_condition!(ax, rows, association, :veridical, VERIDICAL; label="veridical")
        plot_condition!(ax, rows, association, :bearing_sham, SHAM; label="bearing sham", linestyle=:dash)
        blind = subset(rows, association, :blind)
        blind_mean = mean(getfield.(blind, :material))
        hlines!(ax, [blind_mean]; color=BLIND, linewidth=2, linestyle=:dot, label="blind")
        for row in blind
            scatter!(ax, [minimum(getfield.(subset(rows, association, :veridical), :range))], [row.material];
                color=(BLIND, 0.35), markersize=5)
        end
        column == 2 && axislegend(ax; position=:rb, framevisible=false)
    end
    Label(fig[2, :], "Thin traces are matched blocks (n=2); heavy traces are block means. Descriptive pilot only.";
        color=INK, fontsize=11)
    save(joinpath(output, "material_satisfaction.png"), fig; px_per_unit=2)
    return fig
end

function grouped_movement_figure(rows, output)
    fig = Figure(size=(960, 720))
    Label(fig[0, :], "Grouped movement: physical cohesion and coordinated displacement";
        color=INK, fontsize=16, font=:bold)
    metrics = (
        (:proximity_component, "largest proximity-connected fraction"),
        (:coherence, "movement coherence"),
    )
    for (row_index, association) in enumerate((false, true)),
        (column, (metric, label)) in enumerate(metrics)
        ax = Axis(fig[row_index, column];
            title=(association ? "Association need on — " : "Association need off — ") * label,
            xlabel="conspecific sight range",
            ylabel=label,
        )
        for (mode, color, style, mode_label) in (
            (:veridical, VERIDICAL, :solid, "veridical"),
            (:bearing_sham, SHAM, :dash, "bearing sham"),
        )
            selected = subset(rows, association, mode)
            ranges = sort!(unique(row.range for row in selected))
            for block in sort!(unique(row.block for row in selected))
                block_rows = sort!([row for row in selected if row.block == block]; by=row -> row.range)
                lines!(ax, getfield.(block_rows, :range), getfield.(block_rows, metric);
                    color=(color, 0.24), linewidth=1)
                scatter!(ax, getfield.(block_rows, :range), getfield.(block_rows, metric);
                    color=(color, 0.35), markersize=5)
            end
            values = [mean(getfield(row, metric) for row in selected if row.range == range) for range in ranges]
            lines!(ax, ranges, values; color, linewidth=3, linestyle=style, label=mode_label)
            scatter!(ax, ranges, values; color, markersize=8)
        end
        blind = subset(rows, association, :blind)
        hlines!(ax, [mean(getfield(row, metric) for row in blind)];
            color=BLIND, linewidth=2, linestyle=:dot, label="blind")
        maximum_value = maximum(getfield(row, metric) for row in rows)
        ylims!(ax, 0, min(1.05, max(0.1, 1.2 * maximum_value)))
        row_index == 1 && column == 2 && axislegend(ax; position=:rb, framevisible=false)
    end
    Label(fig[3, :], "Proximity graph surface-distance radius = 2.0. Coherence = |Σ displacement| / Σ |displacement| on the recorder grid.";
        color=INK, fontsize=11)
    save(joinpath(output, "grouped_movement.png"), fig; px_per_unit=2)
    return fig
end

function graph_figure(rows, output)
    fig = Figure(size=(960, 420))
    Label(fig[0, :], "The moving ensemble writes a range-dependent perceptual graph";
        color=INK, fontsize=16, font=:bold)
    for (column, metric) in enumerate((:degree, :component))
        ax = Axis(fig[1, column];
            xlabel="conspecific sight range",
            ylabel=metric === :degree ? "mean out-degree" : "largest weak component",
            title=metric === :degree ? "Perceptual degree" : "Perceptual connectivity",
        )
        for (mode, color, style, label) in (
            (:veridical, VERIDICAL, :solid, "veridical"),
            (:bearing_sham, SHAM, :dash, "bearing sham"),
        )
            selected = [row for row in rows if row.mode === mode]
            ranges = sort!(unique(row.range for row in selected))
            values = [mean(getfield(row, metric) for row in selected if row.range == range) for range in ranges]
            lines!(ax, ranges, values; color, linewidth=3, linestyle=style, label)
            scatter!(ax, ranges, values; color, markersize=8)
        end
        metric === :component && ylims!(ax, 0, 1.05)
        column == 2 && axislegend(ax; position=:rb, framevisible=false)
    end
    Label(fig[2, :], "Graph edges are reconstructed from the nearest visible conspecific in each occupied sector.";
        color=INK, fontsize=11)
    save(joinpath(output, "perceptual_graph.png"), fig; px_per_unit=2)
    return fig
end

function main()
    length(ARGS) == 1 || error("usage: shoal_vision_sweep.jl RUN_DIRECTORY")
    run_dir = abspath(ARGS[1])
    rows = parsed_rows(joinpath(run_dir, "figure_inputs.csv"))
    isempty(rows) && error("no figure rows in $run_dir")
    output = joinpath(run_dir, "figures")
    mkpath(output)
    satisfaction_figure(rows, output)
    grouped_movement_figure(rows, output)
    graph_figure(rows, output)
    println(output)
end

main()
