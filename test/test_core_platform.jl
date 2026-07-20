using BrainlessLab
using Test

@testset "core_differential_robot_roundtrip" begin
    preset = joinpath(
        pkgdir(BrainlessLab),
        "examples",
        "embodiments",
        "differential_robot.toml",
    )
    config = read_embodiment_config(preset)
    first = materialize_embodiment(config)
    second = materialize_embodiment(config)

    @test first isa Embodiment
    @test first !== second
    @test first.geometry isa DiscGeometry
    @test only(sensor_components(first)) isa SpectralCamera
    @test only(encoder_components(first)) isa IdentityEncoder
    @test only(actuator_components(first)) isa DifferentialDriveActuator
    @test first.dynamics isa DifferentialDriveDynamics
    @test first.physiology isa NoPhysiology
    @test n_receptors(first) == 72
    @test n_effectors(first) == 2
end

@testset "core_identity_encoder_composition" begin
    descriptor = component_info(:encoder, :identity)
    configured = descriptor.config_resolver(ComponentConfig(
        :camera_passthrough,
        :encoder,
        :identity,
        (
            ports=("red", "green", "blue"),
            sources=("camera",),
        ),
    ))
    @test configured isa IdentityEncoder
    @test configured.port_ids == (:red, :green, :blue)
    @test encoder_sources(configured) == (:camera,)

    auto = materialize_embodiment(read_embodiment_config(joinpath(
        pkgdir(BrainlessLab),
        "examples",
        "embodiments",
        "differential_robot.toml",
    )))
    auto_encoder = only(encoder_components(auto))
    @test encoder_sources(auto_encoder) == (:camera,)
    @test length(auto_encoder.port_ids) == n_receptors(only(sensor_components(auto)))
end

@testset "core_no_physiology_default" begin
    descriptor = component_info(:physiology, :none)
    rejecting = descriptor.config_resolver(ComponentConfig(
        :none,
        :physiology,
        :none,
        NamedTuple(),
    ))
    ignoring = descriptor.config_resolver(ComponentConfig(
        :none,
        :physiology,
        :none,
        (unknown_effects="ignore",),
    ))
    @test rejecting isa NoPhysiology
    @test rejecting.unknown_effects isa RejectUnknownEffects
    @test ignoring.unknown_effects isa IgnoreUnknownEffects
end

@testset "core_object_world_runtime" begin
    include(joinpath(
        pkgdir(BrainlessLab),
        "examples",
        "embodiments",
        "object_world_quickstart.jl",
    ))
    result = run_object_world_quickstart(; ticks=3, seed=13)
    poses = getchannel(result.recorder, :poses)
    receptors_ = getchannel(result.recorder, :receptors)
    @test length(poses) == 3
    @test length(receptors_) == 3
    @test all(frame -> length(only(frame.values)) == 72, receptors_)
    @test any(
        frame -> any(agent_input -> any(!iszero, agent_input), frame.values),
        receptors_,
    )
    @test only(first(poses).values) != only(last(poses).values)
    @test last(poses).ids == [EntityID(101)]
    @test only(result.objects).kind === :beacon
end
