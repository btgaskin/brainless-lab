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
        (:actuator, :forward_turn),
        (:actuator, :antagonistic_turn),
        (:actuator, :differential_drive),
        (:actuator, :planar_force_yaw),
        (:dynamics, :unicycle),
        (:dynamics, :differential_drive),
        (:dynamics, :planar_rigid_body),
    ))
    registered = Set((descriptor.family, descriptor.kind) for descriptor in components())
    @test expected ⊆ registered
    @test length(BUILTIN_COMPONENT_DESCRIPTORS) == length(expected)
    expected_core = Set((
        (:geometry, :disc),
        (:physiology, :none),
        (:sensor, :spectral_camera),
        (:encoder, :identity),
        (:actuator, :differential_drive),
        (:dynamics, :differential_drive),
    ))
    core = Set(
        (descriptor.family, descriptor.kind)
        for descriptor in BUILTIN_COMPONENT_DESCRIPTORS
        if descriptor.readiness === :core
    )
    @test core == expected_core
    @test all(
        descriptor -> descriptor.readiness in (:integrated, :core),
        BUILTIN_COMPONENT_DESCRIPTORS,
    )

    rows = readiness()
    @test all(key -> any(row -> (row.family, row.kind) == key, rows), expected)
    markdown = readiness_markdown()
    @test occursin("| :geometry | :disc | :experimental | :core |", markdown)
    @test occursin("| :sensor | :spectral_camera | :experimental | :core |", markdown)
    @test occursin("| :encoder | :identity | :experimental | :core |", markdown)
    @test occursin(":bilateral_contrast_contract", markdown)
    @test component_info(:sensor, :spectral_camera).parameters.required ==
          (:channels, :field_of_view_deg, :rays, :range)
    @test :sensitivity in component_info(:sensor, :spectral_camera).parameters.optional
    @test component_info(:physiology, :regulated).parameters ==
          (required=(:variables,), optional=(:seed, :unknown_effects))

    root = pkgdir(BrainlessLab)
    paths = (
        joinpath(root, "examples", "embodiments", "differential_robot.toml"),
        joinpath(root, "examples", "embodiments", "planar_uav.toml"),
        joinpath(root, "examples", "embodiments", "bilateral_insect.toml"),
    )
    configs = read_embodiment_config.(paths)
    first_build = materialize_blueprint.(configs)
    second_build = materialize_blueprint.(configs)

    robot = first_build[1]
    @test robot.name === :differential_robot
    @test typeof.(getfield.(robot.components, :value)) == (
        DiscGeometry,
        SpectralCamera,
        DifferentialDriveActuator,
        DifferentialDriveDynamics,
    )
    robot_camera = robot.components[2].value
    @test robot_camera.channels == [:red, :green, :blue]
    @test robot_camera.grid.wavelengths_nm == collect(DEFAULT_CAMERA_WAVELENGTHS_NM)
    @test n_camera_rays(robot_camera) == 24
    @test rawspec(robot_camera).layout === :channel_major
    @test rawspec(robot_camera).width == 72
    @test n_receptors(robot_camera) == 72
    @test n_effectors(robot_camera) == 0
    @test length(ports(robot_camera).receptors) == 72
    @test ports(robot_camera).receptors[1].id === :red_ray_1
    @test ports(robot_camera).receptors[25].id === :green_ray_1
    @test robot_camera.max_range == 8.0
    @test robot.components[3].value.max_wheel_speed == 1.0
    @test robot.components[4].value.wheel_base == 0.55

    uav = first_build[2]
    @test uav.components[1].value isa DiscGeometry
    @test uav.components[2].value isa SpectralCamera
    @test uav.components[3].value isa MountedFieldProbe
    @test uav.components[4].value isa MountedFieldProbe
    @test uav.components[5].value isa BilateralContrastEncoder
    @test encoder_sources(uav.components[5].value) == (:antenna_left, :antenna_right)
    @test uav.components[6].value isa PlanarForceYawActuator
    @test uav.components[7].value isa PlanarRigidBodyDynamics
    @test uav.components[3].value.channel === :radio
    @test Tuple(uav.components[3].value.mount.position) == (0.12, 0.18)
    @test Tuple(uav.components[4].value.mount.position) == (0.12, -0.18)
    raw_probe = sample!(
        uav.components[3].value,
        ConstantSpatialField(0.75),
        (2.0, 2.0),
        0.0,
        0,
        WalledArena(10.0),
    )
    @test raw_probe == [0.75]
    @test encode!(uav.components[3].value, raw_probe) === raw_probe
    @test rawspec(uav.components[3].value).channel === :radio
    @test n_receptors(uav.components[3].value) == 1
    @test only(ports(uav.components[3].value).receptors).id === :field_radio
    @test component_state(uav.components[3].value).response == [0.75]
    @test reset!(uav.components[3].value) === uav.components[3].value
    @test uav.components[3].value.state.shared_seed == uav.components[4].value.state.shared_seed
    @test uav.components[3].value.state.independent_seed != uav.components[4].value.state.independent_seed
    @test uav.components[6].value.max_yaw_torque == 0.8
    @test uav.components[7].value.linear_drag == 0.08
    @test uav.components[7].value.angular_drag == 0.1

    insect = first_build[3]
    @test insect.components[2].value isa MountedFieldProbe
    @test Tuple(insect.components[2].value.mount.position) == (0.18, 0.12)
    @test Tuple(insect.components[3].value.mount.position) == (0.18, -0.12)
    @test insect.components[2].value.channel === :odor
    @test insect.components[2].value.response.tau == 2.0
    bilateral = insect.components[4].value
    @test bilateral isa BilateralContrastEncoder
    @test bilateral.left === :antenna_left
    @test bilateral.right === :antenna_right
    @test bilateral.encoder.epsilon == 1.0e-6
    @test encode_bilateral(bilateral, [1.0, 0.0])[1] < 1.0e-5
    @test insect.components[5].value.max_forward_speed == 0.8
    @test insect.components[5].value.max_turn_rate == 1.2
    @test insect.components[6].value.linear_tau == 0.1
    physiology = insect.components[7].value
    @test physiology isa RegulatedPhysiology
    @test Tuple(variable.name for variable in physiology.variables) == (:energy, :temperature)
    @test physiology.variables[1].mode isa TonicFeedback
    @test physiology.variables[1].failure isa BelowFailure
    @test physiology.variables[2].mode isa BernoulliFeedback
    @test physiology.variables[2].curve isa PowerResponse
    @test regulated_values(physiology) == (energy=0.75, temperature=1.0)
    @test physiology.unknown_effects isa RejectUnknownEffects

    @test robot_camera !== second_build[1].components[2].value
    @test robot_camera.grid.wavelengths_nm !==
          second_build[1].components[2].value.grid.wavelengths_nm
    @test robot_camera.sensitivity !== second_build[1].components[2].value.sensitivity
    first_probe = insect.components[2].value
    second_probe = second_build[3].components[2].value
    @test first_probe.state !== second_probe.state
    push!(first_probe.state.values, 2.0)
    @test length(second_probe.state.values) == 1

    explicit_camera = ComponentConfig(
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
    resolved_camera = component_info(:sensor, :spectral_camera).config_resolver(explicit_camera)
    @test resolved_camera.channels == [:short, :long]
    @test resolved_camera.sensitivity == [1.0 0.0 0.0; 0.0 0.0 1.0]
    @test resolved_camera.ray_angles ≈ [-pi / 4, 0.0, pi / 4]

    grid = resolved_camera.grid
    illuminant = SpectralIlluminant(grid, ones(3))
    reflectance = SpectralReflectance(grid, [1.0, 0.0, 0.0])
    sampled = sample!(
        resolved_camera,
        (0.0, 0.0),
        0.0,
        [SpectralCircleTarget(:target, (2.0, 0.0), 0.5, reflectance)],
        illuminant,
        WalledArena(10.0),
    )
    @test encode!(resolved_camera, sampled) === sampled.values

    disc_resolver = component_info(:geometry, :disc).config_resolver
    @test_throws ArgumentError disc_resolver(
        ComponentConfig(:shape, :geometry, :disc, (diameter=1.0,)),
    )
    @test_throws ArgumentError disc_resolver(
        ComponentConfig(:shape, :geometry, :disc, NamedTuple()),
    )
    @test_throws ArgumentError disc_resolver(
        ComponentConfig(:shape, :geometry, :disc, (radius="wide",)),
    )

    wheel_resolver = component_info(:actuator, :differential_drive).config_resolver
    error = try
        wheel_resolver(ComponentConfig(
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

    probe_resolver = component_info(:sensor, :field_probe).config_resolver
    common_left = probe_resolver(ComponentConfig(
        :common_left,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, 0.1), shared_sigma=0.2, independent_sigma=0.0),
    ))
    common_right = probe_resolver(ComponentConfig(
        :common_right,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, -0.1), shared_sigma=0.2, independent_sigma=0.0),
    ))
    probe_args = (ConstantSpatialField(0.5), (2.0, 2.0), 0.0, 1, WalledArena(5.0))
    @test sample!(common_left, probe_args...) == sample!(common_right, probe_args...)
    independent_left = probe_resolver(ComponentConfig(
        :independent_left,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, 0.1), shared_sigma=0.0, independent_sigma=0.2),
    ))
    independent_right = probe_resolver(ComponentConfig(
        :independent_right,
        :sensor,
        :field_probe,
        (channel="signal", mount=(0.1, -0.1), shared_sigma=0.0, independent_sigma=0.2),
    ))
    @test sample!(independent_left, probe_args...) != sample!(independent_right, probe_args...)

    physiology_resolver = component_info(:physiology, :regulated).config_resolver
    bad_mode = ComponentConfig(
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

    camera_resolver = component_info(:sensor, :spectral_camera).config_resolver
    unsupported_channel = ComponentConfig(
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
