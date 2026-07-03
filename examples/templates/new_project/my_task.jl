using Random

import BrainlessLab: TaskSpec, TaskWorld
import BrainlessLab: sense, step!, reset!, metrics
import BrainlessLab: n_receptors, n_effectors, default_ticks, default_window
import BrainlessLab: register_task!

mutable struct MyTrackingEnv <: TaskWorld
    rng::Any
    x::Float64
    velocity::Float64
    tick::Int
    period::Float64
    actuator_gain::Float64
    damping::Float64
    error_history::Vector{Float64}
    x_history::Vector{Float64}
    target_history::Vector{Float64}
end

function MyTrackingEnv(;
    rng=Random.default_rng(),
    x::Real=0.0,
    period::Real=90.0,
    actuator_gain::Real=0.08,
    damping::Real=0.85,
)
    return MyTrackingEnv(
        rng,
        Float64(x),
        0.0,
        0,
        Float64(period),
        Float64(actuator_gain),
        Float64(damping),
        Float64[],
        Float64[],
        Float64[],
    )
end

MyTrackingEnv(seed::Integer; kwargs...) = MyTrackingEnv(; rng=MersenneTwister(seed), kwargs...)
MyTrackingEnv(rng; kwargs...) = MyTrackingEnv(; rng=rng, kwargs...)

n_receptors(::Type{MyTrackingEnv}) = 2
n_receptors(::MyTrackingEnv) = n_receptors(MyTrackingEnv)
n_effectors(::Type{MyTrackingEnv}) = 2
n_effectors(::MyTrackingEnv) = n_effectors(MyTrackingEnv)
default_ticks(::Type{MyTrackingEnv}) = 300
default_ticks(::MyTrackingEnv) = default_ticks(MyTrackingEnv)
default_window(::Type{MyTrackingEnv}) = 100
default_window(::MyTrackingEnv) = default_window(MyTrackingEnv)

_target(env::MyTrackingEnv) = sin(2.0 * pi * env.tick / env.period)

function sense(env::MyTrackingEnv)
    error = _target(env) - env.x
    return Float64[
        max(0.0, error) / 2.0,
        max(0.0, -error) / 2.0,
    ]
end

function _bounded_effectors(effectors, n::Integer)
    values = Float64.(vec(collect(effectors)))
    length(values) == n || throw(DimensionMismatch("expected $n effectors, got $(length(values))"))
    return clamp.(values, 0.0, 1.0)
end

function step!(env::MyTrackingEnv, effectors)
    e = _bounded_effectors(effectors, n_effectors(env))
    target = _target(env)

    env.velocity = env.damping * env.velocity + env.actuator_gain * (e[1] - e[2])
    env.x = clamp(env.x + env.velocity, -1.0, 1.0)

    push!(env.error_history, target - env.x)
    push!(env.x_history, env.x)
    push!(env.target_history, target)
    env.tick += 1
    return env
end

function reset!(env::MyTrackingEnv; x::Real=0.0)
    env.x = Float64(x)
    env.velocity = 0.0
    env.tick = 0
    empty!(env.error_history)
    empty!(env.x_history)
    empty!(env.target_history)
    return env
end

function _tail_bounds(len::Integer, window::Integer)
    len <= 0 && return 1:0
    window <= 0 && return 1:0
    return max(1, len - Int(window) + 1):len
end

function _mean_abs(values)
    isempty(values) && return 0.0
    total = 0.0
    @inbounds for value in values
        total += abs(Float64(value))
    end
    return total / length(values)
end

function metrics(env::MyTrackingEnv, window::Integer=default_window(env))
    bounds = _tail_bounds(length(env.error_history), Int(window))
    recent_errors = @view env.error_history[bounds]
    mean_abs_error = _mean_abs(recent_errors)
    final_error = isempty(env.error_history) ? 0.0 : env.error_history[end]
    score = clamp(1.0 - mean_abs_error / 2.0, 0.0, 1.0)

    return (
        name="my_task",
        score=Float64(score),
        mean_abs_error=Float64(mean_abs_error),
        final_error=Float64(final_error),
        ticks=length(env.error_history),
        x_history=copy(env.x_history),
        target_history=copy(env.target_history),
        xy_path=nothing,
    )
end

const MY_TASK = TaskSpec(
    :my_task,
    MyTrackingEnv;
    default_ticks=default_ticks(MyTrackingEnv),
    default_window=default_window(MyTrackingEnv),
    score_floor=0.0,
    score_ceiling=1.0,
    score_key=:score,
)

register_task!(:my_task, MY_TASK)
