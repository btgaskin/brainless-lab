using Random

const DELAYED_CUE_DELAYS = (8, 32, 128)
const DELAYED_CUE_HORIZON = 144

"""Binary recall through cue, blank delay, and response phases.

Only `sense` is available to a controller. Pre-response actions are discarded;
the environment accumulates output evidence only while the go channel is active.
"""
mutable struct DelayedCueEnv{R<:AbstractRNG,D<:Tuple} <: TaskWorld
    rng::R
    delays::D
    cue_ticks::Int
    response_ticks::Int
    cue_mode::Symbol
    cue::Int
    delay::Int
    tick::Int
    left_evidence::Float64
    right_evidence::Float64
    decision::Int
    tied::Bool
    done::Bool
end

function _delayed_cue_options(cue_ticks, delays, response_ticks, cue_mode)
    cue_ticks isa Integer && cue_ticks > 0 ||
        throw(ArgumentError("cue_ticks must be a positive integer"))
    response_ticks isa Integer && response_ticks > 0 ||
        throw(ArgumentError("response_ticks must be a positive integer"))
    delays_ = Tuple(delays)
    !isempty(delays_) && all(x -> x isa Integer && x >= 0, delays_) ||
        throw(ArgumentError("delays must contain non-negative integers"))
    length(unique(delays_)) == length(delays_) ||
        throw(ArgumentError("delays must be distinct"))
    mode = Symbol(cue_mode)
    mode in (:transient, :persistent, :hidden) ||
        throw(ArgumentError("cue_mode must be :transient, :persistent, or :hidden"))
    return Int(cue_ticks), Tuple(Int.(delays_)), Int(response_ticks), mode
end

function DelayedCueEnv(; rng=MersenneTwister(0), cue_ticks=8,
    delays=DELAYED_CUE_DELAYS, response_ticks=8, cue_mode=:transient)
    cue_ticks_, delays_, response_ticks_, mode =
        _delayed_cue_options(cue_ticks, delays, response_ticks, cue_mode)
    # Draws do not depend on cue visibility: controls share the same world.
    cue = rand(rng, 1:2)
    delay = rand(rng, delays_)
    return DelayedCueEnv(rng, delays_, cue_ticks_, response_ticks_, mode,
        cue, delay, 0, 0.0, 0.0, 0, false, false)
end

n_receptors(::Type{<:DelayedCueEnv}) = 3
n_receptors(::DelayedCueEnv) = 3
n_effectors(::Type{<:DelayedCueEnv}) = 2
n_effectors(::DelayedCueEnv) = 2
default_ticks(::Type{<:DelayedCueEnv}) = DELAYED_CUE_HORIZON
default_ticks(env::DelayedCueEnv) = env.cue_ticks + maximum(env.delays) + env.response_ticks
default_window(env::DelayedCueEnv) = default_ticks(env)
default_window(::Type{<:DelayedCueEnv}) = DELAYED_CUE_HORIZON
terminated(env::DelayedCueEnv) = env.done

function sense(env::DelayedCueEnv)
    response = !env.done && env.tick >= env.cue_ticks + env.delay
    visible = !env.done && env.cue_mode !== :hidden &&
        (env.tick < env.cue_ticks || env.cue_mode === :persistent)
    return SVector(visible && env.cue == 1 ? 1.0 : 0.0,
        visible && env.cue == 2 ? 1.0 : 0.0, response ? 1.0 : 0.0)
end

function step!(env::DelayedCueEnv, output)
    env.done && return env
    length(output) == 2 || throw(DimensionMismatch("delayed-cue requires two effectors"))
    all(x -> x isa Real && isfinite(x) && 0 <= x <= 1, output) ||
        throw(ArgumentError("delayed-cue effectors must be finite and within [0, 1]"))
    if env.tick >= env.cue_ticks + env.delay
        env.left_evidence += output[1]
        env.right_evidence += output[2]
    end
    env.tick += 1
    if env.tick == env.cue_ticks + env.delay + env.response_ticks
        env.tied = env.left_evidence == env.right_evidence
        env.decision = env.left_evidence >= env.right_evidence ? 1 : 2
        env.done = true
    end
    return env
end

"""Reset this episode without redrawing its cue or delay; new worlds use new seeds."""
function reset!(env::DelayedCueEnv)
    env.tick = 0
    env.left_evidence = 0.0
    env.right_evidence = 0.0
    env.decision = 0
    env.tied = false
    env.done = false
    return env
end

function metrics(env::DelayedCueEnv, window::Integer=default_window(env))
    accuracy = env.done ? Float64(env.decision == env.cue) : missing
    return (name="delayed_cue", score=accuracy, recall_accuracy=accuracy,
        cue=env.cue, delay=env.delay, decision=env.decision, tied=env.tied,
        completed=env.done, cue_mode=env.cue_mode, chance_accuracy=0.5,
        left_evidence=env.left_evidence, right_evidence=env.right_evidence,
        xy_path=nothing)
end

struct DelayedCueSetup end

function (::DelayedCueSetup)(; seed=0, rng=nothing, body=nothing, n_nodes=nothing, kwargs...)
    body === nothing || body === :direct || throw(ArgumentError(
        "delayed-cue freezes its direct observation and action interface"))
    environment = DelayedCueEnv(; rng=rng === nothing ? MersenneTwister(Int(seed)) : rng, kwargs...)
    return TaskSetup(environment, [direct_embodiment(3, 2)])
end
