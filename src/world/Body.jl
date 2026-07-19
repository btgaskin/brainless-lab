using Random

const _TWO_PI = 2.0 * pi

# The bearing-geometry constants are realizations of the default AbstractSensor
# (`BEARING_DEFAULT`, from Sensor.jl, included before Body.jl). The values are
# unchanged: the default sensor is the historical two-eye 62-ray fan, so
# SENS_ANGLES_* and the receptor-bank widths derived below stay byte-identical to
# the historical constants (62 bearings, a 64-wide bank, acoustic lead at 65).
const SENS_ANGLES_DEG = angles_deg(BEARING_DEFAULT)
const SENS_ANGLES_RAD = angles_rad(BEARING_DEFAULT)
const DEFAULT_BEARING_SENSOR_COUNT = n_sensors(BEARING_DEFAULT)
const DEFAULT_BEARING_BANK_RECEPTORS = 2 + DEFAULT_BEARING_SENSOR_COUNT
const DEFAULT_FORAGE_RECEPTORS = 2 * DEFAULT_BEARING_BANK_RECEPTORS
const DEFAULT_SIGNAL_RECEPTOR_INDEX = DEFAULT_BEARING_BANK_RECEPTORS + 1

# Conspecific receptor-bank width. Colour sensing lays out one `n_sensors`-wide
# bearing bank per colour behind the 2 reserved leads (2 + C*nb); colour-blind
# keeps the single (2 + nb)-wide bank. C == 1 colour_sensing reproduces the
# colour-blind width. `n_sensors` defaults to DEFAULT_BEARING_SENSOR_COUNT (62) so
# direct callers stay byte-identical; an AbstractSensor supplies its own ray count.
_legacy_conspecific_width(colour_sensing::Bool, n_colours::Integer; n_sensors::Integer=DEFAULT_BEARING_SENSOR_COUNT) =
    colour_sensing ? (2 + Int(n_colours) * Int(n_sensors)) : (2 + Int(n_sensors))

# The acoustic/source region starts right after the conspecific bank(s). Under
# colour this replaces the historical hardcoded index 65.
_legacy_signal_index(colour_sensing::Bool, n_colours::Integer; n_sensors::Integer=DEFAULT_BEARING_SENSOR_COUNT) =
    _legacy_conspecific_width(colour_sensing, n_colours; n_sensors=n_sensors) + 1

# The situated swarm agent is stateless: per-agent physical state (position,
# heading, speed, heading-rate) and per-agent source_gain live on the
# environment as index-addressed arrays (see TorusEnvironment / ForageEnvironment),
# and the body is an `Embodiment`.
# The uniform kinematic constants and the effector-decode scheme now live on a
# `KinematicMotor` (see Motor.jl), carried on the body and on SwarmConfig.motor;
# `agent_radius` is a SwarmConfig field. The shared kinematic helpers below stay
# here because both `Motor.jl` and the environments consume them.

velocity_hat(heading::Real) = (Float64(cos(heading)), Float64(sin(heading)))

_component_float_vector(x) = Vector{Float64}(vec(Float64.(x)))
_component_float_vector(x::Vector{Float64}) = copy(x)

function _bounded_situated_effectors(output_acts)
    vals = _component_float_vector(output_acts)
    length(vals) in (3, 4) ||
        throw(DimensionMismatch("situated actuator requires 3 or 4 effector values, got $(length(vals))"))
    return clamp.(vals, 0.0, 1.0)
end

emitted_signal(e) = length(e) >= 4 ? clamp(Float64(e[4]), 0.0, 1.0) : 0.0

# `integrate_motion(::KinematicMotor, ...)` (the agent kinematics) now lives in
# Motor.jl, dispatched on the motor so alternative command maps can be swapped in.

# Resolve the effective bank-normalisation mode. `nothing` derives it from the
# legacy `sensory_scaling` flag so existing callers/fixtures are unchanged.
function _resolve_norm_mode(sensory_scaling::Bool, norm_mode)
    norm_mode === nothing && return sensory_scaling ? :hard : :raw
    return Symbol(norm_mode)
end

# In-place normalisation of one bearing bank.
#   :raw      -> untouched (proximity/number grows the drive; can blow up in crowds)
#   :hard     -> x ./= sum(x)         (authors-faithful; invariant to number/proximity)
#   :divisive -> x ./= (sigma + sum)  (Heeger/Carandini semi-saturation: linear-ish at
#                                      low drive so the gradient survives, bounded high)
function _normalize_bank!(bank::AbstractVector{Float64}, mode::Symbol, sigma::Real)
    mode === :raw && return bank
    total = sum(bank)
    total > 0.0 || return bank
    if mode === :hard || mode === :sum
        bank ./= total
    elseif mode === :divisive
        bank ./= (Float64(sigma) + total)
    else
        throw(ArgumentError("unknown sensor-bank norm mode :$(mode); use :sum, :hard, :raw, or :divisive"))
    end
    return bank
end

function assemble_inputs(
    sens_agents_vec,
    sensory_scaling::Bool=true;
    norm_mode=nothing,
    norm_sigma::Real=1.0,
    gain::Real=1.0,
    n_colours::Integer=1,
    colour_sensing::Bool=false,
    n_sensors::Integer=DEFAULT_BEARING_SENSOR_COUNT,
)
    sens = _component_float_vector(sens_agents_vec)
    nb = Int(n_sensors)

    if colour_sensing
        return _assemble_coloured_inputs(sens, sensory_scaling, norm_mode, norm_sigma, gain, Int(n_colours), nb)
    end

    length(sens) == nb ||
        throw(DimensionMismatch("bearing vision requires $(nb) sensors, got $(length(sens))"))

    inputs = zeros(Float64, 2 + nb)
    copyto!(@view(inputs[3:(2 + nb)]), sens)
    _normalize_bank!(inputs, _resolve_norm_mode(sensory_scaling, norm_mode), norm_sigma)
    g = Float64(gain)
    g == 1.0 || (inputs .*= g)

    return inputs
end

# Colour layout: 2 reserved leads followed by C independent `nb`-wide bearing banks.
# Each bank is normalised on its own (same mode/sigma) and gained independently,
# so the colour banks project through independent random input weights downstream.
function _assemble_coloured_inputs(sens::Vector{Float64}, sensory_scaling::Bool, norm_mode, norm_sigma::Real, gain::Real, n_colours::Int, nb::Int)
    length(sens) == n_colours * nb ||
        throw(DimensionMismatch("coloured bearing vision requires $(n_colours * nb) sensors ($(n_colours)×$(nb)), got $(length(sens))"))

    inputs = zeros(Float64, 2 + n_colours * nb)
    mode = _resolve_norm_mode(sensory_scaling, norm_mode)
    g = Float64(gain)
    @inbounds for c in 1:n_colours
        dst = @view inputs[(2 + (c - 1) * nb + 1):(2 + c * nb)]
        copyto!(dst, @view sens[((c - 1) * nb + 1):(c * nb)])
        _normalize_bank!(dst, mode, norm_sigma)
        g == 1.0 || (dst .*= g)
    end
    return inputs
end

function assemble_forage_inputs(
    conspecific_sens_vec,
    source_sens_vec,
    sensory_scaling::Bool=true;
    source_gain::Real=1.0,
    norm_mode=nothing,
    norm_sigma::Real=1.0,
    conspecific_gain::Real=1.0,
    n_colours::Integer=1,
    colour_sensing::Bool=false,
    n_sensors::Integer=DEFAULT_BEARING_SENSOR_COUNT,
)
    source_sens = _component_float_vector(source_sens_vec)
    nb = Int(n_sensors)
    length(source_sens) == nb ||
        throw(DimensionMismatch("source vision requires $(nb) sensors, got $(length(source_sens))"))

    # Only the conspecific bank(s) are normalised; the source bank stays raw×gain
    # (its un-normalised intensity gradient is what makes lone source-seeking work).
    # The source bank stays SINGLE — the food is one uncoloured target — and is
    # laid out right after the conspecific region (2 reserved leads + nb bearings).
    conspecific_bank = assemble_inputs(
        conspecific_sens_vec,
        sensory_scaling;
        norm_mode=norm_mode,
        norm_sigma=norm_sigma,
        gain=conspecific_gain,
        n_colours=n_colours,
        colour_sensing=colour_sensing,
        n_sensors=nb,
    )
    consp_w = length(conspecific_bank)
    inputs = zeros(Float64, consp_w + (2 + nb))
    copyto!(@view(inputs[1:consp_w]), conspecific_bank)
    @views inputs[(consp_w + 3):(consp_w + 2 + nb)] .= Float64(source_gain) .* source_sens
    return inputs
end

# --- bearing-cone vision (position/heading-based) ---

function _accumulate_circular_target!(
    intersections::Vector{Float64},
    sensor_angles::Vector{Float64},
    from_pos,
    target_position,
    target_radius::Real,
    arena::Union{Torus,WalledArena},
    max_d::Float64;
    vision_range=nothing,
)
    radius = max(0.0, Float64(target_radius))
    target_pos = (Float64(target_position[1]), Float64(target_position[2]))

    target_dist = arena_distance(arena, from_pos, target_pos)
    if vision_range !== nothing && target_dist > Float64(vision_range)
        return false
    end

    if radius > 0.0 && target_dist <= radius
        fill!(intersections, 0.0)
        return true
    end

    neighbor_angle = arena_bearing(arena, from_pos, target_pos)
    perpendicular_angle =
        neighbor_angle > 0.0 ? neighbor_angle - pi / 2.0 : neighbor_angle + pi / 2.0
    offset = (
        radius * cos(perpendicular_angle),
        radius * sin(perpendicular_angle),
    )
    edge_a = (target_pos[1] + offset[1], target_pos[2] + offset[2])

    edge_angle_a = arena_bearing(arena, from_pos, edge_a)
    ref_d = mod(edge_angle_a - neighbor_angle + pi, _TWO_PI) - pi
    ref_dist = abs(ref_d)

    @inbounds for i in eachindex(sensor_angles)
        d = mod(sensor_angles[i] - neighbor_angle + pi, _TWO_PI) - pi
        dist = abs(d)
        candidate = dist <= ref_dist ? target_dist : max_d
        if candidate < intersections[i]
            intersections[i] = candidate
        end
    end

    return false
end

# `encoding` is the AbstractSensor activation encoding — a Symbol (:binary/:graded) or
# a legacy Real `sens_agent_dist` (0 => :binary, ≠0 => :graded), resolved via
# `_sensor_encoding`. The branch is RNG-neutral: neither encoding draws, so the
# noise block below preserves the historical draw order exactly.
function _sense_acts_from_intersections(
    intersections::Vector{Float64},
    max_d::Float64,
    encoding,
    sensory_noise::Real,
    rng,
)
    enc = _sensor_encoding(encoding)
    sens_acts = zeros(Float64, length(intersections))
    if enc === :binary
        @inbounds for i in eachindex(intersections)
            sens_acts[i] = intersections[i] < max_d ? 1.0 : 0.0
        end
    elseif enc === :graded
        @inbounds for i in eachindex(intersections)
            sens_acts[i] = 1.0 - intersections[i] / max_d
        end
    else
        throw(ArgumentError("unknown sensor encoding :$(enc); use :binary or :graded"))
    end

    noise = Float64(sensory_noise)
    if noise > 0.0
        rng_ = rng === nothing ? Random.default_rng() : rng
        @inbounds for i in eachindex(sens_acts)
            sens_acts[i] += rand(rng_) * (2.0 * noise) - noise
            if sens_acts[i] < 0.0
                sens_acts[i] = 0.0
            end
        end
    end

    return sens_acts
end

function _sense_circular_targets(
    from_pos,
    heading::Real,
    target_positions,
    target_radii,
    arena::Union{Torus,WalledArena},
    sens_angles_rad,
    sens_agent_dist,
    sensory_noise::Real,
    rng;
    vision_range=nothing,
)
    length(target_positions) == length(target_radii) ||
        throw(DimensionMismatch("target position/radius counts differ"))

    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ Float64(heading)
    max_d = arena_max_distance(arena)
    intersections = fill(max_d, length(sensor_angles))

    for idx in eachindex(target_positions, target_radii)
        done = _accumulate_circular_target!(
            intersections,
            sensor_angles,
            from_pos,
            target_positions[idx],
            target_radii[idx],
            arena,
            max_d;
            vision_range=vision_range,
        )
        done && break
    end

    return _sense_acts_from_intersections(intersections, max_d, sens_agent_dist, sensory_noise, rng)
end

"""
    sense_agents(pos, heading, positions, skip, agent_radius, torus, sens_angles_rad, sens_agent_dist, sensory_noise, rng; vision_range)

Bearing-cone vision of conspecifics. `positions` is every agent's position;
`skip` is the sensing agent's own index (self-exclusion). Every neighbour has
the same `agent_radius`.
"""
function sense_agents(
    pos,
    heading::Real,
    positions::AbstractVector,
    skip::Integer,
    agent_radius::Real,
    arena::Union{Torus,WalledArena},
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist=0,
    sensory_noise::Real=0,
    rng=nothing;
    vision_range=nothing,
    active_mask=nothing,
)
    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ Float64(heading)
    max_d = arena_max_distance(arena)
    intersections = fill(max_d, length(sensor_angles))
    skip_i = Int(skip)

    @inbounds for j in eachindex(positions)
        j == skip_i && continue
        active_mask === nothing || active_mask[j] || continue
        done = _accumulate_circular_target!(
            intersections,
            sensor_angles,
            pos,
            positions[j],
            agent_radius,
            arena,
            max_d;
            vision_range=vision_range,
        )
        done && break
    end

    return _sense_acts_from_intersections(intersections, max_d, sens_agent_dist, sensory_noise, rng)
end

"""
    sense_agents_coloured(pos, heading, positions, colours, skip, agent_radius, torus, sens_angles_rad, sens_agent_dist, sensory_noise, rng; n_colours, vision_range)

Colour-selective bearing-cone vision. Returns `n_colours` stacked 62-wide bearing
banks (concatenated to `n_colours * 62`). Bank `c` (0-based) runs the identical
geometry as [`sense_agents`](@ref) but only over neighbours whose colour equals
`c`. The sensing agent is never told its own colour — it only ever appears on
other agents' banks (self-exclusion via `skip`).

Pre-noise invariant: a sensor ray reports the nearer of the colours it strikes,
so the elementwise `max` over the colour banks reproduces the colour-blind
`sense_agents` bank exactly.
"""
function sense_agents_coloured(
    pos,
    heading::Real,
    positions::AbstractVector,
    colours::AbstractVector,
    skip::Integer,
    agent_radius::Real,
    arena::Union{Torus,WalledArena},
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist=0,
    sensory_noise::Real=0,
    rng=nothing;
    n_colours::Integer=1,
    vision_range=nothing,
    active_mask=nothing,
)
    length(colours) == length(positions) ||
        throw(DimensionMismatch("colours ($(length(colours))) must match positions ($(length(positions)))"))
    nc = Int(n_colours)
    nc >= 1 || throw(ArgumentError("n_colours must be at least 1"))

    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ Float64(heading)
    max_d = arena_max_distance(arena)
    nb = length(sensor_angles)
    skip_i = Int(skip)

    out = zeros(Float64, nc * nb)
    intersections = Vector{Float64}(undef, nb)
    @inbounds for c in 0:(nc - 1)
        fill!(intersections, max_d)
        for j in eachindex(positions)
            j == skip_i && continue
            active_mask === nothing || active_mask[j] || continue
            Int(colours[j]) == c || continue
            done = _accumulate_circular_target!(
                intersections,
                sensor_angles,
                pos,
                positions[j],
                agent_radius,
                arena,
                max_d;
                vision_range=vision_range,
            )
            done && break
        end
        acts = _sense_acts_from_intersections(intersections, max_d, sens_agent_dist, sensory_noise, rng)
        copyto!(@view(out[(c * nb + 1):((c + 1) * nb)]), acts)
    end

    return out
end

"""
    sense_source(pos, heading, source_position, torus, sens_angles_rad, sens_agent_dist, sensory_noise, rng; vision_range, source_radius)

Bearing-cone vision of a single stationary source.
"""
function sense_source(
    pos,
    heading::Real,
    source_position,
    arena::Union{Torus,WalledArena},
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist=0,
    sensory_noise::Real=0,
    rng=nothing;
    vision_range=nothing,
    source_radius::Real=0.5,
)
    source_pos = (Float64(source_position[1]), Float64(source_position[2]))
    return _sense_circular_targets(
        pos,
        heading,
        (source_pos,),
        (Float64(source_radius),),
        arena,
        sens_angles_rad,
        sens_agent_dist,
        sensory_noise,
        rng;
        vision_range=vision_range,
    )
end


"""Bearing-cone vision of an arbitrary set of circular situated objects."""
function sense_objects(
    pos,
    heading::Real,
    positions,
    radii,
    arena::Union{Torus,WalledArena},
    sens_angles_rad=SENS_ANGLES_RAD,
    encoding=0,
    sensory_noise::Real=0,
    rng=nothing;
    vision_range=nothing,
)
    return _sense_circular_targets(
        pos,
        heading,
        positions,
        radii,
        arena,
        sens_angles_rad,
        encoding,
        sensory_noise,
        rng;
        vision_range=vision_range,
    )
end
