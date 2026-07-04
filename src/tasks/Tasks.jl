using Random

struct TaskSpec <: AbstractTask
    name::Symbol
    env_type::Any
    n_receptors::Int
    n_effectors::Int
    default_ticks::Int
    default_window::Int
    score_floor::Float64
    score_ceiling::Float64
    score_key::Symbol
end

function TaskSpec(
    name::Symbol,
    env_type;
    n_receptors::Integer=n_receptors(env_type),
    n_effectors::Integer=n_effectors(env_type),
    default_ticks::Integer=default_ticks(env_type),
    default_window::Integer=default_window(env_type),
    score_floor::Real=0.0,
    score_ceiling::Real=1.0,
    score_key::Symbol=:score,
)
    return TaskSpec(
        name,
        env_type,
        Int(n_receptors),
        Int(n_effectors),
        Int(default_ticks),
        Int(default_window),
        Float64(score_floor),
        Float64(score_ceiling),
        score_key,
    )
end

const WALL_TASK = TaskSpec(
    :wall,
    WallEnv;
    score_floor=0.0,
    score_ceiling=77.3,
)

const TRACKING_TASK = TaskSpec(
    :tracking,
    TrackingEnv;
    score_floor=0.0,
    score_ceiling=1.0,
)

const PONG_TASK = TaskSpec(
    :pong,
    PongEnv;
    score_floor=0.30,
    score_ceiling=0.52,
    score_key=:hit_rate,
)

const PONG_HITRATE_TASK = TaskSpec(
    :pong_hitrate,
    PongEnv;
    score_floor=0.30,
    score_ceiling=0.52,
    score_key=:hit_rate,
)

const CARTPOLE_TASK = TaskSpec(
    :cartpole,
    CartPoleEnv;
    score_floor=0.0,
    score_ceiling=1.0,
)

const CARTPOLE_HARD_TASK = TaskSpec(
    :cartpole_hard,
    CartPoleHardEnv;
    score_floor=0.0,
    score_ceiling=1.0,
)

const CARTPOLE_SWINGUP_TASK = TaskSpec(
    :cartpole_swingup,
    CartPoleSwingupEnv;
    score_floor=0.02,
    score_ceiling=1.0,
    score_key=:mean_uprightness,
)

const CARTPOLE_LONG_TASK = TaskSpec(
    :cartpole_long,
    CartPoleLongEnv;
    score_floor=0.0,
    score_ceiling=1.0,
)

resolve_task(task::TaskSpec) = task
resolve_task(name::AbstractString) = resolve_task(Symbol(name))

function make_env(task::TaskSpec; rng=Random.default_rng(), kwargs...)
    return task.env_type(; rng=rng, kwargs...)
end

make_env(task::TaskSpec, rng; kwargs...) = make_env(task; rng=rng, kwargs...)
make_env(task_name::Union{Symbol,AbstractString}; kwargs...) = make_env(resolve_task(task_name); kwargs...)

function normalized_score(task::TaskSpec, raw_score::Real)
    floor = task.score_floor
    ceiling = task.score_ceiling
    ceiling <= floor &&
        throw(ArgumentError("score_ceiling must exceed score_floor for task $(task.name)"))
    scaled = (Float64(raw_score) - floor) / (ceiling - floor)
    return clamp(scaled, 0.0, 1.0)
end

normalized_score(task_name::Union{Symbol,AbstractString}, raw_score::Real) =
    normalized_score(resolve_task(task_name), raw_score)
