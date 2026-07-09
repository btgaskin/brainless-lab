# The Motor is the effector-decode policy of the swarm layer: it turns a
# reservoir's per-tick output into (1) an effector command vector via `readout`
# and (2) a kinematic state update via `integrate_motion`. It is deliberately a
# *discovery* instrument, not a controller: every readout scheme is a memoryless,
# bias-free re-expression of the reservoir's own output through the SAME effector
# projection, and every command map is a pure function of the current state and
# the clamped effectors — no leaky integrators, no threshold-on-turn, no baked
# heading. The DEFAULT `KinematicMotor()` is a strict byte-identical no-op: its
# `:spike_fraction` readout returns exactly `effectors(r, s)` and its
# `:ven_differential` kinematics reproduce the historical VEN arithmetic.

"""
    Motor

Abstract supertype for effector-decode policies carried by a `Body`.
"""
abstract type Motor end

"""
    KinematicMotor(; scheme=:ven_differential, readout=:spike_fraction, turn_gain=1.0,
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

  - `:ven_differential` (default) — the paper differential drive. Forward thrust
    is effector 3 (`∈ [0,1]`, forward-only); turn is `turn_gain · (e₂ − e₁)`.
  - `:ven_signed` — re-centres the thrust effector to a signed drive
    (`2·e₃ − 1 ∈ [−1,1]`) so the SAME effector can command reverse. `allow_reverse`
    lets the integrated speed cross zero (true reverse vs braking to a stop);
    `brake` re-centres the thrust the same way for `:ven_differential` so a
    forward-only agent can also actively decelerate.
"""
Base.@kwdef struct KinematicMotor <: Motor
    scheme::Symbol = :ven_differential
    readout::Symbol = :spike_fraction
    turn_gain::Float64 = 1.0
    allow_reverse::Bool = false
    brake::Bool = false
    top_speed::Float64 = 0.2
    accel_time::Float64 = 5.0
    top_heading_rate::Float64 = pi / 8.0
    h_accel_time::Float64 = 5.0
    dt::Float64 = 1.0
end

# The default motor is the byte-identical no-op used by every body that does not
# override it (all task envs and the swarm default).
const PASSTHROUGH_MOTOR = KinematicMotor()

# Any body that does not carry its own motor (e.g. a user-registered custom Body,
# or the zero-arg task relay) decodes through the no-op motor, so the seam stays
# byte-identical to the pre-motor `effectors(r, s)`. `PassthroughBody` overrides
# this with its stored motor (see Morphology.jl).
motor(::Body) = PASSTHROUGH_MOTOR

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
#   :ven_differential  -> forward-only paper map (drive = e₃ ∈ [0,1])
#   :ven_signed        -> re-centred signed drive (drive = 2·e₃ − 1 ∈ [−1,1])
# `brake` re-centres the thrust the same signed way for :ven_differential so a
# forward-only agent can also actively decelerate; on :ven_signed it is redundant.
@inline function _thrust_drive(m::KinematicMotor, thrust::Float64)
    signed = m.scheme === :ven_signed || m.brake
    return signed ? 2.0 * thrust - 1.0 : thrust
end

"""
    integrate_motion(motor, pos, heading, speed, heading_rate, e, torus)

Advance one agent's kinematics for a single tick under `motor`. Pure: returns the
updated `(pos, heading, speed, heading_rate)` from the current state and clamped
effector vector `e`. The default `:ven_differential` motor reproduces the
historical VEN differential drive byte-for-byte (forward = e₃, turn = e₂ − e₁,
same friction/inertia/wrap).
"""
function integrate_motion(
    m::KinematicMotor,
    pos,
    heading::Real,
    speed::Real,
    heading_rate::Real,
    e,
    torus::Torus,
)
    m.scheme === :ven_differential || m.scheme === :ven_signed ||
        throw(ArgumentError("unknown motor scheme :$(m.scheme); use :ven_differential or :ven_signed"))

    output_acts = _ven_output_acts(e)
    dt = Float64(m.dt)

    # Longitudinal drive.
    drive = _thrust_drive(m, output_acts[3])
    max_a = m.top_speed / m.accel_time
    fric_a = max_a / m.top_speed
    accel = drive * max_a
    speed = Float64(speed) + (accel - fric_a * Float64(speed)) * dt
    # A signed drive can push speed below zero; without allow_reverse we clamp to
    # a standstill (brake, don't reverse). Forward-only drives never reach here, so
    # the default :ven_differential path is left byte-identical.
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
