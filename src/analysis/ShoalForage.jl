using Statistics

function _require_shoal_forage(sim::SimResult, name::Symbol)
    sim.task === :shoal_forage || throw(ArgumentError(
        "$(name) requires a :shoal_forage simulation, got :$(sim.task)",
    ))
    return sim
end

function _shoal_evaluation_rows(sim::SimResult, channel::Symbol, warmup::Integer)
    samples = getchannel(sim.recorder, channel)
    isempty(samples) && throw(ArgumentError(
        "shoal analysis needs :$(channel) recorded",
    ))
    warmup_ = Int(warmup)
    warmup_ >= 0 || throw(ArgumentError("warmup must be non-negative"))
    every = Int(sim.config.every)
    rows = findall(index -> 1 + (index - 1) * every > warmup_, eachindex(samples))
    isempty(rows) && throw(ArgumentError(
        "warmup $(warmup_) leaves no recorded :$(channel) samples",
    ))
    return samples, rows
end

function _shoal_variable_config(sim::SimResult, name::Symbol)
    variables = sim.config.agents[1].body.physiology.variables
    index = findfirst(variable -> variable.name === name, variables)
    index === nothing && throw(ArgumentError("shoal physiology has no :$(name) variable"))
    return variables[index]
end

function _shoal_satisfaction(value::Real, variable)
    value_ = Float64(value)
    if variable.deficit.kind === :below_setpoint
        span = variable.setpoint - variable.minimum
        span <= 0.0 && return 1.0
        return clamp(1.0 - max(0.0, variable.setpoint - value_) / span, 0.0, 1.0)
    end
    throw(ArgumentError(
        "shoal satisfaction currently supports below-setpoint needs, got $(variable.deficit.kind)",
    ))
end

function _shoal_no_exposure_satisfaction(variable, tick::Integer)
    value = clamp(
        variable.initial + Int(tick) * variable.drift,
        variable.minimum,
        variable.maximum,
    )
    return _shoal_satisfaction(value, variable)
end

"""
    shoal_need_satisfaction(sim; warmup=1000, both_threshold=0.8)

Summarize the Experimental shoal-forage need trajectories. The primary value,
`mean_material_satisfaction`, averages normalized satisfaction across agents,
both resource needs, and evaluation samples. `balanced_material_satisfaction`
instead averages the lower of the two material satisfactions, while
`fraction_both_satisfied` reports the fraction of agent-samples where both are
at least `both_threshold`.

`material_regulation_gain` removes the deterministic no-contact trajectory
implied by each material need's initial state and drift:
`(observed - no_contact_floor) / (1 - no_contact_floor)`. This is useful when
screening need rates, where raw satisfaction is otherwise mechanically changed
by the imposed demand. It remains a descriptive normalization: changing drift
also changes when need feedback reaches the controller.

Association satisfaction is returned only when the association need is active;
the matched association-off receptor remains present but pinned at one and is
not treated as an outcome.
"""
function shoal_need_satisfaction(
    sim::SimResult;
    warmup::Integer=1000,
    both_threshold::Real=0.8,
)
    _require_shoal_forage(sim, :shoal_need_satisfaction)
    threshold = Float64(both_threshold)
    0.0 <= threshold <= 1.0 || throw(ArgumentError("both_threshold must lie in [0, 1]"))
    samples, rows = _shoal_evaluation_rows(sim, :needs, warmup)
    ids = samples[first(rows)].ids
    n_agents = length(ids)
    resource_1 = _shoal_variable_config(sim, :resource_1)
    resource_2 = _shoal_variable_config(sim, :resource_2)
    association = _shoal_variable_config(sim, :association)
    association_active = association.mode.kind !== :off

    material_sum = zeros(Float64, n_agents)
    balanced_sum = zeros(Float64, n_agents)
    both_count = zeros(Int, n_agents)
    association_sum = zeros(Float64, n_agents)
    for row in rows
        frame = align_entities(samples[row], ids)
        @inbounds for agent in 1:n_agents
            needs = frame[agent]
            s1 = _shoal_satisfaction(needs.resource_1, resource_1)
            s2 = _shoal_satisfaction(needs.resource_2, resource_2)
            material_sum[agent] += (s1 + s2) / 2.0
            balanced_sum[agent] += min(s1, s2)
            both_count[agent] += s1 >= threshold && s2 >= threshold
            association_active && (association_sum[agent] +=
                _shoal_satisfaction(needs.association, association))
        end
    end
    count = length(rows)
    no_contact_floor = mean(begin
        tick = 1 + (row - 1) * Int(sim.config.every)
        (
            _shoal_no_exposure_satisfaction(resource_1, tick) +
            _shoal_no_exposure_satisfaction(resource_2, tick)
        ) / 2.0
    end for row in rows)
    per_agent = [(
        entity_id=ids[agent],
        mean_material_satisfaction=material_sum[agent] / count,
        material_regulation_gain=(material_sum[agent] / count - no_contact_floor) /
            max(eps(Float64), 1.0 - no_contact_floor),
        balanced_material_satisfaction=balanced_sum[agent] / count,
        fraction_both_satisfied=both_count[agent] / count,
        association_satisfaction=association_active ? association_sum[agent] / count : nothing,
    ) for agent in 1:n_agents]
    return (
        evidence_status=:exploratory,
        warmup=Int(warmup),
        recorded_samples=count,
        both_threshold=threshold,
        material_no_contact_floor=no_contact_floor,
        mean_material_satisfaction=mean(row.mean_material_satisfaction for row in per_agent),
        material_regulation_gain=mean(row.material_regulation_gain for row in per_agent),
        balanced_material_satisfaction=mean(row.balanced_material_satisfaction for row in per_agent),
        fraction_both_satisfied=mean(row.fraction_both_satisfied for row in per_agent),
        association_satisfaction=association_active ?
            mean(row.association_satisfaction for row in per_agent) : nothing,
        per_agent=per_agent,
    )
end

"""
Summarize resource contacts and cross-resource alternation observed at recorder
samples after warmup.

This is a deliberately lightweight diagnostic. When `every > 1`, contacts
between recorder samples are not represented, so rates are sampled lower bounds
rather than exact collision counts. Need satisfaction remains the experiment's
primary endpoint.
"""
function shoal_contact_summary(sim::SimResult; warmup::Integer=1000)
    _require_shoal_forage(sim, :shoal_contact_summary)
    samples, rows = _shoal_evaluation_rows(sim, :interactions, warmup)
    ids = EntityID[id for id in sim.config.entity_ids]
    sequences = Dict(id => Symbol[] for id in ids)
    counts = Dict(id => Dict(:resource_1 => 0, :resource_2 => 0) for id in ids)
    for row in rows, event in samples[row]
        event.kind in (:resource_1, :resource_2) || continue
        push!(sequences[event.agent], event.kind)
        counts[event.agent][event.kind] += 1
    end
    evaluation_ticks = length(rows) * Int(sim.config.every)
    per_agent = map(ids) do id
        sequence = sequences[id]
        alternations = count(index -> sequence[index] != sequence[index - 1], 2:length(sequence))
        opportunities = max(0, length(sequence) - 1)
        total = length(sequence)
        (
            entity_id=id,
            resource_1_contacts=counts[id][:resource_1],
            resource_2_contacts=counts[id][:resource_2],
            contact_rate=total / evaluation_ticks,
            alternation_fraction=opportunities == 0 ? 0.0 : alternations / opportunities,
        )
    end
    return (
        warmup=Int(warmup),
        exact=false,
        sampling=:recorder_grid,
        record_every=Int(sim.config.every),
        mean_contact_rate=mean(row.contact_rate for row in per_agent),
        mean_alternation_fraction=mean(row.alternation_fraction for row in per_agent),
        per_agent,
    )
end

"""
    shoal_movement_summary(sim; warmup=1000, stationary_speed=1e-3, wall_band=1)

Recorded-pose movement diagnostics. Path length uses chords between recorded
poses and is therefore a lower bound when `every > 1`; mean speed divides each
chord by the corresponding tick interval.
"""
function shoal_movement_summary(
    sim::SimResult;
    warmup::Integer=1000,
    stationary_speed::Real=1.0e-3,
    wall_band::Real=1.0,
)
    _require_shoal_forage(sim, :shoal_movement_summary)
    samples, rows = _shoal_evaluation_rows(sim, :poses, warmup)
    length(rows) >= 2 || throw(ArgumentError("movement summary needs at least two evaluation samples"))
    ids = samples[first(rows)].ids
    n_agents = length(ids)
    every = Int(sim.config.every)
    arena_size_ = Float64(sim.config.environment.size)
    speed_threshold = Float64(stationary_speed)
    band = Float64(wall_band)
    path = zeros(Float64, n_agents)
    stationary = zeros(Int, n_agents)
    wall = zeros(Int, n_agents)
    transitions = length(rows) - 1
    for (row_index, row) in enumerate(rows)
        frame = align_entities(samples[row], ids)
        @inbounds for agent in 1:n_agents
            x, y, _ = frame[agent]
            min(x, arena_size_ - x, y, arena_size_ - y) <= band && (wall[agent] += 1)
            row_index == 1 && continue
            previous = align_entities(samples[rows[row_index - 1]], ids)[agent]
            distance = hypot(x - previous[1], y - previous[2])
            path[agent] += distance
            distance / every <= speed_threshold && (stationary[agent] += 1)
        end
    end
    per_agent = [(
        entity_id=ids[agent],
        recorded_path_length=path[agent],
        mean_recorded_speed=path[agent] / (transitions * every),
        stationary_fraction=stationary[agent] / transitions,
        wall_occupancy=wall[agent] / length(rows),
    ) for agent in 1:n_agents]
    return (
        warmup=Int(warmup),
        mean_recorded_path_length=mean(row.recorded_path_length for row in per_agent),
        mean_recorded_speed=mean(row.mean_recorded_speed for row in per_agent),
        stationary_fraction=mean(row.stationary_fraction for row in per_agent),
        wall_occupancy=mean(row.wall_occupancy for row in per_agent),
        per_agent,
    )
end

function _shoal_graph_edges(frame::EntityFrame, sensor, body_radius::Float64)
    sensor.mode === :blind && return Set{Tuple{UInt64,UInt64}}()
    edges = Set{Tuple{UInt64,UInt64}}()
    for observer in eachindex(frame)
        x, y, heading = frame[observer]
        nearest = fill((Inf, 0), sensor.channels)
        for target in eachindex(frame)
            target == observer && continue
            tx, ty, _ = frame[target]
            dx, dy = tx - x, ty - y
            centre_distance = hypot(dx, dy)
            surface_distance = centre_distance - 2.0 * body_radius
            surface_distance <= sensor.range || continue
            relative = atan(dy, dx) - heading
            sector_sensor = SectorVision(
                ConspecificSource();
                channels=sensor.channels,
                field_of_view=deg2rad(sensor.field_of_view_deg),
                max_range=sensor.range,
            )
            sector = _sector_index(sector_sensor, relative)
            sector === nothing && continue
            centre_distance < nearest[sector][1] &&
                (nearest[sector] = (centre_distance, target))
        end
        for (_, target) in nearest
            target == 0 && continue
            push!(edges, (frame.ids[observer].value, frame.ids[target].value))
        end
    end
    return edges
end

function _shoal_largest_weak_component(edges, ids)
    neighbors = Dict(id.value => Set{UInt64}() for id in ids)
    for (source, target) in edges
        push!(neighbors[source], target)
        push!(neighbors[target], source)
    end
    largest = 0
    seen = Set{UInt64}()
    for id in keys(neighbors)
        id in seen && continue
        stack = UInt64[id]
        push!(seen, id)
        size = 0
        while !isempty(stack)
            current = pop!(stack)
            size += 1
            for neighbor in neighbors[current]
                neighbor in seen && continue
                push!(seen, neighbor)
                push!(stack, neighbor)
            end
        end
        largest = max(largest, size)
    end
    return largest / length(ids)
end

function _shoal_proximity_edges(
    frame::EntityFrame,
    radius::Float64,
    body_radius::Float64,
)
    edges = Set{Tuple{UInt64,UInt64}}()
    for source in eachindex(frame), target in (source + 1):length(frame)
        sx, sy, _ = frame[source]
        tx, ty, _ = frame[target]
        hypot(tx - sx, ty - sy) - 2.0 * body_radius <= radius || continue
        push!(edges, (frame.ids[source].value, frame.ids[target].value))
    end
    return edges
end

function _shoal_mean_nearest_distance(frame::EntityFrame)
    length(frame) < 2 && return 0.0
    distances = Float64[]
    for source in eachindex(frame)
        sx, sy, _ = frame[source]
        nearest = Inf
        for target in eachindex(frame)
            source == target && continue
            tx, ty, _ = frame[target]
            nearest = min(nearest, hypot(tx - sx, ty - sy))
        end
        push!(distances, nearest)
    end
    return mean(distances)
end

"""
    shoal_group_movement_summary(sim; warmup=1000, grouping_radius=2)

Describe whether agents remain together and move together without collapsing
the two questions into a single score. Cohesion is reported as mean nearest-
neighbour distance and the mean fraction of agents in the largest undirected
proximity component. Movement coherence is the magnitude of the summed
recorded displacement vectors divided by summed displacement length, so it is
zero for cancelling directions and one for perfectly aligned movement.

Proximity values are exact at recorder samples. Displacement values use chords
between samples and are therefore recorder-grid diagnostics when `every > 1`.
"""
function shoal_group_movement_summary(
    sim::SimResult;
    warmup::Integer=1000,
    grouping_radius::Real=2.0,
)
    _require_shoal_forage(sim, :shoal_group_movement_summary)
    radius = Float64(grouping_radius)
    radius > 0.0 || throw(ArgumentError("grouping_radius must be positive"))
    samples, rows = _shoal_evaluation_rows(sim, :poses, warmup)
    length(rows) >= 2 || throw(ArgumentError(
        "group movement summary needs at least two evaluation samples",
    ))
    ids = samples[first(rows)].ids
    every = Int(sim.config.every)
    body_radius = Float64(sim.config.agents[1].body.geometry.radius)
    nearest = Float64[]
    components = Float64[]
    coherence = Float64[]
    translation_speed = Float64[]
    previous = nothing
    for row in rows
        frame = align_entities(samples[row], ids)
        push!(nearest, _shoal_mean_nearest_distance(frame))
        edges = _shoal_proximity_edges(frame, radius, body_radius)
        push!(components, _shoal_largest_weak_component(edges, ids))
        if previous !== nothing
            sum_x = 0.0
            sum_y = 0.0
            total_distance = 0.0
            for agent in eachindex(frame)
                dx = frame[agent][1] - previous[agent][1]
                dy = frame[agent][2] - previous[agent][2]
                sum_x += dx
                sum_y += dy
                total_distance += hypot(dx, dy)
            end
            push!(coherence, total_distance <= eps(Float64) ?
                0.0 : hypot(sum_x, sum_y) / total_distance)
            push!(translation_speed, hypot(sum_x, sum_y) / (length(frame) * every))
        end
        previous = frame
    end
    return (
        warmup=Int(warmup),
        grouping_radius=radius,
        record_every=every,
        mean_nearest_neighbor_distance=mean(nearest),
        largest_proximity_component_fraction=mean(components),
        movement_coherence=mean(coherence),
        group_translation_speed=mean(translation_speed),
        samples=length(rows),
    )
end

"""
    shoal_perceptual_graph(sim; warmup=1000)

Reconstruct the directed, sector-limited conspecific graph from recorded poses
using the run's exact sight geometry. At most the nearest target in each sector
creates an edge. Blind observations have no edges; bearing sham preserves edge
availability while corrupting the egocentric sector assignment. Edge turnover
is one minus consecutive-frame Jaccard similarity.
"""
function shoal_perceptual_graph(sim::SimResult; warmup::Integer=1000)
    _require_shoal_forage(sim, :shoal_perceptual_graph)
    samples, rows = _shoal_evaluation_rows(sim, :poses, warmup)
    body = sim.config.agents[1].body
    sensor = body.sensors[1]
    body_radius = Float64(body.geometry.radius)
    degrees = Float64[]
    components = Float64[]
    turnovers = Float64[]
    previous = nothing
    for row in rows
        frame = samples[row]
        edges = _shoal_graph_edges(frame, sensor, body_radius)
        push!(degrees, length(edges) / length(frame))
        push!(components, _shoal_largest_weak_component(edges, frame.ids))
        if previous !== nothing
            union_size = length(union(previous, edges))
            intersection_size = length(intersect(previous, edges))
            push!(turnovers, union_size == 0 ? 0.0 : 1.0 - intersection_size / union_size)
        end
        previous = edges
    end
    return (
        warmup=Int(warmup),
        mode=sensor.mode,
        conspecific_range=Float64(sensor.range),
        mean_degree=mean(degrees),
        largest_weak_component_fraction=mean(components),
        edge_turnover=isempty(turnovers) ? 0.0 : mean(turnovers),
        samples=length(rows),
    )
end

"""Return all registered exploratory summaries for one shoal-forage run."""
function shoal_experiment_summary(sim::SimResult; warmup::Integer=1000)
    return (
        needs=shoal_need_satisfaction(sim; warmup),
        contacts=shoal_contact_summary(sim; warmup),
        movement=shoal_movement_summary(sim; warmup),
        group_movement=shoal_group_movement_summary(sim; warmup),
        perceptual_graph=shoal_perceptual_graph(sim; warmup),
    )
end
