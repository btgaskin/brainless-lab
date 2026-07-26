using BrainlessLab
using Test

@testset "Geometry and motion-state validation" begin
    geometry = BrainlessLab.DiscGeometry(0.5)
    @test BrainlessLab.geometry_radius(geometry) == 0.5
    @test BrainlessLab.geometry_area(geometry) ≈ pi / 4
    @test_throws ArgumentError BrainlessLab.DiscGeometry(0.0)
    @test_throws ArgumentError BrainlessLab.DiscGeometry(Inf)

    state = BrainlessLab.MotionState2D(
        position=(1.0, 2.0),
        heading=2pi + 0.25,
        velocity=(3.0, 4.0),
        angular_velocity=0.5,
    )
    @test state.position == [1.0, 2.0]
    @test state.heading ≈ 0.25
    @test BrainlessLab.linear_speed(state) == 5.0
    @test_throws ArgumentError BrainlessLab.MotionState2D(position=(NaN, 0.0))
end

@testset "Actuator port contracts and decoding" begin
    direct = BrainlessLab.DirectRelayActuator((:a, :b); minimum=-1.0, maximum=1.0)
    @test [port.id for port in BrainlessLab.ports(direct).effectors] == [:a, :b]
    @test n_receptors(direct) == 0
    @test n_effectors(direct) == 2
    direct_command = BrainlessLab.command_buffer(direct)
    @test BrainlessLab.decode!(direct_command, direct, [-2.0, 0.25]).values == [-1.0, 0.25]
    @test_throws ArgumentError BrainlessLab.DirectRelayActuator((:a, :a))
    @test_throws DimensionMismatch BrainlessLab.decode!(direct_command, direct, [1.0])

    forward = BrainlessLab.ForwardTurnActuator(
        max_forward_speed=2.0,
        max_turn_rate=pi,
        allow_reverse=true,
    )
    @test [port.id for port in BrainlessLab.ports(forward).effectors] == [:forward, :turn]
    forward_command = BrainlessLab.command_buffer(forward)
    BrainlessLab.decode!(forward_command, forward, [0.25, 0.75])
    @test forward_command.forward_speed == -1.0
    @test forward_command.turn_rate ≈ pi / 2

    wheels = BrainlessLab.DifferentialDriveActuator(max_wheel_speed=4.0, allow_reverse=true)
    @test [port.id for port in BrainlessLab.ports(wheels).effectors] == [:left_wheel, :right_wheel]
    wheel_command = BrainlessLab.command_buffer(wheels)
    BrainlessLab.decode!(wheel_command, wheels, [0.25, 0.75])
    @test wheel_command.left_speed == -2.0
    @test wheel_command.right_speed == 2.0

    force = BrainlessLab.PlanarForceYawActuator(max_force=6.0, max_yaw_torque=4.0)
    @test [port.id for port in BrainlessLab.ports(force).effectors] ==
          [:force_forward, :force_left, :yaw_torque]
    force_command = BrainlessLab.command_buffer(force)
    BrainlessLab.decode!(force_command, force, [1.0, 0.0, 0.75])
    @test force_command.force_body == [6.0, -6.0]
    @test force_command.yaw_torque == 2.0

    @test_throws ArgumentError BrainlessLab.ForwardTurnActuator(max_forward_speed=Inf)
    @test_throws ArgumentError BrainlessLab.DifferentialDriveActuator(max_wheel_speed=0.0)
    @test_throws ArgumentError BrainlessLab.PlanarForceYawActuator(max_force=NaN)
    @test_throws ArgumentError BrainlessLab.decode!(forward_command, forward, [NaN, 0.5])
end

@testset "Decode and integration remain separate and inferred" begin
    actuator = BrainlessLab.ForwardTurnActuator(max_forward_speed=1.0, max_turn_rate=pi / 2)
    command = BrainlessLab.command_buffer(actuator)
    @test @inferred(BrainlessLab.decode!(command, actuator, [1.0, 1.0])) === command
    state = BrainlessLab.MotionState2D()
    dynamics = BrainlessLab.UnicycleDynamics(dt=1.0)
    @test @inferred(BrainlessLab.integrate!(state, dynamics, command)) === state
    @test state.heading ≈ pi / 2
    @test state.position ≈ [0.0, 1.0]
    @test state.velocity ≈ [0.0, 1.0]

    # Warmed hot calls use fixed-size state/commands and do not allocate.
    BrainlessLab.decode!(command, actuator, [1.0, 1.0])
    BrainlessLab.integrate!(state, dynamics, command)
    effectors = [1.0, 1.0]
    @test @allocated(BrainlessLab.decode!(command, actuator, effectors)) == 0
    @test @allocated(BrainlessLab.integrate!(state, dynamics, command)) == 0
end

@testset "Differential and planar dynamics" begin
    wheel_state = BrainlessLab.MotionState2D()
    wheel_dynamics = BrainlessLab.DifferentialDriveDynamics(dt=1.0, wheel_base=2.0)
    wheel_command = BrainlessLab.DifferentialDriveCommand(0.0, 2.0)
    BrainlessLab.integrate!(wheel_state, wheel_dynamics, wheel_command)
    @test wheel_state.angular_velocity == 1.0
    @test wheel_state.heading ≈ 1.0
    @test wheel_state.velocity ≈ [cos(1.0), sin(1.0)]
    @test wheel_state.position ≈ wheel_state.velocity

    rigid_state = BrainlessLab.MotionState2D()
    rigid_dynamics = BrainlessLab.PlanarRigidBodyDynamics(
        dt=1.0,
        mass=2.0,
        moment_of_inertia=2.0,
        max_linear_speed=5.0,
        max_angular_speed=2.0,
    )
    rigid_command = BrainlessLab.PlanarForceYawCommand((2.0, 0.0), 2.0)
    @test @inferred(BrainlessLab.integrate!(rigid_state, rigid_dynamics, rigid_command)) === rigid_state
    @test rigid_state.velocity == [1.0, 0.0]
    @test rigid_state.position == [1.0, 0.0]
    @test rigid_state.angular_velocity == 1.0
    @test rigid_state.heading ≈ 1.0

    capped = BrainlessLab.MotionState2D(velocity=(4.0, 0.0), angular_velocity=1.5)
    cap_dynamics = BrainlessLab.PlanarRigidBodyDynamics(
        dt=1.0,
        mass=1.0,
        moment_of_inertia=1.0,
        max_linear_speed=2.0,
        max_angular_speed=1.0,
    )
    BrainlessLab.integrate!(capped, cap_dynamics, BrainlessLab.PlanarForceYawCommand((10.0, 0.0), 10.0))
    @test BrainlessLab.linear_speed(capped) ≈ 2.0
    @test capped.angular_velocity == 1.0

    @test_throws ArgumentError BrainlessLab.UnicycleDynamics(dt=0.0)
    @test_throws ArgumentError BrainlessLab.DifferentialDriveDynamics(wheel_base=Inf)
    @test_throws ArgumentError BrainlessLab.PlanarRigidBodyDynamics(mass=0.0)
end
