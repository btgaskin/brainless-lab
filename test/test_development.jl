using Random

import BrainlessLab: effectors, n_effectors, n_nodes, n_receptors, step!

mutable struct _DevelopedRuntimeReservoir <: Reservoir
    nr::Int
    output::Vector{Float64}
end
n_receptors(reservoir::_DevelopedRuntimeReservoir) = reservoir.nr
n_effectors(reservoir::_DevelopedRuntimeReservoir) = length(reservoir.output)
n_nodes(::_DevelopedRuntimeReservoir) = 1
step!(::_DevelopedRuntimeReservoir, receptors) = [sum(receptors)]
effectors(reservoir::_DevelopedRuntimeReservoir, spikes) = copy(reservoir.output)

function _developed_runtime_sampler(body, state, tick, arena)
    samples = Tuple(begin
        sensor isa BrainlessLab.SpectralCamera || throw(ArgumentError("development runtime fixture expects cameras"))
        illuminant = BrainlessLab.SpectralIlluminant(sensor.grid, ones(length(sensor.grid)))
        reflectance = BrainlessLab.SpectralReflectance(sensor.grid, ones(length(sensor.grid)))
        target = BrainlessLab.SpectralCircleTarget(
            :target,
            (state.position[1] + 2.0, state.position[2]),
            0.5,
            reflectance,
        )
        BrainlessLab.sample!(sensor, state.position, state.heading, [target], illuminant, arena).values
    end for sensor in BrainlessLab.sensor_components(body))
    return length(samples) == 1 ? only(samples) : samples
end

function _development_test_config(name::AbstractString)
    return BrainlessLab.read_embodiment_config(joinpath(
        pkgdir(BrainlessLab), "examples", "embodiments", name,
    ))
end

function _development_replace_component(config::BrainlessLab.EmbodimentConfig, replacement::BrainlessLab.ComponentConfig)
    components = Tuple(
        component.id === replacement.id ? replacement : component
        for component in config.components
    )
    return BrainlessLab.EmbodimentConfig(config.schema_version, config.name, components, config.source)
end

function _development_drop_family(config::BrainlessLab.EmbodimentConfig, family::Symbol)
    components = Tuple(component for component in config.components if component.family !== family)
    return BrainlessLab.EmbodimentConfig(config.schema_version, config.name, components, config.source)
end

@testset "bounded development maps genotype to fresh embodiment blueprints" begin
    config = _development_test_config("differential_robot.toml")
    blocks = (
        BrainlessLab.DevelopmentBlock(:shape, :chassis, :radius => (0.2, 0.6)),
        BrainlessLab.DevelopmentBlock(
            :camera_optics,
            :camera,
            :range => (2.0, 20.0),
            "field_of_view_deg" => (60.0, 180.0),
        ),
        BrainlessLab.DevelopmentBlock(:drive, :wheels, :max_speed => (0.2, 3.0)),
        BrainlessLab.DevelopmentBlock(:wheelbase, :motion, :wheel_base => (0.2, 1.0)),
    )
    spec = BrainlessLab.DevelopmentSpec(config, blocks)
    base = BrainlessLab.DevelopmentGenotype(spec)

    @test !Base.ismutabletype(typeof(spec))
    @test !Base.ismutabletype(typeof(base))
    @test spec.slices == (1:1, 2:3, 4:4, 5:5)
    @test paramdim(spec) == 5
    @test pack_params(spec) == [0.35, 8.0, 120.0, 1.0, 0.55]
    @test pack_params(base) == pack_params(spec)
    @test [entry.label for entry in BrainlessLab.paramspace(spec)] == [
        :shape__radius,
        :camera_optics__range,
        :camera_optics__field_of_view_deg,
        :drive__max_speed,
        :wheelbase__wheel_base,
    ]

    raw = [0.45, 10.0, 150.0, 1.7, 0.7]
    genotype = unpack_params(spec, raw)
    context = BrainlessLab.DevelopmentContext(seed=41, entity_id=7, generation=3)
    first = BrainlessLab.develop(genotype, context)
    second = BrainlessLab.develop(spec, raw, context)

    @test first.context === context
    @test first.structure_signature == spec.signature
    @test getfield.(first.components, :id) == (:chassis, :camera, :wheels, :motion)
    @test typeof.(getfield.(first.components, :value)) == (
        BrainlessLab.DiscGeometry,
        BrainlessLab.SpectralCamera,
        BrainlessLab.DifferentialDriveActuator,
        BrainlessLab.DifferentialDriveDynamics,
    )
    @test first.components[1].value.radius == 0.45
    @test first.components[2].value.max_range == 10.0
    @test rad2deg(
        last(first.components[2].value.ray_angles) - Base.first(first.components[2].value.ray_angles),
    ) ≈ 150.0
    @test first.components[3].value.max_wheel_speed == 1.7
    @test first.components[4].value.wheel_base == 0.7

    # Development never stores or reuses transient component state.
    @test first.components[2].value !== second.components[2].value
    @test first.components[2].value.grid.wavelengths_nm !==
          second.components[2].value.grid.wavelengths_nm
    @test first.components[2].value.sensitivity !== second.components[2].value.sensitivity
    @test first.component_seeds == second.component_seeds
    @test config.components[1].parameters.radius == 0.35

    first_body = BrainlessLab.materialize_embodiment(first)
    second_body = BrainlessLab.materialize_embodiment(second)
    @test first_body isa BrainlessLab.Embodiment
    @test first_body !== second_body
    @test first_body.sensors[1] !== second_body.sensors[1]
    @test n_receptors(first_body) == 72
    state = BrainlessLab.MotionState2D(position=(5.0, 5.0), heading=0.0)
    environment = BrainlessLab.EmbodiedEnvironment(BrainlessLab.WalledArena(20.0), [state], _developed_runtime_sampler)
    reservoir = _DevelopedRuntimeReservoir(n_receptors(first_body), [1.0, 1.0])
    ensemble = BrainlessLab.Ensemble([BrainlessLab.Agent(reservoir, first_body)], environment)
    before = environment.states[1].position
    step!(ensemble)
    @test environment.tick == 1
    @test environment.states[1].position != before

    @test BrainlessLab.development_seed(context, :camera) == BrainlessLab.development_seed(context, :camera)
    @test BrainlessLab.development_seed(context, :camera) != BrainlessLab.development_seed(context, :wheels)
    @test BrainlessLab.development_seed(context, :camera) != BrainlessLab.development_seed(
        BrainlessLab.DevelopmentContext(seed=41, entity_id=8, generation=3), :camera,
    )
    @test_throws ArgumentError BrainlessLab.DevelopmentContext(seed=-1)
    @test_throws ArgumentError BrainlessLab.DevelopmentContext(generation=-1)
    @test_throws DimensionMismatch BrainlessLab.DevelopmentGenotype(spec, raw[1:end-1])
    @test_throws ArgumentError BrainlessLab.DevelopmentGenotype(spec, [0.1, raw[2:end]...])
    @test_throws ArgumentError BrainlessLab.DevelopmentGenotype(spec, [NaN, raw[2:end]...])
end

@testset "development context creates reproducible but unshared sensor state" begin
    config = _development_test_config("bilateral_insect.toml")
    noisy_left = BrainlessLab.ComponentConfig(
        :antenna_left,
        :sensor,
        :field_probe,
        merge(
            config.components[2].parameters,
            (shared_sigma=0.1, independent_sigma=0.1),
        ),
    )
    config = _development_replace_component(config, noisy_left)
    spec = BrainlessLab.DevelopmentSpec(
        config,
        BrainlessLab.DevelopmentBlock(:response, :antenna_left, :response_tau => (0.0, 5.0)),
    )
    context = BrainlessLab.DevelopmentContext(seed=9, entity_id=2, generation=1)
    first = BrainlessLab.develop(spec, context)
    second = BrainlessLab.develop(spec, context)
    third = BrainlessLab.develop(spec, BrainlessLab.DevelopmentContext(seed=9, entity_id=3, generation=1))
    first_probe = first.components[2].value
    second_probe = second.components[2].value
    third_probe = third.components[2].value

    @test first_probe isa BrainlessLab.MountedFieldProbe
    @test first_probe.state !== second_probe.state
    @test first_probe.state.values !== second_probe.state.values
    @test first_probe.state.shared_rng !== second_probe.state.shared_rng
    @test first_probe.state.shared_seed == second_probe.state.shared_seed
    @test first_probe.state.shared_seed != third_probe.state.shared_seed

    args = (BrainlessLab.ConstantSpatialField(0.5), (1.0, 1.0), 0.0, 0, BrainlessLab.WalledArena(4.0))
    @test BrainlessLab.sample_field_probe!(first_probe, args...) == BrainlessLab.sample_field_probe!(second_probe, args...)
    @test BrainlessLab.sample_field_probe!(first_probe, args...) != BrainlessLab.sample_field_probe!(third_probe, args...)
    first_probe.state.values[1] = 0.0
    @test first_probe.state.values != second_probe.state.values

    first_physiology = first.components[7].value
    second_physiology = second.components[7].value
    third_physiology = third.components[7].value
    @test first_physiology isa BrainlessLab.RegulatedPhysiology
    @test first_physiology.seed == second_physiology.seed
    @test first_physiology.seed != third_physiology.seed
    @test first_physiology.seed != config.components[7].parameters.seed
    for physiology in (first_physiology, second_physiology, third_physiology)
        physiology.values[2] = 0.0
    end
    function feedback_stream!(physiology)
        values = Float64[]
        for _ in 1:128
            push!(values, last(BrainlessLab.physiology_feedback!(physiology)))
            BrainlessLab.physiology_update!(physiology)
        end
        return values
    end
    first_stream = feedback_stream!(first_physiology)
    second_stream = feedback_stream!(second_physiology)
    third_stream = feedback_stream!(third_physiology)
    @test first_stream == second_stream
    @test first_stream != third_stream
end

@testset "development paths address tuple coordinates and named regulated variables" begin
    config = _development_test_config("bilateral_insect.toml")
    spec = BrainlessLab.DevelopmentSpec(config, (
        BrainlessLab.DevelopmentBlock(:left_mount, :antenna_left, "mount.2" => (-0.25, 0.25)),
        BrainlessLab.DevelopmentBlock(:energy_gain, :metabolism, "variables.energy.gain" => (0.1, 1.0)),
        BrainlessLab.DevelopmentBlock(
            :temperature_emission,
            :metabolism,
            (:variables, :temperature, :emission_p) => (0.01, 0.5),
        ),
    ))
    @test pack_params(spec) == [0.12, 0.5, 0.1]
    @test [entry.label for entry in BrainlessLab.paramspace(spec)] == [
        :left_mount__mount__2,
        :energy_gain__variables__energy__gain,
        :temperature_emission__variables__temperature__emission_p,
    ]

    developed = BrainlessLab.develop(
        spec,
        [0.2, 0.8, 0.25],
        BrainlessLab.DevelopmentContext(seed=4, entity_id=12, generation=2),
    )
    left_probe = developed.components[2].value
    physiology = developed.components[7].value
    @test Tuple(left_probe.mount.position) == (0.18, 0.2)
    @test physiology.variables[1].name === :energy
    @test physiology.variables[1].gain == 0.8
    @test physiology.variables[2].name === :temperature
    @test physiology.variables[2].emission_p == 0.25

    # Numeric collection paths remain available when a collection has no stable
    # named-member convention, and the source configuration stays immutable.
    indexed = BrainlessLab.DevelopmentSpec(
        config,
        BrainlessLab.DevelopmentBlock(:indexed_gain, :metabolism, "variables.1.gain" => (0.1, 1.0)),
    )
    @test pack_params(indexed) == [0.5]
    @test config.components[2].parameters.mount == (0.18, 0.12)
    @test config.components[7].parameters.variables[1].gain == 0.5

    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(
        config,
        BrainlessLab.DevelopmentBlock(:missing_need, :metabolism, "variables.missing.gain" => (0.1, 1.0)),
    )
    @test_throws ArgumentError BrainlessLab.DevelopmentBlock(:bad_index, :antenna_left, ("mount", 0) => (-0.2, 0.2))
    @test_throws ArgumentError BrainlessLab.DevelopmentBlock(:bad_string_index, :antenna_left, "mount.0" => (-0.2, 0.2))
end

@testset "development mutation and recombination preserve fixed bounded structure" begin
    config = _development_test_config("differential_robot.toml")
    spec = BrainlessLab.DevelopmentSpec(config, (
        BrainlessLab.DevelopmentBlock(:shape, :chassis, :radius => (0.2, 0.6)),
        BrainlessLab.DevelopmentBlock(:drive, :wheels, :max_speed => (0.2, 3.0)),
    ))
    left = BrainlessLab.DevelopmentGenotype(spec)
    right = BrainlessLab.DevelopmentGenotype(spec, [0.6, 3.0])

    @test pack_params(BrainlessLab.mutate(left, MersenneTwister(3); sigma=0.0)) == pack_params(left)
    mutated_a = BrainlessLab.mutate(left, MersenneTwister(3); sigma=10.0)
    mutated_b = BrainlessLab.mutate(left, MersenneTwister(3); sigma=10.0)
    @test mutated_a.values == mutated_b.values
    @test all(
        entry.lo <= value <= entry.hi
        for (value, entry) in zip(mutated_a.values, BrainlessLab.paramspace(spec))
    )

    @test BrainlessLab.recombine(left, right, MersenneTwister(4); left_probability=1.0).values == left.values
    @test BrainlessLab.recombine(left, right, MersenneTwister(4); left_probability=0.0).values == right.values
    child_a = BrainlessLab.recombine(left, right, MersenneTwister(5))
    child_b = BrainlessLab.recombine(left, right, MersenneTwister(5))
    @test child_a.values == child_b.values
    @test all(child_a.values[i] in (left.values[i], right.values[i]) for i in eachindex(child_a.values))
    @test_throws ArgumentError BrainlessLab.mutate(left, MersenneTwister(1); sigma=-0.1)
    @test_throws ArgumentError BrainlessLab.recombine(left, right, MersenneTwister(1); left_probability=1.1)

    other = BrainlessLab.DevelopmentSpec(config, BrainlessLab.DevelopmentBlock(:shape, :chassis, :radius => (0.1, 0.7)))
    @test_throws ArgumentError BrainlessLab.recombine(
        left,
        BrainlessLab.DevelopmentGenotype(other),
        MersenneTwister(1),
    )
end

@testset "development structure validation rejects unsafe compositions" begin
    robot = _development_test_config("differential_robot.toml")
    insect = _development_test_config("bilateral_insect.toml")

    duplicate_blocks = (
        BrainlessLab.DevelopmentBlock(:shape, :chassis, :radius => (0.2, 0.6)),
        BrainlessLab.DevelopmentBlock(:shape, :wheels, :max_speed => (0.2, 3.0)),
    )
    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(robot, duplicate_blocks)
    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(robot, (
        BrainlessLab.DevelopmentBlock(:a, :chassis, :radius => (0.2, 0.6)),
        BrainlessLab.DevelopmentBlock(:b, :chassis, :radius => (0.2, 0.6)),
    ))
    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(
        robot,
        BrainlessLab.DevelopmentBlock(:missing, :nowhere, :radius => (0.2, 0.6)),
    )
    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(
        robot,
        BrainlessLab.DevelopmentBlock(:missing, :chassis, :diameter => (0.2, 0.6)),
    )
    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(
        robot,
        BrainlessLab.DevelopmentBlock(:nonscalar, :camera, :channels => (0.0, 1.0)),
    )
    @test_throws ArgumentError BrainlessLab.DevelopmentSpec(
        robot,
        BrainlessLab.DevelopmentBlock(:outside, :chassis, :radius => (0.4, 0.6)),
    )

    bilateral = insect.components[4]
    missing_reference = BrainlessLab.ComponentConfig(
        bilateral.id,
        bilateral.family,
        bilateral.kind,
        merge(bilateral.parameters, (left="missing",)),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_replace_component(insect, missing_reference),
    )
    same_reference = BrainlessLab.ComponentConfig(
        bilateral.id,
        bilateral.family,
        bilateral.kind,
        merge(bilateral.parameters, (right=bilateral.parameters.left,)),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_replace_component(insect, same_reference),
    )

    incompatible_actuator = BrainlessLab.ComponentConfig(
        :wheels,
        :actuator,
        :forward_turn,
        (max_forward=1.0, max_turn=1.0),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_replace_component(robot, incompatible_actuator),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :geometry),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :dynamics),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :actuator),
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :sensor),
    )
    @test BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :geometry); physical=false,
    ) isa BrainlessLab.EmbodimentConfig
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :actuator); physical=false,
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        _development_drop_family(robot, :sensor); physical=false,
    )

    duplicate_dynamics = BrainlessLab.EmbodimentConfig(
        robot.schema_version,
        robot.name,
        (
            robot.components...,
            BrainlessLab.ComponentConfig(
                :backup_motion,
                :dynamics,
                :differential_drive,
                (wheel_base=0.55,),
            ),
        ),
        robot.source,
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(duplicate_dynamics)

    metabolism = only(component for component in insect.components if component.family === :physiology)
    duplicate_physiology = BrainlessLab.EmbodimentConfig(
        insect.schema_version,
        insect.name,
        (
            insect.components...,
            BrainlessLab.ComponentConfig(
                :backup_metabolism,
                metabolism.family,
                metabolism.kind,
                metabolism.parameters,
            ),
        ),
        insect.source,
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(duplicate_physiology)
    @test_throws ArgumentError BrainlessLab.materialize_embodiment(duplicate_physiology)

    unsupported = BrainlessLab.EmbodimentConfig(
        robot.schema_version,
        robot.name,
        (
            robot.components...,
            BrainlessLab.ComponentConfig(:status_light, :accessory, :test_tag, NamedTuple()),
        ),
        robot.source,
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(unsupported)

    wheels = only(component for component in robot.components if component.family === :actuator)
    no_dynamics = _development_drop_family(robot, :dynamics)
    multi_actuator_no_dynamics = BrainlessLab.EmbodimentConfig(
        no_dynamics.schema_version,
        no_dynamics.name,
        (
            no_dynamics.components...,
            BrainlessLab.ComponentConfig(:backup_wheels, wheels.family, wheels.kind, wheels.parameters),
        ),
        no_dynamics.source,
    )
    @test BrainlessLab.validate_development_structure(
        multi_actuator_no_dynamics;
        physical=false,
    ) isa BrainlessLab.EmbodimentConfig
    passive_body = BrainlessLab.materialize_embodiment(multi_actuator_no_dynamics)
    @test length(BrainlessLab.actuator_components(passive_body)) == 2
    @test passive_body.dynamics isa BrainlessLab.NoDynamics
    @test_throws ArgumentError BrainlessLab.validate_development_structure(multi_actuator_no_dynamics)

    multi_actuator_with_dynamics = BrainlessLab.EmbodimentConfig(
        robot.schema_version,
        robot.name,
        (
            robot.components...,
            BrainlessLab.ComponentConfig(:backup_wheels, wheels.family, wheels.kind, wheels.parameters),
        ),
        robot.source,
    )
    @test_throws ArgumentError BrainlessLab.validate_development_structure(
        multi_actuator_with_dynamics;
        physical=false,
    )
    @test_throws ArgumentError BrainlessLab.materialize_embodiment(multi_actuator_with_dynamics)
end
