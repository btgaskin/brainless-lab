using BrainlessLab
using Random
using Test

@testset "Morphology defaults" begin
    task_counts = (
        (WALL_TASK, 2, 2),
        (TRACKING_TASK, 62, 2),
        (PONG_TASK, 46, 2),
        (PONG_HITRATE_TASK, 46, 2),
        (CARTPOLE_TASK, 8, 2),
        (CARTPOLE_HARD_TASK, 8, 2),
        (CARTPOLE_SWINGUP_TASK, 8, 2),
        (CARTPOLE_LONG_TASK, 8, 2),
    )

    for (task, receptors_expected, effectors_expected) in task_counts
        env = make_env(task; rng=MersenneTwister(11))
        morphology = default_morphology(env)
        spec = portspec(morphology)

        @test morphology isa PassthroughMorphology
        @test n_receptors(morphology) == receptors_expected
        @test n_effectors(morphology) == effectors_expected
        @test n_receptors(spec) == receptors_expected
        @test n_effectors(spec) == effectors_expected
        @test length(ports(spec).receptors) == receptors_expected
        @test length(ports(spec).effectors) == effectors_expected
    end

    morphology = default_morphology(VENBody((0.0, 0.0), 0.0))
    spec = portspec(morphology)

    @test morphology isa VENMorphology
    @test n_receptors(morphology) == 64
    @test n_effectors(morphology) == 3
    @test n_receptors(spec) == 64
    @test n_effectors(spec) == 3
    @test length(ports(spec).receptors) == 64
    @test length(ports(spec).effectors) == 3
end

@testset "Morphology receptor and effector transforms" begin
    ven = VENMorphology()
    percept62 = collect(1.0:62.0)
    percept64 = collect(1.0:64.0)

    @test encode_receptors(ven, percept62) == assemble_inputs(percept62)
    @test encode_receptors(ven, percept64) == percept64

    passthrough = PassthroughMorphology(2, 2)
    percept = [0.1, 0.2]
    effectors = [0.3, 0.4]

    @test encode_receptors(passthrough, percept) === percept
    @test decode_effectors(passthrough, effectors) === effectors
end
