using BrainlessLab
using Test

@testset "CompositeGenome packs namespaced node, motor, and sensor blocks" begin
    node_template = FalandaysParams(
        leak=0.35,
        lrate_wmat=0.12,
        lrate_targ=0.02,
        threshold_mult=2.5,
        targ_min=0.8,
        input_weight=1.4,
        weight_init_std=0.7,
    )
    motor_template = KinematicMotor(
        turn_gain=1.25,
        turn_gain_range=(0.5, 2.0),
        top_speed=0.3,
        top_speed_range=(0.1, 0.5),
    )
    sensor_template = BearingSensor(
        angles_deg=[-30.0, 0.0, 30.0],
        angle_range_deg=(-90.0, 90.0),
        tuning_deg=5.0,
        tuning_range_deg=(0.0, 20.0),
    )

    genome = compose_genome(
        node=:falandays_base,
        motor=motor_template,
        sensor=sensor_template,
        node_template=node_template,
    )

    @test paramdim(genome) ==
        paramdim(FalandaysParams) + paramdim(motor_template) + paramdim(sensor_template)
    @test length(pack_params(genome)) == paramdim(genome)
    @test length(genome.slices) == 3
    @test genome.slices[1] == 1:paramdim(FalandaysParams)

    labels = [entry.label for entry in BrainlessLab.paramspace(genome)]
    @test labels[1:7] == [
        :node__leak,
        :node__lrate_wmat,
        :node__lrate_targ,
        :node__threshold_mult,
        :node__targ_min,
        :node__input_weight,
        :node__weight_init_std,
    ]
    @test :motor__turn_gain in labels
    @test :motor__top_speed in labels
    @test :sensor__angle_1 in labels
    @test labels[end] == :sensor__tuning

    parts = unpack_params(genome, pack_params(genome))
    @test propertynames(parts) == (:node, :motor, :sensor)
    @test parts.node isa FalandaysParams
    @test isapprox(pack_params(parts.node), pack_params(node_template); atol=1e-8)
    @test parts.motor isa KinematicMotor
    @test isapprox(parts.motor.turn_gain, motor_template.turn_gain; atol=1e-6)
    @test isapprox(parts.motor.top_speed, motor_template.top_speed; atol=1e-6)
    @test parts.motor.turn_gain_range == motor_template.turn_gain_range
    @test parts.sensor isa BearingSensor
    @test isapprox(BrainlessLab.angles_deg(parts.sensor), BrainlessLab.angles_deg(sensor_template); atol=1e-6)
    @test isapprox(parts.sensor.tuning_deg, sensor_template.tuning_deg; atol=1e-6)

    routed = BrainlessLab._route_parts(parts)
    @test routed.node_kwargs[:params] === parts.node
    @test routed.swarm_kwargs[:motor] === parts.motor
    @test routed.swarm_kwargs[:sensor] === parts.sensor

    @test_throws DimensionMismatch unpack_params(genome, pack_params(genome)[1:(end - 1)])
end

@testset "Falandays paramspace exposes the flat raw node genome" begin
    space = BrainlessLab.paramspace(FalandaysParams)
    @test length(space) == paramdim(FalandaysParams)
    @test [entry.label for entry in space] == [
        :leak,
        :lrate_wmat,
        :lrate_targ,
        :threshold_mult,
        :targ_min,
        :input_weight,
        :weight_init_std,
    ]
    @test all(entry -> entry.lo == -Inf && entry.hi == Inf, space)
end

@testset "Composite swarm evaluation runs through evolve" begin
    genome = compose_genome(
        node=:falandays_base,
        motor=KinematicMotor(turn_gain_range=(0.5, 1.5)),
        sensor=BearingSensor(angles_deg=[-30.0, 30.0], angle_range_deg=(-90.0, 90.0)),
    )
    evaluator = swarm_evaluate(
        genome;
        n_agents=4,
        n_nodes=12,
        ticks=40,
        window=20,
        n_colours=2,
    )
    direct = evaluator(pack_params(genome), 0)
    @test isfinite(direct)
    @test -1.0 <= direct <= 1.0

    out = evolve(
        genome=genome,
        evaluate=evaluator,
        generations=2,
        popsize=4,
        k_trials=1,
        sigma0=0.1,
        seed=5,
        threaded=false,
    )
    @test length(out.fitnesses) == 2
    @test all(isfinite, reduce(vcat, out.fitnesses))
    @test isfinite(out.best_fitness)
    @test length(out.best_raw) == paramdim(genome)
    @test out.optimizer.n_dim == paramdim(genome)
end
