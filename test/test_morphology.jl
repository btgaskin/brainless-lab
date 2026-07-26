using BrainlessLab
using Random
using Test

@testset "Embodiment component composition and task relays" begin
    task_counts = (
        (BrainlessLab.WALL_TASK, 2, 2),
        (BrainlessLab.TRACKING_TASK, 62, 2),
        (BrainlessLab.PONG_TASK, 46, 2),
        (BrainlessLab.PONG_HITRATE_TASK, 46, 2),
        (BrainlessLab.CARTPOLE_TASK, 8, 2),
        (BrainlessLab.CARTPOLE_HARD_TASK, 8, 2),
        (BrainlessLab.CARTPOLE_SWINGUP_TASK, 8, 2),
        (BrainlessLab.CARTPOLE_LONG_TASK, 8, 2),
    )

    for (task, receptors_expected, effectors_expected) in task_counts
        env = BrainlessLab.make_env(task; rng=MersenneTwister(11))
        body = BrainlessLab.direct_embodiment(n_receptors(env), n_effectors(env))
        spec = portspec(body)

        @test body isa BrainlessLab.Embodiment
        @test body.geometry isa BrainlessLab.NoGeometry
        @test only(BrainlessLab.sensor_components(body)) isa BrainlessLab.DirectRelaySensor
        @test only(BrainlessLab.encoder_components(body)) isa BrainlessLab.IdentityEncoder
        @test only(BrainlessLab.actuator_components(body)) isa BrainlessLab.DirectRelayActuator
        @test body.dynamics isa BrainlessLab.NoDynamics
        @test body.physiology isa BrainlessLab.NoPhysiology
        @test n_receptors(body) == receptors_expected
        @test n_effectors(body) == effectors_expected
        @test n_receptors(spec) == receptors_expected
        @test n_effectors(spec) == effectors_expected
        @test length(BrainlessLab.ports(spec).receptors) == receptors_expected
        @test length(BrainlessLab.ports(spec).effectors) == effectors_expected
    end

    layout = BrainlessLab.SituatedSensorLayout()
    body = BrainlessLab.situated_embodiment(layout)
    @test BrainlessLab.situated_sensor(body) === layout
    @test only(BrainlessLab.encoder_components(body)) isa BrainlessLab.SituatedEncoder
    @test n_receptors(body) == 64
    @test n_effectors(body) == 3
end

@testset "Embodiment sampling and encoding stay distinct" begin
    layout = BrainlessLab.SituatedSensorLayout()
    situated = BrainlessLab.situated_embodiment(layout)
    percept62 = collect(1.0:62.0)
    percept64 = collect(1.0:64.0)

    @test only(values(BrainlessLab.rawspec(situated))) == BrainlessLab.rawspec(layout)
    @test BrainlessLab.sense!(situated, percept62) == BrainlessLab.assemble_inputs(percept62)
    @test BrainlessLab.sense!(situated, percept64) == percept64

    direct = BrainlessLab.direct_embodiment(2, 2)
    percept = [0.1, 0.2]
    effectors = [0.3, 0.4]

    @test BrainlessLab.sense!(direct, percept) == percept
    @test BrainlessLab.command_values(BrainlessLab.decode!(direct, effectors)) == effectors
end
