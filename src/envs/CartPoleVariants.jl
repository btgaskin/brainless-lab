const CARTPOLE_DEFAULT_TICKS = 1000
const CARTPOLE_DEFAULT_WINDOW = 1000

mutable struct CartPoleVariantEnv{R} <: TaskWorld
    rng::R
    name::Symbol
    tau::Float64
    gravity::Float64
    force_mag::Float64
    pole_length::Float64
    pole_mass::Float64
    cart_mass::Float64
    total_mass::Float64
    max_x::Float64
    max_theta::Float64
    terminate_on_theta::Bool
    score_kind::Symbol
    obs_max::Vector{Float64}
    init_x_range::NTuple{2,Float64}
    init_xdot_range::NTuple{2,Float64}
    init_theta_range::NTuple{2,Float64}
    init_thetadot_range::NTuple{2,Float64}
    state::Vector{Float64}
    step_count::Int
    done::Bool
    balance_history::Vector{Float64}
    upright_history::Vector{Float64}
end

function _cartpole_range(value::Nothing, default::NTuple{2,Float64})
    return default
end

function _cartpole_range(value::Real, default::NTuple{2,Float64})
    v = Float64(value)
    return (v, v)
end

function _cartpole_range(value, default::NTuple{2,Float64})
    vals = Tuple(Float64.(collect(value)))
    length(vals) == 2 || throw(ArgumentError("CartPole range values must have length 2"))
    lo, hi = vals
    lo <= hi || throw(ArgumentError("CartPole range lower bound must be <= upper bound"))
    return (lo, hi)
end

function _cartpole_sample(rng, range::NTuple{2,Float64})
    lo, hi = range
    return lo == hi ? lo : _rng_uniform(rng, lo, hi)
end

function _cartpole_initial_state(
    rng,
    x_range::NTuple{2,Float64},
    xdot_range::NTuple{2,Float64},
    theta_range::NTuple{2,Float64},
    thetadot_range::NTuple{2,Float64},
)
    return [
        _cartpole_sample(rng, x_range),
        _cartpole_sample(rng, xdot_range),
        _cartpole_sample(rng, theta_range),
        _cartpole_sample(rng, thetadot_range),
    ]
end

function CartPoleVariantEnv(;
    rng=Random.default_rng(),
    name::Symbol=:cartpole_variant,
    tau::Real=0.02,
    gravity::Real=9.8,
    max_force::Real=10.0,
    pole_length::Real=0.5,
    pole_mass::Real=0.1,
    cart_mass::Real=1.0,
    max_x::Real=2.4,
    max_theta::Real=0.2095,
    terminate_on_theta::Bool=true,
    score_kind::Symbol=:balanced_fraction,
    init_x=nothing,
    init_x_range=(-1.2, 1.2),
    init_xdot=nothing,
    init_xdot_range=(-0.05, 0.05),
    init_theta=nothing,
    init_theta_range=(-0.10475, 0.10475),
    init_thetadot=nothing,
    init_thetadot_range=(-0.05, 0.05),
    obs_max=nothing,
)
    pole_length_ = Float64(pole_length)
    pole_mass_ = Float64(pole_mass)
    cart_mass_ = Float64(cart_mass)
    total_mass = pole_mass_ + cart_mass_
    max_x_ = Float64(max_x)
    max_theta_ = Float64(max_theta)
    theta_range = _cartpole_range(init_theta, _cartpole_range(init_theta_range, (-0.10475, 0.10475)))
    x_range = _cartpole_range(init_x, _cartpole_range(init_x_range, (-1.2, 1.2)))
    xdot_range = _cartpole_range(init_xdot, _cartpole_range(init_xdot_range, (-0.05, 0.05)))
    thetadot_range = _cartpole_range(init_thetadot, _cartpole_range(init_thetadot_range, (-0.05, 0.05)))
    obs = obs_max === nothing ? [max_x_, 5.0, pi, 5.0] : Vector{Float64}(Float64.(obs_max))
    length(obs) == 4 || throw(DimensionMismatch("obs_max must have length 4"))

    return CartPoleVariantEnv(
        rng,
        name,
        Float64(tau),
        Float64(gravity),
        Float64(max_force),
        pole_length_,
        pole_mass_,
        cart_mass_,
        total_mass,
        max_x_,
        max_theta_,
        Bool(terminate_on_theta),
        score_kind,
        obs,
        x_range,
        xdot_range,
        theta_range,
        thetadot_range,
        _cartpole_initial_state(rng, x_range, xdot_range, theta_range, thetadot_range),
        0,
        false,
        Float64[],
        Float64[],
    )
end

CartPoleVariantEnv(seed::Integer; kwargs...) = CartPoleVariantEnv(; rng=MersenneTwister(seed), kwargs...)
CartPoleVariantEnv(rng; kwargs...) = CartPoleVariantEnv(; rng=rng, kwargs...)

n_receptors(::Type{<:CartPoleVariantEnv}) = 8
n_receptors(::CartPoleVariantEnv) = n_receptors(CartPoleVariantEnv)
n_effectors(::Type{<:CartPoleVariantEnv}) = 2
n_effectors(::CartPoleVariantEnv) = n_effectors(CartPoleVariantEnv)
default_ticks(::Type{<:CartPoleVariantEnv}) = CARTPOLE_DEFAULT_TICKS
default_ticks(::CartPoleVariantEnv) = CARTPOLE_DEFAULT_TICKS
default_window(::Type{<:CartPoleVariantEnv}) = CARTPOLE_DEFAULT_WINDOW
default_window(::CartPoleVariantEnv) = CARTPOLE_DEFAULT_WINDOW

function sense(env::CartPoleVariantEnv)
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

function _integrate_cartpole_state!(
    state::Vector{Float64},
    force::Real;
    tau::Real,
    gravity::Real,
    pole_length::Real,
    pole_mass::Real,
    total_mass::Real,
    integrator::Symbol=:semi_implicit_euler,
)
    length(state) == 4 || throw(DimensionMismatch(
        "CartPole state must contain x, x_dot, theta, and theta_dot",
    ))
    x = state[1]
    x_dot = state[2]
    theta = state[3]
    theta_dot = state[4]

    costheta = cos(theta)
    sintheta = sin(theta)
    temp = (Float64(force) + pole_mass * pole_length * theta_dot^2 * sintheta) / total_mass
    thetaacc = (gravity * sintheta - costheta * temp) /
        (pole_length * ((4.0 / 3.0) - pole_mass * costheta^2 / total_mass))
    xacc = temp - pole_mass * pole_length * thetaacc * costheta / total_mass

    if integrator === :euler
        x += tau * x_dot
        x_dot += tau * xacc
        theta += tau * theta_dot
        theta_dot += tau * thetaacc
    elseif integrator === :semi_implicit_euler
        x_dot += tau * xacc
        x += tau * x_dot
        theta_dot += tau * thetaacc
        theta += tau * theta_dot
    else
        throw(ArgumentError(
            "unsupported CartPole integrator $(repr(integrator)); expected :euler or :semi_implicit_euler",
        ))
    end

    state[1] = Float64(x)
    state[2] = Float64(x_dot)
    state[3] = Float64(theta)
    state[4] = Float64(theta_dot)
    return state
end

function _cartpole_step_state!(env::CartPoleVariantEnv, force::Real)
    _integrate_cartpole_state!(
        env.state,
        force;
        tau=env.tau,
        gravity=env.gravity,
        pole_length=env.pole_length,
        pole_mass=env.pole_mass,
        total_mass=env.total_mass,
    )
    return env
end

function step!(env::CartPoleVariantEnv, effectors)
    env.done && return env

    e = _bounded_effectors(effectors, n_effectors(env))
    force = e[1] >= e[2] ? -env.force_mag : env.force_mag
    _cartpole_step_state!(env, force)

    env.step_count += 1
    theta = _wrap_rad(env.state[3])
    balanced = abs(env.state[1]) <= env.max_x && abs(theta) <= env.max_theta
    alive = abs(env.state[1]) <= env.max_x && (!env.terminate_on_theta || abs(theta) <= env.max_theta)
    push!(env.balance_history, balanced ? 1.0 : 0.0)
    push!(env.upright_history, (cos(env.state[3]) + 1.0) / 2.0)
    env.done = !alive
    return env
end

function reset!(env::CartPoleVariantEnv)
    copyto!(
        env.state,
        _cartpole_initial_state(
            env.rng,
            env.init_x_range,
            env.init_xdot_range,
            env.init_theta_range,
            env.init_thetadot_range,
        ),
    )
    env.step_count = 0
    env.done = false
    empty!(env.balance_history)
    empty!(env.upright_history)
    return env
end

function _cartpole_window_mean(values::Vector{Float64}, window::Integer)
    window = Int(window)
    window <= 0 && return 0.0
    bounds = _tail_bounds(length(values), Int(window))
    isempty(bounds) && return 0.0
    return sum(@view values[bounds]) / window
end

function metrics(env::CartPoleVariantEnv, window::Integer=default_window(env))
    balanced_fraction = _cartpole_window_mean(env.balance_history, window)
    mean_uprightness = _cartpole_window_mean(env.upright_history, window)
    raw_score =
        env.score_kind == :mean_uprightness ? mean_uprightness :
        env.score_kind == :balanced_fraction ? balanced_fraction :
        throw(ArgumentError("unknown CartPole score_kind $(env.score_kind)"))
    return (
        name=String(env.name),
        score=Float64(raw_score),
        balanced_fraction=Float64(balanced_fraction),
        mean_uprightness=Float64(mean_uprightness),
        steps_balanced=Int(round(sum(env.balance_history))),
        ticks=env.step_count,
        fell=env.done,
        xy_path=nothing,
    )
end

function _cartpole_variant_env(rng, defaults::NamedTuple, kwargs)
    options = Dict{Symbol,Any}()
    for (key, value) in pairs(defaults)
        options[Symbol(key)] = value
    end
    for (key, value) in pairs(kwargs)
        options[Symbol(key)] = value
    end
    keys_ = Tuple(keys(options))
    values_ = Tuple(options[key] for key in keys_)
    return CartPoleVariantEnv(; rng=rng, NamedTuple{keys_}(values_)...)
end

function CartPoleHardEnv(; rng=Random.default_rng(), kwargs...)
    return _cartpole_variant_env(
        rng,
        (
            name=:cartpole_hard,
            max_theta=0.12,
            max_force=8.0,
            pole_length=0.75,
            obs_max=[2.4, 5.0, 0.12, 5.0],
        ),
        kwargs,
    )
end

function CartPoleLongEnv(; rng=Random.default_rng(), kwargs...)
    return _cartpole_variant_env(
        rng,
        (
            name=:cartpole_long,
            pole_length=1.0,
            max_theta=0.2095,
            max_force=10.0,
            obs_max=[2.4, 5.0, 0.2095, 5.0],
        ),
        kwargs,
    )
end

function CartPoleSwingupEnv(; rng=Random.default_rng(), kwargs...)
    return _cartpole_variant_env(
        rng,
        (
            name=:cartpole_swingup,
            init_x_range=(-0.25, 0.25),
            init_theta_range=(pi - 0.08, pi + 0.08),
            terminate_on_theta=false,
            max_x=20.0,
            max_theta=pi,
            max_force=10.0,
            score_kind=:mean_uprightness,
            obs_max=[20.0, 5.0, pi, 8.0],
        ),
        kwargs,
    )
end

CartPoleHardEnv(seed::Integer; kwargs...) = CartPoleHardEnv(; rng=MersenneTwister(seed), kwargs...)
CartPoleHardEnv(rng; kwargs...) = CartPoleHardEnv(; rng=rng, kwargs...)
CartPoleLongEnv(seed::Integer; kwargs...) = CartPoleLongEnv(; rng=MersenneTwister(seed), kwargs...)
CartPoleLongEnv(rng; kwargs...) = CartPoleLongEnv(; rng=rng, kwargs...)
CartPoleSwingupEnv(seed::Integer; kwargs...) = CartPoleSwingupEnv(; rng=MersenneTwister(seed), kwargs...)
CartPoleSwingupEnv(rng; kwargs...) = CartPoleSwingupEnv(; rng=rng, kwargs...)

n_receptors(::typeof(CartPoleHardEnv)) = 8
n_receptors(::typeof(CartPoleLongEnv)) = 8
n_receptors(::typeof(CartPoleSwingupEnv)) = 8
n_effectors(::typeof(CartPoleHardEnv)) = 2
n_effectors(::typeof(CartPoleLongEnv)) = 2
n_effectors(::typeof(CartPoleSwingupEnv)) = 2
default_ticks(::typeof(CartPoleHardEnv)) = 1500
default_ticks(::typeof(CartPoleLongEnv)) = CARTPOLE_DEFAULT_TICKS
default_ticks(::typeof(CartPoleSwingupEnv)) = 1500
default_window(::typeof(CartPoleHardEnv)) = 1500
default_window(::typeof(CartPoleLongEnv)) = CARTPOLE_DEFAULT_WINDOW
default_window(::typeof(CartPoleSwingupEnv)) = 1500

function _cartpole_force_effectors(force::Real)
    return Float64(force) < 0.0 ? [1.0, 0.0] : [0.0, 1.0]
end

function cartpole_balancer(env)
    theta = _wrap_rad(env.state[3])
    theta_dot = env.state[4]
    x = env.state[1]
    x_dot = env.state[2]
    command = 80.0 * theta + 18.0 * theta_dot + 1.0 * x + 2.0 * x_dot
    return _cartpole_force_effectors(command)
end

function cartpole_swingup_controller(env)
    theta = _wrap_rad(env.state[3])
    theta_dot = env.state[4]
    if abs(theta) < 0.22
        return cartpole_balancer(env)
    end

    energy = 0.5 * (env.pole_length * theta_dot)^2 + env.gravity * env.pole_length * (cos(theta) - 1.0)
    command = theta_dot * cos(theta) * energy + 0.1 * env.state[1] + 0.2 * env.state[2]
    if abs(command) < 1e-9
        command = theta >= 0.0 ? -1.0 : 1.0
    end
    return _cartpole_force_effectors(command)
end

scene(env::CartPoleVariantEnv) = (kind=:cartpole, x=env.state[1], theta=env.state[3],
                                  max_x=env.max_x, pole_length=env.pole_length)
