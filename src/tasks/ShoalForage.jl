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

function _shoal_need(name::Symbol)
    return RegulatedVariable(
        name;
        minimum=0.0,
        maximum=1.0,
        initial=1.0,
        setpoint=1.0,
        drift=-0.001,
        deficit=BelowSetpoint(),
        curve=LinearFeedback(),
        mode=BernoulliFeedback(),
        gain=1.0,
        emission_p=0.2,
        failure=NoFailure(),
    )
end

function _shoal_association_need(enabled::Bool)
    enabled && return _shoal_need(:association)
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
    sham_seed::Integer,
)
    sensors = (
        SectorVision(
            ConspecificSource();
            channels=SHOAL_FORAGE_SECTORS,
            field_of_view=SHOAL_FORAGE_FIELD_OF_VIEW,
            max_range=conspecific_range,
            mode=conspecific_mode,
            sham_seed=sham_seed,
        ),
        SectorVision(
            ObjectSource(:resource_1);
            channels=SHOAL_FORAGE_SECTORS,
            field_of_view=SHOAL_FORAGE_FIELD_OF_VIEW,
            max_range=source_range,
        ),
        SectorVision(
            ObjectSource(:resource_2);
            channels=SHOAL_FORAGE_SECTORS,
            field_of_view=SHOAL_FORAGE_FIELD_OF_VIEW,
            max_range=source_range,
        ),
    )
    sensor_ids = (:conspecific_vision, :resource_1_vision, :resource_2_vision)
    encoders = Tuple(
        IdentityEncoder(sensor.channels; prefix=id, sources=(id,))
        for (id, sensor) in zip(sensor_ids, sensors)
    )
    physiology = RegulatedPhysiology((
        _shoal_need(:resource_1),
        _shoal_need(:resource_2),
        _shoal_association_need(association_need),
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
    isfinite(conspecific_range_) && conspecific_range_ > 0.0 || throw(ArgumentError(
        "conspecific_range must be finite and positive",
    ))
    isfinite(source_range_) && source_range_ > 0.0 || throw(ArgumentError(
        "source_range must be finite and positive",
    ))

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
            sham_seed=Int(sham_seed) + 101 * Int(block),
        )
        for index in 1:Int(n_agents)
    ]

    resource_1 = ObjectType(
        :resource_1;
        bank=:resource_1,
        radius=SHOAL_FORAGE_SOURCE_RADIUS,
        effects=(Exposure(:resource_1, 0.01),),
        capacity=nothing,
    )
    resource_2 = ObjectType(
        :resource_2;
        bank=:resource_2,
        radius=SHOAL_FORAGE_SOURCE_RADIUS,
        effects=(Exposure(:resource_2, 0.01),),
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
            radius=2.0,
            amount=0.004,
            target_neighbors=2.0,
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
