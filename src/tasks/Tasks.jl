using Random

"""
    TaskSetup(environment, bodies)

Concrete runtime pieces produced by a task setup callable. Reservoirs are built
after this value exists, from each body's own port contract.
"""
struct TaskSetup{E<:Environment,B<:AbstractVector}
    environment::E
    bodies::B

    function TaskSetup(environment::E, bodies::AbstractVector) where {E<:Environment}
        isempty(bodies) && throw(ArgumentError("TaskSetup requires at least one body"))
        all(body -> body isa AbstractBody, bodies) || throw(ArgumentError(
            "TaskSetup bodies must all be AbstractBody values",
        ))
        first_type = typeof(first(bodies))
        body_vec = if all(body -> body isa first_type, bodies)
            out = Vector{first_type}(undef, length(bodies))
            copyto!(out, bodies)
            out
        else
            AbstractBody[body for body in bodies]
        end
        return new{E,typeof(body_vec)}(environment, body_vec)
    end
end

"""Setup callable used by the compatibility `TaskSpec(name, TaskWorldType)` form."""
struct TaskWorldSetup{C}
    constructor::C
end

environment_type(setup::TaskWorldSetup) = setup.constructor
environment_type(setup) = nothing

function _task_setup_rng(seed)
    return seed === nothing ? MersenneTwister() : MersenneTwister(Int(seed))
end

function _setup_body(body, environment)
    if body === nothing || body === :direct || body == "direct"
        return direct_embodiment(n_receptors(environment), n_effectors(environment))
    elseif body isa AbstractBody
        return body
    end

    ctor =
        body isa Symbol ? resolve_body(body) :
        body isa AbstractString ? resolve_body(Symbol(body)) :
        body
    applicable(ctor) || throw(ArgumentError(
        "task body must be an AbstractBody instance, registered body symbol, or zero-argument AbstractBody constructor",
    ))
    body_obj = ctor()
    body_obj isa AbstractBody || throw(ArgumentError(
        "task body constructor returned $(typeof(body_obj)), not an AbstractBody",
    ))
    return body_obj
end

function (setup::TaskWorldSetup)(;
    seed=0,
    rng=nothing,
    body=nothing,
    kwargs...,
)
    env_rng = rng === nothing ? _task_setup_rng(seed) : rng
    environment = setup.constructor(; rng=env_rng, kwargs...)
    environment isa TaskWorld || throw(ArgumentError(
        "task-world constructor returned $(typeof(environment)), not a TaskWorld",
    ))
    return TaskSetup(environment, [_setup_body(body, environment)])
end

"""
    TaskSpec

Task composition plus rollout/scoring metadata. `setup` is any concrete callable
returning `TaskSetup`; no builder hierarchy is required. Static receptor/effector
counts are optional default metadata only; resolved body ports size reservoirs.
"""
struct TaskSpec{S,E} <: AbstractTask
    name::Symbol
    setup::S
    env_type::E
    n_receptors::Union{Nothing,Int}
    n_effectors::Union{Nothing,Int}
    default_ticks::Int
    default_window::Int
    floor::ScoreAnchor
    ceiling::ScoreAnchor
    score_key::Union{Nothing,Symbol}
    descriptor_keys::Vector{Symbol}
end

function TaskSpec(
    name::Symbol,
    env_type::Union{Type{<:TaskWorld},Function};
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
    return TaskSpec(
        name,
        TaskWorldSetup(env_type);
        env_type=env_type,
        n_receptors=n_receptors,
        n_effectors=n_effectors,
        default_ticks=default_ticks,
        default_window=default_window,
        floor=floor,
        ceiling=ceiling,
        score_floor=score_floor,
        score_ceiling=score_ceiling,
        score_key=score_key,
        descriptor_keys=descriptor_keys,
    )
end

function TaskSpec(
    name::Symbol,
    setup::S;
    env_type=nothing,
    n_receptors=nothing,
    n_effectors=nothing,
    default_ticks::Integer=1000,
    default_window::Integer=default_ticks,
    floor=nothing,
    ceiling=nothing,
    score_floor=nothing,
    score_ceiling=nothing,
    score_key::Union{Nothing,Symbol}=nothing,
    descriptor_keys=Symbol[],
) where {S}
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
        setup,
        env_type,
        n_receptors === nothing ? nothing : Int(n_receptors),
        n_effectors === nothing ? nothing : Int(n_effectors),
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
has_objective(task::TaskSpec) = task.score_key !== nothing

function setup_task(task::TaskSpec; seed=0, rng=nothing, body=nothing, kwargs...)
    setup = rng === nothing ?
        task.setup(; seed=seed, body=body, kwargs...) :
        task.setup(; seed=seed, rng=rng, body=body, kwargs...)
    setup isa TaskSetup || throw(ArgumentError(
        "task :$(task.name) setup returned $(typeof(setup)); expected TaskSetup",
    ))
    return validate_task_setup(setup)
end

validate_task_setup(setup::TaskSetup) = setup

"""
    resolved_task_ports(task; kwargs...)

Construct a task's default setup and return one port layout per body in stable
world-slot order.
`TaskSpec.n_receptors` and `n_effectors` are optional legacy/default metadata;
resolved bodies remain the runtime source of truth.
"""
function resolved_task_ports(task::TaskSpec; kwargs...)
    setup = setup_task(task; kwargs...)
    return Tuple(portspec(body) for body in setup.bodies)
end

function _fixed_port_counts(layouts; context::AbstractString="fixed-layout caller")
    isempty(layouts) && throw(ArgumentError("$(context) received no port layouts"))
    first_layout = first(layouts)
    counts = (n_receptors=n_receptors(first_layout), n_effectors=n_effectors(first_layout))
    for (slot, layout) in enumerate(layouts)
        candidate = (n_receptors(layout), n_effectors(layout))
        candidate == (counts.n_receptors, counts.n_effectors) || throw(ArgumentError(
            "$(context) requires one fixed receptor/effector layout, but slot 1 has " *
            "($(counts.n_receptors), $(counts.n_effectors)) and slot $(slot) has $(candidate). " *
            "Use per-body resolved_task_ports layouts or configure explicit fixed R/E values.",
        ))
    end
    return counts
end

const WALL_TASK = TaskSpec(
    :wall,
    WallEnv;
    floor=null_anchor(0.763125, "null=null_random, score_key=nav_score, seeds 0:7, git d420563, 2026-07-04"),
    ceiling=analytic(1.0; note="nav_score max = collision-free navigation while moving (a true analytic optimum); untrained falandays_base ref measured ~0.013 << null 0.763, so the analytic optimum is the honest ceiling, not a reference agent"),
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
    ceiling=analytic(1.0; note="hit_rate max = intercept every ball (a true analytic optimum); no trained reference agent exists yet, so a reference-agent ceiling is a TODO(reference-genome)"),
    score_key=:hit_rate,
)

const PONG_HITRATE_TASK = TaskSpec(
    :pong_hitrate,
    PongEnv;
    floor=null_anchor(0.3561507936507936, "null=null_random, score_key=hit_rate, seeds 0:7, git d420563, 2026-07-04"),
    ceiling=analytic(1.0; note="hit_rate max = intercept every ball (a true analytic optimum); no trained reference agent exists yet, so a reference-agent ceiling is a TODO(reference-genome)"),
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

function make_env(task::TaskSpec{S}; rng=Random.default_rng(), kwargs...) where {S<:TaskWorldSetup}
    return environment_type(task.setup)(; rng=rng, kwargs...)
end

function make_env(task::TaskSpec; rng=Random.default_rng(), kwargs...)
    return setup_task(task; seed=0, rng=rng, kwargs...).environment
end

make_env(task::TaskSpec, rng; kwargs...) = make_env(task; rng=rng, kwargs...)
make_env(task_name::Union{Symbol,AbstractString}; kwargs...) = make_env(resolve_task(task_name); kwargs...)

function normalized_score(task::TaskSpec, raw_score::Real)
    return _normalized_anchor_score(raw_score, task.floor, task.ceiling, "task $(task.name)")
end

normalized_score(task_name::Union{Symbol,AbstractString}, raw_score::Real) =
    normalized_score(resolve_task(task_name), raw_score)
