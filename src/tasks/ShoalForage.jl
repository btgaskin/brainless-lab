using Random

const SHOAL_FORAGE_ARENA_SIZE = 20.0
const SHOAL_FORAGE_BODY_RADIUS = 0.25
const SHOAL_FORAGE_SOURCE_RADIUS = 1.0
const SHOAL_FORAGE_SOURCE_RANGE = 6.0
const SHOAL_FORAGE_SECTORS = 16
const SHOAL_FORAGE_FIELD_OF_VIEW = deg2rad(300.0)

"""
    ShoalForageSetup()

Experimental two-resource collective-foraging setup. Sixteen disc-bodied
agents use independent canonical Falandays reservoirs through three matched
16-sector visual banks (conspecifics, resource 1, resource 2), three regulated
needs, and antagonistic turn plus thrust outputs.

This is an experiment scaffold rather than a calibrated benchmark. It has no
scalar task objective and does not imply that the untrained reference node will
discover useful foraging behavior.
"""
struct ShoalForageSetup end

is_multiagent(::ShoalForageSetup) = true
environment_type(::ShoalForageSetup) = ObjectWorld

function _shoal_source_positions(block::Integer)
    block_ = Int(block)
    block_ >= 1 || throw(ArgumentError("shoal-forage block must be positive"))
    quarter_turns = mod(block_ - 1, 4)
    points = ((5.0, 10.0), (15.0, 10.0))
    transform(point) = begin
        x, y = point[1] - 10.0, point[2] - 10.0
        rotated = if quarter_turns == 0
            (x, y)
        elseif quarter_turns == 1
            (-y, x)
        elseif quarter_turns == 2
            (-x, -y)
        else
            (y, -x)
        end
        (rotated[1] + 10.0, rotated[2] + 10.0)
    end
    transformed = transform.(points)
    return iseven(block_) ? reverse(transformed) : transformed
end

function _shoal_initial_states(
    rng::AbstractRNG,
    n_agents::Integer,
    source_positions,
)
    count = Int(n_agents)
    count >= 1 || throw(ArgumentError("shoal-forage n_agents must be positive"))
    states = MotionState2D[]
    arena = WalledArena(SHOAL_FORAGE_ARENA_SIZE)
    minimum_agent_distance = 2.0 * SHOAL_FORAGE_BODY_RADIUS
    minimum_source_distance = SHOAL_FORAGE_BODY_RADIUS + SHOAL_FORAGE_SOURCE_RADIUS
    attempts = 0
    while length(states) < count
        attempts += 1
        attempts <= 100_000 || throw(ArgumentError(
            "could not place $(count) non-overlapping shoal agents",
        ))
        position = sample_position(rng, arena; radius=SHOAL_FORAGE_BODY_RADIUS)
        all(arena_distance(arena, position, source) > minimum_source_distance for source in source_positions) ||
            continue
        all(arena_distance(arena, position, state.position) > minimum_agent_distance for state in states) ||
            continue
        push!(states, MotionState2D(
            position=position,
            heading=2pi * rand(rng),
            velocity=(0.0, 0.0),
            angular_velocity=0.0,
        ))
    end
    return states
end

function _shoal_need(
    name::Symbol;
    drift::Real=-0.001,
    feedback_gain::Real=1.0,
    feedback_exponent::Real=1.0,
    feedback_emission_probability::Real=0.2,
)
    exponent = Float64(feedback_exponent)
    curve = exponent == 1.0 ? LinearFeedback() : PowerFeedback(exponent)
    return RegulatedVariable(
        name;
        minimum=0.0,
        maximum=1.0,
        initial=1.0,
        setpoint=1.0,
        drift,
        deficit=BelowSetpoint(),
        curve,
        mode=BernoulliFeedback(),
        gain=feedback_gain,
        emission_p=feedback_emission_probability,
        failure=NoFailure(),
    )
end

function _shoal_association_need(
    enabled::Bool;
    drift::Real=-0.001,
    feedback_gain::Real=1.0,
    feedback_exponent::Real=1.0,
    feedback_emission_probability::Real=0.2,
)
    enabled && return _shoal_need(
        :association;
        drift,
        feedback_gain,
        feedback_exponent,
        feedback_emission_probability,
    )
    return RegulatedVariable(
        :association;
        minimum=0.0,
        maximum=1.0,
        initial=1.0,
        setpoint=1.0,
        drift=0.0,
        deficit=BelowSetpoint(),
        curve=LinearFeedback(),
        mode=OffFeedback(),
        gain=1.0,
        emission_p=0.2,
        failure=NoFailure(),
    )
end

function _shoal_body(
    agent_index::Integer,
    seed::Integer;
    association_need::Bool,
    conspecific_mode::Symbol,
    conspecific_range::Real,
    source_range::Real,
    conspecific_input_gain::Real,
    resource_input_gain::Real,
    conspecific_distance_exponent::Real,
    resource_distance_exponent::Real,
    material_drift::Real,
    material_feedback_gain::Real,
    material_feedback_exponent::Real,
    material_feedback_emission_probability::Real,
    association_drift::Real,
    association_feedback_gain::Real,
    association_feedback_exponent::Real,
    association_feedback_emission_probability::Real,
    sham_seed::Integer,
)
    sensors = (
        SectorVision(
            ConspecificSource();
            channels=SHOAL_FORAGE_SECTORS,
            field_of_view=SHOAL_FORAGE_FIELD_OF_VIEW,
            max_range=conspecific_range,
            gain=conspecific_input_gain,
            distance_exponent=conspecific_distance_exponent,
            mode=conspecific_mode,
            sham_seed=sham_seed,
        ),
        SectorVision(
            ObjectSource(:resource_1);
            channels=SHOAL_FORAGE_SECTORS,
            field_of_view=SHOAL_FORAGE_FIELD_OF_VIEW,
            max_range=source_range,
            gain=resource_input_gain,
            distance_exponent=resource_distance_exponent,
        ),
        SectorVision(
            ObjectSource(:resource_2);
            channels=SHOAL_FORAGE_SECTORS,
            field_of_view=SHOAL_FORAGE_FIELD_OF_VIEW,
            max_range=source_range,
            gain=resource_input_gain,
            distance_exponent=resource_distance_exponent,
        ),
    )
    sensor_ids = (:conspecific_vision, :resource_1_vision, :resource_2_vision)
    encoders = Tuple(
        IdentityEncoder(sensor.channels; prefix=id, sources=(id,))
        for (id, sensor) in zip(sensor_ids, sensors)
    )
    physiology = RegulatedPhysiology((
        _shoal_need(
            :resource_1;
            drift=material_drift,
            feedback_gain=material_feedback_gain,
            feedback_exponent=material_feedback_exponent,
            feedback_emission_probability=material_feedback_emission_probability,
        ),
        _shoal_need(
            :resource_2;
            drift=material_drift,
            feedback_gain=material_feedback_gain,
            feedback_exponent=material_feedback_exponent,
            feedback_emission_probability=material_feedback_emission_probability,
        ),
        _shoal_association_need(
            association_need;
            drift=association_drift,
            feedback_gain=association_feedback_gain,
            feedback_exponent=association_feedback_exponent,
            feedback_emission_probability=association_feedback_emission_probability,
        ),
    ); seed=Int(seed) + 10_000 + Int(agent_index))
    return Embodiment(
        geometry=DiscGeometry(SHOAL_FORAGE_BODY_RADIUS),
        sensors=sensors,
        encoders=encoders,
        actuators=(AntagonisticTurnActuator(
            max_forward_speed=0.2,
            max_turn_rate=pi / 8.0,
        ),),
        dynamics=UnicycleDynamics(dt=1.0, linear_tau=5.0, angular_tau=5.0),
        physiology=physiology,
        traits=(experimental=true, morphology=:fish_like),
        component_ids=(
            geometry=:fish_geometry,
            sensors=sensor_ids,
            encoders=(:conspecific_encoder, :resource_1_encoder, :resource_2_encoder),
            actuators=(:swim_motor,),
            dynamics=:swim_dynamics,
            physiology=:needs,
        ),
    )
end

function (::ShoalForageSetup)(;
    seed::Integer=0,
    rng=nothing,
    body=nothing,
    n_nodes::Integer=250,
    n_agents::Integer=16,
    block::Integer=1,
    association_need::Bool=true,
    conspecific_mode::Symbol=:veridical,
    conspecific_range::Real=5.0,
    source_range::Real=SHOAL_FORAGE_SOURCE_RANGE,
    conspecific_input_gain::Real=1.0,
    resource_input_gain::Real=1.0,
    conspecific_distance_exponent::Real=1.0,
    resource_distance_exponent::Real=1.0,
    material_drift::Real=-0.001,
    material_contact_restore::Real=0.01,
    material_feedback_gain::Real=1.0,
    material_feedback_exponent::Real=1.0,
    material_feedback_emission_probability::Real=0.2,
    association_drift::Real=-0.001,
    association_restore_max::Real=0.004,
    association_proximity_radius::Real=2.0,
    association_target_neighbors::Real=2.0,
    association_feedback_gain::Real=1.0,
    association_feedback_exponent::Real=1.0,
    association_feedback_emission_probability::Real=0.2,
    sham_seed::Integer=91_337,
    kwargs...,
)
    isempty(kwargs) || throw(ArgumentError(
        "unsupported shoal-forage options: $(sort!(collect(keys(kwargs))))",
    ))
    body === nothing || throw(ArgumentError(
        ":shoal_forage fixes its Experimental fish embodiment; body overrides are not supported",
    ))
    Int(n_nodes) >= 1 || throw(ArgumentError("n_nodes must be positive"))
    Int(n_agents) >= 2 || throw(ArgumentError("shoal-forage requires at least two agents"))
    conspecific_mode in (:veridical, :blind, :bearing_sham) || throw(ArgumentError(
        "conspecific_mode must be :veridical, :blind, or :bearing_sham",
    ))
    conspecific_range_ = Float64(conspecific_range)
    source_range_ = Float64(source_range)
    conspecific_input_gain_ = Float64(conspecific_input_gain)
    resource_input_gain_ = Float64(resource_input_gain)
    conspecific_distance_exponent_ = Float64(conspecific_distance_exponent)
    resource_distance_exponent_ = Float64(resource_distance_exponent)
    material_drift_ = Float64(material_drift)
    material_contact_restore_ = Float64(material_contact_restore)
    material_feedback_gain_ = Float64(material_feedback_gain)
    material_feedback_exponent_ = Float64(material_feedback_exponent)
    material_feedback_emission_probability_ = Float64(material_feedback_emission_probability)
    association_drift_ = Float64(association_drift)
    association_restore_max_ = Float64(association_restore_max)
    association_proximity_radius_ = Float64(association_proximity_radius)
    association_target_neighbors_ = Float64(association_target_neighbors)
    association_feedback_gain_ = Float64(association_feedback_gain)
    association_feedback_exponent_ = Float64(association_feedback_exponent)
    association_feedback_emission_probability_ =
        Float64(association_feedback_emission_probability)
    isfinite(conspecific_range_) && conspecific_range_ > 0.0 || throw(ArgumentError(
        "conspecific_range must be finite and positive",
    ))
    isfinite(source_range_) && source_range_ > 0.0 || throw(ArgumentError(
        "source_range must be finite and positive",
    ))
    all(isfinite, (
        conspecific_input_gain_,
        resource_input_gain_,
        material_feedback_gain_,
        association_feedback_gain_,
    )) &&
        all(>=(0.0), (
            conspecific_input_gain_,
            resource_input_gain_,
            material_feedback_gain_,
            association_feedback_gain_,
        )) || throw(ArgumentError("shoal-forage input and feedback gains must be finite and non-negative"))
    all(isfinite, (
        conspecific_distance_exponent_,
        resource_distance_exponent_,
        material_feedback_exponent_,
        association_feedback_exponent_,
    )) && all(>(0.0), (
        conspecific_distance_exponent_,
        resource_distance_exponent_,
        material_feedback_exponent_,
        association_feedback_exponent_,
    )) || throw(ArgumentError("shoal-forage curve exponents must be finite and positive"))
    isfinite(material_drift_) && material_drift_ <= 0.0 || throw(ArgumentError(
        "material_drift must be finite and non-positive",
    ))
    isfinite(material_contact_restore_) && material_contact_restore_ >= 0.0 ||
        throw(ArgumentError("material_contact_restore must be finite and non-negative"))
    isfinite(association_drift_) && association_drift_ <= 0.0 || throw(ArgumentError(
        "association_drift must be finite and non-positive",
    ))
    all(isfinite, (
        association_restore_max_,
        association_proximity_radius_,
        association_target_neighbors_,
    )) && association_restore_max_ >= 0.0 && association_proximity_radius_ > 0.0 &&
        association_target_neighbors_ > 0.0 || throw(ArgumentError(
            "association restoration requires non-negative amount and positive finite radius/target",
        ))
    all(probability -> isfinite(probability) && 0.0 <= probability <= 1.0, (
        material_feedback_emission_probability_,
        association_feedback_emission_probability_,
    )) || throw(ArgumentError("shoal-forage feedback emission probabilities must lie in [0, 1]"))

    source_positions = _shoal_source_positions(block)
    world_rng = rng === nothing ? MersenneTwister(seed) : rng
    # Layout is derived from the explicit seed and block only, never from a
    # condition-specific sensor mode or range.
    layout_rng = MersenneTwister(Int(seed) + 1_000_003 * Int(block))
    states = _shoal_initial_states(layout_rng, n_agents, source_positions)
    bodies = [
        _shoal_body(
            index,
            seed;
            association_need,
            conspecific_mode,
            conspecific_range=conspecific_range_,
            source_range=source_range_,
            conspecific_input_gain=conspecific_input_gain_,
            resource_input_gain=resource_input_gain_,
            conspecific_distance_exponent=conspecific_distance_exponent_,
            resource_distance_exponent=resource_distance_exponent_,
            material_drift=material_drift_,
            material_feedback_gain=material_feedback_gain_,
            material_feedback_exponent=material_feedback_exponent_,
            material_feedback_emission_probability=material_feedback_emission_probability_,
            association_drift=association_drift_,
            association_feedback_gain=association_feedback_gain_,
            association_feedback_exponent=association_feedback_exponent_,
            association_feedback_emission_probability=
                association_feedback_emission_probability_,
            sham_seed=Int(sham_seed) + 101 * Int(block),
        )
        for index in 1:Int(n_agents)
    ]

    resource_1 = ObjectType(
        :resource_1;
        bank=:resource_1,
        radius=SHOAL_FORAGE_SOURCE_RADIUS,
        effects=(Exposure(:resource_1, material_contact_restore_),),
        capacity=nothing,
    )
    resource_2 = ObjectType(
        :resource_2;
        bank=:resource_2,
        radius=SHOAL_FORAGE_SOURCE_RADIUS,
        effects=(Exposure(:resource_2, material_contact_restore_),),
        capacity=nothing,
    )
    world = ObjectWorld(
        WalledArena(SHOAL_FORAGE_ARENA_SIZE),
        states;
        populations=(
            ObjectPopulation(resource_1, [source_positions[1]]),
            ObjectPopulation(resource_2, [source_positions[2]]),
        ),
        relations=(ProximityExposure(
            :association;
            radius=association_proximity_radius_,
            amount=association_restore_max_,
            target_neighbors=association_target_neighbors_,
        ),),
        rng=world_rng,
    )
    return TaskSetup(world, bodies)
end

const SHOAL_FORAGE_TASK = TaskSpec(
    :shoal_forage,
    ShoalForageSetup();
    env_type=ObjectWorld,
    n_receptors=51,
    n_effectors=3,
    default_ticks=4000,
    default_window=3000,
    score_key=nothing,
    descriptor_keys=[:experimental, :two_resource, :conspecific_vision],
)
