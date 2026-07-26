@testset "built-in physical component catalog" begin
    expected = Set((
        (:geometry, :disc),
        (:physiology, :none),
        (:physiology, :regulated),
        (:sensor, :spectral_camera),
        (:sensor, :sector_vision),
        (:sensor, :field_probe),
        (:encoder, :identity),
        (:encoder, :bilateral_contrast),
        (:readout, :mean),
        (:readout, :instant),
        (:readout, :voting),
        (:actuator, :forward_turn),
        (:actuator, :antagonistic_turn),
        (:actuator, :differential_drive),
        (:actuator, :planar_force_yaw),
        (:dynamics, :unicycle),
        (:dynamics, :differential_drive),
        (:dynamics, :planar_rigid_body),
    ))
    registered = Set((descriptor.family, descriptor.kind) for descriptor in BrainlessLab.components())
    @test expected ⊆ registered
    @test length(BrainlessLab.BUILTIN_COMPONENT_DESCRIPTORS) == length(expected)
    expected_core = Set((
        (:geometry, :disc),
        (:physiology, :none),
        (:sensor, :spectral_camera),
        (:encoder, :identity),
        (:readout, :mean),
        (:actuator, :differential_drive),
        (:dynamics, :differential_drive),
    ))
    core = Set(
        (descriptor.family, descriptor.kind)
        for descriptor in BrainlessLab.BUILTIN_COMPONENT_DESCRIPTORS
        if descriptor.readiness === :core
    )
    @test core == expected_core
    @test all(
        descriptor -> descriptor.readiness in (:integrated, :core),
        BrainlessLab.BUILTIN_COMPONENT_DESCRIPTORS,
    )

    rows = BrainlessLab.readiness()
    @test all(key -> any(row -> (row.family, row.kind) == key, rows), expected)
    markdown = BrainlessLab.readiness_markdown()
    @test occursin("| :geometry | :disc | :experimental | :core |", markdown)
    @test occursin("| :sensor | :spectral_camera | :experimental | :core |", markdown)
    @test occursin("| :encoder | :identity | :experimental | :core |", markdown)
    @test occursin(":bilateral_contrast_contract", markdown)
    @test BrainlessLab.component_info(:sensor, :spectral_camera).parameters.required ==
          (:channels, :field_of_view_deg, :rays, :range)
    @test :sensitivity in BrainlessLab.component_info(:sensor, :spectral_camera).parameters.optional
    @test BrainlessLab.component_info(:physiology, :regulated).parameters ==
          (required=(:variables,), optional=(:seed, :unknown_effects))

    root = pkgdir(BrainlessLab)
    paths = (
        joinpath(root, "examples", "embodiments", "differential_robot.toml"),
        joinpath(root, "examples", "embodiments", "planar_uav.toml"),
        joinpath(root, "examples", "embodiments", "bilateral_insect.toml"),
    )
    configs = BrainlessLab.read_embodiment_config.(paths)
    first_build = BrainlessLab.materialize_blueprint.(configs)
    second_build = BrainlessLab.materialize_blueprint.(configs)

    robot = first_build[1]
    @test robot.name === :differential_robot
    @test typeof.(getfield.(robot.components, :value)) == (
        BrainlessLab.DiscGeometry,
        BrainlessLab.SpectralCamera,
        BrainlessLab.DifferentialDriveActuator,
        BrainlessLab.DifferentialDriveDynamics,
    )
    robot_camera = robot.components[2].value
    @test robot_camera.channels == [:red, :green, :blue]
    @test robot_camera.grid.wavelengths_nm == collect(BrainlessLab.DEFAULT_CAMERA_WAVELENGTHS_NM)
    @test BrainlessLab.n_camera_rays(robot_camera) == 24
    @test BrainlessLab.rawspec(robot_camera).layout === :channel_major
    @test BrainlessLab.rawspec(robot_camera).width == 72
    @test n_receptors(robot_camera) == 72
    @test n_effectors(robot_camera) == 0
    @test length(BrainlessLab.ports(robot_camera).receptors) == 72
    @test BrainlessLab.ports(robot_camera).receptors[1].id === :red_ray_1
    @test BrainlessLab.ports(robot_camera).receptors[25].id === :green_ray_1
    @test robot_camera.max_range == 8.0
    @test robot.components[3].value.max_wheel_speed == 1.0
    @test robot.components[4].value.wheel_base == 0.55

    uav = first_build[2]
    @test uav.components[1].value isa BrainlessLab.DiscGeometry
    @test uav.components[2].value isa BrainlessLab.SpectralCamera
    @test uav.components[3].value isa BrainlessLab.MountedFieldProbe
    @test uav.components[4].value isa BrainlessLab.MountedFieldProbe
    @test uav.components[5].value isa BrainlessLab.BilateralContrastEncoder
    @test BrainlessLab.encoder_sources(uav.components[5].value) == (:antenna_left, :antenna_right)
    @test uav.components[6].value isa BrainlessLab.PlanarForceYawActuator
    @test uav.components[7].value isa BrainlessLab.PlanarRigidBodyDynamics
    @test uav.components[3].value.channel === :radio
    @test Tuple(uav.components[3].value.mount.position) == (0.12, 0.18)
    @test Tuple(uav.components[4].value.mount.position) == (0.12, -0.18)
    raw_probe = BrainlessLab.sample!(
        uav.components[3].value,
        BrainlessLab.ConstantSpatialField(0.75),
        (2.0, 2.0),
        0.0,
        0,
        BrainlessLab.WalledArena(10.0),
    )
    @test raw_probe == [0.75]
    @test BrainlessLab.encode!(uav.components[3].value, raw_probe) === raw_probe
    @test BrainlessLab.rawspec(uav.components[3].value).channel === :radio
    @test n_receptors(uav.components[3].value) == 1
    @test only(BrainlessLab.ports(uav.components[3].value).receptors).id === :field_radio
    @test BrainlessLab.component_state(uav.components[3].value).response == [0.75]
    @test reset!(uav.components[3].value) === uav.components[3].value
    @test uav.components[3].value.state.shared_seed == uav.components[4].value.state.shared_seed
    @test uav.components[3].value.state.independent_seed != uav.components[4].value.state.independent_seed
    @test uav.components[6].value.max_yaw_torque == 0.8
    @test uav.components[7].value.linear_drag == 0.08
    @test uav.components[7].value.angular_drag == 0.1

    insect = first_build[3]
    @test insect.components[2].value isa BrainlessLab.MountedFieldProbe
    @test Tuple(insect.components[2].value.mount.position) == (0.18, 0.12)
    @test Tuple(insect.components[3].value.mount.position) == (0.18, -0.12)
    @test insect.components[2].value.channel === :odor
    @test insect.components[2].value.response.tau == 2.0
    bilateral = insect.components[4].value
    @test bilateral isa BrainlessLab.BilateralContrastEncoder
    @test bilateral.left === :antenna_left
    @test bilateral.right === :antenna_right
    @test bilateral.encoder.epsilon == 1.0e-6
    @test BrainlessLab.encode_bilateral(bilateral, [1.0, 0.0])[1] < 1.0e-5
    @test insect.components[5].value.max_forward_speed == 0.8
    @test insect.components[5].value.max_turn_rate == 1.2
    @test insect.components[6].value.linear_tau == 0.1
    physiology = insect.components[7].value
    @test physiology isa BrainlessLab.RegulatedPhysiology
    @test Tuple(variable.name for variable in physiology.variables) == (:energy, :temperature)
    @test physiology.variables[1].mode isa BrainlessLab.TonicFeedback
    @test physiology.variables[1].failure isa BrainlessLab.BelowFailure
    @test physiology.variables[2].mode isa BrainlessLab.BernoulliFeedback
    @test physiology.variables[2].curve isa BrainlessLab.PowerResponse
    @test BrainlessLab.regulated_values(physiology) == (energy=0.75, temperature=1.0)
    @test physiology.unknown_effects isa BrainlessLab.RejectUnknownEffects

    @test robot_camera !== second_build[1].components[2].value
    @test robot_camera.grid.wavelengths_nm !==
          second_build[1].components[2].value.grid.wavelengths_nm
    @test robot_camera.sensitivity !== second_build[1].components[2].value.sensitivity
    first_probe = insect.components[2].value
    second_probe = second_build[3].components[2].value
    @test first_probe.state !== second_probe.state
    push!(first_probe.state.values, 2.0)
    @test length(second_probe.state.values) == 1

    explicit_camera = BrainlessLab.ComponentConfig(
        :explicit,
        :sensor,
        :spectral_camera,
        (
            channels=("short", "long"),
            field_of_view_deg=90.0,
            rays=3,
            range=4.0,
            wavelengths_nm=(400, 500, 600),
            sensitivity=((1, 0, 0), (0, 0, 1)),
        ),
    )
    resolved_camera = BrainlessLab.component_info(:sensor, :spectral_camera).config_resolver(explicit_camera)
    @test resolved_camera.channels == [:short, :long]
    @test resolved_camera.sensitivity == [1.0 0.0 0.0; 0.0 0.0 1.0]
    @test resolved_camera.ray_angles ≈ [-pi / 4, 0.0, pi / 4]

    grid = resolved_camera.grid
    illuminant = BrainlessLab.SpectralIlluminant(grid, ones(3))
    reflectance = BrainlessLab.SpectralReflectance(grid, [1.0, 0.0, 0.0])
    sampled = BrainlessLab.sample!(
        resolved_camera,
        (0.0, 0.0),
        0.0,
        [BrainlessLab.SpectralCircleTarget(:target, (2.0, 0.0), 0.5, reflectance)],
        illuminant,
        BrainlessLab.WalledArena(10.0),
    )
    @test BrainlessLab.encode!(resolved_camera, sampled) === sampled.values

    disc_resolver = BrainlessLab.component_info(:geometry, :disc).config_resolver
    @test_throws ArgumentError disc_resolver(
        BrainlessLab.ComponentConfig(:shape, :geometry, :disc, (diameter=1.0,)),
    )
    @test_throws ArgumentError disc_resolver(
        BrainlessLab.ComponentConfig(:shape, :geometry, :disc, NamedTuple()),
    )
    @test_throws ArgumentError disc_resolver(
        BrainlessLab.ComponentConfig(:shape, :geometry, :disc, (radius="wide",)),
    )

    wheel_resolver = BrainlessLab.component_info(:actuator, :differential_drive).config_resolver
    error = try
        wheel_resolver(BrainlessLab.ComponentConfig(
            :wheels,
            :actuator,
            :differential_drive,
            (max_speed=1.0, wheel_base=0.5),
        ))
        nothing
    catch err
        err
    end
    @test error isa ArgumentError
    @test occursin("component :wheels", sprint(showerror, error))
    @test occursin("unknown parameter", sprint(showerror, error))

    probe_resolver = BrainlessLab.component_info(:sensor, :field_probe).config_resolver
    common_left = probe_resolver(BrainlessLab.ComponentConfig(
        :common_left,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, 0.1), shared_sigma=0.2, independent_sigma=0.0),
    ))
    common_right = probe_resolver(BrainlessLab.ComponentConfig(
        :common_right,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, -0.1), shared_sigma=0.2, independent_sigma=0.0),
    ))
    probe_args = (BrainlessLab.ConstantSpatialField(0.5), (2.0, 2.0), 0.0, 1, BrainlessLab.WalledArena(5.0))
    @test BrainlessLab.sample!(common_left, probe_args...) == BrainlessLab.sample!(common_right, probe_args...)
    independent_left = probe_resolver(BrainlessLab.ComponentConfig(
        :independent_left,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, 0.1), shared_sigma=0.0, independent_sigma=0.2),
    ))
    independent_right = probe_resolver(BrainlessLab.ComponentConfig(
        :independent_right,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, -0.1), shared_sigma=0.0, independent_sigma=0.2),
    ))
    @test BrainlessLab.sample!(independent_left, probe_args...) != BrainlessLab.sample!(independent_right, probe_args...)

    physiology_resolver = BrainlessLab.component_info(:physiology, :regulated).config_resolver
    bad_mode = BrainlessLab.ComponentConfig(
        :needs,
        :physiology,
        :regulated,
        (variables=((name="energy", feedback_mode="continuous"),),),
    )
    mode_error = try
        physiology_resolver(bad_mode)
        nothing
    catch err
        err
    end
    @test mode_error isa ArgumentError
    @test occursin("feedback_mode", sprint(showerror, mode_error))

    camera_resolver = BrainlessLab.component_info(:sensor, :spectral_camera).config_resolver
    unsupported_channel = BrainlessLab.ComponentConfig(
        :camera,
        :sensor,
        :spectral_camera,
        (channels=("infrared",), field_of_view_deg=60.0, rays=3, range=5.0),
    )
    channel_error = try
        camera_resolver(unsupported_channel)
        nothing
    catch err
        err
    end
    @test channel_error isa ArgumentError
    @test occursin("needs explicit :sensitivity", sprint(showerror, channel_error))
end
