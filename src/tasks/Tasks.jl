using Random

struct TaskSpec <: AbstractTask
    name::Symbol
    env_type::Any
    n_receptors::Int
    n_effectors::Int
    default_ticks::Int
    default_window::Int
    floor::ScoreAnchor
    ceiling::ScoreAnchor
    score_key::Symbol
    descriptor_keys::Vector{Symbol}
end

function TaskSpec(
    name::Symbol,
    env_type;
    n_receptors::Integer=n_receptors(env_type),
    n_effectors::Integer=n_effectors(env_type),
    default_ticks::Integer=default_ticks(env_type),
    default_window::Integer=default_window(env_type),
    floor=nothing,
    ceiling=nothing,
    score_floor=nothing,
    score_ceiling=nothing,
    score_key::Symbol=:score,
    descriptor_keys=Symbol[],
)
    task_name = Symbol(name)
    floor_anchor = _task_anchor(
        task_name,
        :floor,
        floor,
        score_floor,
        analytic(0.0; note="default analytic floor"),
    )
    ceiling_anchor = _task_anchor(
        task_name,
        :ceiling,
        ceiling,
        score_ceiling,
        analytic(1.0; note="default analytic ceiling"),
    )
    return TaskSpec(
        task_name,
        env_type,
        Int(n_receptors),
        Int(n_effectors),
        Int(default_ticks),
        Int(default_window),
        floor_anchor,
        ceiling_anchor,
        score_key,
        Symbol.(collect(descriptor_keys)),
    )
end

function Base.getproperty(task::TaskSpec, key::Symbol)
    if key === :score_floor
        return getfield(task, :floor).value
    elseif key === :score_ceiling
        return getfield(task, :ceiling).value
    end
    return getfield(task, key)
end

score_floor(task::TaskSpec) = task.floor.value
score_ceiling(task::TaskSpec) = task.ceiling.value

const WALL_TASK = TaskSpec(
    :wall,
    WallEnv;
    floor=null_anchor(0.763125, "null=null_random, score_key=nav_score, seeds 0:7, git d420563, 2026-07-04"),
    ceiling=reference_anchor(1.0, "legacy observed best, pending reference-genome calibration; reference=falandays_base measured 0.013392857142857137 <= null floor 0.763125, score_key=nav_score, seeds 0:7, git d420563, 2026-07-04"), # TODO(reference-genome)
    score_key=:nav_score,
    descriptor_keys=[:collisions_window, :distance_window],
)

const TRACKING_TASK = TaskSpec(
    :tracking,
    TrackingEnv;
    floor=analytic(0.0; note="E[cos]=0 chance"),
    ceiling=analytic(1.0; note="perfect heading alignment"),
    score_key=:track_score,
)

const PONG_TASK = TaskSpec(
    :pong,
    PongEnv;
    floor=null_anchor(0.3561507936507936, "null=null_random, score_key=hit_rate, seeds 0:7, git d420563, 2026-07-04"),
    ceiling=reference_anchor(0.7008928571428571, "reference=falandays_base, score_key=hit_rate, seeds 0:7, git d420563, 2026-07-04"),
    score_key=:hit_rate,
)

const PONG_HITRATE_TASK = TaskSpec(
    :pong_hitrate,
    PongEnv;
    floor=null_anchor(0.3561507936507936, "null=null_random, score_key=hit_rate, seeds 0:7, git d420563, 2026-07-04"),
    ceiling=reference_anchor(0.7008928571428571, "reference=falandays_base, score_key=hit_rate, seeds 0:7, git d420563, 2026-07-04"),
    score_key=:hit_rate,
)

const CARTPOLE_TASK = TaskSpec(
    :cartpole,
    CartPoleEnv;
    floor=analytic(0.0; note="minimum balanced fraction"),
    ceiling=analytic(1.0; note="full episode balanced"),
)

const CARTPOLE_HARD_TASK = TaskSpec(
    :cartpole_hard,
    CartPoleHardEnv;
    floor=analytic(0.0; note="minimum balanced fraction"),
    ceiling=analytic(1.0; note="full window balanced"),
)

const CARTPOLE_SWINGUP_TASK = TaskSpec(
    :cartpole_swingup,
    CartPoleSwingupEnv;
    floor=null_anchor(0.1569039231621101, "null=null_random, score_key=mean_uprightness, seeds 0:7, git d420563, 2026-07-04"),
    ceiling=analytic(1.0; note="perfect uprightness"),
    score_key=:mean_uprightness,
)

const CARTPOLE_LONG_TASK = TaskSpec(
    :cartpole_long,
    CartPoleLongEnv;
    floor=analytic(0.0; note="minimum balanced fraction"),
    ceiling=analytic(1.0; note="full window balanced"),
)

const FORAGE_FLOOR_ANCHOR =
    null_anchor(0.4556865216303779, "null=null_random, score_key=forage_score, seeds 0:7, git d420563, 2026-07-04")
const FORAGE_CEILING_ANCHOR =
    analytic(1.0; note="agents on source")

function normalized_forage_score(raw_score::Real)
    return _normalized_anchor_score(
        raw_score,
        FORAGE_FLOOR_ANCHOR,
        FORAGE_CEILING_ANCHOR,
        "forage",
    )
end

resolve_task(task::TaskSpec) = task
resolve_task(name::AbstractString) = resolve_task(Symbol(name))

function make_env(task::TaskSpec; rng=Random.default_rng(), kwargs...)
    return task.env_type(; rng=rng, kwargs...)
end

make_env(task::TaskSpec, rng; kwargs...) = make_env(task; rng=rng, kwargs...)
make_env(task_name::Union{Symbol,AbstractString}; kwargs...) = make_env(resolve_task(task_name); kwargs...)

function normalized_score(task::TaskSpec, raw_score::Real)
    return _normalized_anchor_score(raw_score, task.floor, task.ceiling, "task $(task.name)")
end

normalized_score(task_name::Union{Symbol,AbstractString}, raw_score::Real) =
    normalized_score(resolve_task(task_name), raw_score)
