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

"""
    PassthroughBody()

Stateless body for task environments that already expose reservoir-shaped
percepts and accept reservoir-shaped motor commands.
"""
struct PassthroughBody <: Body end

Base.@kwdef struct VENParams
    top_speed::Float64 = 0.2
    accel_time::Float64 = 5.0
    top_heading_rate::Float64 = pi / 8.0
    h_accel_time::Float64 = 5.0
    dt::Float64 = 1.0
    agent_radius::Float64 = 0.5
end

mutable struct VENBody <: Body
    pos::NTuple{2,Float64}
    heading::Float64
    speed::Float64
    heading_rate::Float64
    params::VENParams
    sensory_scaling::Bool
    source_bank::Bool
    source_gain::Float64
end

function VENBody(
    pos,
    heading;
    params::VENParams=VENParams(),
    speed::Real=0.0,
    heading_rate::Real=0.0,
    sensory_scaling::Bool=true,
    source_bank::Bool=false,
    source_gain::Real=1.0,
)
    return VENBody(
        (Float64(pos[1]), Float64(pos[2])),
        mod(Float64(heading), _TWO_PI),
        Float64(speed),
        Float64(heading_rate),
        params,
        Bool(sensory_scaling),
        Bool(source_bank),
        Float64(source_gain),
    )
end

function VENBody(
    pos,
    heading,
    params::VENParams;
    speed::Real=0.0,
    heading_rate::Real=0.0,
    sensory_scaling::Bool=true,
    source_bank::Bool=false,
    source_gain::Real=1.0,
)
    return VENBody(
        pos,
        heading;
        params=params,
        speed=speed,
        heading_rate=heading_rate,
        sensory_scaling=sensory_scaling,
        source_bank=source_bank,
        source_gain=source_gain,
    )
end

velocity_hat(b::VENBody) = (Float64(cos(b.heading)), Float64(sin(b.heading)))

function _ven_output_acts(output_acts)
    vals = Float64.(vec(collect(output_acts)))
    length(vals) == 3 ||
        throw(DimensionMismatch("VENBody requires exactly 3 effector values, got $(length(vals))"))
    return clamp.(vals, 0.0, 1.0)
end

function motor(b::VENBody, e, torus::Torus)
    output_acts = _ven_output_acts(e)
    params = b.params
    dt = Float64(params.dt)

    max_a = params.top_speed / params.accel_time
    fric_a = max_a / params.top_speed
    accel = output_acts[3] * max_a
    b.speed += (accel - fric_a * b.speed) * dt

    max_ha = params.top_heading_rate / params.h_accel_time
    fric_h = max_ha / params.top_heading_rate
    h_accel = (output_acts[2] - output_acts[1]) * max_ha
    b.heading_rate += (h_accel - fric_h * b.heading_rate) * dt
    b.heading = mod(b.heading + b.heading_rate * dt, _TWO_PI)

    x = b.pos[1] + b.speed * cos(b.heading) * dt
    y = b.pos[2] + b.speed * sin(b.heading) * dt
    b.pos = wrap(torus, x, y)

    return b
end

function assemble_inputs(sens_agents_vec, sensory_scaling::Bool=true)
    sens = Float64.(vec(collect(sens_agents_vec)))
    length(sens) == VEN_BEARING_SENSOR_COUNT ||
        throw(DimensionMismatch("bearing vision requires $(VEN_BEARING_SENSOR_COUNT) sensors, got $(length(sens))"))

    inputs = zeros(Float64, VEN_BANK_RECEPTORS)
    copyto!(@view(inputs[3:VEN_BANK_RECEPTORS]), sens)

    if sensory_scaling
        total = sum(inputs)
        if total > 0.0
            inputs ./= total
        end
    end

    return inputs
end

function assemble_forage_inputs(
    conspecific_sens_vec,
    source_sens_vec,
    sensory_scaling::Bool=true;
    source_gain::Real=1.0,
)
    source_sens = Float64.(vec(collect(source_sens_vec)))
    length(source_sens) == VEN_BEARING_SENSOR_COUNT ||
        throw(DimensionMismatch("source vision requires $(VEN_BEARING_SENSOR_COUNT) sensors, got $(length(source_sens))"))

    inputs = zeros(Float64, VEN_FORAGE_RECEPTORS)
    conspecific_bank = assemble_inputs(conspecific_sens_vec, sensory_scaling)
    copyto!(@view(inputs[1:VEN_BANK_RECEPTORS]), conspecific_bank)
    @views inputs[(VEN_BANK_RECEPTORS + 3):VEN_FORAGE_RECEPTORS] .= Float64(source_gain) .* source_sens
    return inputs
end

function _sense_circular_targets(
    body::VENBody,
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

    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ body.heading
    max_d = max_dist(torus)
    intersections = fill(max_d, length(sensor_angles))

    for idx in eachindex(target_positions, target_radii)
        target = target_positions[idx]
        radius = max(0.0, Float64(target_radii[idx]))
        target_pos = (Float64(target[1]), Float64(target[2]))

        target_dist = tdistance(torus, body.pos, target_pos)
        if vision_range !== nothing && target_dist > Float64(vision_range)
            continue
        end

        if radius > 0.0 && target_dist <= radius
            fill!(intersections, 0.0)
            break
        end

        neighbor_angle = bearing(torus, body.pos, target_pos)
        perpendicular_angle =
            neighbor_angle > 0.0 ? neighbor_angle - pi / 2.0 : neighbor_angle + pi / 2.0
        offset = (
            radius * cos(perpendicular_angle),
            radius * sin(perpendicular_angle),
        )
        edge_a = (target_pos[1] + offset[1], target_pos[2] + offset[2])

        edge_angle_a = bearing(torus, body.pos, edge_a)
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
    end

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

function sense_agents(
    body::VENBody,
    others,
    torus::Torus,
    params::VENParams=body.params,
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist::Real=0,
    sensory_noise::Real=0,
    rng=nothing;
    vision_range=nothing,
)
    target_positions = NTuple{2,Float64}[]
    target_radii = Float64[]
    for other in others
        other === body && continue
        other isa VENBody || throw(ArgumentError("sense_agents expects VENBody neighbours"))
        push!(target_positions, other.pos)
        push!(target_radii, Float64(params.agent_radius))
    end

    return _sense_circular_targets(
        body,
        target_positions,
        target_radii,
        torus,
        sens_angles_rad,
        sens_agent_dist,
        sensory_noise,
        rng;
        vision_range=vision_range,
    )
end

function sense_source(
    body::VENBody,
    source_position,
    torus::Torus,
    params::VENParams=body.params,
    sens_angles_rad=SENS_ANGLES_RAD,
    sens_agent_dist::Real=0,
    sensory_noise::Real=0,
    rng=nothing;
    vision_range=nothing,
    source_radius::Real=params.agent_radius,
)
    source_pos = (Float64(source_position[1]), Float64(source_position[2]))
    return _sense_circular_targets(
        body,
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
