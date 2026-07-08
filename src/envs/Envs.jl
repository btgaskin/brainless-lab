using Random

abstract type TaskWorld end

function default_ticks end
function default_window end
bounds(::TaskWorld) = nothing
pose(::TaskWorld) = nothing

_wrap_rad(theta::Real) = mod(Float64(theta) + pi, 2.0 * pi) - pi
_wrap_deg(angle::Real) = mod(Float64(angle) + 180.0, 360.0) - 180.0
_angle_delta_deg(a::Real, b::Real) = _wrap_deg(Float64(a) - Float64(b))

function _bounded_effectors(effectors, n::Integer)
    values = Float64.(vec(collect(effectors)))
    length(values) == n ||
        throw(DimensionMismatch("expected $n effectors, got $(length(values))"))
    return clamp.(values, 0.0, 1.0)
end

function _mean_float(values)
    isempty(values) && return 0.0
    total = 0.0
    @inbounds for value in values
        total += Float64(value)
    end
    return total / length(values)
end

function _tail_bounds(len::Integer, window::Integer)
    if window <= 0 || len <= 0
        return 1:0
    end
    first_i = max(1, len - Int(window) + 1)
    return first_i:len
end

function _xy_path(box::WallBox)
    out = zeros(Float64, length(box.poses), 2)
    @inbounds for (i, pose) in enumerate(box.poses)
        out[i, 1] = pose[1]
        out[i, 2] = pose[2]
    end
    return out
end

mutable struct WallEnv{R} <: TaskWorld
    rng::R
    lam::Float64
    sensory_noise::Float64
    clip_sensory_noise::Bool
    box::WallBox{R}
end

function WallEnv(;
    rng=Random.default_rng(),
    x=nothing,
    y=nothing,
    theta=nothing,
    lam::Real=1.0,
    sensory_noise::Real=0.0,
    clip_sensory_noise::Bool=true,
)
    return WallEnv(
        rng,
        Float64(lam),
        Float64(sensory_noise),
        Bool(clip_sensory_noise),
        WallBox(; rng=rng, x=x, y=y, theta=theta),
    )
end

WallEnv(seed::Integer; kwargs...) = WallEnv(; rng=MersenneTwister(seed), kwargs...)
WallEnv(rng; kwargs...) = WallEnv(; rng=rng, kwargs...)

n_receptors(::Type{<:WallEnv}) = 2
n_receptors(::WallEnv) = n_receptors(WallEnv)
n_effectors(::Type{<:WallEnv}) = 2
n_effectors(::WallEnv) = n_effectors(WallEnv)
default_ticks(::Type{<:WallEnv}) = 1000
default_ticks(::WallEnv) = default_ticks(WallEnv)
default_window(::Type{<:WallEnv}) = 200
default_window(::WallEnv) = default_window(WallEnv)
bounds(env::WallEnv) = (0.0, Float64(env.box.size), 0.0, Float64(env.box.size))
pose(env::WallEnv) = (Float64(env.box.x), Float64(env.box.y), Float64(env.box.theta))

sense(env::WallEnv) = sense(
    env.box;
    sensory_noise=env.sensory_noise,
    clip=env.clip_sensory_noise,
    rng=env.rng,
)

function step!(env::WallEnv, effectors)
    e = _bounded_effectors(effectors, n_effectors(env))
    step!(env.box, e[1], e[2])
    return env
end

function reset!(env::WallEnv; x=nothing, y=nothing, theta=nothing)
    reset!(env.box; x=x, y=y, theta=theta)
    return env
end

function metrics(env::WallEnv, window::Integer=default_window(env))
    window_n = Int(window)
    distance_window = distance_last(env.box, window_n)
    collisions_window = collisions_last(env.box, window_n)
    effective_window = max(window_n, 1)
    collision_free_rate = clamp(1.0 - Float64(collisions_window) / Float64(effective_window), 0.0, 1.0)
    # Lenient anti-freeze gate: this is a task-definition threshold, not a speed reward.
    movement_gate = clamp(Float64(distance_window) / (0.1 * Float64(effective_window)), 0.0, 1.0)
    nav_score = collision_free_rate * movement_gate
    return (
        name="wall",
        # Brainless reconstruction: the authors' wall code records trajectories,
        # not an in-code scalar score.
        score=Float64(distance_window - env.lam * collisions_window),
        nav_score=nav_score,
        distance_window=distance_window,
        collisions_window=collisions_window,
        xy_path=_xy_path(env.box),
    )
end

mutable struct TrackingEnv{R} <: TaskWorld
    rng::R
    theta::Float64
    phi::Float64
    direction::Float64
    tick::Int
    error_history::Vector{Float64}
    heading_history::Vector{Float64}
    phi_history::Vector{Float64}
    eye_offsets_deg::NTuple{2,Float64}
    sensor_offsets_deg::Vector{Float64}
    stim_speed_rad::Float64
    movement_amp::Float64
    theta0::Float64
    phi0::Float64
    direction0::Float64
end

function TrackingEnv(;
    rng=Random.default_rng(),
    stim_speed_rad::Real=deg2rad(1.0),
    movement_amp::Real=10.0,
    eye_offset_deg::Real=30.0,
    sensor_offsets_deg::AbstractVector{<:Real}=collect(-60.0:4.0:60.0),
    randomize_start::Bool=false,
    theta0=nothing,
    phi0=nothing,
    direction0=nothing,
)
    th0 = theta0 !== nothing ? Float64(theta0) : (randomize_start ? 2pi * rand(rng) : pi / 2.0)
    ph0 = phi0 !== nothing ? Float64(phi0) : (randomize_start ? 2pi * rand(rng) : 0.0)
    dir0 = direction0 !== nothing ? Float64(direction0) : (randomize_start ? (rand(rng, Bool) ? 1.0 : -1.0) : 1.0)
    return TrackingEnv(
        rng,
        th0,
        ph0,
        dir0,
        0,
        Float64[],
        Float64[],
        Float64[],
        (Float64(eye_offset_deg), -Float64(eye_offset_deg)),
        collect(Float64, sensor_offsets_deg),
        Float64(stim_speed_rad),
        Float64(movement_amp),
        th0,
        ph0,
        dir0,
    )
end

TrackingEnv(seed::Integer; kwargs...) = TrackingEnv(; rng=MersenneTwister(seed), kwargs...)
TrackingEnv(rng; kwargs...) = TrackingEnv(; rng=rng, kwargs...)

n_receptors(::Type{<:TrackingEnv}) = 62
n_receptors(::TrackingEnv) = n_receptors(TrackingEnv)
n_effectors(::Type{<:TrackingEnv}) = 2
n_effectors(::TrackingEnv) = n_effectors(TrackingEnv)
default_ticks(::Type{<:TrackingEnv}) = 1000
default_ticks(::TrackingEnv) = default_ticks(TrackingEnv)
default_window(::Type{<:TrackingEnv}) = 200
default_window(::TrackingEnv) = default_window(TrackingEnv)

function sense(env::TrackingEnv)
    theta_deg = rad2deg(env.theta)
    phi_deg = rad2deg(env.phi)
    values = Vector{Float64}(undef, n_receptors(env))
    idx = 1
    @inbounds for eye_offset in env.eye_offsets_deg
        for sensor_offset in env.sensor_offsets_deg
            angle = theta_deg + eye_offset + sensor_offset
            delta = _angle_delta_deg(angle, phi_deg)
            values[idx] = abs(delta) <= 4.0 ? 1.0 : exp(-(delta * delta) / 10.0)
            idx += 1
        end
    end
    return values
end

function step!(env::TrackingEnv, effectors)
    e = _bounded_effectors(effectors, n_effectors(env))
    dtheta_deg = env.movement_amp * (e[1] - e[2])
    env.theta = _wrap_rad(env.theta + deg2rad(dtheta_deg))

    env.phi = _wrap_rad(env.phi + env.direction * env.stim_speed_rad)
    env.tick += 1
    if env.tick % 720 == 0
        env.direction *= -1.0
    end

    error = _wrap_rad(env.theta - env.phi)
    push!(env.error_history, error)
    push!(env.heading_history, env.theta)
    push!(env.phi_history, env.phi)
    return env
end

function reset!(env::TrackingEnv)
    env.theta = env.theta0
    env.phi = env.phi0
    env.direction = env.direction0
    env.tick = 0
    empty!(env.error_history)
    empty!(env.heading_history)
    empty!(env.phi_history)
    return env
end

function metrics(env::TrackingEnv, window::Integer=default_window(env))
    bounds = _tail_bounds(length(env.error_history), Int(window))
    errors = @view env.error_history[bounds]
    if isempty(errors)
        track_score = 0.0
        mean_abs_error_deg = 0.0
        frac_within_30deg = 0.0
    else
        cos_sum = 0.0
        abs_sum = 0.0
        within = 0
        @inbounds for error in errors
            abs_error_deg = abs(rad2deg(error))
            cos_sum += cos(error)
            abs_sum += abs_error_deg
            within += abs_error_deg <= 30.0 ? 1 : 0
        end
        track_score = cos_sum / length(errors)
        mean_abs_error_deg = abs_sum / length(errors)
        frac_within_30deg = within / length(errors)
    end

    return (
        name="tracking",
        # Brainless reconstruction: the authors' tracking code records heading
        # error, not an in-code scalar score.
        score=Float64(track_score),
        track_score=Float64(track_score),
        mean_abs_error_deg=Float64(mean_abs_error_deg),
        frac_within_30deg=Float64(frac_within_30deg),
        xy_path=nothing,
    )
end

mutable struct PongEnv{R} <: TaskWorld
    rng::R
    width::Float64
    height::Float64
    ball_r::Float64
    ball_speed::Float64
    paddle_x::Float64
    paddle_h::Float64
    paddle_min_y::Float64
    paddle_max_y::Float64
    paddle_y::Float64
    ball_x::Float64
    ball_y::Float64
    vx::Float64
    vy::Float64
    _past_paddle::Bool
    hit_flags::Vector{Int}
    miss_flags::Vector{Int}
    align_flags::Vector{Float64}
    sensor_angles_deg::Vector{Float64}
end

function PongEnv(; rng=Random.default_rng())
    env = PongEnv(
        rng,
        1000.0,
        500.0,
        15.0,
        5.0,
        100.0,
        100.0,
        50.0,
        450.0,
        250.0,
        995.0,
        0.0,
        -5.0,
        0.0,
        false,
        Int[],
        Int[],
        Float64[],
        collect(-90.0:4.0:90.0),
    )
    _reset_ball!(env)
    return env
end

PongEnv(seed::Integer; kwargs...) = PongEnv(; rng=MersenneTwister(seed), kwargs...)
PongEnv(rng; kwargs...) = PongEnv(; rng=rng, kwargs...)

n_receptors(::Type{<:PongEnv}) = 46
n_receptors(::PongEnv) = n_receptors(PongEnv)
n_effectors(::Type{<:PongEnv}) = 2
n_effectors(::PongEnv) = n_effectors(PongEnv)
default_ticks(::Type{<:PongEnv}) = 2000
default_ticks(::PongEnv) = default_ticks(PongEnv)
default_window(::Type{<:PongEnv}) = 1000
default_window(::PongEnv) = default_window(PongEnv)
bounds(env::PongEnv) = (0.0, Float64(env.width), 0.0, Float64(env.height))

function _reset_ball!(env::PongEnv)
    env.ball_x = env.width - 5.0
    env.ball_y = _rng_uniform(env.rng, 1.0, env.height - 1.0)
    env.vx = -env.ball_speed
    env.vy = env.ball_speed * _rng_choice_pm1(env.rng)
    env._past_paddle = false
    return env
end

function sense(env::PongEnv)
    dx = env.ball_x - env.paddle_x
    dy = env.ball_y - env.paddle_y
    bearing = rad2deg(atan(dy, dx))
    sensors = zeros(Float64, n_receptors(env))
    if -90.0 <= bearing <= 90.0
        @inbounds for (i, angle) in enumerate(env.sensor_angles_deg)
            delta = _angle_delta_deg(bearing, angle)
            if abs(delta) <= 2.0
                sensors[i] = 1.0
            end
        end
    end
    return sensors
end

function step!(env::PongEnv, effectors)
    e = _bounded_effectors(effectors, n_effectors(env))
    env.paddle_y = clamp(
        env.paddle_y + 100.0 * (e[1] - e[2]),
        env.paddle_min_y,
        env.paddle_max_y,
    )

    hit = 0
    miss = 0

    env.ball_x += env.vx
    env.ball_y += env.vy

    if env.ball_y <= 5.0
        env.ball_y = 5.0
        env.vy = abs(env.vy)
    elseif env.ball_y >= env.height - 5.0
        env.ball_y = env.height - 5.0
        env.vy = -abs(env.vy)
    end

    if env.ball_x >= env.width - 5.0
        env.ball_x = env.width - 5.0
        env.vx = -abs(env.vx)
        env._past_paddle = false
    end

    if env.vx < 0.0 && !env._past_paddle && env.ball_x <= env.paddle_x + env.ball_r
        if abs(env.ball_y - env.paddle_y) <= env.paddle_h / 2.0 + env.ball_r
            env.ball_x = env.paddle_x + env.ball_r
            env.vx = abs(env.vx)
            hit = 1
        else
            env._past_paddle = true
        end
    end

    if env.ball_x < 0.0
        miss = 1
        _reset_ball!(env)
    end

    push!(env.hit_flags, hit)
    push!(env.miss_flags, miss)
    align = max(0.0, 1.0 - abs(env.ball_y - env.paddle_y) / (env.height / 2.0))
    push!(env.align_flags, align)
    return env
end

function reset!(env::PongEnv)
    env.paddle_y = env.height / 2.0
    empty!(env.hit_flags)
    empty!(env.miss_flags)
    empty!(env.align_flags)
    _reset_ball!(env)
    return env
end

function metrics(env::PongEnv, window::Integer=default_window(env))
    bounds = eachindex(env.hit_flags)
    hits = isempty(bounds) ? 0 : Int(sum(@view env.hit_flags[bounds]))
    misses = isempty(bounds) ? 0 : Int(sum(@view env.miss_flags[bounds]))
    denom = hits + misses
    hit_rate = denom == 0 ? 0.0 : hits / denom
    align_values = @view env.align_flags[bounds]
    mean_align = _mean_float(align_values)
    return (
        name="pong",
        score=Float64(hit_rate),
        mean_align=Float64(mean_align),
        hit_rate=Float64(hit_rate),
        hits=hits,
        misses=misses,
        xy_path=nothing,
    )
end

mutable struct CartPoleEnv{R} <: TaskWorld
    rng::R
    tau::Float64
    gravity::Float64
    force_mag::Float64
    pole_length::Float64
    pole_mass::Float64
    cart_mass::Float64
    total_mass::Float64
    max_x::Float64
    max_theta::Float64
    obs_max::Vector{Float64}
    dead_zone::Float64
    state::Vector{Float64}
    step_count::Int
    done::Bool
end

function CartPoleEnv(; rng=Random.default_rng())
    state = [
        _rng_uniform(rng, -1.2, 1.2),
        _rng_uniform(rng, -0.05, 0.05),
        _rng_uniform(rng, -0.10475, 0.10475),
        _rng_uniform(rng, -0.05, 0.05),
    ]
    return CartPoleEnv(
        rng,
        0.02,
        9.8,
        10.0,
        0.5,
        0.1,
        1.0,
        1.1,
        2.4,
        0.2095,
        [2.4, 1.0, 0.2095, 1.0],
        0.05,
        state,
        0,
        false,
    )
end

CartPoleEnv(seed::Integer; kwargs...) = CartPoleEnv(; rng=MersenneTwister(seed), kwargs...)
CartPoleEnv(rng; kwargs...) = CartPoleEnv(; rng=rng, kwargs...)

n_receptors(::Type{<:CartPoleEnv}) = 8
n_receptors(::CartPoleEnv) = n_receptors(CartPoleEnv)
n_effectors(::Type{<:CartPoleEnv}) = 2
n_effectors(::CartPoleEnv) = n_effectors(CartPoleEnv)
default_ticks(::Type{<:CartPoleEnv}) = 1000
default_ticks(::CartPoleEnv) = default_ticks(CartPoleEnv)
default_window(::Type{<:CartPoleEnv}) = 1000
default_window(::CartPoleEnv) = default_window(CartPoleEnv)

function sense(env::CartPoleEnv)
    if env.done
        return zeros(Float64, n_receptors(env))
    end
    sensors = zeros(Float64, n_receptors(env))
    @inbounds for i in eachindex(env.state)
        normalized = clamp(env.state[i] / env.obs_max[i], -1.0, 1.0)
        sensors[2 * i - 1] = max(0.0, -normalized)
        sensors[2 * i] = max(0.0, normalized)
    end
    return sensors
end

function _cartpole_bangbang_force(e1::Real, e2::Real, force_mag::Real, dead_zone::Real)
    diff = e1 - e2
    abs(diff) < dead_zone && return 0.0
    return diff >= 0.0 ? -force_mag : force_mag
end

function step!(env::CartPoleEnv, effectors)
    env.done && return env

    e = _bounded_effectors(effectors, n_effectors(env))
    force = _cartpole_bangbang_force(e[1], e[2], env.force_mag, env.dead_zone)

    x = env.state[1]
    x_dot = env.state[2]
    theta = env.state[3]
    theta_dot = env.state[4]

    costheta = cos(theta)
    sintheta = sin(theta)
    temp = (force + env.pole_mass * env.pole_length * theta_dot^2 * sintheta) / env.total_mass
    thetaacc = (env.gravity * sintheta - costheta * temp) /
        (env.pole_length * ((4.0 / 3.0) - env.pole_mass * costheta^2 / env.total_mass))
    xacc = temp - env.pole_mass * env.pole_length * thetaacc * costheta / env.total_mass

    x_dot += env.tau * xacc
    x += env.tau * x_dot
    theta_dot += env.tau * thetaacc
    theta += env.tau * theta_dot

    env.state[1] = Float64(x)
    env.state[2] = Float64(x_dot)
    env.state[3] = Float64(theta)
    env.state[4] = Float64(theta_dot)
    env.step_count += 1
    env.done = abs(x) > env.max_x || abs(theta) > env.max_theta
    return env
end

function reset!(env::CartPoleEnv)
    env.state[1] = _rng_uniform(env.rng, -1.2, 1.2)
    env.state[2] = _rng_uniform(env.rng, -0.05, 0.05)
    env.state[3] = _rng_uniform(env.rng, -0.10475, 0.10475)
    env.state[4] = _rng_uniform(env.rng, -0.05, 0.05)
    env.step_count = 0
    env.done = false
    return env
end

function metrics(env::CartPoleEnv, window::Integer=default_window(env))
    return (
        name="cartpole",
        score=Float64(env.step_count / window),
        steps_balanced=env.step_count,
        ticks=env.step_count,
        fell=env.done && env.step_count < window,
        xy_path=nothing,
    )
end

# --- Visualizable scene state (consumed by `animate`) ---
# Default: no scene (the agent is shown via :poses instead, e.g. wall/torus).
scene(::TaskWorld) = nothing

scene(env::TrackingEnv) = (kind=:tracking, theta=env.theta, phi=env.phi)

scene(env::PongEnv) = (kind=:pong, width=env.width, height=env.height,
                       ball_x=env.ball_x, ball_y=env.ball_y, ball_r=env.ball_r,
                       paddle_x=env.paddle_x, paddle_y=env.paddle_y, paddle_h=env.paddle_h)

scene(env::CartPoleEnv) = (kind=:cartpole, x=env.state[1], theta=env.state[3],
                           max_x=env.max_x, pole_length=env.pole_length)
