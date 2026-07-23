# Figures for the underpowered shoal operating-point sensitivity screen.
#
#   julia --project=experiments/figures \
#     experiments/figures/shoal_sensitivity_screen.jl [run_directory]

using CairoMakie
using Statistics

const INK = RGBf(0.38, 0.42, 0.48)
const ACCENT = RGBf(0.12, 0.47, 0.71)
const BLOCK = RGBf(0.52, 0.60, 0.68)

set_theme!(Theme(
    fontsize=12,
    figure_padding=12,
    Axis=(;
        backgroundcolor=:transparent,
        xgridcolor=(INK, 0.14),
        ygridvisible=false,
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

function parsed_rows(path)
    return [(
        block=parse(Int, row.block),
        axis=Symbol(row.axis),
        level=parse(Float64, row.level),
        material=parse(Float64, row.material_satisfaction_minus_baseline),
        regulation=parse(Float64, row.material_regulation_gain_minus_baseline),
        association=parse(Float64, row.association_satisfaction_minus_baseline),
        contact=parse(Float64, row.contact_rate_minus_baseline),
        speed=parse(Float64, row.speed_minus_baseline),
        wall=parse(Float64, row.wall_occupancy_minus_baseline),
        proximity=parse(Float64, row.proximity_component_minus_baseline),
        coherence=parse(Float64, row.movement_coherence_minus_baseline),
    ) for row in read_simple_csv(path)]
end

function axis_label(axis)
    labels = Dict(
        :conspecific_input_gain => "social input gain",
        :resource_input_gain => "resource input gain",
        :material_feedback_gain => "need-feedback gain",
        :material_drift => "need depletion / tick",
        :material_contact_restore => "contact replenishment",
        :conspecific_distance_exponent => "social distance exponent",
        :resource_distance_exponent => "resource distance exponent",
        :material_feedback_exponent => "need-feedback exponent",
        :material_feedback_emission_probability => "need-feedback probability",
        :source_range => "resource sight range",
        :association_drift => "social-need depletion / tick",
        :association_restore_max => "social restoration maximum",
        :association_proximity_radius => "social restoration radius",
        :association_target_neighbors => "social target neighbours",
        :association_feedback_gain => "social-feedback gain",
        :association_feedback_exponent => "social-feedback exponent",
        :association_feedback_emission_probability => "social-feedback probability",
    )
    return get(labels, axis, replace(string(axis), '_' => ' '))
end

format_level(level) = abs(level) < 0.01 ? string(round(level; sigdigits=2)) :
    string(round(level; digits=3))

function ordered_conditions(rows)
    order = (
        :conspecific_input_gain,
        :resource_input_gain,
        :material_feedback_gain,
        :material_drift,
        :material_contact_restore,
        :conspecific_distance_exponent,
        :resource_distance_exponent,
        :material_feedback_exponent,
        :material_feedback_emission_probability,
        :source_range,
        :association_drift,
        :association_restore_max,
        :association_proximity_radius,
        :association_target_neighbors,
        :association_feedback_gain,
        :association_feedback_exponent,
        :association_feedback_emission_probability,
    )
    return [(axis, level) for axis in order for level in
        sort!(unique(row.level for row in rows if row.axis === axis))]
end

function contrast_axis!(ax, rows, conditions, metric; labels=false)
    positions = reverse(collect(eachindex(conditions)))
    for (position, (axis, level)) in zip(positions, conditions)
        selected = [row for row in rows if row.axis === axis && row.level == level]
        values = getfield.(selected, metric)
        scatter!(ax, values, fill(position, length(values));
            color=(BLOCK, 0.55), markersize=7)
        scatter!(ax, [mean(values)], [position]; color=ACCENT, markersize=11)
    end
    vlines!(ax, [0.0]; color=(INK, 0.7), linestyle=:dash, linewidth=1.5)
    if labels
        ax.yticks = (
            positions,
            ["$(axis_label(axis)) = $(format_level(level))" for (axis, level) in conditions],
        )
    else
        ax.yticks = (positions, fill("", length(positions)))
    end
    return ax
end

function outcome_figure(rows, output)
    conditions = ordered_conditions(rows)
    fig = Figure(size=(1580, 1160))
    Label(fig[0, :], "One-factor sensitivity around the veridical association-on baseline";
        color=INK, fontsize=16, font=:bold)
    regulation = Axis(fig[1, 1];
        title="Demand-normalized material regulation",
        xlabel="difference from matched baseline",
    )
    association = Axis(fig[1, 2];
        title="Association satisfaction",
        xlabel="difference from matched baseline",
    )
    coherence = Axis(fig[1, 3];
        title="Movement coherence",
        xlabel="difference from matched baseline",
    )
    contrast_axis!(regulation, rows, conditions, :regulation; labels=true)
    contrast_axis!(association, rows, conditions, :association)
    contrast_axis!(coherence, rows, conditions, :coherence)
    Label(fig[2, :], "Small points are the two matched blocks; large points are their means. Exploratory screen only.";
        color=INK, fontsize=11)
    save(joinpath(output, "sensitivity_outcomes.png"), fig; px_per_unit=2)
    return fig
end

function diagnostic_figure(rows, output)
    conditions = ordered_conditions(rows)
    fig = Figure(size=(1580, 1160))
    Label(fig[0, :], "Sensitivity diagnostics: opportunity, boundary use, and physical grouping";
        color=INK, fontsize=16, font=:bold)
    for (column, (metric, title)) in enumerate((
        (:contact, "Sampled source-contact rate"),
        (:wall, "Wall occupancy"),
        (:proximity, "Proximity-connected fraction"),
    ))
        ax = Axis(fig[1, column]; title, xlabel="difference from matched baseline")
        contrast_axis!(ax, rows, conditions, metric; labels=column == 1)
    end
    Label(fig[2, :], "Contact rate is recorder-grid sampled, not an exact event count; all panels show descriptive differences.";
        color=INK, fontsize=11)
    save(joinpath(output, "sensitivity_diagnostics.png"), fig; px_per_unit=2)
    return fig
end

function main()
    length(ARGS) == 1 || error("usage: shoal_sensitivity_screen.jl RUN_DIRECTORY")
    run_dir = abspath(ARGS[1])
    rows = parsed_rows(joinpath(run_dir, "paired_contrasts.csv"))
    isempty(rows) && error("no sensitivity contrasts in $run_dir")
    output = joinpath(run_dir, "figures")
    mkpath(output)
    outcome_figure(rows, output)
    diagnostic_figure(rows, output)
    println(output)
end

main()
