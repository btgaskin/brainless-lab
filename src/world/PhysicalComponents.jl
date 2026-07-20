using LinearAlgebra: dot
using StaticArrays: SVector

# --- Geometry -----------------------------------------------------------------

"""Abstract supertype for physical geometry carried by an embodied entity."""
abstract type AbstractGeometry end

"""No spatial footprint, used by direct task-relay embodiments."""
struct NoGeometry <: AbstractGeometry end

geometry_radius(::NoGeometry) = 0.0
geometry_area(::NoGeometry) = 0.0

"""Circular 2D geometry used for collision, contact, and ray-intersection bounds."""
struct DiscGeometry <: AbstractGeometry
    radius::Float64

    function DiscGeometry(radius::Real)
        radius_ = Float64(radius)
        isfinite(radius_) && radius_ > 0.0 ||
            throw(ArgumentError("disc radius must be finite and positive"))
        return new(radius_)
    end
end

geometry_radius(geometry::DiscGeometry) = geometry.radius
geometry_area(geometry::DiscGeometry) = pi * geometry.radius^2

# --- Runtime motion state ------------------------------------------------------

"""
    MotionState2D(; position=(0, 0), heading=0, velocity=(0, 0),
                    angular_velocity=0)

Mutable planar pose and velocity state. Position and velocity use fixed-size
vectors so dynamics can update the state without allocating transient arrays.
"""
mutable struct MotionState2D
    position::SVector{2,Float64}
    heading::Float64
    velocity::SVector{2,Float64}
    angular_velocity::Float64

    function MotionState2D(
        position::SVector{2,Float64},
        heading::Float64,
        velocity::SVector{2,Float64},
        angular_velocity::Float64,
    )
        all(isfinite, position) && isfinite(heading) && all(isfinite, velocity) &&
            isfinite(angular_velocity) || throw(ArgumentError("motion state must be finite"))
        return new(position, mod(heading, 2pi), velocity, angular_velocity)
    end
end

function MotionState2D(;
    position=(0.0, 0.0),
    heading::Real=0.0,
    velocity=(0.0, 0.0),
    angular_velocity::Real=0.0,
)
    position_ = SVector{2,Float64}(Float64(position[1]), Float64(position[2]))
    heading_ = Float64(heading)
    velocity_ = SVector{2,Float64}(Float64(velocity[1]), Float64(velocity[2]))
    angular_ = Float64(angular_velocity)
    all(isfinite, position_) && isfinite(heading_) && all(isfinite, velocity_) &&
        isfinite(angular_) || throw(ArgumentError("motion state must be finite"))
    return MotionState2D(position_, mod(heading_, 2pi), velocity_, angular_)
end

@inline function _validate_motion_state(state::MotionState2D)
    all(isfinite, state.position) && isfinite(state.heading) &&
        all(isfinite, state.velocity) && isfinite(state.angular_velocity) ||
        throw(ArgumentError("motion state must remain finite"))
    return state
end

linear_speed(state::MotionState2D) = hypot(state.velocity[1], state.velocity[2])

# --- Commands -----------------------------------------------------------------

"""Abstract supertype for decoded, physical actuation commands."""
abstract type AbstractCommand end

"""Arbitrary fixed-width task command used by a direct relay actuator."""
mutable struct DirectCommand <: AbstractCommand
    values::Vector{Float64}

    function DirectCommand(values)
        values_ = Float64.(vec(collect(values)))
        all(isfinite, values_) || throw(ArgumentError("direct command values must be finite"))
        return new(values_)
    end
end

DirectCommand(width::Integer) = begin
    width_ = Int(width)
    width_ >= 1 || throw(ArgumentError("direct command width must be positive"))
    DirectCommand(zeros(Float64, width_))
end

"""Target forward speed and yaw rate for unicycle-like motion."""
mutable struct ForwardTurnCommand <: AbstractCommand
    forward_speed::Float64
    turn_rate::Float64

    function ForwardTurnCommand(forward_speed::Real=0.0, turn_rate::Real=0.0)
        forward_ = Float64(forward_speed)
        turn_ = Float64(turn_rate)
        all(isfinite, (forward_, turn_)) ||
            throw(ArgumentError("forward/turn command values must be finite"))
        return new(forward_, turn_)
    end
end

"""Target left and right wheel linear speeds."""
mutable struct DifferentialDriveCommand <: AbstractCommand
    left_speed::Float64
    right_speed::Float64

    function DifferentialDriveCommand(left_speed::Real=0.0, right_speed::Real=0.0)
        left_ = Float64(left_speed)
        right_ = Float64(right_speed)
        all(isfinite, (left_, right_)) ||
            throw(ArgumentError("differential-drive command values must be finite"))
        return new(left_, right_)
    end
end

"""Body-frame planar force and yaw torque for rigid-body motion."""
mutable struct PlanarForceYawCommand <: AbstractCommand
    force_body::SVector{2,Float64}
    yaw_torque::Float64

    function PlanarForceYawCommand(force_body=(0.0, 0.0), yaw_torque::Real=0.0)
        force_ = SVector{2,Float64}(Float64(force_body[1]), Float64(force_body[2]))
        torque_ = Float64(yaw_torque)
        all(isfinite, force_) && isfinite(torque_) ||
            throw(ArgumentError("planar force/yaw command values must be finite"))
        return new(force_, torque_)
    end
end

command_values(command::DirectCommand) = command.values
command_values(command::ForwardTurnCommand) =
    (forward_speed=command.forward_speed, turn_rate=command.turn_rate)
command_values(command::DifferentialDriveCommand) =
    (left_speed=command.left_speed, right_speed=command.right_speed)
command_values(command::PlanarForceYawCommand) =
    (force_body=command.force_body, yaw_torque=command.yaw_torque)

reset_command!(command::DirectCommand) = (fill!(command.values, 0.0); command)
reset_command!(command::ForwardTurnCommand) =
    (command.forward_speed = 0.0; command.turn_rate = 0.0; command)
reset_command!(command::DifferentialDriveCommand) =
    (command.left_speed = 0.0; command.right_speed = 0.0; command)
reset_command!(command::PlanarForceYawCommand) =
    (command.force_body = SVector{2,Float64}(0.0, 0.0); command.yaw_torque = 0.0; command)

@inline function _require_finite(command::DirectCommand)
    all(isfinite, command.values) || throw(ArgumentError("direct command values must be finite"))
    return command
end

@inline function _require_finite(command::ForwardTurnCommand)
    all(isfinite, (command.forward_speed, command.turn_rate)) ||
        throw(ArgumentError("forward/turn command values must be finite"))
    return command
end


@inline function _require_finite(command::DifferentialDriveCommand)
    all(isfinite, (command.left_speed, command.right_speed)) ||
        throw(ArgumentError("differential-drive command values must be finite"))
    return command
end


@inline function _require_finite(command::PlanarForceYawCommand)
    all(isfinite, command.force_body) && isfinite(command.yaw_torque) ||
        throw(ArgumentError("planar force/yaw command values must be finite"))
    return command
end

# --- Actuators and effector contracts -----------------------------------------

"""Abstract supertype for policies that decode normalized effectors."""
abstract type AbstractActuator end

function _validate_effector_ids(ids)
    ids_ = Tuple(Symbol(id) for id in ids)
    isempty(ids_) && throw(ArgumentError("an actuator needs at least one effector port"))
    length(unique(ids_)) == length(ids_) ||
        throw(ArgumentError("actuator effector port IDs must be unique"))
    return ids_
end

function _actuator_ports(ids::NTuple{N,Symbol}) where {N}
    receptor_ports = Port{NoPlacement}[]
    effector_ports = Port{NoPlacement}[Port(id) for id in ids]
    return PortSpec(0, N, receptor_ports, effector_ports)
end

n_receptors(::AbstractActuator) = 0
n_effectors(actuator::AbstractActuator) = n_effectors(portspec(actuator))
ports(actuator::AbstractActuator) = ports(portspec(actuator))

@inline function _require_effectors(effectors, expected::Int)
    length(effectors) == expected || throw(DimensionMismatch(
        "actuator expected $(expected) effectors, got $(length(effectors))",
    ))
    return effectors
end

@inline function _unit_effector(value, port::Symbol)
    value_ = Float64(value)
    isfinite(value_) || throw(ArgumentError("effector :$(port) must be finite"))
    return clamp(value_, 0.0, 1.0)
end

"""Relay an arbitrary named effector vector into a reusable direct command."""
struct DirectRelayActuator{N} <: AbstractActuator
    port_ids::NTuple{N,Symbol}
    minimum::Float64
    maximum::Float64

    function DirectRelayActuator{N}(
        port_ids::NTuple{N,Symbol},
        minimum::Real,
        maximum::Real,
    ) where {N}
        N >= 1 || throw(ArgumentError("an actuator needs at least one effector port"))
        length(unique(port_ids)) == N ||
            throw(ArgumentError("actuator effector port IDs must be unique"))
        lo, hi = Float64(minimum), Float64(maximum)
        all(isfinite, (lo, hi)) && lo < hi ||
            throw(ArgumentError("direct-relay bounds must be finite and ordered"))
        return new{N}(port_ids, lo, hi)
    end
end

function DirectRelayActuator(ids; minimum::Real=0.0, maximum::Real=1.0)
    ids_ = _validate_effector_ids(ids)
    return DirectRelayActuator{length(ids_)}(ids_, minimum, maximum)
end

DirectRelayActuator(width::Integer; kwargs...) = begin
    width_ = Int(width)
    width_ >= 1 || throw(ArgumentError("direct-relay width must be positive"))
    DirectRelayActuator(ntuple(i -> Symbol(:direct_, i), width_); kwargs...)
end

portspec(actuator::DirectRelayActuator) = _actuator_ports(actuator.port_ids)
command_buffer(actuator::DirectRelayActuator{N}) where {N} = DirectCommand(N)

function decode!(command::DirectCommand, actuator::DirectRelayActuator{N}, effectors) where {N}
    _require_effectors(effectors, N)
    length(command.values) == N || throw(DimensionMismatch(
        "direct command has width $(length(command.values)); expected $(N)",
    ))
    @inbounds for i in 1:N
        value = Float64(effectors[i])
        isfinite(value) || throw(ArgumentError("effector :$(actuator.port_ids[i]) must be finite"))
        command.values[i] = clamp(value, actuator.minimum, actuator.maximum)
    end
    return command
end

"""Decode `[forward, turn]` effectors into physical target speed and yaw rate."""
struct ForwardTurnActuator <: AbstractActuator
    max_forward_speed::Float64
    max_turn_rate::Float64
    allow_reverse::Bool

    function ForwardTurnActuator(
        max_forward_speed::Real,
        max_turn_rate::Real;
        allow_reverse::Bool=false,
    )
        speed_ = Float64(max_forward_speed)
        turn_ = Float64(max_turn_rate)
        all(isfinite, (speed_, turn_)) && speed_ > 0.0 && turn_ > 0.0 ||
            throw(ArgumentError("forward/turn limits must be finite and positive"))
        return new(speed_, turn_, allow_reverse)
    end
end

ForwardTurnActuator(; max_forward_speed=1.0, max_turn_rate=pi, allow_reverse=false) =
    ForwardTurnActuator(max_forward_speed, max_turn_rate; allow_reverse=allow_reverse)

const _FORWARD_TURN_PORTS = (:forward, :turn)
portspec(::ForwardTurnActuator) = _actuator_ports(_FORWARD_TURN_PORTS)
command_buffer(::ForwardTurnActuator) = ForwardTurnCommand()

function decode!(command::ForwardTurnCommand, actuator::ForwardTurnActuator, effectors)
    _require_effectors(effectors, 2)
    forward = _unit_effector(effectors[1], :forward)
    turn = _unit_effector(effectors[2], :turn)
    command.forward_speed = actuator.max_forward_speed *
        (actuator.allow_reverse ? 2.0 * forward - 1.0 : forward)
    command.turn_rate = actuator.max_turn_rate * (2.0 * turn - 1.0)
    return command
end

"""Decode two normalized wheel channels into physical wheel linear speeds."""
struct DifferentialDriveActuator <: AbstractActuator
    max_wheel_speed::Float64
    allow_reverse::Bool

    function DifferentialDriveActuator(max_wheel_speed::Real; allow_reverse::Bool=false)
        speed_ = Float64(max_wheel_speed)
        isfinite(speed_) && speed_ > 0.0 ||
            throw(ArgumentError("maximum wheel speed must be finite and positive"))
        return new(speed_, allow_reverse)
    end
end

DifferentialDriveActuator(; max_wheel_speed=1.0, allow_reverse=false) =
    DifferentialDriveActuator(max_wheel_speed; allow_reverse=allow_reverse)

const _DIFFERENTIAL_DRIVE_PORTS = (:left_wheel, :right_wheel)
portspec(::DifferentialDriveActuator) = _actuator_ports(_DIFFERENTIAL_DRIVE_PORTS)
command_buffer(::DifferentialDriveActuator) = DifferentialDriveCommand()

function decode!(command::DifferentialDriveCommand, actuator::DifferentialDriveActuator, effectors)
    _require_effectors(effectors, 2)
    left = _unit_effector(effectors[1], :left_wheel)
    right = _unit_effector(effectors[2], :right_wheel)
    if actuator.allow_reverse
        left = 2.0 * left - 1.0
        right = 2.0 * right - 1.0
    end
    command.left_speed = actuator.max_wheel_speed * left
    command.right_speed = actuator.max_wheel_speed * right
    return command
end

"""Decode body-forward force, body-left force, and yaw-torque channels."""
struct PlanarForceYawActuator <: AbstractActuator
    max_force::Float64
    max_yaw_torque::Float64

    function PlanarForceYawActuator(max_force::Real, max_yaw_torque::Real)
        force_ = Float64(max_force)
        torque_ = Float64(max_yaw_torque)
        all(isfinite, (force_, torque_)) && force_ > 0.0 && torque_ > 0.0 ||
            throw(ArgumentError("planar force/yaw limits must be finite and positive"))
        return new(force_, torque_)
    end
end

PlanarForceYawActuator(; max_force=1.0, max_yaw_torque=1.0) =
    PlanarForceYawActuator(max_force, max_yaw_torque)

const _PLANAR_FORCE_YAW_PORTS = (:force_forward, :force_left, :yaw_torque)
portspec(::PlanarForceYawActuator) = _actuator_ports(_PLANAR_FORCE_YAW_PORTS)
command_buffer(::PlanarForceYawActuator) = PlanarForceYawCommand()

function decode!(command::PlanarForceYawCommand, actuator::PlanarForceYawActuator, effectors)
    _require_effectors(effectors, 3)
    forward = 2.0 * _unit_effector(effectors[1], :force_forward) - 1.0
    left = 2.0 * _unit_effector(effectors[2], :force_left) - 1.0
    torque = 2.0 * _unit_effector(effectors[3], :yaw_torque) - 1.0
    command.force_body = SVector{2,Float64}(
        actuator.max_force * forward,
        actuator.max_force * left,
    )
    command.yaw_torque = actuator.max_yaw_torque * torque
    return command
end

# --- Dynamics -----------------------------------------------------------------

"""Abstract supertype for physical policies that integrate decoded commands."""
abstract type AbstractDynamics end

"""No body-owned motion integration, used when a task consumes commands directly."""
struct NoDynamics <: AbstractDynamics end

@inline _response_fraction(dt::Float64, tau::Float64) =
    tau == 0.0 ? 1.0 : -expm1(-dt / tau)

"""First-order target-following unicycle dynamics."""
struct UnicycleDynamics <: AbstractDynamics
    dt::Float64
    linear_tau::Float64
    angular_tau::Float64

    function UnicycleDynamics(dt::Real, linear_tau::Real, angular_tau::Real)
        dt_, linear_, angular_ = Float64(dt), Float64(linear_tau), Float64(angular_tau)
        all(isfinite, (dt_, linear_, angular_)) && dt_ > 0.0 &&
            linear_ >= 0.0 && angular_ >= 0.0 ||
            throw(ArgumentError("unicycle dt must be positive and response times non-negative"))
        return new(dt_, linear_, angular_)
    end
end

UnicycleDynamics(; dt=1.0, linear_tau=0.0, angular_tau=0.0) =
    UnicycleDynamics(dt, linear_tau, angular_tau)

function integrate!(state::MotionState2D, dynamics::UnicycleDynamics, command::ForwardTurnCommand)
    _validate_motion_state(state)
    _require_finite(command)
    forward = SVector{2,Float64}(cos(state.heading), sin(state.heading))
    speed = dot(state.velocity, forward)
    speed += _response_fraction(dynamics.dt, dynamics.linear_tau) *
             (command.forward_speed - speed)
    angular = state.angular_velocity +
              _response_fraction(dynamics.dt, dynamics.angular_tau) *
              (command.turn_rate - state.angular_velocity)
    heading = mod(state.heading + angular * dynamics.dt, 2pi)
    velocity = SVector{2,Float64}(speed * cos(heading), speed * sin(heading))
    state.position = state.position + velocity * dynamics.dt
    state.heading = heading
    state.velocity = velocity
    state.angular_velocity = angular
    return state
end

"""Ideal no-slip differential-drive kinematics."""
struct DifferentialDriveDynamics <: AbstractDynamics
    dt::Float64
    wheel_base::Float64

    function DifferentialDriveDynamics(dt::Real, wheel_base::Real)
        dt_, base_ = Float64(dt), Float64(wheel_base)
        all(isfinite, (dt_, base_)) && dt_ > 0.0 && base_ > 0.0 ||
            throw(ArgumentError("differential-drive dt and wheel base must be finite and positive"))
        return new(dt_, base_)
    end
end


DifferentialDriveDynamics(; dt=1.0, wheel_base=1.0) =
    DifferentialDriveDynamics(dt, wheel_base)

function integrate!(
    state::MotionState2D,
    dynamics::DifferentialDriveDynamics,
    command::DifferentialDriveCommand,
)
    _validate_motion_state(state)
    _require_finite(command)
    speed = (command.left_speed + command.right_speed) / 2.0
    angular = (command.right_speed - command.left_speed) / dynamics.wheel_base
    heading = mod(state.heading + angular * dynamics.dt, 2pi)
    velocity = SVector{2,Float64}(speed * cos(heading), speed * sin(heading))
    state.position = state.position + velocity * dynamics.dt
    state.heading = heading
    state.velocity = velocity
    state.angular_velocity = angular
    return state
end

"""Damped planar rigid-body dynamics driven by body-frame force and yaw torque."""
struct PlanarRigidBodyDynamics <: AbstractDynamics
    dt::Float64
    mass::Float64
    moment_of_inertia::Float64
    linear_drag::Float64
    angular_drag::Float64
    max_linear_speed::Float64
    max_angular_speed::Float64

    function PlanarRigidBodyDynamics(
        dt::Real,
        mass::Real,
        moment_of_inertia::Real,
        linear_drag::Real,
        angular_drag::Real,
        max_linear_speed::Real,
        max_angular_speed::Real,
    )
        dt_, mass_, inertia_ = Float64(dt), Float64(mass), Float64(moment_of_inertia)
        linear_, angular_ = Float64(linear_drag), Float64(angular_drag)
        max_linear_, max_angular_ = Float64(max_linear_speed), Float64(max_angular_speed)
        all(isfinite, (dt_, mass_, inertia_, linear_, angular_, max_linear_, max_angular_)) &&
            dt_ > 0.0 && mass_ > 0.0 && inertia_ > 0.0 &&
            linear_ >= 0.0 && angular_ >= 0.0 &&
            max_linear_ > 0.0 && max_angular_ > 0.0 ||
            throw(ArgumentError("planar rigid-body parameters must be finite and physically bounded"))
        return new(dt_, mass_, inertia_, linear_, angular_, max_linear_, max_angular_)
    end
end

PlanarRigidBodyDynamics(;
    dt=1.0,
    mass=1.0,
    moment_of_inertia=1.0,
    linear_drag=0.0,
    angular_drag=0.0,
    max_linear_speed=10.0,
    max_angular_speed=2pi,
) = PlanarRigidBodyDynamics(
    dt,
    mass,
    moment_of_inertia,
    linear_drag,
    angular_drag,
    max_linear_speed,
    max_angular_speed,
)

@inline function _bounded_velocity(velocity::SVector{2,Float64}, max_speed::Float64)
    speed = hypot(velocity[1], velocity[2])
    return speed > max_speed ? velocity * (max_speed / speed) : velocity
end

function integrate!(
    state::MotionState2D,
    dynamics::PlanarRigidBodyDynamics,
    command::PlanarForceYawCommand,
)
    _validate_motion_state(state)
    _require_finite(command)
    c, s = cos(state.heading), sin(state.heading)
    force_world = SVector{2,Float64}(
        c * command.force_body[1] - s * command.force_body[2],
        s * command.force_body[1] + c * command.force_body[2],
    )
    acceleration = force_world / dynamics.mass - dynamics.linear_drag * state.velocity
    velocity = _bounded_velocity(
        state.velocity + acceleration * dynamics.dt,
        dynamics.max_linear_speed,
    )
    angular_acceleration = command.yaw_torque / dynamics.moment_of_inertia -
                           dynamics.angular_drag * state.angular_velocity
    angular = clamp(
        state.angular_velocity + angular_acceleration * dynamics.dt,
        -dynamics.max_angular_speed,
        dynamics.max_angular_speed,
    )
    state.position = state.position + velocity * dynamics.dt
    state.heading = mod(state.heading + angular * dynamics.dt, 2pi)
    state.velocity = velocity
    state.angular_velocity = angular
    return state
end
