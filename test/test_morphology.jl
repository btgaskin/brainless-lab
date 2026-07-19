using BrainlessLab
using Random
using Test

@testset "Embodiment component composition and task relays" begin
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
        body = direct_embodiment(n_receptors(env), n_effectors(env))
        spec = portspec(body)

        @test body isa Embodiment
        @test body.geometry isa NoGeometry
        @test only(sensor_components(body)) isa DirectRelaySensor
        @test only(encoder_components(body)) isa IdentityEncoder
        @test only(actuator_components(body)) isa DirectRelayActuator
        @test body.dynamics isa NoDynamics
        @test body.physiology isa NoPhysiology
        @test n_receptors(body) == receptors_expected
        @test n_effectors(body) == effectors_expected
        @test n_receptors(spec) == receptors_expected
        @test n_effectors(spec) == effectors_expected
        @test length(ports(spec).receptors) == receptors_expected
        @test length(ports(spec).effectors) == effectors_expected
    end

    layout = SituatedSensorLayout()
    body = situated_embodiment(layout)
    @test situated_sensor(body) === layout
    @test only(encoder_components(body)) isa SituatedEncoder
    @test n_receptors(body) == 64
    @test n_effectors(body) == 3
end

@testset "Embodiment sampling and encoding stay distinct" begin
    layout = SituatedSensorLayout()
    situated = situated_embodiment(layout)
    percept62 = collect(1.0:62.0)
    percept64 = collect(1.0:64.0)

    @test only(values(rawspec(situated))) == rawspec(layout)
    @test sense!(situated, percept62) == assemble_inputs(percept62)
    @test sense!(situated, percept64) == percept64

    direct = direct_embodiment(2, 2)
    percept = [0.1, 0.2]
    effectors = [0.3, 0.4]

    @test sense!(direct, percept) == percept
    @test command_values(decode!(direct, effectors)) == effectors
end
