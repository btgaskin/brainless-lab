using Random

const _TWO_PI = 2.0 * pi
const _BASE_SENSOR_DEG = collect(-60.0:4.0:60.0)
const SENS_ANGLES_DEG = Float64.(
    vcat(
        reverse(sort(_BASE_SENSOR_DEG .+ 30.0)),
        reverse(sort(_BASE_SENSOR_DEG .- 30.0)),
    ),
)
const SENS_ANGLES_RAD = SENS_ANGLES_DEG .* (pi / 180.0)
const VEN_BEARING_SENSOR_COUNT = length(SENS_ANGLES_RAD)
const VEN_BANK_RECEPTORS = 64
const VEN_FORAGE_RECEPTORS = 2 * VEN_BANK_RECEPTORS
const VEN_ACOUSTIC_RECEPTOR_INDEX = VEN_BANK_RECEPTORS + 1

# Conspecific receptor-bank width. Colour sensing lays out one 62-wide bearing
# bank per colour behind the 2 reserved leads (2 + C*62); colour-blind keeps the
# single 64-wide bank. C == 1 colour_sensing reproduces the colour-blind width.
_ven_conspecific_width(colour_sensing::Bool, n_colours::Integer) =
    colour_sensing ? (2 + Int(n_colours) * VEN_BEARING_SENSOR_COUNT) : VEN_BANK_RECEPTORS

# The acoustic/source region starts right after the conspecific bank(s). Under
# colour this replaces the hardcoded index 65 (VEN_ACOUSTIC_RECEPTOR_INDEX).
_ven_acoustic_index(colour_sensing::Bool, n_colours::Integer) =
    _ven_conspecific_width(colour_sensing, n_colours) + 1

# The VEN swarm agent is now stateless: per-agent physical state (position,
# heading, speed, heading-rate) and per-agent source_gain live on the
# environment as index-addressed arrays (see TorusEnvironment / ForageEnvironment),
# and the body is a `PassthroughBody{VENMorphology}` (defined in Morphology.jl).
# VENParams are the uniform kinematic constants, carried on SwarmConfig.ven.
Base.@kwdef struct VENParams
    top_speed::Float64 = 0.2
    accel_time::Float64 = 5.0
    top_heading_rate::Float64 = pi / 8.0
    h_accel_time::Float64 = 5.0
    dt::Float64 = 1.0
    agent_radius::Float64 = 0.5
end

velocity_hat(heading::Real) = (Float64(cos(heading)), Float64(sin(heading)))

_ven_float_vector(x) = Vector{Float64}(vec(Float64.(x)))
_ven_float_vector(x::Vector{Float64}) = x

function _ven_output_acts(output_acts)
    vals = _ven_float_vector(output_acts)
    length(vals) in (3, 4) ||
        throw(DimensionMismatch("VEN motor decode requires 3 or 4 effector values, got $(length(vals))"))
    return clamp.(vals, 0.0, 1.0)
end

ven_emitted_signal(e) = length(e) >= 4 ? clamp(Float64(e[4]), 0.0, 1.0) : 0.0

"""
    integrate_motion(pos, heading, speed, heading_rate, e, params, torus)

Advance one VEN agent's kinematics for a single tick. Pure: returns the updated
`(pos, heading, speed, heading_rate)` from the current state and clamped effector
vector `e`. Same differential drive as before; state is threaded rather than
mutated on a body (the environment owns the arrays).
"""
function integrate_motion(pos, heading::Real, speed::Real, heading_rate::Real, e, params::VENParams, torus::Torus)
    output_acts = _ven_output_acts(e)
    dt = Float64(params.dt)

    max_a = params.top_speed / params.accel_time
    fric_a = max_a / params.top_speed
    accel = output_acts[3] * max_a
    speed = Float64(speed) + (accel - fric_a * Float64(speed)) * dt

    max_ha = params.top_heading_rate / params.h_accel_time
    fric_h = max_ha / params.top_heading_rate
    h_accel = (output_acts[2] - output_acts[1]) * max_ha
    heading_rate = Float64(heading_rate) + (h_accel - fric_h * Float64(heading_rate)) * dt
    heading = mod(Float64(heading) + heading_rate * dt, _TWO_PI)

    x = pos[1] + speed * cos(heading) * dt
    y = pos[2] + speed * sin(heading) * dt
    new_pos = wrap(torus, x, y)

    return (new_pos, heading, speed, heading_rate)
end

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
    if mode === :hard
        bank ./= total
    elseif mode === :divisive
        bank ./= (Float64(sigma) + total)
    else
        throw(ArgumentError("unknown VEN norm mode :$(mode); use :hard, :raw, or :divisive"))
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
)
    sens = _ven_float_vector(sens_agents_vec)

    if colour_sensing
        return _assemble_coloured_inputs(sens, sensory_scaling, norm_mode, norm_sigma, gain, Int(n_colours))
    end

    length(sens) == VEN_BEARING_SENSOR_COUNT ||
        throw(DimensionMismatch("bearing vision requires $(VEN_BEARING_SENSOR_COUNT) sensors, got $(length(sens))"))

    inputs = zeros(Float64, VEN_BANK_RECEPTORS)
    copyto!(@view(inputs[3:VEN_BANK_RECEPTORS]), sens)
    _normalize_bank!(inputs, _resolve_norm_mode(sensory_scaling, norm_mode), norm_sigma)
    g = Float64(gain)
    g == 1.0 || (inputs .*= g)

    return inputs
end

# Colour layout: 2 reserved leads followed by C independent 62-wide bearing banks.
# Each bank is normalised on its own (same mode/sigma) and gained independently,
# so the colour banks project through independent random input weights downstream.
function _assemble_coloured_inputs(sens::Vector{Float64}, sensory_scaling::Bool, norm_mode, norm_sigma::Real, gain::Real, n_colours::Int)
    nb = VEN_BEARING_SENSOR_COUNT
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
)
    source_sens = _ven_float_vector(source_sens_vec)
    length(source_sens) == VEN_BEARING_SENSOR_COUNT ||
        throw(DimensionMismatch("source vision requires $(VEN_BEARING_SENSOR_COUNT) sensors, got $(length(source_sens))"))

    # Only the conspecific bank(s) are normalised; the source bank stays raw×gain
    # (its un-normalised intensity gradient is what makes lone source-seeking work).
    # The source bank stays SINGLE — the food is one uncoloured target — and is
    # laid out right after the conspecific region (2 reserved leads + 62 bearings).
    conspecific_bank = assemble_inputs(
        conspecific_sens_vec,
        sensory_scaling;
        norm_mode=norm_mode,
        norm_sigma=norm_sigma,
        gain=conspecific_gain,
        n_colours=n_colours,
        colour_sensing=colour_sensing,
    )
    consp_w = length(conspecific_bank)
    inputs = zeros(Float64, consp_w + VEN_BANK_RECEPTORS)
    copyto!(@view(inputs[1:consp_w]), conspecific_bank)
    @views inputs[(consp_w + 3):(consp_w + VEN_BANK_RECEPTORS)] .= Float64(source_gain) .* source_sens
    return inputs
end

# --- bearing-cone vision (position/heading-based) ---

function _accumulate_circular_target!(
    intersections::Vector{Float64},
    sensor_angles::Vector{Float64},
    from_pos,
    target_position,
    target_radius::Real,
    torus::Torus,
    max_d::Float64;
    vision_range=nothing,
)
    radius = max(0.0, Float64(target_radius))
    target_pos = (Float64(target_position[1]), Float64(target_position[2]))

    target_dist = tdistance(torus, from_pos, target_pos)
    if vision_range !== nothing && target_dist > Float64(vision_range)
        return false
    end

    if radius > 0.0 && target_dist <= radius
        fill!(intersections, 0.0)
        return true
    end

    neighbor_angle = bearing(torus, from_pos, target_pos)
    perpendicular_angle =
        neighbor_angle > 0.0 ? neighbor_angle - pi / 2.0 : neighbor_angle + pi / 2.0
    offset = (
        radius * cos(perpendicular_angle),
        radius * sin(perpendicular_angle),
    )
    edge_a = (target_pos[1] + offset[1], target_pos[2] + offset[2])

    edge_angle_a = bearing(torus, from_pos, edge_a)
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

function _sense_acts_from_intersections(
    intersections::Vector{Float64},
    max_d::Float64,
    sens_agent_dist::Real,
    sensory_noise::Real,
    rng,
)
    sens_acts = zeros(Float64, length(intersections))
    if Float64(sens_agent_dist) == 0.0
        @inbounds for i in eachindex(intersections)
            sens_acts[i] = intersections[i] < max_d ? 1.0 : 0.0
        end
    else
        @inbounds for i in eachindex(intersections)
            sens_acts[i] = 1.0 - intersections[i] / max_d
        end
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
    torus::Torus,
    sens_angles_rad,
    sens_agent_dist::Real,
    sensory_noise::Real,
    rng;
    vision_range=nothing,
)
    length(target_positions) == length(target_radii) ||
        throw(DimensionMismatch("target position/radius counts differ"))

    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ Float64(heading)
    max_d = max_dist(torus)
    intersections = fill(max_d, length(sensor_angles))

    for idx in eachindex(target_positions, target_radii)
        done = _accumulate_circular_target!(
            intersections,
            sensor_angles,
            from_pos,
            target_positions[idx],
            target_radii[idx],
            torus,
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
    torus::Torus,
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist::Real=0,
    sensory_noise::Real=0,
    rng=nothing;
    vision_range=nothing,
)
    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ Float64(heading)
    max_d = max_dist(torus)
    intersections = fill(max_d, length(sensor_angles))
    skip_i = Int(skip)

    @inbounds for j in eachindex(positions)
        j == skip_i && continue
        done = _accumulate_circular_target!(
            intersections,
            sensor_angles,
            pos,
            positions[j],
            agent_radius,
            torus,
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
    torus::Torus,
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist::Real=0,
    sensory_noise::Real=0,
    rng=nothing;
    n_colours::Integer=1,
    vision_range=nothing,
)
    length(colours) == length(positions) ||
        throw(DimensionMismatch("colours ($(length(colours))) must match positions ($(length(positions)))"))
    nc = Int(n_colours)
    nc >= 1 || throw(ArgumentError("n_colours must be at least 1"))

    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ Float64(heading)
    max_d = max_dist(torus)
    nb = length(sensor_angles)
    skip_i = Int(skip)

    out = zeros(Float64, nc * nb)
    intersections = Vector{Float64}(undef, nb)
    @inbounds for c in 0:(nc - 1)
        fill!(intersections, max_d)
        for j in eachindex(positions)
            j == skip_i && continue
            Int(colours[j]) == c || continue
            done = _accumulate_circular_target!(
                intersections,
                sensor_angles,
                pos,
                positions[j],
                agent_radius,
                torus,
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
    torus::Torus,
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist::Real=0,
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
        torus,
        sens_angles_rad,
        sens_agent_dist,
        sensory_noise,
        rng;
        vision_range=vision_range,
    )
end
