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
Declare accepted setup keyword defaults in `options` so composition resolution
can reject unknown keys and record the complete setup.

`default_window` remains the environment-metric fallback. The independent
`minimum_scored_ticks` field declares how many scored ticks a task objective
needs before its value is meaningful.

For the `TaskWorld` compatibility path, implement `sense(environment)`,
`step!(environment, effectors)`, `metrics(environment, window)`,
`reset!(environment)`, `n_receptors(::Type{Environment})`,
`n_effectors(::Type{Environment})`, `default_ticks(::Type{Environment})`, and
`default_window(::Type{Environment})`. Register the resulting `TaskSpec` with
`register_task!`.
"""
struct TaskSpec{S,E,O} <: AbstractTask
    name::Symbol
    setup::S
    env_type::E
    n_receptors::Union{Nothing,Int}
    n_effectors::Union{Nothing,Int}
    default_ticks::Int
    default_window::Int
    minimum_scored_ticks::Int
    interaction_cycle::Union{Nothing,InteractionCycle}
    status::Symbol
    tags::Tuple{Vararg{Symbol}}
    protocol::NamedTuple
    options::O
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
    minimum_scored_ticks::Integer=default_window,
    interaction_cycle::Union{Nothing,InteractionCycle}=nothing,
    status::Symbol=:stable,
    tags=(),
    protocol::NamedTuple=NamedTuple(),
    options=Dict{Symbol,Any}(),
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
        minimum_scored_ticks=minimum_scored_ticks,
        interaction_cycle=interaction_cycle,
        status=status,
        tags=tags,
        protocol=protocol,
        options=options,
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
    minimum_scored_ticks::Integer=default_window,
    interaction_cycle::Union{Nothing,InteractionCycle}=nothing,
    status::Symbol=:stable,
    tags=(),
    protocol::NamedTuple=NamedTuple(),
    options=Dict{Symbol,Any}(),
    floor=nothing,
    ceiling=nothing,
    score_floor=nothing,
    score_ceiling=nothing,
    score_key::Union{Nothing,Symbol}=nothing,
    descriptor_keys=Symbol[],
) where {S}
    task_name = Symbol(name)
    status in (:reference, :stable, :experimental, :control, :alias) ||
        throw(ArgumentError(
            "task :$(task_name) status must be :reference, :stable, :experimental, :control, or :alias",
        ))
    tags_ = Tuple(Symbol(tag) for tag in tags)
    length(unique(tags_)) == length(tags_) || throw(ArgumentError(
        "task :$(task_name) tags must be unique; got $(tags_)",
    ))
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
    _anchor_scored_ticks(floor_anchor, ceiling_anchor)
    options_ = _option_defaults(options, "task :$(task_name)")
    minimum_scored_ticks_ = Int(minimum_scored_ticks)
    minimum_scored_ticks_ > 0 || throw(ArgumentError(
        "task :$(task_name) minimum_scored_ticks must be positive",
    ))
    # A task whose own default run cannot satisfy its own minimum makes the
    # no-argument call an error, which is the silent-inconsistency class this
    # minimum exists to remove. Reject it at registration.
    Int(default_ticks) >= minimum_scored_ticks_ || throw(ArgumentError(
        "task :$(task_name) default_ticks = $(Int(default_ticks)) is below its " *
        "minimum_scored_ticks = $(minimum_scored_ticks_); a default run must be " *
        "long enough to score",
    ))
    return TaskSpec(
        task_name,
        setup,
        env_type,
        n_receptors === nothing ? nothing : Int(n_receptors),
        n_effectors === nothing ? nothing : Int(n_effectors),
        Int(default_ticks),
        Int(default_window),
        minimum_scored_ticks_,
        interaction_cycle,
        status,
        tags_,
        protocol,
        options_,
        floor_anchor,
        ceiling_anchor,
        score_key,
        Symbol.(collect(descriptor_keys)),
    )
end

function _validate_minimum_scored_ticks(
    task::TaskSpec,
    scored_ticks::Integer;
    explicit_window::Bool=false,
    typed_evaluation::Bool=false,
)
    scored_ticks_ = Int(scored_ticks)
    task.score_key === nothing && return scored_ticks_
    explicit_window && return scored_ticks_
    scored_ticks_ >= task.minimum_scored_ticks && return scored_ticks_
    action = typed_evaluation ?
        "Increase evaluation horizon or reduce warmup" :
        "Increase ticks, or pass an explicit window to acknowledge a shorter diagnostic run"
    throw(ArgumentError(
        "task :$(task.name) scored interval is $(scored_ticks_) ticks, but " *
        "minimum_scored_ticks is $(task.minimum_scored_ticks). $(action).",
    ))
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

const WALL_TASK_OPTIONS = (
    x=nothing,
    y=nothing,
    theta=nothing,
    lam=1.0,
    sensory_noise=0.0,
    clip_sensory_noise=true,
)

const TRACKING_TASK_OPTIONS = (
    stim_speed_rad=deg2rad(1.0),
    movement_amp=10.0,
    eye_offset_deg=30.0,
    sensor_offsets_deg=collect(-60.0:4.0:60.0),
    sensory_gain=1.0,
    randomize_start=true,
    theta0=nothing,
    phi0=nothing,
    direction0=nothing,
)

const PONG_TASK_OPTIONS = (sensory_gain=1.0,)

const CARTPOLE_VARIANT_TASK_OPTIONS = (
    name=:cartpole_variant,
    tau=0.02,
    gravity=9.8,
    max_force=10.0,
    pole_length=0.5,
    pole_mass=0.1,
    cart_mass=1.0,
    max_x=2.4,
    max_theta=0.2095,
    terminate_on_theta=true,
    score_kind=:balanced_fraction,
    init_x=nothing,
    init_x_range=(-1.2, 1.2),
    init_xdot=nothing,
    init_xdot_range=(-0.05, 0.05),
    init_theta=nothing,
    init_theta_range=(-0.10475, 0.10475),
    init_thetadot=nothing,
    init_thetadot_range=(-0.05, 0.05),
    obs_max=(2.4, 5.0, Float64(pi), 5.0),
)

function _cartpole_variant_task_options(overrides::NamedTuple)
    defaults = Dict{Symbol,Any}(pairs(CARTPOLE_VARIANT_TASK_OPTIONS))
    merge!(defaults, Dict{Symbol,Any}(pairs(overrides)))
    return defaults
end

const WALL_TASK = TaskSpec(
    :wall,
    WallEnv;
    status=:reference,
    tags=(:benchmark, :qualification, :core),
    minimum_scored_ticks=200,
    options=WALL_TASK_OPTIONS,
    floor=null_anchor(0.81609374999999995, "task=wall, null=null_random, rate_reference=falandays, null_target_rate=0.34008828124999996, score_key=nav_score, scored_ticks=200, sem=0.0120, sd=0.0677, n=32, rng=MersenneTwister, julia=1.12.6, seeds 0:31, git e944fab, 2026-07-28"; scored_ticks=200),
    ceiling=analytic(1.0; note="nav_score max = collision-free navigation while moving (a true analytic optimum); untrained falandays ref measured ~0.013 << null 0.776, so the analytic optimum is the honest ceiling, not a reference agent"),
    score_key=:nav_score,
    descriptor_keys=[:collisions_window, :distance_window],
)

const TRACKING_TASK = TaskSpec(
    :tracking,
    TrackingEnv;
    status=:reference,
    tags=(:benchmark, :qualification, :core),
    minimum_scored_ticks=2000,
    options=TRACKING_TASK_OPTIONS,
    floor=analytic(0.0; note="E[cos]=0 chance; a rate-matched null over 40 seeds at scored_ticks=2000 measures 0.0022 (sd 0.0167 across five 8-seed blocks), consistent with zero, so the analytic anchor stands. The earlier 0.0599 +/- 0.0691 (sd 0.3907) figure was measured over a 200-tick window, where the estimator is dominated by sampling noise"),
    ceiling=analytic(1.0; note="perfect heading alignment"),
    score_key=:track_score,
)

const PONG_TASK = TaskSpec(
    :pong,
    PongEnv;
    status=:reference,
    tags=(:benchmark, :qualification, :core),
    minimum_scored_ticks=6000,
    options=PONG_TASK_OPTIONS,
    floor=null_anchor(0.2704470119755446, "task=pong, null=null_random, rate_reference=falandays, null_target_rate=0.16227604166666712, score_key=hit_rate, scored_ticks=6000, sem=0.0137, sd=0.0778, n=32, rng=MersenneTwister, julia=1.12.6, seeds 0:31, git e944fab, 2026-07-28"; scored_ticks=6000),
    ceiling=analytic(1.0; note="hit_rate max = intercept every ball (a true analytic optimum); no trained reference agent exists yet, so a reference-agent ceiling is a TODO(reference-genome)"),
    score_key=:hit_rate,
)

const PONG_HITRATE_TASK = TaskSpec(
    :pong_hitrate,
    PongEnv;
    status=:alias,
    tags=(:alias,),
    minimum_scored_ticks=6000,
    options=PONG_TASK_OPTIONS,
    floor=null_anchor(0.2704470119755446, "task=pong_hitrate, null=null_random, rate_reference=falandays, null_target_rate=0.16227604166666712, score_key=hit_rate, scored_ticks=6000, sem=0.0137, sd=0.0778, n=32, rng=MersenneTwister, julia=1.12.6, seeds 0:31, git e944fab, 2026-07-28"; scored_ticks=6000),
    ceiling=analytic(1.0; note="hit_rate max = intercept every ball (a true analytic optimum); no trained reference agent exists yet, so a reference-agent ceiling is a TODO(reference-genome)"),
    score_key=:hit_rate,
)

const CARTPOLE_TASK = TaskSpec(
    :cartpole,
    CartPoleEnv;
    status=:experimental,
    tags=(:extended, :control),
    floor=analytic(0.0; note="minimum balanced fraction"),
    ceiling=analytic(1.0; note="full episode balanced"),
)

const CARTPOLE_HARD_TASK = TaskSpec(
    :cartpole_hard,
    CartPoleHardEnv;
    status=:experimental,
    tags=(:extended, :legacy_cartpole_variant),
    options=_cartpole_variant_task_options((
        name=:cartpole_hard,
        max_theta=0.12,
        max_force=8.0,
        pole_length=0.75,
        obs_max=(2.4, 5.0, 0.12, 5.0),
    )),
    floor=analytic(0.0; note="minimum balanced fraction"),
    ceiling=analytic(1.0; note="full window balanced"),
)

const CARTPOLE_SWINGUP_TASK = TaskSpec(
    :cartpole_swingup,
    CartPoleSwingupEnv;
    status=:experimental,
    tags=(:extended, :legacy_cartpole_variant),
    options=_cartpole_variant_task_options((
        name=:cartpole_swingup,
        init_x_range=(-0.25, 0.25),
        init_theta_range=(Float64(pi - 0.08), Float64(pi + 0.08)),
        terminate_on_theta=false,
        max_x=20.0,
        max_theta=Float64(pi),
        max_force=10.0,
        score_kind=:mean_uprightness,
        obs_max=(20.0, 5.0, Float64(pi), 8.0),
    )),
    floor=null_anchor(0.023001180092574576, "task=cartpole_swingup, null=null_random, rate_reference=falandays, null_target_rate=0.08925895833333375, score_key=mean_uprightness, sem=0.0018, sd=0.0104, n=32, rng=MersenneTwister, julia=1.12.6, seeds 0:31, git e944fab, 2026-07-28"),
    ceiling=analytic(1.0; note="perfect uprightness"),
    score_key=:mean_uprightness,
)

const CARTPOLE_LONG_TASK = TaskSpec(
    :cartpole_long,
    CartPoleLongEnv;
    status=:experimental,
    tags=(:extended, :legacy_cartpole_variant),
    options=_cartpole_variant_task_options((
        name=:cartpole_long,
        pole_length=1.0,
        max_theta=0.2095,
        max_force=10.0,
        obs_max=(2.4, 5.0, 0.2095, 5.0),
    )),
    floor=analytic(0.0; note="minimum balanced fraction"),
    ceiling=analytic(1.0; note="full window balanced"),
)

const PLANK_CARTPOLE_PROTOCOL = (
    family=:plank_cartpole_2025,
    source_doi="10.3390/jlpea15010005",
    source_repository="TENNLab-UTK/framework-open",
    source_path="markdown/cartpole_example.md",
    neural_frames=PLANK_CARTPOLE_NEURAL_FRAMES,
    evaluation=EvaluationSpec(
        blocks=1,
        trials_per_block=PLANK_CARTPOLE_EVAL_EPISODES,
        horizon=PLANK_CARTPOLE_MISSION_STEPS,
        construction_scope=:evaluation,
        reset=:full,
        root_seed=10_000,
        aggregate=:mean,
    ),
    cross_task_aggregate=false,
    conformance=(
        dynamics=:gym_default_explicit_euler,
        spike_ff_2=:authors_source_example_matched,
        argyle_4=:paper_specified_adjacent_bins_brainlesslab_schedule_v1,
        voting=:authors_source_lower_index_tie,
    ),
)

function _plank_cartpole_task(level_name::Symbol)
    level = plank_cartpole_level(level_name)
    receptor_count = level.encoder === :argyle_4 ?
        4length(level.observation_indices) :
        2length(level.observation_indices)
    return TaskSpec(
        Symbol(:cartpole_plank_, level.name),
        PlankCartPoleSetup(level);
        env_type=PlankCartPoleEnv,
        n_receptors=receptor_count,
        n_effectors=length(level.actions),
        default_ticks=PLANK_CARTPOLE_MISSION_STEPS,
        default_window=PLANK_CARTPOLE_MISSION_STEPS,
        interaction_cycle=FixedRateCycle(PLANK_CARTPOLE_NEURAL_FRAMES),
        status=:experimental,
        tags=level.name === :easy ?
             (:experimental, :plank_cartpole, :frontier) :
             (:experimental, :plank_cartpole),
        options=(
            initial_ranges=(
                (-1.2, 1.2),
                (-0.05, 0.05),
                (-0.10475, 0.10475),
                (-0.05, 0.05),
            ),
        ),
        protocol=(;
            PLANK_CARTPOLE_PROTOCOL...,
            level=level.name,
            observations=level.observation_indices,
            actions=level.actions,
            encoder=level.encoder,
            target_fitness=level.target_fitness,
            activity_threshold=level.activity_threshold,
        ),
        floor=analytic(0.0; note="minimum raw CartPole fitness"),
        ceiling=analytic(
            PLANK_CARTPOLE_MISSION_STEPS;
            note="maximum mission time before the Medium activity adjustment",
        ),
        score_key=:fitness,
        descriptor_keys=(
            :mission_fraction,
            :steps_balanced,
            :noop_fraction,
            :target_fitness,
            :achieved,
        ),
    )
end

const CARTPOLE_PLANK_EASY_TASK = _plank_cartpole_task(:easy)
const CARTPOLE_PLANK_MEDIUM_TASK = _plank_cartpole_task(:medium)
const CARTPOLE_PLANK_HARD_TASK = _plank_cartpole_task(:hard)
const CARTPOLE_PLANK_HARDEST_TASK = _plank_cartpole_task(:hardest)

const FORAGE_FLOOR_ANCHOR =
    null_anchor(0.45309936524964084, "task=forage, null=null_random, rate_reference=falandays, null_target_rate=0.4352481640624999, score_key=forage_score, sem=0.0037, sd=0.0212, n=32, rng=MersenneTwister, julia=1.12.6, seeds 0:31, git e944fab, 2026-07-28")
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

"""
    normalized_score(task, raw_score; window=nothing)

Map a raw task score between its declared floor and ceiling. Values at or
beyond an anchor are clamped to `[0, 1]`. Aggregated results must therefore
report how many observations hit each bound. A Student-t interval over these
censored values is descriptive; it is not a calibrated interval. A measured
anchor with `scored_ticks` requires a matching `window`.
"""
function normalized_score(task::TaskSpec, raw_score::Real; window=nothing)
    anchor_scored_ticks = _anchor_scored_ticks(task.floor, task.ceiling)
    if anchor_scored_ticks !== nothing
        window === nothing && throw(ArgumentError(
            "normalizing task :$(task.name) requires window=$(anchor_scored_ticks), " *
            "the interval used to measure its anchor",
        ))
        Int(window) == anchor_scored_ticks || throw(ArgumentError(
            "cannot normalize task :$(task.name) over window=$(Int(window)); its " *
            "measured anchor applies at scored_ticks=$(anchor_scored_ticks)",
        ))
    end
    return _normalized_anchor_score(raw_score, task.floor, task.ceiling, "task $(task.name)")
end

normalized_score(task_name::Union{Symbol,AbstractString}, raw_score::Real; kwargs...) =
    normalized_score(resolve_task(task_name), raw_score; kwargs...)
