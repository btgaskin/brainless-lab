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

"""
    PassthroughBody()

Stateless body for task environments that already expose reservoir-shaped
percepts and accept reservoir-shaped motor commands.
"""
struct PassthroughBody <: Body end

receptors(::PassthroughBody, percept) = percept

motor(::PassthroughBody, e) = e

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
end

function VENBody(pos, heading; params::VENParams=VENParams(), speed::Real=0.0, heading_rate::Real=0.0)
    return VENBody(
        (Float64(pos[1]), Float64(pos[2])),
        mod(Float64(heading), _TWO_PI),
        Float64(speed),
        Float64(heading_rate),
        params,
    )
end

function VENBody(pos, heading, params::VENParams; speed::Real=0.0, heading_rate::Real=0.0)
    return VENBody(pos, heading; params=params, speed=speed, heading_rate=heading_rate)
end

velocity_hat(b::VENBody) = (Float64(cos(b.heading)), Float64(sin(b.heading)))

function _ven_output_acts(output_acts)
    vals = Float64.(vec(collect(output_acts)))
    length(vals) == 3 ||
        throw(DimensionMismatch("VENBody requires exactly 3 effector values, got $(length(vals))"))
    return clamp.(vals, 0.0, 1.0)
end

motor(::VENBody, e) = _ven_output_acts(e)

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
    length(sens) == 62 ||
        throw(DimensionMismatch("bearing vision requires 62 sensors, got $(length(sens))"))

    inputs = zeros(Float64, 64)
    copyto!(@view(inputs[3:64]), sens)

    if sensory_scaling
        total = sum(inputs)
        if total > 0.0
            inputs ./= total
        end
    end

    return inputs
end

function receptors(::VENBody, percept)
    vals = Float64.(vec(collect(percept)))
    if length(vals) == 64
        return copy(vals)
    elseif length(vals) == 62
        return assemble_inputs(vals)
    end
    throw(DimensionMismatch("VENBody percept must have length 62 or 64, got $(length(vals))"))
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
    sensor_angles = Float64.(vec(collect(sens_angles_rad))) .+ body.heading
    max_d = max_dist(torus)
    intersections = fill(max_d, length(sensor_angles))

    for other in others
        other === body && continue
        other isa VENBody || throw(ArgumentError("sense_agents expects VENBody neighbours"))

        neighbor_dist = tdistance(torus, body.pos, other.pos)
        if vision_range !== nothing && neighbor_dist > Float64(vision_range)
            continue
        end

        neighbor_angle = bearing(torus, body.pos, other.pos)
        perpendicular_angle =
            neighbor_angle > 0.0 ? neighbor_angle - pi / 2.0 : neighbor_angle + pi / 2.0
        offset = (
            params.agent_radius * cos(perpendicular_angle),
            params.agent_radius * sin(perpendicular_angle),
        )
        edge_a = (other.pos[1] + offset[1], other.pos[2] + offset[2])
        edge_b = (other.pos[1] - offset[1], other.pos[2] - offset[2])

        edge_angle_a = bearing(torus, body.pos, edge_a)
        ref_dist = abs(edge_angle_a - neighbor_angle)

        @inbounds for i in eachindex(sensor_angles)
            dist = mod(abs(sensor_angles[i] - neighbor_angle), _TWO_PI)
            candidate = dist <= ref_dist ? neighbor_dist : max_d
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
