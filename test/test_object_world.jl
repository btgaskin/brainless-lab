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
    return BrainlessLab.materialize_embodiment(BrainlessLab.read_embodiment_config(path))
end

@testset "object populations canonicalize one policy per stable type name" begin
    appearance_a = BrainlessLab.rgb_appearance((0.2, 0.4, 0.8))
    appearance_b = BrainlessLab.rgb_appearance((0.2, 0.4, 0.8))
    resource_a = BrainlessLab.ObjectType(
        :resource;
        bank=:resource,
        radius=0.25,
        effects=(:restore,),
        capacity=2,
        respawn=BrainlessLab.SamePositionRespawn(1),
        appearance=appearance_a,
    )
    resource_b = BrainlessLab.ObjectType(
        :resource;
        bank=:resource,
        radius=0.25,
        effects=(:restore,),
        capacity=2,
        respawn=BrainlessLab.SamePositionRespawn(1),
        appearance=appearance_b,
    )
    world = BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(10.0),
        [BrainlessLab.MotionState2D()];
        populations=(
            BrainlessLab.ObjectPopulation(resource_a, [(2.0, 2.0)]),
            BrainlessLab.ObjectPopulation(resource_b, [(8.0, 8.0)]),
        ),
    )
    @test length(world.object_types) == 1
    @test getfield.(world.objects, :type_index) == [1, 1]
    @test [object.type_index for object in BrainlessLab.object_snapshot(world)] == [1, 1]
    @test [object.kind for object in BrainlessLab.object_snapshot(world)] ==
          [:resource, :resource]

    conflicting = BrainlessLab.ObjectType(
        :resource;
        bank=:resource,
        radius=0.5,
        effects=(:restore,),
        capacity=2,
        respawn=BrainlessLab.SamePositionRespawn(1),
        appearance=appearance_a,
    )
    @test_throws ArgumentError BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(10.0),
        [BrainlessLab.MotionState2D()];
        populations=(
            BrainlessLab.ObjectPopulation(resource_a, [(2.0, 2.0)]),
            BrainlessLab.ObjectPopulation(conflicting, [(8.0, 8.0)]),
        ),
    )
end

@testset "object appearance and configured spectral robot" begin
    @test BrainlessLab.ObjectType(:plain).appearance isa BrainlessLab.NoAppearance
    appearance = BrainlessLab.rgb_appearance((1.0, 0.05, 0.0))
    @test appearance isa BrainlessLab.SpectralAppearance
    @test BrainlessLab.spectral_reflectance(appearance) isa BrainlessLab.SpectralReflectance
    @test_throws DimensionMismatch BrainlessLab.rgb_appearance((1.0, 0.0))
    @test_throws ArgumentError BrainlessLab.rgb_appearance((1.1, 0.0, 0.0))

    robot = _object_world_preset(:differential_robot)
    beacon = BrainlessLab.ObjectType(
        :beacon;
        radius=0.4,
        capacity=1,
        appearance=appearance,
    )
    world = BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(12.0),
        [BrainlessLab.MotionState2D(position=(2.0, 2.0), heading=0.0)];
        populations=(BrainlessLab.ObjectPopulation(beacon, [(3.35, 2.0)]),),
    )

    raw = only(BrainlessLab.sample!(world, [robot]))
    @test length(raw) == 72
    @test maximum(raw) > 0.0

    camera = only(BrainlessLab.sensor_components(robot))
    half_light = BrainlessLab.SpectralIlluminant(camera.grid, fill(0.5, length(camera.grid)))
    half_world = BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(12.0),
        [BrainlessLab.MotionState2D(position=(2.0, 2.0), heading=0.0)];
        populations=(BrainlessLab.ObjectPopulation(beacon, [(3.35, 2.0)]),),
        illuminant=half_light,
    )
    half_raw = only(BrainlessLab.sample!(half_world, [robot]))
    @test 0.0 < maximum(half_raw) < maximum(raw)

    reservoir = _ObjectWorldReservoir(n_receptors(robot), [1.0, 1.0])
    recorder = Recorder(enabled=(:objects, :interactions, :poses))
    ensemble = BrainlessLab.Ensemble(
        [BrainlessLab.Agent(reservoir, robot)],
        world;
        ids=[BrainlessLab.EntityID(71)],
        recorder=recorder,
    )
    before = world.states[1].position
    step!(ensemble)
    @test world.states[1].position != before
    @test length(BrainlessLab.interaction_events(world)) == 1
    event = only(BrainlessLab.interaction_events(world))
    @test event.agent == BrainlessLab.EntityID(71)
    @test event.object == BrainlessLab.ObjectID(1)
    @test event.kind === :beacon
    @test only(BrainlessLab.object_snapshot(world)).id == BrainlessLab.ObjectID(1)
    @test !only(BrainlessLab.object_snapshot(world)).active
    @test only(getchannel(recorder, :poses)).ids == [BrainlessLab.EntityID(71)]
    @test only(only(getchannel(recorder, :interactions))).agent == BrainlessLab.EntityID(71)
    @test only(only(getchannel(recorder, :objects))).id == BrainlessLab.ObjectID(1)

    config = BrainlessLab._environment_config(world)
    @test config.kind === :object_world
    @test config.entity_ids == (BrainlessLab.EntityID(71),)
    @test only(config.object_types).appearance.kind === :spectral
    @test only(config.objects).id == BrainlessLab.ObjectID(1)
end

@testset "camera and bilateral probes compose in one UAV" begin
    uav = _object_world_preset(:planar_uav)
    target = BrainlessLab.ObjectType(
        :radio_tower;
        radius=0.5,
        appearance=BrainlessLab.rgb_appearance((0.1, 0.3, 1.0)),
    )
    world = BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(20.0),
        [BrainlessLab.MotionState2D(position=(4.0, 4.0), heading=0.0)];
        populations=(BrainlessLab.ObjectPopulation(target, [(7.0, 4.0)]),),
        fields=(radio=BrainlessLab.LinearSpatialField((0.0, 0.0), (0.0, 1.0); offset=0.0, scale=10.0),),
    )
    raw = only(BrainlessLab.sample!(world, [uav]))
    @test raw isa Tuple
    @test length(raw) == 3
    @test maximum(raw[1]) > 0.0
    @test only(raw[2]) > only(raw[3])
    encoded = BrainlessLab.sense!(uav, raw)
    @test length(encoded) == 97
    @test all(isfinite, encoded)

    command = BrainlessLab.decode!(uav, [1.0, 0.5, 0.5])
    before = world.states[1].position
    effects = BrainlessLab.apply_commands!(world, [uav], [command])
    @test world.states[1].position != before
    @test isempty(only(effects))
end

@testset "heterogeneous bodies, exposures, identity, death, and respawn" begin
    insect = _object_world_preset(:bilateral_insect)
    blind = BrainlessLab.Embodiment(
        geometry=BrainlessLab.DiscGeometry(0.2),
        sensors=(BrainlessLab.DirectRelaySensor(0),),
        encoders=(BrainlessLab.IdentityEncoder(0; prefix=:blind),),
        actuators=(BrainlessLab.ForwardTurnActuator(max_forward_speed=0.5, max_turn_rate=1.0),),
        dynamics=BrainlessLab.UnicycleDynamics(),
        physiology=BrainlessLab.NoPhysiology(unknown_effects=BrainlessLab.IgnoreUnknownEffects()),
    )
    food = BrainlessLab.ObjectType(
        :food;
        radius=0.3,
        effects=(BrainlessLab.Exposure(:energy, 0.2),),
        capacity=1,
        respawn=BrainlessLab.SamePositionRespawn(1),
        appearance=BrainlessLab.rgb_appearance((0.2, 1.0, 0.1)),
    )
    neutral = BrainlessLab.ObjectType(
        :neutral;
        radius=0.3,
        effects=(:unhandled,),
        appearance=BrainlessLab.NoAppearance(),
    )
    world = BrainlessLab.ObjectWorld(
        BrainlessLab.Torus(10.0),
        [
            BrainlessLab.MotionState2D(position=(2.0, 2.0)),
            BrainlessLab.MotionState2D(position=(7.0, 7.0)),
        ];
        populations=(
            BrainlessLab.ObjectPopulation(food, [(2.0, 2.0)]),
            BrainlessLab.ObjectPopulation(neutral, [(7.0, 7.0)]),
        ),
        fields=(odor=BrainlessLab.ConstantSpatialField(0.6),),
        rng=MersenneTwister(9),
    )

    raw = BrainlessLab.sample!(world, AbstractBody[insect, blind])
    @test raw[1] isa Tuple
    @test length(raw[1]) == 2
    @test raw[2] == Float64[]

    agents = BrainlessLab.Agent[
        BrainlessLab.Agent(_ObjectWorldReservoir(n_receptors(insect), [0.0, 0.5]), insect),
        BrainlessLab.Agent(_ObjectWorldReservoir(n_receptors(blind), [0.0, 0.5]), blind),
    ]
    ensemble = BrainlessLab.Ensemble(agents, world; ids=[BrainlessLab.EntityID(91), BrainlessLab.EntityID(12)])
    step!(ensemble)
    @test BrainlessLab.regulated_values(insect.physiology).energy ≈ 0.948
    events = BrainlessLab.interaction_events(world)
    @test Set(event.agent for event in events) == Set((BrainlessLab.EntityID(91), BrainlessLab.EntityID(12)))
    @test Set(event.object for event in events) == Set((BrainlessLab.ObjectID(1), BrainlessLab.ObjectID(2)))
    @test BrainlessLab.object_snapshot(world)[1].id == BrainlessLab.ObjectID(1)
    @test !BrainlessLab.object_snapshot(world)[1].active

    before = Tuple(copy(sensor.state.values) for sensor in BrainlessLab.sensor_components(insect))
    insect.physiology.is_alive = false
    dead_raw = BrainlessLab.sample!(world, AbstractBody[insect, blind])[1]
    @test all(values -> all(iszero, values), dead_raw)
    @test Tuple(sensor.state.values for sensor in BrainlessLab.sensor_components(insect)) == before

    # One complete unavailable tick, then the same stable object ID respawns.
    step!(ensemble)
    @test !BrainlessLab.object_snapshot(world)[1].active
    step!(ensemble)
    @test BrainlessLab.object_snapshot(world)[1].active
    @test BrainlessLab.object_snapshot(world)[1].id == BrainlessLab.ObjectID(1)

    reset!(world)
    @test world.tick == 0
    @test all(object -> object.active, BrainlessLab.object_snapshot(world))
    first_draw = rand(world.rng)
    reset!(world)
    @test rand(world.rng) == first_draw
end

@testset "documented object-world quickstart runs" begin
    isdefined(Main, :run_object_world_quickstart) ||
        include(joinpath(@__DIR__, "..", "examples", "embodiments", "object_world_quickstart.jl"))
    result = run_object_world_quickstart(ticks=2, seed=3)
    poses = getchannel(result.recorder, :poses)
    @test length(poses) == 2
    @test last(poses).ids == [BrainlessLab.EntityID(101)]
    @test only(result.objects).id == BrainlessLab.ObjectID(1)
end

@testset "object-world metrics exclude inactive stale motion" begin
    body = _object_world_preset("bilateral_insect")
    body.physiology.is_alive = false
    world = BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(10.0),
        [BrainlessLab.MotionState2D(position=(5.0, 5.0), velocity=(1.0, 0.0))],
    )
    ensemble = BrainlessLab.Ensemble(
        [BrainlessLab.Agent(_ObjectWorldReservoir(n_receptors(body), zeros(n_effectors(body))), body)],
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
