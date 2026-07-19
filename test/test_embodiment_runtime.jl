using BrainlessLab
using Test

import BrainlessLab: effectors, n_effectors, n_nodes, n_receptors, reset!, step!

mutable struct _PresetReservoir <: Reservoir
    nr::Int
    output::Vector{Float64}
end
n_receptors(reservoir::_PresetReservoir) = reservoir.nr
n_effectors(reservoir::_PresetReservoir) = length(reservoir.output)
n_nodes(::_PresetReservoir) = 1
step!(::_PresetReservoir, receptors) = [sum(receptors)]
effectors(reservoir::_PresetReservoir, spikes) = copy(reservoir.output)

mutable struct _ResettableBodyState
    value::Int
end
reset!(state::_ResettableBodyState) = (state.value = 0; state)

function _runtime_sensor_sample(sensor, state, tick, arena)
    if sensor isa SpectralCamera
        illuminant = SpectralIlluminant(sensor.grid, ones(length(sensor.grid)))
        reflectance = SpectralReflectance(sensor.grid, ones(length(sensor.grid)))
        target = SpectralCircleTarget(
            :target,
            (state.position[1] + 2.0, state.position[2]),
            0.5,
            reflectance,
        )
        return sample!(
            sensor,
            state.position,
            state.heading,
            [target],
            illuminant,
            arena,
        ).values
    elseif sensor isa MountedFieldProbe
        field = LinearSpatialField((0.0, 0.0), (0.0, 1.0); offset=0.0, scale=10.0)
        return sample!(sensor, field, state.position, state.heading, tick, arena)
    end
    throw(ArgumentError("unsupported runtime-test sensor $(typeof(sensor))"))
end

function _runtime_sampler(body, state, tick, arena)
    samples = Tuple(
        _runtime_sensor_sample(sensor, state, tick, arena)
        for sensor in sensor_components(body)
    )
    return length(samples) == 1 ? only(samples) : samples
end

function _preset_body(name)
    path = joinpath(pkgdir(BrainlessLab), "examples", "embodiments", "$(name).toml")
    return materialize_embodiment(read_embodiment_config(path))
end

@testset "port contracts reject invalid counts and ambiguous identities" begin
    @test_throws ArgumentError PortSpec(-1, 0)
    @test_throws ArgumentError PortSpec(0, -1)
    @test_throws ArgumentError PortSpec(
        2,
        0,
        [Port(:duplicate), Port(:duplicate)],
        typeof(Port(:unused))[],
    )
    @test_throws ArgumentError PortSpec(
        1,
        1,
        [Port(:shared)],
        [Port(:shared)],
    )
end

@testset "configured embodiments run through the main physical loop" begin
    cases = (
        (:differential_robot, 72, 2, [1.0, 0.0], DifferentialDriveCommand),
        (:planar_uav, 97, 3, [1.0, 0.5, 1.0], PlanarForceYawCommand),
        (:bilateral_insect, 3, 2, [1.0, 0.75], ForwardTurnCommand),
    )

    for (name, nr, ne, output, command_type) in cases
        body = _preset_body(name)
        @test body isa Embodiment
        @test portspec(body) === portspec(body)
        @test n_receptors(body) == nr
        @test n_effectors(body) == ne
        @test length(unique(port.id for port in ports(body).receptors)) == nr
        @test all(slot -> component_id(slot) isa Symbol, component_slots(body).sensors)
        if name === :planar_uav
            @test length(encoder_components(body)) == 2
            @test encoder_sources(encoder_components(body)[1]) ==
                  (:antenna_left, :antenna_right)
            @test encoder_sources(encoder_components(body)[2]) == (:camera,)
            @test component_id(component_slots(body).encoders[2]) ===
                  :camera__identity_encoder
        end

        state = MotionState2D(position=(5.0, 5.0), heading=0.0)
        environment = EmbodiedEnvironment(WalledArena(20.0), [state], _runtime_sampler)
        raw = only(sample!(environment, [body]))
        encoded = sense!(body, raw)
        @test sense!(body, raw) === encoded
        @test length(encoded) == nr
        if name === :bilateral_insect
            @test encoded[1] < 0.5
            @test encoded[2] ≈ 0.125
            @test encoded[3] == 0.0
        end
        if name === :planar_uav
            @test body.state.encoder_groups[1][4] == (2, 3)
            @test body.state.encoder_groups[2][4] == (1,)
            @test encoded[2:end] == raw[1]
        end

        command = decode!(body, output)
        @test command isa command_type
        @test decode!(body, output) === command

        reservoir = _PresetReservoir(nr, output)
        ensemble = Ensemble([Agent(reservoir, body)], environment)
        before = copy(environment.states[1].position)
        step!(ensemble)
        @test environment.tick == 1
        @test environment.states[1].position != before
        @test only(body.state.commands) === command
    end
end

@testset "inactive embodiments do not integrate inertial motion" begin
    body = _preset_body(:bilateral_insect)
    body.physiology.is_alive = false
    state = MotionState2D(
        position=(5.0, 5.0),
        velocity=(0.75, -0.25),
        angular_velocity=0.4,
    )
    environment = EmbodiedEnvironment(WalledArena(20.0), [state], _runtime_sampler)
    before = (
        position=state.position,
        velocity=state.velocity,
        heading=state.heading,
        angular_velocity=state.angular_velocity,
    )

    effects = apply_commands!(environment, [body], [ForwardTurnCommand(0.8, 1.2)])

    @test only(effects) == ()
    @test environment.tick == 1
    @test state.position == before.position
    @test state.velocity == before.velocity
    @test state.heading == before.heading
    @test state.angular_velocity == before.angular_velocity
end

@testset "embodied activity owns reset and active-only motion metrics" begin
    active_body = _preset_body(:bilateral_insect)
    inactive_body = _preset_body(:bilateral_insect)
    inactive_body.physiology.is_alive = false
    environment = EmbodiedEnvironment(
        WalledArena(20.0),
        [
            MotionState2D(position=(3.0, 4.0), velocity=(3.0, 4.0)),
            MotionState2D(position=(7.0, 8.0), velocity=(8.0, 6.0)),
        ],
        _runtime_sampler,
    )
    sync_activity!(environment, [active_body, inactive_body])
    @test environment.initial_active_agents == BitVector([true, false])
    @test environment.active_agents == BitVector([true, false])
    @test Tuple(environment.states[1].velocity) == (3.0, 4.0)
    @test Tuple(environment.states[2].velocity) == (0.0, 0.0)
    @test metrics(environment) == (
        mean_speed=5.0,
        active_count=1,
        active_fraction=0.5,
    )
    environment.states[1].position = (9.0, 9.0)
    environment.states[1].velocity = (0.0, 0.0)
    fill!(environment.active_agents, false)
    environment.tick = 7
    reset!(environment)
    @test environment.tick == 0
    @test Tuple(environment.states[1].position) == (3.0, 4.0)
    @test Tuple(environment.states[1].velocity) == (3.0, 4.0)
    @test Tuple(environment.states[2].position) == (7.0, 8.0)
    @test Tuple(environment.states[2].velocity) == (0.0, 0.0)
    @test environment.active_agents == BitVector([true, false])
end

@testset "embodiment runtime configuration retains the component graph" begin
    robot = _preset_body(:differential_robot)
    config = BrainlessLab._body_config(robot)
    @test config.kind === :embodiment
    @test config.component_ids.geometry === :chassis
    @test config.component_ids.sensors == (:camera,)
    @test config.component_ids.actuators == (:wheels,)
    @test config.component_ids.dynamics === :motion
    @test only(config.sensors).kind === :spectral_camera
    @test only(config.sensors).channels == (:red, :green, :blue)
    @test length(only(config.sensors).wavelengths_nm) == length(DEFAULT_CAMERA_WAVELENGTHS_NM)
    @test length(only(config.sensors).sensitivity) == 3
    @test only(config.actuators).max_wheel_speed == 1.0
    @test config.dynamics.wheel_base == 0.55

    uav_config = BrainlessLab._body_config(_preset_body(:planar_uav))
    @test uav_config.component_ids.encoders == (:radio_contrast, :camera__identity_encoder)
    @test uav_config.encoders[1].left === :antenna_left
    @test uav_config.encoders[2].sources == (:camera,)

    insect = _preset_body(:bilateral_insect)
    insect_config = BrainlessLab._body_config(insect)
    @test insect_config.component_ids.physiology === :metabolism
    @test insect_config.physiology.kind === :regulated
    @test insect_config.physiology.unknown_effects === :reject
    @test Tuple(variable.name for variable in insect_config.physiology.variables) ==
          (:energy, :temperature)
    @test insect_config.sensors[1].mount.position == (0.18, 0.12)
    @test insect_config.sensors[1].shared_seed == 0
    @test only(insect_config.encoders).left === :antenna_left
end

@testset "component state records by stable entity and component IDs" begin
    body = _preset_body(:bilateral_insect)
    state = MotionState2D(position=(5.0, 5.0))
    environment = EmbodiedEnvironment(WalledArena(20.0), [state], _runtime_sampler)
    reservoir = _PresetReservoir(n_receptors(body), [1.0, 0.75])
    recorder = Recorder(enabled=(:components,))
    ensemble = Ensemble([Agent(reservoir, body)], environment; ids=[EntityID(41)], recorder=recorder)
    step!(ensemble)
    frame = only(getchannel(recorder, :components))
    @test frame isa EntityFrame
    @test frame.ids == [EntityID(41)]
    components = only(frame)
    @test hasproperty(components, :antenna_left)
    @test hasproperty(components, :antenna_right)
    @test hasproperty(components, :metabolism)
    @test components.antenna_left.response[1] > 0.0
end

@testset "inactive embodiments do not advance stateful sensors" begin
    body = _preset_body(:bilateral_insect)
    left = component_value(first(component_slots(body).sensors))
    before = copy(left.state.values)
    body.physiology.is_alive = false
    environment = EmbodiedEnvironment(
        WalledArena(20.0),
        [MotionState2D(position=(5.0, 5.0))],
        _runtime_sampler,
    )
    percept = only(sample!(environment, [body]))
    @test all(sample -> all(iszero, sample), percept)
    @test left.state.values == before
    @test all(iszero, sense!(body, percept))
end

@testset "embodiment reset and effect policy are explicit" begin
    body = _preset_body(:bilateral_insect)
    state = MotionState2D(position=(5.0, 5.0))
    environment = EmbodiedEnvironment(WalledArena(20.0), [state], _runtime_sampler)
    sense!(body, only(sample!(environment, [body])))
    @test any(!iszero, component_value(first(component_slots(body).sensors)).state.values)
    reset!(body)
    @test all(iszero, component_value(first(component_slots(body).sensors)).state.values)

    user_state = _ResettableBodyState(3)
    stateful = Embodiment(state=user_state)
    reset!(stateful)
    @test user_state.value == 0

    @test_throws ArgumentError update!(body, (:unhandled,))
    ignoring = direct_embodiment(
        1,
        1;
        physiology=NoPhysiology(unknown_effects=IgnoreUnknownEffects()),
    )
    @test update!(ignoring, (:unhandled,)) === nothing
end
