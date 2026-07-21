using BrainlessLab
using Random
using Test

function _sector_test_body(sensor; physiology=NoPhysiology())
    return Embodiment(
        geometry=DiscGeometry(0.25),
        sensors=(sensor,),
        encoders=(IdentityEncoder(n_receptors(sensor); prefix=:sector, sources=(:vision,)),),
        actuators=(AntagonisticTurnActuator(max_forward_speed=0.2, max_turn_rate=pi / 8),),
        dynamics=UnicycleDynamics(),
        physiology=physiology,
        component_ids=(
            geometry=:shape,
            sensors=(:vision,),
            encoders=(:vision_encoder,),
            actuators=(:motor,),
            dynamics=:motion,
            physiology=:physiology,
        ),
    )
end

@testset "antagonistic turn actuator contract" begin
    actuator = AntagonisticTurnActuator(max_forward_speed=0.2, max_turn_rate=pi / 8)
    @test [port.id for port in ports(actuator).effectors] ==
          [:left_turn, :right_turn, :thrust]
    command = command_buffer(actuator)
    @test decode!(command, actuator, [1.0, 0.25, 0.5]) === command
    @test command.forward_speed == 0.1
    @test command.turn_rate ≈ 3pi / 32
    decode!(command, actuator, [0.0, 1.0, 1.0])
    @test command.forward_speed == 0.2
    @test command.turn_rate ≈ -pi / 8
    @test_throws DimensionMismatch decode!(command, actuator, [1.0, 0.0])
end

@testset "sector vision geometry and matched controls" begin
    veridical = SectorVision(
        ConspecificSource();
        channels=16,
        field_of_view=deg2rad(300),
        max_range=5.0,
    )
    observer = _sector_test_body(veridical)
    target = _sector_test_body(SectorVision(ConspecificSource(); max_range=5.0))
    world = ObjectWorld(
        WalledArena(10.0),
        [
            MotionState2D(position=(2.0, 2.0), heading=0.0),
            MotionState2D(position=(4.0, 2.0), heading=0.0),
        ],
    )
    values = sample!(world, [observer, target])[1]
    @test length(values) == 16
    @test count(>(0.0), values) == 1
    @test maximum(values) ≈ 0.7
    @test argmax(values) in (8, 9)

    shaped_body = _sector_test_body(SectorVision(
        ConspecificSource();
        channels=16,
        field_of_view=deg2rad(300),
        max_range=5.0,
        gain=2.0,
        distance_exponent=2.0,
    ))
    shaped = sample!(world, [shaped_body, target])[1]
    @test maximum(shaped) ≈ 2.0 * 0.7^2

    blind_body = _sector_test_body(SectorVision(
        ConspecificSource();
        channels=16,
        field_of_view=deg2rad(300),
        max_range=5.0,
        mode=:blind,
    ))
    @test all(iszero, sample!(world, [blind_body, target])[1])

    sham_body = _sector_test_body(SectorVision(
        ConspecificSource();
        channels=16,
        field_of_view=deg2rad(300),
        max_range=5.0,
        mode=:bearing_sham,
        sham_seed=17,
    ))
    sham = sample!(world, [sham_body, target])[1]
    @test sort(sham) == sort(values)
    @test sham != values

    source = ObjectType(:food; bank=:food, radius=0.5)
    source_world = ObjectWorld(
        WalledArena(10.0),
        [MotionState2D(position=(2.0, 2.0), heading=pi / 2)];
        populations=(ObjectPopulation(source, [(2.0, 4.0)]),),
    )
    source_body = _sector_test_body(SectorVision(ObjectSource(:food); max_range=5.0))
    @test maximum(only(sample!(source_world, [source_body]))) ≈ 0.75
    @test_throws ArgumentError SectorVision(ConspecificSource(); gain=-1.0)
    @test_throws ArgumentError SectorVision(ConspecificSource(); distance_exponent=0.0)
end

@testset "proximity exposure is independent of sight" begin
    association = RegulatedVariable(
        :association;
        initial=0.5,
        setpoint=1.0,
        drift=0.0,
        mode=OffFeedback(),
    )
    bodies = [
        _sector_test_body(
            SectorVision(ConspecificSource(); max_range=1.0, mode=:blind);
            physiology=RegulatedPhysiology((association,); seed=index),
        )
        for index in 1:2
    ]
    world = ObjectWorld(
        WalledArena(10.0),
        [
            MotionState2D(position=(2.0, 2.0)),
            MotionState2D(position=(3.0, 2.0)),
        ];
        relations=(ProximityExposure(
            :association;
            radius=2.0,
            amount=0.004,
            target_neighbors=2.0,
        ),),
    )
    commands = [ForwardTurnCommand(), ForwardTurnCommand()]
    effects = apply_commands!(world, bodies, commands)
    @test all(length(effect) == 1 for effect in effects)
    @test all(only(effect).name === :association for effect in effects)
    @test all(only(effect).amount ≈ 0.0015 for effect in effects)
end

@testset "shoal forage task contract and matched blocks" begin
    on = setup_task(
        SHOAL_FORAGE_TASK;
        seed=23,
        n_nodes=40,
        n_agents=4,
        block=2,
        association_need=true,
        conspecific_mode=:veridical,
        conspecific_range=5.0,
    )
    off = setup_task(
        SHOAL_FORAGE_TASK;
        seed=23,
        n_nodes=40,
        n_agents=4,
        block=2,
        association_need=false,
        conspecific_mode=:bearing_sham,
        conspecific_range=10.0,
    )
    @test length(on.bodies) == length(off.bodies) == 4
    @test all(n_receptors(body) == 51 for body in on.bodies)
    @test all(n_effectors(body) == 3 for body in on.bodies)
    @test getfield.(on.environment.initial_states, :position) ==
          getfield.(off.environment.initial_states, :position)
    @test getfield.(on.environment.initial_states, :heading) ==
          getfield.(off.environment.initial_states, :heading)
    @test [object.origin for object in on.environment.objects] ==
          [object.origin for object in off.environment.objects]
    @test on.bodies[1].physiology.variables[3].mode isa BernoulliFeedback
    @test off.bodies[1].physiology.variables[3].mode isa OffFeedback
    @test off.bodies[1].physiology.variables[3].drift == 0.0

    sensitive = setup_task(
        SHOAL_FORAGE_TASK;
        seed=23,
        n_nodes=40,
        n_agents=4,
        block=2,
        association_need=true,
        conspecific_input_gain=0.5,
        resource_input_gain=2.0,
        conspecific_distance_exponent=0.5,
        resource_distance_exponent=2.0,
        material_drift=-0.002,
        material_contact_restore=0.02,
        material_feedback_gain=1.5,
        material_feedback_exponent=2.0,
        material_feedback_emission_probability=0.4,
        association_drift=-0.002,
        association_restore_max=0.008,
        association_proximity_radius=4.0,
        association_target_neighbors=4.0,
        association_feedback_gain=0.5,
        association_feedback_exponent=0.5,
        association_feedback_emission_probability=0.1,
    )
    @test sensitive.bodies[1].sensors[1].gain == 0.5
    @test sensitive.bodies[1].sensors[2].gain == 2.0
    @test sensitive.bodies[1].sensors[1].distance_exponent == 0.5
    @test sensitive.bodies[1].sensors[2].distance_exponent == 2.0
    @test sensitive.bodies[1].physiology.variables[1].drift == -0.002
    @test sensitive.bodies[1].physiology.variables[1].gain == 1.5
    @test sensitive.bodies[1].physiology.variables[1].curve isa PowerFeedback
    @test sensitive.bodies[1].physiology.variables[1].emission_p == 0.4
    @test sensitive.bodies[1].physiology.variables[3].drift == -0.002
    @test sensitive.bodies[1].physiology.variables[3].gain == 0.5
    @test sensitive.bodies[1].physiology.variables[3].curve isa PowerFeedback
    @test sensitive.bodies[1].physiology.variables[3].emission_p == 0.1
    @test sensitive.environment.object_types[1].effects[1].amount == 0.02
    @test sensitive.environment.relations[1].amount == 0.008
    @test sensitive.environment.relations[1].radius == 4.0
    @test sensitive.environment.relations[1].target_neighbors == 4.0

    sim = simulate(
        :shoal_forage;
        node=:falandays,
        ticks=2,
        seed=23,
        n_nodes=40,
        n_agents=4,
        task_kwargs=(
            block=2,
            association_need=true,
            conspecific_mode=:veridical,
            conspecific_range=5.0,
        ),
        record=(:needs, :poses, :interactions, :rate),
    )
    @test sim.task === :shoal_forage
    @test length(getchannel(sim.recorder, :needs)) == 2
    @test length(getchannel(sim.recorder, :poses)) == 2
    @test sim.config.environment.relations[1].kind === :proximity_exposure
    @test sim.config.agents[1].body.sensors[1].kind === :sector_vision
    @test sim.config.agents[1].body.actuators[1].kind === :antagonistic_turn
    needs = shoal_need_satisfaction(sim; warmup=0)
    grouped = shoal_group_movement_summary(sim; warmup=0, grouping_radius=2.0)
    @test 0.0 <= needs.mean_material_satisfaction <= 1.0
    @test 0.0 <= needs.material_no_contact_floor <= 1.0
    @test isfinite(needs.material_regulation_gain)
    @test grouped.mean_nearest_neighbor_distance >= 0.0
    @test 0.0 <= grouped.largest_proximity_component_fraction <= 1.0
    @test 0.0 <= grouped.movement_coherence <= 1.0 + eps(Float64)
    @test grouped.group_translation_speed >= 0.0
end

@testset "experimental component catalog entries" begin
    sensor_resolver = component_info(:sensor, :sector_vision).config_resolver
    sensor = sensor_resolver(ComponentConfig(
        :social,
        :sensor,
        :sector_vision,
        (
            source="conspecific",
            channels=16,
            field_of_view_deg=300.0,
            range=5.0,
            gain=2.0,
            distance_exponent=0.5,
            mode="bearing_sham",
            sham_seed=9,
        ),
    ))
    @test sensor.source isa ConspecificSource
    @test sensor.mode === :bearing_sham
    @test sensor.sham_seed == 9
    @test sensor.gain == 2.0
    @test sensor.distance_exponent == 0.5

    actuator_resolver = component_info(:actuator, :antagonistic_turn).config_resolver
    actuator = actuator_resolver(ComponentConfig(
        :motor,
        :actuator,
        :antagonistic_turn,
        (max_forward=0.2, max_turn=pi / 8),
    ))
    @test actuator isa AntagonisticTurnActuator
end
