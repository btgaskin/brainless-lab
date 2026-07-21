using Random

"""Stable identity for an object instance, retained across depletion and respawn."""
struct ObjectID
    value::UInt64

    function ObjectID(value::Integer)
        value >= 1 || throw(ArgumentError("ObjectID must be positive, got $(value)"))
        return new(UInt64(value))
    end
end

Base.convert(::Type{UInt64}, id::ObjectID) = id.value
Base.show(io::IO, id::ObjectID) = print(io, "ObjectID(", id.value, ")")

"""One stable, identity-aware contact recorded by an [`ObjectWorld`](@ref)."""
struct ObjectInteractionEvent
    agent::EntityID
    object::ObjectID
    kind::Symbol
end

mutable struct ObjectWorldState
    id::ObjectID
    type_index::Int
    position::NTuple{2,Float64}
    origin::NTuple{2,Float64}
    remaining::Int
    active::Bool
    respawn_timer::Int
end

"""
    ObjectWorld(arena, states; populations=(), fields=NamedTuple(),
                illuminant=nothing, rng=MersenneTwister(0))

A bounded physical object world for composed [`Embodiment`](@ref) bodies.
Each body owns its geometry, sensors, actuator, dynamics, and physiology. The
world owns planar motion states, static object instances, named analytic scalar
fields, contact/depletion/respawn state, and stable interaction identities.

The built-in runtime deliberately supports one actuator command and one
dynamics component per body. Sensor widths and layouts remain per-body, so
blind and heterogeneous populations do not need a uniform sensor-bank schema.
When `illuminant=nothing`, each spectral camera receives a unit illuminant on
its own wavelength grid.
"""
mutable struct ObjectWorld{
    A<:Union{Torus,WalledArena},
    K<:Tuple,
    F<:NamedTuple,
    I<:Union{Nothing,SpectralIlluminant},
    R<:AbstractRNG,
    L<:Tuple,
} <: Environment
    arena::A
    initial_states::Vector{MotionState2D}
    states::Vector{MotionState2D}
    object_types::K
    objects::Vector{ObjectWorldState}
    fields::F
    illuminant::I
    relations::L
    initial_rng::R
    rng::R
    entity_ids::Vector{EntityID}
    initial_active_agents::BitVector
    active_agents::BitVector
    last_interactions::Vector{ObjectInteractionEvent}
    interaction_effects::Vector{Vector{Any}}
    tick::Int
end

_copy_motion_state(state::MotionState2D) = MotionState2D(
    position=state.position,
    heading=state.heading,
    velocity=state.velocity,
    angular_velocity=state.angular_velocity,
)

function _object_world_states(states)
    out = MotionState2D[_copy_motion_state(state) for state in states]
    isempty(out) && throw(ArgumentError("ObjectWorld requires at least one motion state"))
    return out
end

function _object_world_fields(fields::NamedTuple)
    all(field -> field isa AbstractSpatialField, values(fields)) || throw(ArgumentError(
        "ObjectWorld named fields must all subtype AbstractSpatialField",
    ))
    return fields
end

function _object_world_objects(
    populations::Tuple,
    arena::Union{Torus,WalledArena},
)
    all(population -> population isa ObjectPopulation, populations) || throw(ArgumentError(
        "ObjectWorld populations must all be ObjectPopulation values",
    ))
    kinds = ObjectType[]
    objects = ObjectWorldState[]
    next_id = 1
    for population in populations
        kind = population.kind
        type_index = findfirst(candidate -> candidate.name === kind.name, kinds)
        if type_index === nothing
            push!(kinds, kind)
            type_index = length(kinds)
        elseif !_same_object_policy(kinds[type_index], kind)
            throw(ArgumentError(
                "ObjectWorld populations sharing name :$(kind.name) must share one ObjectType policy",
            ))
        end
        for position in population.positions
            placed = first(arena_position(
                arena,
                position[1],
                position[2],
                kind.radius,
            ))
            push!(objects, ObjectWorldState(
                ObjectID(next_id),
                type_index,
                placed,
                placed,
                something(kind.capacity, typemax(Int)),
                true,
                -1,
            ))
            next_id += 1
        end
    end
    return Tuple(kinds), objects
end

function ObjectWorld(
    arena::Union{Torus,WalledArena},
    states;
    populations=(),
    fields::NamedTuple=NamedTuple(),
    illuminant::Union{Nothing,SpectralIlluminant}=nothing,
    rng::AbstractRNG=MersenneTwister(0),
    relations=(),
)
    states_ = _object_world_states(states)
    populations_ = Tuple(populations)
    kinds, objects = _object_world_objects(populations_, arena)
    fields_ = _object_world_fields(fields)
    relations_ = Tuple(relations)
    all(relation -> relation isa AbstractWorldRelation, relations_) || throw(ArgumentError(
        "ObjectWorld relations must all subtype AbstractWorldRelation",
    ))
    ids = EntityID.(1:length(states_))
    effects = [Any[] for _ in states_]
    initial_rng = deepcopy(rng)
    runtime_rng = deepcopy(rng)
    active = trues(length(states_))
    return ObjectWorld{
        typeof(arena),typeof(kinds),typeof(fields_),typeof(illuminant),typeof(rng),typeof(relations_),
    }(
        arena,
        _copy_motion_state.(states_),
        states_,
        kinds,
        objects,
        fields_,
        illuminant,
        relations_,
        initial_rng,
        runtime_rng,
        ids,
        copy(active),
        active,
        ObjectInteractionEvent[],
        effects,
        0,
    )
end

"""Observer identity and population context supplied to physical sensors."""
struct ObjectWorldSensorContext{B}
    slot::Int
    entity_id::EntityID
    bodies::B
end

function sync_activity!(world::ObjectWorld, bodies)
    length(bodies) == length(world.active_agents) || throw(DimensionMismatch(
        "ObjectWorld has $(length(world.active_agents)) slots for $(length(bodies)) bodies",
    ))
    capture_initial = world.tick == 0
    @inbounds for index in eachindex(bodies)
        active = alive(bodies[index])
        world.active_agents[index] = active
        capture_initial && (world.initial_active_agents[index] = active)
        if !active
            world.states[index].velocity = (0.0, 0.0)
            world.states[index].angular_velocity = 0.0
        end
    end
    return nothing
end

function bind_entity_ids!(world::ObjectWorld, ids)
    values = EntityID[id isa EntityID ? id : EntityID(id) for id in ids]
    length(values) == length(world.states) || throw(DimensionMismatch(
        "ObjectWorld has $(length(world.states)) slots but received $(length(values)) entity IDs",
    ))
    length(unique(values)) == length(values) ||
        throw(ArgumentError("ObjectWorld entity IDs must be unique"))
    world.entity_ids = values
    return nothing
end

"""Return the stable interaction events produced by the most recent world step."""
interaction_events(world::ObjectWorld) = copy(world.last_interactions)

function object_snapshot(world::ObjectWorld)
    return map(world.objects) do object
        kind = world.object_types[object.type_index]
        (
            id=object.id,
            type_index=object.type_index,
            kind=kind.name,
            bank=kind.bank,
            position=object.position,
            radius=kind.radius,
            active=object.active,
            remaining=object.remaining,
            capacity=kind.capacity,
            respawn_timer=object.respawn_timer,
            appearance=kind.appearance,
        )
    end
end

function _world_illuminant(world::ObjectWorld, camera::SpectralCamera)
    world.illuminant === nothing &&
        return SpectralIlluminant(camera.grid, ones(length(camera.grid)))
    return world.illuminant
end

function _spectral_object_targets(world::ObjectWorld)
    targets = SpectralCircleTarget{ObjectID}[]
    for object in world.objects
        object.active || continue
        kind = world.object_types[object.type_index]
        appearance = kind.appearance
        appearance isa SpectralAppearance || continue
        push!(targets, SpectralCircleTarget(
            object.id,
            object.position,
            kind.radius,
            spectral_reflectance(appearance),
        ))
    end
    return targets
end

"""
    sample_world_sensor!(sensor, world, state)

Sample one sensor component against an `ObjectWorld`. Extend this function for
custom physical sensors. Built-in methods cover spectral cameras, named mounted
field probes, and zero-valued direct relays used for deliberately blind bodies.
"""
function sample_world_sensor!(sensor::AbstractSensor, world::ObjectWorld, state::MotionState2D)
    throw(ArgumentError(
        "ObjectWorld sampling is not implemented for sensor $(typeof(sensor)); " *
        "extend sample_world_sensor! for this sensor/world pair",
    ))
end

# Existing third-party ObjectWorld sensors retain their three-argument
# extension contract. Observer-aware sensors opt into this overload.
sample_world_sensor!(
    sensor::AbstractSensor,
    world::ObjectWorld,
    state::MotionState2D,
    context::ObjectWorldSensorContext,
) = sample_world_sensor!(sensor, world, state)

function sample_world_sensor!(
    camera::SpectralCamera,
    world::ObjectWorld,
    state::MotionState2D,
)
    sampled = sample_spectral_camera(
        camera,
        state.position,
        state.heading,
        _spectral_object_targets(world),
        _world_illuminant(world, camera),
        world.arena,
    )
    return sampled.values
end

function sample_world_sensor!(
    probe::MountedFieldProbe,
    world::ObjectWorld,
    state::MotionState2D,
)
    hasproperty(world.fields, probe.channel) || throw(ArgumentError(
        "ObjectWorld has no analytic field named :$(probe.channel)",
    ))
    field = getproperty(world.fields, probe.channel)
    return sample!(probe, field, state.position, state.heading, world.tick, world.arena)
end

sample_world_sensor!(sensor::DirectRelaySensor, world::ObjectWorld, state::MotionState2D) =
    zeros(Float64, n_sensors(sensor))

function _accumulate_sector_target!(
    values::Vector{Float64},
    sensor::SectorVision,
    world::ObjectWorld,
    state::MotionState2D,
    target_position,
    target_radius::Real,
    observer_radius::Real,
)
    bearing = arena_bearing(world.arena, state.position, target_position)
    sector = _sector_index(sensor, bearing - state.heading)
    sector === nothing && return values
    centre_distance = arena_distance(world.arena, state.position, target_position)
    surface_distance = centre_distance - Float64(observer_radius) - Float64(target_radius)
    activation = _sector_activation(
        surface_distance,
        sensor.max_range,
        sensor.gain,
        sensor.distance_exponent,
    )
    values[sector] = max(values[sector], activation)
    return values
end

function sample_world_sensor!(
    sensor::SectorVision{<:ObjectSource},
    world::ObjectWorld,
    state::MotionState2D,
    context::ObjectWorldSensorContext,
)
    values = zeros(Float64, sensor.channels)
    sensor.mode === :blind && return values
    observer = context.bodies[context.slot]
    observer isa Embodiment || throw(ArgumentError(
        "SectorVision requires an Embodiment observer",
    ))
    channel = source_name(sensor.source)
    for object in world.objects
        object.active || continue
        kind = world.object_types[object.type_index]
        kind.bank === channel || continue
        _accumulate_sector_target!(
            values,
            sensor,
            world,
            state,
            object.position,
            kind.radius,
            geometry_radius(observer.geometry),
        )
    end
    return _apply_sector_mode!(values, sensor, context.entity_id.value, world.tick)
end

function sample_world_sensor!(
    sensor::SectorVision{ConspecificSource},
    world::ObjectWorld,
    state::MotionState2D,
    context::ObjectWorldSensorContext,
)
    values = zeros(Float64, sensor.channels)
    sensor.mode === :blind && return values
    observer = context.bodies[context.slot]
    observer isa Embodiment || throw(ArgumentError(
        "SectorVision requires an Embodiment observer",
    ))
    observer_radius = geometry_radius(observer.geometry)
    for target_slot in eachindex(world.states)
        target_slot == context.slot && continue
        world.active_agents[target_slot] || continue
        target = context.bodies[target_slot]
        target isa Embodiment || throw(ArgumentError(
            "SectorVision requires Embodiment conspecifics",
        ))
        _accumulate_sector_target!(
            values,
            sensor,
            world,
            state,
            world.states[target_slot].position,
            geometry_radius(target.geometry),
            observer_radius,
        )
    end
    return _apply_sector_mode!(values, sensor, context.entity_id.value, world.tick)
end

function _sample_object_world_body(
    world::ObjectWorld,
    body::Embodiment,
    state::MotionState2D,
    context::ObjectWorldSensorContext,
)
    samples = Tuple(
        sample_world_sensor!(sensor, world, state, context)
        for sensor in sensor_components(body)
    )
    return length(samples) == 1 ? only(samples) : samples
end

function sample!(world::ObjectWorld, bodies)
    length(bodies) == length(world.states) || throw(DimensionMismatch(
        "ObjectWorld has $(length(world.states)) states for $(length(bodies)) bodies",
    ))
    output = Vector{Any}(undef, length(bodies))
    @inbounds for index in eachindex(bodies)
        body = bodies[index]
        body isa Embodiment || throw(ArgumentError(
            "ObjectWorld requires composed Embodiment bodies; got $(typeof(body))",
        ))
        context = ObjectWorldSensorContext(index, world.entity_ids[index], bodies)
        output[index] = alive(body) ?
            _sample_object_world_body(world, body, world.states[index], context) :
            _inactive_sensor_samples(body)
    end
    return output
end

function apply_world_relation!(
    world::ObjectWorld,
    bodies,
    relation::ProximityExposure,
)
    @inbounds for observer_slot in eachindex(bodies)
        world.active_agents[observer_slot] || continue
        observer = bodies[observer_slot]
        observer isa Embodiment || continue
        observer_radius = geometry_radius(observer.geometry)
        weight = 0.0
        for target_slot in eachindex(bodies)
            target_slot == observer_slot && continue
            world.active_agents[target_slot] || continue
            target = bodies[target_slot]
            target isa Embodiment || continue
            surface_distance = arena_distance(
                world.arena,
                world.states[observer_slot].position,
                world.states[target_slot].position,
            ) - observer_radius - geometry_radius(target.geometry)
            weight += clamp(1.0 - max(0.0, surface_distance) / relation.radius, 0.0, 1.0)
        end
        level = clamp(weight / relation.target_neighbors, 0.0, 1.0)
        level > 0.0 && push!(
            world.interaction_effects[observer_slot],
            Exposure(relation.name, relation.amount * level),
        )
    end
    return nothing
end

function apply_world_relation!(
    world::ObjectWorld,
    bodies,
    relation::AbstractWorldRelation,
)
    throw(ArgumentError(
        "no ObjectWorld relation implementation for $(typeof(relation)); " *
        "extend BrainlessLab.apply_world_relation!",
    ))
end

function _apply_world_relations!(world::ObjectWorld, bodies)
    for relation in world.relations
        apply_world_relation!(world, bodies, relation)
    end
    return nothing
end

_object_world_respawn_delay(::NoRespawn) = nothing
_object_world_respawn_delay(policy::Union{SamePositionRespawn,UniformRespawn}) = policy.delay

_object_world_respawn_position(::SamePositionRespawn, object::ObjectWorldState, world::ObjectWorld) =
    object.origin
_object_world_respawn_position(::UniformRespawn, object::ObjectWorldState, world::ObjectWorld) =
    sample_position(
        world.rng,
        world.arena;
        radius=world.object_types[object.type_index].radius,
    )

function _tick_object_world_respawns!(world::ObjectWorld)
    for object in world.objects
        object.active && continue
        kind = world.object_types[object.type_index]
        delay = _object_world_respawn_delay(kind.respawn)
        delay === nothing && continue
        if object.respawn_timer == 0
            object.position = _object_world_respawn_position(kind.respawn, object, world)
            object.remaining = something(kind.capacity, typemax(Int))
            object.active = true
        else
            object.respawn_timer -= 1
        end
    end
    return nothing
end

prepare_step!(world::ObjectWorld, bodies) = _tick_object_world_respawns!(world)

function _integrate_object_world_body!(
    world::ObjectWorld,
    body::Embodiment,
    state::MotionState2D,
    command,
)
    length(actuator_components(body)) == 1 || throw(ArgumentError(
        "ObjectWorld currently supports exactly one actuator command per body",
    ))
    command isa Tuple && throw(ArgumentError(
        "ObjectWorld currently supports exactly one actuator command per body",
    ))
    applicable(integrate!, state, body.dynamics, command) || throw(ArgumentError(
        "ObjectWorld cannot integrate $(typeof(command)) with $(typeof(body.dynamics))",
    ))
    integrate!(state, body.dynamics, command)
    _project_motion!(state, world.arena, body.geometry)
    return state
end

function _contact_slots(world::ObjectWorld, bodies, object::ObjectWorldState, kind::ObjectType)
    slots = Int[]
    @inbounds for index in eachindex(bodies)
        body = bodies[index]
        alive(body) || continue
        distance = arena_distance(world.arena, world.states[index].position, object.position)
        distance <= geometry_radius(body.geometry) + kind.radius || continue
        push!(slots, index)
    end
    return slots
end

function _object_world_interactions!(world::ObjectWorld, bodies)
    empty!(world.last_interactions)
    for effects in world.interaction_effects
        empty!(effects)
    end
    for object in world.objects
        object.active || continue
        kind = world.object_types[object.type_index]
        contenders = _contact_slots(world, bodies, object, kind)
        isempty(contenders) && continue
        recipients = if kind.capacity === nothing
            contenders
        else
            # Draw from stable-ID order so a seeded world remains independent
            # of heterogeneous grouping and slot iteration order without
            # permanently favouring the lowest identity.
            sort!(contenders; by=index -> world.entity_ids[index].value)
            recipient = length(contenders) == 1 ? only(contenders) : rand(world.rng, contenders)
            (recipient,)
        end
        for index in recipients
            append!(world.interaction_effects[index], kind.effects)
            push!(world.last_interactions, ObjectInteractionEvent(
                world.entity_ids[index],
                object.id,
                kind.name,
            ))
        end
        kind.capacity === nothing && continue
        object.remaining -= 1
        if object.remaining <= 0
            object.active = false
            delay = _object_world_respawn_delay(kind.respawn)
            object.respawn_timer = something(delay, -1)
        end
    end
    _apply_world_relations!(world, bodies)
    return world.interaction_effects
end

function apply_commands!(world::ObjectWorld, bodies, commands)
    length(bodies) == length(world.states) == length(commands) ||
        throw(DimensionMismatch("ObjectWorld requires one command per body"))
    @inbounds for index in eachindex(bodies)
        body = bodies[index]
        body isa Embodiment || throw(ArgumentError(
            "ObjectWorld requires composed Embodiment bodies; got $(typeof(body))",
        ))
        alive(body) || continue
        _integrate_object_world_body!(
            world,
            body,
            world.states[index],
            commands[index],
        )
    end
    world.tick += 1
    return _object_world_interactions!(world, bodies)
end

function reset!(world::ObjectWorld)
    for index in eachindex(world.states)
        initial = world.initial_states[index]
        state = world.states[index]
        state.position = initial.position
        state.heading = initial.heading
        state.velocity = initial.velocity
        state.angular_velocity = initial.angular_velocity
        if !world.initial_active_agents[index]
            state.velocity = (0.0, 0.0)
            state.angular_velocity = 0.0
        end
    end
    for object in world.objects
        kind = world.object_types[object.type_index]
        object.position = object.origin
        object.remaining = something(kind.capacity, typemax(Int))
        object.active = true
        object.respawn_timer = -1
    end
    empty!(world.last_interactions)
    foreach(empty!, world.interaction_effects)
    world.rng = deepcopy(world.initial_rng)
    copyto!(world.active_agents, world.initial_active_agents)
    world.tick = 0
    return world
end

function _active_mean_speed(world::ObjectWorld)
    return _active_mean_speed(world.states, world.active_agents)
end

metrics(world::ObjectWorld, window::Integer=1) = (
    mean_speed=_active_mean_speed(world),
    active_count=count(identity, world.active_agents),
    active_fraction=_active_fraction(world.active_agents),
    active_objects=count(object -> object.active, world.objects),
    contacts=length(world.last_interactions),
)

function _pose_payload(world::ObjectWorld, bodies)
    return NTuple{3,Float64}[
        (state.position[1], state.position[2], state.heading) for state in world.states
    ]
end

_motion_state_config(state::MotionState2D) = (
    position=Tuple(state.position),
    heading=state.heading,
    velocity=Tuple(state.velocity),
    angular_velocity=state.angular_velocity,
)

_world_relation_config(relation::ProximityExposure) = (
    kind=:proximity_exposure,
    name=relation.name,
    radius=relation.radius,
    amount=relation.amount,
    target_neighbors=relation.target_neighbors,
)

_world_relation_config(relation::AbstractWorldRelation) = (
    kind=:custom,
    type=_config_type(relation),
)

function _environment_config(world::ObjectWorld)
    illuminant = world.illuminant === nothing ? nothing : (
        wavelengths_nm=Tuple(world.illuminant.grid.wavelengths_nm),
        values=Tuple(world.illuminant.values),
    )
    return (
        kind=:object_world,
        arena=Symbol(lowercase(string(nameof(typeof(world.arena))))),
        bounds=arena_bounds(world.arena),
        size=arena_size(world.arena),
        entity_ids=Tuple(world.entity_ids),
        initial_states=Tuple(_motion_state_config(state) for state in world.initial_states),
        object_types=Tuple(_object_type_config(kind) for kind in world.object_types),
        objects=Tuple((
            id=object.id,
            type_index=object.type_index,
            origin=object.origin,
        ) for object in world.objects),
        fields=Tuple((name=name, field=_spatial_field_config(field)) for (name, field) in pairs(world.fields)),
        illuminant=illuminant,
        relations=Tuple(_world_relation_config(relation) for relation in world.relations),
        rng_type=_config_type(world.rng),
    )
end
