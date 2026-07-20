# The Motor is the effector-decode policy of the swarm layer: it turns a
# reservoir's per-tick output into (1) an effector command vector via `readout`
# and (2) a kinematic state update via `integrate_motion`. It is deliberately a
# *discovery* instrument, not a controller: every readout scheme is a memoryless,
# bias-free re-expression of the reservoir's own output through the SAME effector
# projection, and every command map is a pure function of the current state and
# the clamped effectors — no leaky integrators, no threshold-on-turn, no baked
# heading. The DEFAULT `KinematicMotor()` is a strict byte-identical no-op: its
# `:spike_fraction` readout returns exactly `effectors(r, s)` and its
# `:differential` kinematics preserve the established situated arithmetic.

"""
    Motor

Abstract supertype for legacy effector-decode policies carried by an `AbstractBody`.
"""
abstract type Motor end

"""
    KinematicMotor(; scheme=:differential, readout=:spike_fraction, turn_gain=1.0,
                     allow_reverse=false, brake=false, top_speed=0.2, accel_time=5.0,
                     top_heading_rate=pi/8, h_accel_time=5.0, dt=1.0)

The one built-in motor. `readout` selects how the reservoir's output is
re-expressed as an effector command (see [`readout`](@ref)); `scheme` selects the
differential-drive command map (see [`integrate_motion`](@ref)); the remaining
fields are the uniform kinematic constants.

Readout schemes (all a projection of the reservoir's own output through the same
`effectors` map):

  - `:spike_fraction` (default) — `effectors(r, spikes)`, the per-effector spike
    fraction. Byte-identical to the pre-motor readout.
  - `:window_rate` — also defers to `effectors(r, spikes)`; the temporal average
    is the node's own `substeps` window (`step_window!`), not re-averaged here.
  - `:graded_state` — Falandays only: `effectors(r, acts ./ (targets · threshold_mult))`,
    the graded distance-to-threshold instead of the binary spike.
  - `:graded_deviation` — Falandays only: `effectors(r, acts .- targets)`, the
    signed homeostatic error.

Command-map schemes:

  - `:differential` (default) — forward-only differential drive. Forward thrust
    is effector 3 (`∈ [0,1]`, forward-only); turn is `turn_gain · (e₂ − e₁)`.
  - `:signed_differential` — re-centres the thrust effector to a signed drive
    (`2·e₃ − 1 ∈ [−1,1]`) so the SAME effector can command reverse. `allow_reverse`
    lets the integrated speed cross zero (true reverse vs braking to a stop);
    `brake` re-centres the thrust the same way for `:differential` so a
    forward-only agent can also actively decelerate.
"""
Base.@kwdef struct KinematicMotor <: Motor
    scheme::Symbol = :differential
    readout::Symbol = :spike_fraction
    turn_gain::Float64 = 1.0
    turn_gain_range::NTuple{2,Float64} = (1.0, 1.0)
    allow_reverse::Bool = false
    brake::Bool = false
    top_speed::Float64 = 0.2
    top_speed_range::NTuple{2,Float64} = (0.2, 0.2)
    accel_time::Float64 = 5.0
    accel_time_range::NTuple{2,Float64} = (5.0, 5.0)
    top_heading_rate::Float64 = pi / 8.0
    top_heading_rate_range::NTuple{2,Float64} = (pi / 8.0, pi / 8.0)
    h_accel_time::Float64 = 5.0
    h_accel_time_range::NTuple{2,Float64} = (5.0, 5.0)
    dt::Float64 = 1.0
end

# The default motor is the byte-identical no-op used by every body that does not
# override it (all task envs and the swarm default).
const PASSTHROUGH_MOTOR = KinematicMotor()

# Any body that does not carry its own policy (e.g. a user-registered custom AbstractBody,
# or the zero-arg task relay) decodes through the no-op motor, so the seam stays
# byte-identical to the pre-policy `effectors(r, s)`. `Embodiment` overrides this
# with its stored policy.
readout_policy(::AbstractBody) = PASSTHROUGH_MOTOR

# --- genome (bounded kinematic constants) --------------------------------------

const _KINEMATIC_MOTOR_GENES = (
    (:turn_gain, :turn_gain_range),
    (:top_speed, :top_speed_range),
    (:accel_time, :accel_time_range),
    (:top_heading_rate, :top_heading_rate_range),
    (:h_accel_time, :h_accel_time_range),
)

_motor_range_evolvable(range::NTuple{2,Float64}) = range[1] != range[2]
_motor_map(raw, lo, hi) = _sensor_map(raw, lo, hi)
_motor_unmap(x, lo, hi) = _sensor_unmap(x, lo, hi)

"""
    paramspace(motor)

Labeled `(label, lo, hi)` bounds for each evolvable scalar of a `KinematicMotor`.
Categorical choices (`scheme`, `readout`, `allow_reverse`, `brake`) and `dt` are
not genes. A degenerate range `(lo, lo)` drops that scalar from the genome.
"""
function paramspace(m::KinematicMotor)
    space = NamedTuple{(:label, :lo, :hi),Tuple{Symbol,Float64,Float64}}[]
    for (field, range_field) in _KINEMATIC_MOTOR_GENES
        lo, hi = getfield(m, range_field)
        _motor_range_evolvable((lo, hi)) || continue
        push!(space, (label=field, lo=Float64(lo), hi=Float64(hi)))
    end
    return space
end

function paramdim(m::KinematicMotor)
    count = 0
    for (_, range_field) in _KINEMATIC_MOTOR_GENES
        _motor_range_evolvable(getfield(m, range_field)) && (count += 1)
    end
    return count
end

function pack_params(m::KinematicMotor)
    g = Float64[]
    for (field, range_field) in _KINEMATIC_MOTOR_GENES
        lo, hi = getfield(m, range_field)
        _motor_range_evolvable((lo, hi)) || continue
        push!(g, _motor_unmap(getfield(m, field), lo, hi))
    end
    return g
end

function unpack_params(m::KinematicMotor, raw::AbstractVector{<:Real})::KinematicMotor
    n = paramdim(m)
    length(raw) == n ||
        throw(DimensionMismatch("KinematicMotor genome expects $(n) raw parameters, got $(length(raw))"))

    values = Dict{Symbol,Float64}(
        :turn_gain => m.turn_gain,
        :top_speed => m.top_speed,
        :accel_time => m.accel_time,
        :top_heading_rate => m.top_heading_rate,
        :h_accel_time => m.h_accel_time,
    )

    k = 0
    for (field, range_field) in _KINEMATIC_MOTOR_GENES
        lo, hi = getfield(m, range_field)
        _motor_range_evolvable((lo, hi)) || continue
        k += 1
        values[field] = _motor_map(raw[k], lo, hi)
    end

    return KinematicMotor(
        scheme=m.scheme,
        readout=m.readout,
        turn_gain=values[:turn_gain],
        turn_gain_range=m.turn_gain_range,
        allow_reverse=m.allow_reverse,
        brake=m.brake,
        top_speed=values[:top_speed],
        top_speed_range=m.top_speed_range,
        accel_time=values[:accel_time],
        accel_time_range=m.accel_time_range,
        top_heading_rate=values[:top_heading_rate],
        top_heading_rate_range=m.top_heading_rate_range,
        h_accel_time=values[:h_accel_time],
        h_accel_time_range=m.h_accel_time_range,
        dt=m.dt,
    )
end

# --- readout -------------------------------------------------------------------

_is_graded_readout(scheme::Symbol) = scheme === :graded_state || scheme === :graded_deviation

# Default readout: the spike-based schemes (:spike_fraction, :window_rate) both
# re-express the reservoir's own spikes through the SAME effector projection, so
# they defer to `effectors`. Graded schemes need a reservoir that exposes graded
# internal state (targets/activations); only the Falandays family does, so reject
# them here rather than silently return the spike readout.
function readout(m::Motor, r::Reservoir, spikes)
    _is_graded_readout(m.readout) && throw(ArgumentError(
        "graded readout :$(m.readout) unsupported for $(typeof(r)); " *
        "use readout=:spike_fraction/:window_rate or a Falandays reservoir",
    ))
    return effectors(r, spikes)
end

# The Falandays specialization (`readout(::Motor, ::FalandaysReservoir, spikes)`)
# lives in Ensemble.jl, alongside the other reservoir-type-dispatched seam helpers
# and after the node types are defined.

# --- kinematics ----------------------------------------------------------------

# Longitudinal drive from the thrust effector (output_acts[3]).
#   :differential         -> forward-only map (drive = e₃ ∈ [0,1])
#   :signed_differential  -> re-centred signed drive (drive = 2·e₃ − 1 ∈ [−1,1])
# `brake` re-centres the thrust the same signed way for :differential so a
# forward-only agent can also actively decelerate; on :signed_differential it is redundant.
@inline function _thrust_drive(m::KinematicMotor, thrust::Float64)
    signed = m.scheme === :signed_differential || m.brake
    return signed ? 2.0 * thrust - 1.0 : thrust
end

"""
    integrate!(motor, pos, heading, speed, heading_rate, e, torus)

Advance one agent's kinematics for a single tick under `motor`. Pure: returns the
updated `(pos, heading, speed, heading_rate)` from the current state and clamped
effector vector `e`. The default `:differential` motor preserves the established
differential-drive trajectory (forward = e₃, turn = e₂ − e₁,
same friction/inertia/wrap).
"""
function integrate!(
    m::KinematicMotor,
    pos,
    heading::Real,
    speed::Real,
    heading_rate::Real,
    e,
    torus::Torus,
)
    m.scheme === :differential || m.scheme === :signed_differential ||
        throw(ArgumentError("unknown motor scheme :$(m.scheme); use :differential or :signed_differential"))

    output_acts = _bounded_situated_effectors(e)
    dt = Float64(m.dt)

    # Longitudinal drive.
    drive = _thrust_drive(m, output_acts[3])
    max_a = m.top_speed / m.accel_time
    fric_a = max_a / m.top_speed
    accel = drive * max_a
    speed = Float64(speed) + (accel - fric_a * Float64(speed)) * dt
    # A signed drive can push speed below zero; without allow_reverse we clamp to
    # a standstill (brake, don't reverse). Forward-only drives never reach here, so
    # the default :differential path is left byte-identical.
    if drive < 0.0 && !m.allow_reverse && speed < 0.0
        speed = 0.0
    end

    # Turn drive (differential of the two turn effectors), scaled by turn_gain.
    turn = m.turn_gain * (output_acts[2] - output_acts[1])
    max_ha = m.top_heading_rate / m.h_accel_time
    fric_h = max_ha / m.top_heading_rate
    h_accel = turn * max_ha
    heading_rate = Float64(heading_rate) + (h_accel - fric_h * Float64(heading_rate)) * dt
    heading = mod(Float64(heading) + heading_rate * dt, _TWO_PI)

    x = pos[1] + speed * cos(heading) * dt
    y = pos[2] + speed * sin(heading) * dt
    new_pos = wrap(torus, x, y)

    return (new_pos, heading, speed, heading_rate)
end

function integrate!(
    m::KinematicMotor,
    pos,
    heading::Real,
    speed::Real,
    heading_rate::Real,
    e,
    arena::WalledArena;
    radius::Real=0.0,
)
    m.scheme === :differential || m.scheme === :signed_differential ||
        throw(ArgumentError("unknown motor scheme :$(m.scheme); use :differential or :signed_differential"))

    output_acts = _bounded_situated_effectors(e)
    dt = Float64(m.dt)
    drive = _thrust_drive(m, output_acts[3])
    max_a = m.top_speed / m.accel_time
    fric_a = max_a / m.top_speed
    speed_ = Float64(speed) + (drive * max_a - fric_a * Float64(speed)) * dt
    if drive < 0.0 && !m.allow_reverse && speed_ < 0.0
        speed_ = 0.0
    end

    turn = m.turn_gain * (output_acts[2] - output_acts[1])
    max_ha = m.top_heading_rate / m.h_accel_time
    fric_h = max_ha / m.top_heading_rate
    heading_rate_ = Float64(heading_rate) +
                    (turn * max_ha - fric_h * Float64(heading_rate)) * dt
    heading_ = mod(Float64(heading) + heading_rate_ * dt, _TWO_PI)
    x = pos[1] + speed_ * cos(heading_) * dt
    y = pos[2] + speed_ * sin(heading_) * dt
    new_pos, collided = arena_position(arena, x, y, radius)
    collided && (speed_ = 0.0)

    return (new_pos, heading_, speed_, heading_rate_)
end
