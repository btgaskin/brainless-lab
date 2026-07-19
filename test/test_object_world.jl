using Random

import BrainlessLab: effectors, n_effectors, n_nodes, n_receptors, step!

mutable struct _ObjectWorldReservoir <: Reservoir
    nr::Int
    output::Vector{Float64}
end

n_receptors(reservoir::_ObjectWorldReservoir) = reservoir.nr
n_effectors(reservoir::_ObjectWorldReservoir) = length(reservoir.output)
n_nodes(::_ObjectWorldReservoir) = 1
step!(::_ObjectWorldReservoir, receptors) = [sum(receptors)]
effectors(reservoir::_ObjectWorldReservoir, spikes) = copy(reservoir.output)

function _object_world_preset(name)
    path = joinpath(pkgdir(BrainlessLab), "examples", "embodiments", "$(name).toml")
    return materialize_embodiment(read_embodiment_config(path))
end

@testset "object populations canonicalize one policy per stable type name" begin
    appearance_a = rgb_appearance((0.2, 0.4, 0.8))
    appearance_b = rgb_appearance((0.2, 0.4, 0.8))
    resource_a = ObjectType(
        :resource;
        bank=:resource,
        radius=0.25,
        effects=(:restore,),
        capacity=2,
        respawn=SamePositionRespawn(1),
        appearance=appearance_a,
    )
    resource_b = ObjectType(
        :resource;
        bank=:resource,
        radius=0.25,
        effects=(:restore,),
        capacity=2,
        respawn=SamePositionRespawn(1),
        appearance=appearance_b,
    )
    world = ObjectWorld(
        WalledArena(10.0),
        [MotionState2D()];
        populations=(
            ObjectPopulation(resource_a, [(2.0, 2.0)]),
            ObjectPopulation(resource_b, [(8.0, 8.0)]),
        ),
    )
    @test length(world.object_types) == 1
    @test getfield.(world.objects, :type_index) == [1, 1]
    @test [object.type_index for object in object_snapshot(world)] == [1, 1]
    @test [object.kind for object in object_snapshot(world)] ==
          [:resource, :resource]

    conflicting = ObjectType(
        :resource;
        bank=:resource,
        radius=0.5,
        effects=(:restore,),
        capacity=2,
        respawn=SamePositionRespawn(1),
        appearance=appearance_a,
    )
    @test_throws ArgumentError ObjectWorld(
        WalledArena(10.0),
        [MotionState2D()];
        populations=(
            ObjectPopulation(resource_a, [(2.0, 2.0)]),
            ObjectPopulation(conflicting, [(8.0, 8.0)]),
        ),
    )
end

@testset "object appearance and configured spectral robot" begin
    @test ObjectType(:plain).appearance isa NoAppearance
    appearance = rgb_appearance((1.0, 0.05, 0.0))
    @test appearance isa SpectralAppearance
    @test spectral_reflectance(appearance) isa SpectralReflectance
    @test_throws DimensionMismatch rgb_appearance((1.0, 0.0))
    @test_throws ArgumentError rgb_appearance((1.1, 0.0, 0.0))

    robot = _object_world_preset(:differential_robot)
    beacon = ObjectType(
        :beacon;
        radius=0.4,
        capacity=1,
        appearance=appearance,
    )
    world = ObjectWorld(
        WalledArena(12.0),
        [MotionState2D(position=(2.0, 2.0), heading=0.0)];
        populations=(ObjectPopulation(beacon, [(3.35, 2.0)]),),
    )

    raw = only(sample!(world, [robot]))
    @test length(raw) == 72
    @test maximum(raw) > 0.0

    camera = only(sensor_components(robot))
    half_light = SpectralIlluminant(camera.grid, fill(0.5, length(camera.grid)))
    half_world = ObjectWorld(
        WalledArena(12.0),
        [MotionState2D(position=(2.0, 2.0), heading=0.0)];
        populations=(ObjectPopulation(beacon, [(3.35, 2.0)]),),
        illuminant=half_light,
    )
    half_raw = only(sample!(half_world, [robot]))
    @test 0.0 < maximum(half_raw) < maximum(raw)

    reservoir = _ObjectWorldReservoir(n_receptors(robot), [1.0, 1.0])
    recorder = Recorder(enabled=(:objects, :interactions, :poses))
    ensemble = Ensemble(
        [Agent(reservoir, robot)],
        world;
        ids=[EntityID(71)],
        recorder=recorder,
    )
    before = world.states[1].position
    step!(ensemble)
    @test world.states[1].position != before
    @test length(interaction_events(world)) == 1
    event = only(interaction_events(world))
    @test event.agent == EntityID(71)
    @test event.object == ObjectID(1)
    @test event.kind === :beacon
    @test only(object_snapshot(world)).id == ObjectID(1)
    @test !only(object_snapshot(world)).active
    @test only(getchannel(recorder, :poses)).ids == [EntityID(71)]
    @test only(only(getchannel(recorder, :interactions))).agent == EntityID(71)
    @test only(only(getchannel(recorder, :objects))).id == ObjectID(1)

    config = BrainlessLab._environment_config(world)
    @test config.kind === :object_world
    @test config.entity_ids == (EntityID(71),)
    @test only(config.object_types).appearance.kind === :spectral
    @test only(config.objects).id == ObjectID(1)
end

@testset "camera and bilateral probes compose in one UAV" begin
    uav = _object_world_preset(:planar_uav)
    target = ObjectType(
        :radio_tower;
        radius=0.5,
        appearance=rgb_appearance((0.1, 0.3, 1.0)),
    )
    world = ObjectWorld(
        WalledArena(20.0),
        [MotionState2D(position=(4.0, 4.0), heading=0.0)];
        populations=(ObjectPopulation(target, [(7.0, 4.0)]),),
        fields=(radio=LinearSpatialField((0.0, 0.0), (0.0, 1.0); offset=0.0, scale=10.0),),
    )
    raw = only(sample!(world, [uav]))
    @test raw isa Tuple
    @test length(raw) == 3
    @test maximum(raw[1]) > 0.0
    @test only(raw[2]) > only(raw[3])
    encoded = sense!(uav, raw)
    @test length(encoded) == 97
    @test all(isfinite, encoded)

    command = decode!(uav, [1.0, 0.5, 0.5])
    before = world.states[1].position
    effects = apply_commands!(world, [uav], [command])
    @test world.states[1].position != before
    @test isempty(only(effects))
end

@testset "heterogeneous bodies, exposures, identity, death, and respawn" begin
    insect = _object_world_preset(:bilateral_insect)
    blind = Embodiment(
        geometry=DiscGeometry(0.2),
        sensors=(DirectRelaySensor(0),),
        encoders=(IdentityEncoder(0; prefix=:blind),),
        actuators=(ForwardTurnActuator(max_forward_speed=0.5, max_turn_rate=1.0),),
        dynamics=UnicycleDynamics(),
        physiology=NoPhysiology(unknown_effects=IgnoreUnknownEffects()),
    )
    food = ObjectType(
        :food;
        radius=0.3,
        effects=(Exposure(:energy, 0.2),),
        capacity=1,
        respawn=SamePositionRespawn(1),
        appearance=rgb_appearance((0.2, 1.0, 0.1)),
    )
    neutral = ObjectType(
        :neutral;
        radius=0.3,
        effects=(:unhandled,),
        appearance=NoAppearance(),
    )
    world = ObjectWorld(
        Torus(10.0),
        [
            MotionState2D(position=(2.0, 2.0)),
            MotionState2D(position=(7.0, 7.0)),
        ];
        populations=(
            ObjectPopulation(food, [(2.0, 2.0)]),
            ObjectPopulation(neutral, [(7.0, 7.0)]),
        ),
        fields=(odor=ConstantSpatialField(0.6),),
        rng=MersenneTwister(9),
    )

    raw = sample!(world, AbstractBody[insect, blind])
    @test raw[1] isa Tuple
    @test length(raw[1]) == 2
    @test raw[2] == Float64[]

    agents = Agent[
        Agent(_ObjectWorldReservoir(n_receptors(insect), [0.0, 0.5]), insect),
        Agent(_ObjectWorldReservoir(n_receptors(blind), [0.0, 0.5]), blind),
    ]
    ensemble = Ensemble(agents, world; ids=[EntityID(91), EntityID(12)])
    step!(ensemble)
    @test regulated_values(insect.physiology).energy ≈ 0.948
    events = interaction_events(world)
    @test Set(event.agent for event in events) == Set((EntityID(91), EntityID(12)))
    @test Set(event.object for event in events) == Set((ObjectID(1), ObjectID(2)))
    @test object_snapshot(world)[1].id == ObjectID(1)
    @test !object_snapshot(world)[1].active

    before = Tuple(copy(sensor.state.values) for sensor in sensor_components(insect))
    insect.physiology.is_alive = false
    dead_raw = sample!(world, AbstractBody[insect, blind])[1]
    @test all(values -> all(iszero, values), dead_raw)
    @test Tuple(sensor.state.values for sensor in sensor_components(insect)) == before

    # One complete unavailable tick, then the same stable object ID respawns.
    step!(ensemble)
    @test !object_snapshot(world)[1].active
    step!(ensemble)
    @test object_snapshot(world)[1].active
    @test object_snapshot(world)[1].id == ObjectID(1)

    reset!(world)
    @test world.tick == 0
    @test all(object -> object.active, object_snapshot(world))
    first_draw = rand(world.rng)
    reset!(world)
    @test rand(world.rng) == first_draw
end

@testset "documented object-world quickstart runs" begin
    include(joinpath(@__DIR__, "..", "examples", "embodiments", "object_world_quickstart.jl"))
    result = run_object_world_quickstart(ticks=2, seed=3)
    poses = getchannel(result.recorder, :poses)
    @test length(poses) == 2
    @test last(poses).ids == [EntityID(101)]
    @test only(result.objects).id == ObjectID(1)
end

@testset "object-world metrics exclude inactive stale motion" begin
    body = _object_world_preset("bilateral_insect")
    body.physiology.is_alive = false
    world = ObjectWorld(
        WalledArena(10.0),
        [MotionState2D(position=(5.0, 5.0), velocity=(1.0, 0.0))],
    )
    ensemble = Ensemble(
        [Agent(_ObjectWorldReservoir(n_receptors(body), zeros(n_effectors(body))), body)],
        world,
    )

    step!(ensemble)
    @test !world.active_agents[1]
    @test all(iszero, world.states[1].velocity)
    @test metrics(world).mean_speed == 0.0
    @test metrics(world).active_count == 0
    @test metrics(world).active_fraction == 0.0
    reset!(world)
    @test world.active_agents == world.initial_active_agents == BitVector([false])
    @test all(iszero, world.states[1].velocity)
end

@testset "documented object-world TaskSpec example runs" begin
    include(joinpath(@__DIR__, "..", "examples", "embodiments", "object_world_task.jl"))
    sim = run_object_world_task(ticks=3, seed=5)

    @test sim isa SimResult
    @test sim.task === :object_world_example
    @test length(getchannel(sim.recorder, :poses)) == 3
    @test length(getchannel(sim.recorder, :objects)) == 3
    @test length(getchannel(sim.recorder, :receptors)) == 3
    @test length(getchannel(sim.recorder, :components)) == 3
    @test hasproperty(sim.metrics, :mean_speed)
    @test !hasproperty(sim.metrics, :score)
end
