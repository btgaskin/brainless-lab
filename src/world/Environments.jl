using Random

abstract type AbstractSituatedEnvironment <: Environment end
abstract type AbstractTorusEnvironment <: AbstractSituatedEnvironment end

"""Compatibility adapter; `TaskWorld` itself is now an `Environment`."""
struct TaskEnvironment{W<:TaskWorld} <: Environment
    world::W
end

function _require_single_body(bodies)
    length(bodies) == 1 ||
        throw(ArgumentError("TaskEnvironment wraps one TaskWorld and requires exactly one body"))
    return nothing
end

function sample!(m::TaskWorld, bodies)
    _require_single_body(bodies)
    return [sense(m)]
end

function apply_commands!(m::TaskWorld, bodies, Es)
    _require_single_body(bodies)
    length(Es) == 1 ||
        throw(ArgumentError("TaskWorld requires exactly one effector command"))
    command = Es[1]
    step!(m, command isa DirectCommand ? command_values(command) : command)
    return nothing
end

sample!(m::TaskEnvironment, bodies) = sample!(m.world, bodies)
apply_commands!(m::TaskEnvironment, bodies, Es) = apply_commands!(m.world, bodies, Es)
metrics(m::TaskEnvironment, window::Integer=default_window(m.world)) =
    metrics(m.world, Int(window))

"""
    EmbodiedEnvironment(arena, states, sampler)

Minimal generic physical runtime for composed embodiments. `sampler` receives
`(body, motion_state, tick, arena)` and returns raw samples aligned with the
body's sensor components. Commands are decoded by the body, integrated by its
own dynamics component, then projected back into the arena boundary.
"""
mutable struct EmbodiedEnvironment{A<:Union{Torus,WalledArena},F} <: Environment
    arena::A
    states::Vector{MotionState2D}
    sampler::F
    tick::Int
end

function EmbodiedEnvironment(
    arena::Union{Torus,WalledArena},
    states,
    sampler,
)
    states_ = MotionState2D[state for state in states]
    isempty(states_) && throw(ArgumentError("EmbodiedEnvironment requires at least one motion state"))
    return EmbodiedEnvironment{typeof(arena),typeof(sampler)}(arena, states_, sampler, 0)
end

function sample!(environment::EmbodiedEnvironment, bodies)
    length(bodies) == length(environment.states) || throw(DimensionMismatch(
        "EmbodiedEnvironment has $(length(environment.states)) states for $(length(bodies)) bodies",
    ))
    return [
        alive(body) ?
            environment.sampler(body, environment.states[index], environment.tick, environment.arena) :
            _inactive_sensor_samples(body)
        for (index, body) in enumerate(bodies)
    ]
end

function _inactive_sensor_samples(body::Embodiment)
    samples = Tuple(zeros(Float64, _raw_width(sensor)) for sensor in sensor_components(body))
    return length(samples) == 1 ? only(samples) : samples
end

_inactive_sensor_samples(body::AbstractBody) = zeros(Float64, n_receptors(body))

function _project_motion!(state::MotionState2D, arena::Torus, geometry::AbstractGeometry)
    state.position = typeof(state.position)(wrap(arena, state.position[1], state.position[2])...)
    return state
end


function _project_motion!(state::MotionState2D, arena::WalledArena, geometry::AbstractGeometry)
    radius = geometry_radius(geometry)
    xmin, xmax, ymin, ymax = arena_bounds(arena)
    x = clamp(state.position[1], xmin + radius, xmax - radius)
    y = clamp(state.position[2], ymin + radius, ymax - radius)
    vx = x == state.position[1] ? state.velocity[1] : 0.0
    vy = y == state.position[2] ? state.velocity[2] : 0.0
    state.position = typeof(state.position)(x, y)
    state.velocity = typeof(state.velocity)(vx, vy)
    return state
end

function apply_commands!(environment::EmbodiedEnvironment, bodies, commands)
    length(bodies) == length(environment.states) == length(commands) ||
        throw(DimensionMismatch("EmbodiedEnvironment requires one command per body"))
    @inbounds for index in eachindex(bodies)
        body = bodies[index]
        body isa Embodiment || throw(ArgumentError(
            "EmbodiedEnvironment requires composed Embodiment bodies; got $(typeof(body))",
        ))
        alive(body) || continue
        command = commands[index]
        command isa Tuple && throw(ArgumentError(
            "EmbodiedEnvironment currently requires one actuator command per body",
        ))
        integrate!(environment.states[index], body.dynamics, command)
        _project_motion!(environment.states[index], environment.arena, body.geometry)
    end
    environment.tick += 1
    return [() for _ in bodies]
end

metrics(environment::EmbodiedEnvironment, window::Integer=1) = (
    mean_speed=sum(linear_speed, environment.states) / length(environment.states),
)

Base.@kwdef struct SituatedConfig
    n_agents::Int
    space_size::Float64 = 15.0
    n_nodes::Int = 250
    link_p::Float64 = 0.1
    sens_agent_dist::Int = 0
    vision_range::Union{Nothing,Float64} = nothing
    source_vision_range::Union{Nothing,Float64} = nothing
    sensory_noise::Float64 = 0.1
    sensory_scaling::Bool = true
    visual_coupling::Bool = true
    physical_coupling::Bool = false
    conspecific_vision::Bool = true
    # Optional body-to-body interaction policy. An active agent receives each
    # effect at most once per tick when any active conspecific is in range.
    conspecific_contact_radius::Union{Nothing,Float64} = nothing
    conspecific_contact_effects::Tuple = ()
    source_position::Union{Nothing,NTuple{2,Float64}} = nothing
    source_gain::Float64 = 1.0
    # Informed-subset ("lookout") mask for :forage: the first `n_lookouts` agents
    # see the source (source_gain), the rest are blind followers (source_gain=0).
    # `nothing` = every agent is a lookout (symmetric forage). Materialised into
    # the per-agent `source_gains` env array at construction.
    n_lookouts::Union{Nothing,Int} = nothing
    # Conspecific-bank normalisation: nothing -> derive from sensory_scaling
    # (authors-faithful). Explicit :hard | :raw | :divisive overrides; norm_sigma
    # is the :divisive semi-saturation constant.
    norm_mode::Union{Nothing,Symbol} = nothing
    norm_sigma::Float64 = 1.0
    conspecific_gain::Float64 = 1.0
    signalling::Bool = false
    signal_range::Float64 = 3.0
    signal_gain::Float64 = 1.0
    capture_radius::Float64 = 1.0
    # The uniform kinematic constants + effector-decode scheme live on the motor;
    # the default KinematicMotor is the byte-identical no-op. agent_radius is the
    # per-agent collision/vision radius.
    motor::KinematicMotor = KinematicMotor()
    agent_radius::Float64 = 0.5
    # Perception geometry (which rays + how an intersection becomes an activation)
    # lives on the AbstractSensor. The default BearingSensor is the
    # byte-identical no-op (historical 62-ray fan, :binary encoding). The legacy
    # sens_agent_dist knob still selects the encoding: a non-zero value forces the
    # graded (1 - d/max_d) map — see `_resolve_encoding`.
    sensor::AbstractSensor = BEARING_DEFAULT
    seed::Int = 0
    record_inputs::Bool = true
    # Colour-tagged sensing: split the conspecific bearing bank into one selective
    # copy per colour. `colours` is an explicit per-agent 0-based assignment;
    # nothing => balanced interleaved split (0,1,...,n_colours-1,0,...). The
    # defaults (n_colours=1, colour_sensing=false) are a pure no-op.
    n_colours::Int = 1
    colour_sensing::Bool = false
    colours::Union{Nothing,Vector{Int}} = nothing
end

"""Compatibility alias for the canonical `SituatedConfig`."""
const SwarmConfig = SituatedConfig

abstract type SituatedMode end
struct CollectiveMode <: SituatedMode end
struct ForageMode <: SituatedMode end

"""
    SituatedEnvironment

Canonical mutable world for established collective and forage tasks. Geometry,
agent poses, interaction state, histories, and world RNGs live here; bodies
remain the owners of receptor encoding and physiology. Generic object-based
tasks use `ObjectWorld`.
"""
mutable struct SituatedEnvironment{M<:SituatedMode,A,R<:AbstractRNG} <: AbstractSituatedEnvironment
    mode::M
    arena::A
    config::SituatedConfig
    colours::Vector{Int}
    initial_positions::Vector{NTuple{2,Float64}}
    initial_headings::Vector{Float64}
    positions::Vector{NTuple{2,Float64}}
    headings::Vector{Float64}
    speeds::Vector{Float64}
    heading_rates::Vector{Float64}
    source_gains::Vector{Float64}
    last_signal::Vector{Float64}
    visual_coupling::Bool
    physical_coupling::Bool
    sensory_noise::Float64
    rng::R
    sens_angles_rad::Vector{Float64}
    history::Vector{Vector{NTuple{3,Float64}}}
    input_history::Vector{Vector{Vector{Float64}}}
    last_inputs::Union{Nothing,Vector{Vector{Float64}}}
    active_agents::BitVector
    last_conspecific_contacts::BitVector
    interaction_effects::Vector{Vector{Any}}
    tick::Int
end

"""Compatibility facade for direct construction of the historical torus world."""
struct TorusEnvironment{W<:SituatedEnvironment} <: AbstractTorusEnvironment
    world::W
end

"""Compatibility facade for direct construction of the historical forage world."""
struct ForageEnvironment{W<:SituatedEnvironment} <: AbstractTorusEnvironment
    world::W
end

function Base.getproperty(env::Union{TorusEnvironment,ForageEnvironment}, name::Symbol)
    name === :world && return getfield(env, :world)
    world = getfield(env, :world)
    name === :torus && return world.arena
    name === :source_position && return world.config.source_position
    return getproperty(world, name)
end

function Base.propertynames(env::Union{TorusEnvironment,ForageEnvironment}, private::Bool=false)
    return (:world, :torus, :source_position, propertynames(getfield(env, :world), private)...)
end

function Base.setproperty!(env::Union{TorusEnvironment,ForageEnvironment}, name::Symbol, value)
    name === :world && throw(ArgumentError("compatibility world reference is immutable"))
    return setproperty!(getfield(env, :world), name, value)
end

function Base.getproperty(env::SituatedEnvironment, name::Symbol)
    name === :torus && return getfield(env, :arena)
    name === :source_position && return getfield(env, :config).source_position
    return getfield(env, name)
end

n_agents(m::AbstractSituatedEnvironment) = length(m.positions)

function _environment_named_tuple(dict::Dict{Symbol,Any})
    isempty(dict) && return NamedTuple()
    keys_ = Tuple(keys(dict))
    values_ = Tuple(dict[key] for key in keys_)
    return NamedTuple{keys_}(values_)
end

function _swarm_config_with(config::SwarmConfig; kwargs...)
    values = Dict{Symbol,Any}()
    for name in fieldnames(SwarmConfig)
        values[name] = getfield(config, name)
    end
    for (key, value) in pairs(kwargs)
        values[Symbol(key)] = value
    end
    return SwarmConfig(; _environment_named_tuple(values)...)
end

function _resolve_n_lookouts(config::SwarmConfig, n_agents::Integer)
    nl = config.n_lookouts
    nl === nothing && return Int(n_agents)
    k = Int(nl)
    0 <= k <= Int(n_agents) ||
        throw(ArgumentError("n_lookouts must be in 0:n_agents (got $(k) for $(n_agents) agents)"))
    return k
end

# Per-agent colour tag (0-based). Explicit `config.colours` (one entry per agent)
# else a balanced interleaved split (agent i -> (i-1) mod n_colours), so a mixed
# start is the natural null for the segregation metric.
function _resolve_colours(config::SwarmConfig, n::Integer)
    n_ = Int(n)
    nc = Int(config.n_colours)
    nc >= 1 || throw(ArgumentError("n_colours must be >= 1 (got $(nc))"))
    explicit = config.colours
    if explicit !== nothing
        cols = Int[Int(c) for c in explicit]
        length(cols) == n_ ||
            throw(ArgumentError("config.colours must have one entry per agent (got $(length(cols)) for $(n_) agents)"))
        all(c -> 0 <= c < nc, cols) ||
            throw(ArgumentError("config.colours entries must be in 0:$(nc - 1) (n_colours=$(nc)); an out-of-range colour would be invisible to every colour bank"))
        return cols
    end
    return Int[mod(i - 1, nc) for i in 1:n_]
end

# Per-agent source_gain from the lookout mask: first k agents see the source.
function _source_gains(config::SwarmConfig, n::Integer)
    k = _resolve_n_lookouts(config, n)
    return Float64[i <= k ? Float64(config.source_gain) : 0.0 for i in 1:Int(n)]
end

function _source_position_tuple(pos)
    pos === nothing && return nothing
    return (Float64(pos[1]), Float64(pos[2]))
end

function _resolve_source_position(config::SwarmConfig, torus::Torus, rng::AbstractRNG)
    pos = _source_position_tuple(config.source_position)
    pos === nothing && return (rand(rng) * torus.size, rand(rng) * torus.size)
    return wrap(torus, pos)
end

function _validate_forage_config(config::SwarmConfig)
    isfinite(config.source_gain) && config.source_gain >= 0.0 ||
        throw(ArgumentError("source_gain must be finite and non-negative"))
    isfinite(config.capture_radius) && config.capture_radius >= 0.0 ||
        throw(ArgumentError("capture_radius must be finite and non-negative"))
    if config.signalling
        isfinite(config.signal_range) && config.signal_range > 0.0 ||
            throw(ArgumentError("signal_range must be finite and positive when signalling is enabled"))
        isfinite(config.signal_gain) && config.signal_gain >= 0.0 ||
            throw(ArgumentError("signal_gain must be finite and non-negative when signalling is enabled"))
    end
    return nothing
end

function _validate_conspecific_contact(config::SwarmConfig)
    radius = config.conspecific_contact_radius
    isempty(config.conspecific_contact_effects) && radius === nothing && return nothing
    radius === nothing && throw(ArgumentError(
        "conspecific_contact_radius is required when contact effects are configured",
    ))
    isfinite(radius) && radius >= 0.0 || throw(ArgumentError(
        "conspecific_contact_radius must be finite and non-negative",
    ))
    return nothing
end

function _empty_torus_histories(n::Integer)
    n_ = Int(n)
    history = [NTuple{3,Float64}[] for _ in 1:n_]
    input_history = [Vector{Float64}[] for _ in 1:n_]
    return history, input_history
end

function _make_situated_environment(
    mode::SituatedMode,
    arena,
    config::SwarmConfig,
    positions,
    headings,
    rng::AbstractRNG,
)
    _validate_conspecific_contact(config)
    pos = _coerce_positions(positions)
    n = length(pos)
    heads = _coerce_headings(headings, n)
    history, input_history = _empty_torus_histories(n)
    return SituatedEnvironment(
        mode,
        arena,
        config,
        _resolve_colours(config, n),
        copy(pos),
        copy(heads),
        pos,
        heads,
        zeros(Float64, n),
        zeros(Float64, n),
        _source_gains(config, n),
        zeros(Float64, n),
        Bool(config.visual_coupling),
        Bool(config.physical_coupling),
        Float64(config.sensory_noise),
        rng,
        angles_rad(config.sensor),
        history,
        input_history,
        nothing,
        trues(n),
        falses(n),
        [Any[] for _ in 1:n],
        0,
    )
end

function _sample_open_position(rng::AbstractRNG, arena::Union{Torus,WalledArena}, config::SwarmConfig, positions, min_separation)
    for _ in 1:10000
        pos = sample_position(rng, arena; radius=config.agent_radius)
        open = true
        for p in positions
            if arena_distance(arena, pos, p) < min_separation
                open = false
                break
            end
        end
        open && return pos
    end
    throw(ArgumentError("could not place non-overlapping agents in the torus"))
end

# Sample initial per-agent (position, heading). RNG draw order matches the old
# per-body sampling: an agent's open position, then its heading.
function _sample_states(config::SwarmConfig, arena::Union{Torus,WalledArena}, rng::AbstractRNG)
    Int(config.n_agents) >= 1 || throw(ArgumentError("n_agents must be at least 1"))
    positions = NTuple{2,Float64}[]
    headings = Float64[]
    min_separation = 2.0 * config.agent_radius + 0.2
    for _ in 1:config.n_agents
        pos = _sample_open_position(rng, arena, config, positions, min_separation)
        push!(positions, pos)
        push!(headings, rand(rng) * _TWO_PI)
    end
    return positions, headings
end

function _coerce_positions(positions)
    values = NTuple{2,Float64}[(Float64(p[1]), Float64(p[2])) for p in positions]
    all(position -> all(isfinite, position), values) ||
        throw(ArgumentError("agent positions must be finite"))
    return values
end

function _coerce_headings(headings, n::Integer)
    headings === nothing && return zeros(Float64, Int(n))
    heads = Float64.(collect(headings))
    length(heads) == Int(n) ||
        throw(DimensionMismatch("expected $(n) headings, got $(length(heads))"))
    all(isfinite, heads) || throw(ArgumentError("agent headings must be finite"))
    return heads
end

# --- TorusEnvironment constructors ---

function _make_torus_environment(torus::Torus, config::SwarmConfig, positions, headings, rng::AbstractRNG)
    world = _make_situated_environment(
        CollectiveMode(), torus, config, positions, headings, rng,
    )
    return TorusEnvironment(world)
end

function TorusEnvironment(config::SwarmConfig; rng::AbstractRNG=MersenneTwister(config.seed))
    torus = Torus(config.space_size)
    positions, headings = _sample_states(config, torus, rng)
    return _make_torus_environment(torus, config, positions, headings, rng)
end

# Bring-your-own-state. The narrow `NTuple{2,Float64}` element type makes stale
# body-vector callers fail loudly (no compat alias).
function TorusEnvironment(
    torus::Torus,
    positions::AbstractVector{<:NTuple{2,Float64}};
    headings=nothing,
    config::Union{Nothing,SwarmConfig}=nothing,
    rng::AbstractRNG=MersenneTwister(0),
    visual_coupling::Bool=true,
    physical_coupling::Bool=false,
    sensory_noise::Real=0.0,
    sensory_scaling::Bool=true,
    sens_agent_dist::Integer=0,
    vision_range=nothing,
    record_inputs::Bool=true,
)
    n = length(positions)
    n >= 1 || throw(ArgumentError("TorusEnvironment requires at least one position"))
    config_ =
        config === nothing ?
        SwarmConfig(
            n_agents=n,
            space_size=torus.size,
            sens_agent_dist=Int(sens_agent_dist),
            vision_range=vision_range === nothing ? nothing : Float64(vision_range),
            sensory_noise=Float64(sensory_noise),
            sensory_scaling=Bool(sensory_scaling),
            visual_coupling=Bool(visual_coupling),
            physical_coupling=Bool(physical_coupling),
            record_inputs=Bool(record_inputs),
        ) :
        config
    config_ isa SwarmConfig || throw(ArgumentError("config must be a SwarmConfig"))
    config_.n_agents == n ||
        throw(DimensionMismatch("SwarmConfig expects $(config_.n_agents) agents, got $(n)"))
    return _make_torus_environment(torus, config_, positions, headings, rng)
end

# --- ForageEnvironment constructors ---

function _make_forage_environment(
    torus::Torus,
    config::SwarmConfig,
    positions,
    headings,
    rng::AbstractRNG,
)
    world = _make_situated_environment(
        ForageMode(), torus, config, positions, headings, rng,
    )
    return ForageEnvironment(world)
end

function ForageEnvironment(config::SwarmConfig; rng::AbstractRNG=MersenneTwister(config.seed))
    _validate_forage_config(config)
    torus = Torus(config.space_size)
    positions, headings = _sample_states(config, torus, rng)
    source_pos = _resolve_source_position(config, torus, rng)
    config_ = _swarm_config_with(config; source_position=source_pos)
    return _make_forage_environment(torus, config_, positions, headings, rng)
end

function ForageEnvironment(
    torus::Torus,
    positions::AbstractVector{<:NTuple{2,Float64}};
    headings=nothing,
    config::Union{Nothing,SwarmConfig}=nothing,
    rng::AbstractRNG=MersenneTwister(0),
    visual_coupling::Bool=true,
    physical_coupling::Bool=false,
    sensory_noise::Real=0.0,
    sensory_scaling::Bool=true,
    sens_agent_dist::Integer=0,
    vision_range=nothing,
    source_vision_range=nothing,
    source_position=nothing,
    source_gain::Real=1.0,
    signalling::Bool=false,
    signal_range::Real=3.0,
    signal_gain::Real=1.0,
    conspecific_vision::Bool=true,
    capture_radius::Real=1.0,
    record_inputs::Bool=true,
)
    n = length(positions)
    n >= 1 || throw(ArgumentError("ForageEnvironment requires at least one position"))
    config_ =
        config === nothing ?
        SwarmConfig(
            n_agents=n,
            space_size=torus.size,
            sens_agent_dist=Int(sens_agent_dist),
            vision_range=vision_range === nothing ? nothing : Float64(vision_range),
            source_vision_range=source_vision_range === nothing ? nothing : Float64(source_vision_range),
            sensory_noise=Float64(sensory_noise),
            sensory_scaling=Bool(sensory_scaling),
            visual_coupling=Bool(visual_coupling),
            physical_coupling=Bool(physical_coupling),
            conspecific_vision=Bool(conspecific_vision),
            source_position=_source_position_tuple(source_position),
            source_gain=Float64(source_gain),
            signalling=Bool(signalling),
            signal_range=Float64(signal_range),
            signal_gain=Float64(signal_gain),
            capture_radius=Float64(capture_radius),
            record_inputs=Bool(record_inputs),
        ) :
        config
    config_ isa SwarmConfig || throw(ArgumentError("config must be a SwarmConfig"))
    config_.n_agents == n ||
        throw(DimensionMismatch("SwarmConfig expects $(config_.n_agents) agents, got $(n)"))
    _validate_forage_config(config_)
    source_pos = _resolve_source_position(config_, torus, rng)
    config_ = _swarm_config_with(config_; source_position=source_pos)
    return _make_forage_environment(torus, config_, positions, headings, rng)
end

"""Concrete setup callable for the registered periodic collective world."""
struct TorusTaskSetup end

"""Concrete setup callable for the registered source-foraging world."""
struct ForageTaskSetup end

is_multiagent(setup) = false
is_multiagent(::TaskWorldSetup) = false
is_multiagent(::TorusTaskSetup) = true
is_multiagent(::ForageTaskSetup) = true

function _swarm_task_setup(
    forage::Bool;
    seed=0,
    rng=nothing,
    body=nothing,
    n_agents::Integer=8,
    n_nodes::Integer=100,
    kwargs...,
)
    if body !== nothing
        throw(ArgumentError(
            "torus and forage construct situated embodiments from task options; got body=$(body)",
        ))
    end

    options = Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(kwargs))
    options[:n_agents] = Int(n_agents)
    options[:n_nodes] = Int(n_nodes)
    options[:seed] = seed === nothing ? 0 : Int(seed)
    keys_ = Tuple(keys(options))
    values_ = Tuple(options[key] for key in keys_)
    config = SwarmConfig(; NamedTuple{keys_}(values_)...)
    env_rng = rng === nothing ? _task_setup_rng(seed) : rng
    facade = forage ? ForageEnvironment(config; rng=env_rng) : TorusEnvironment(config; rng=env_rng)
    environment = facade.world

    layout = SituatedSensorLayout(
        sensory_scaling=config.sensory_scaling,
        source_bank=forage,
        source_gain=config.source_gain,
        signalling=forage && config.signalling,
        norm_mode=config.norm_mode,
        norm_sigma=config.norm_sigma,
        conspecific_gain=config.conspecific_gain,
        n_colours=config.n_colours,
        colour_sensing=config.colour_sensing,
        sensor=config.sensor,
    )
    bodies = [
        situated_embodiment(layout, config.motor; radius=config.agent_radius)
        for _ in 1:config.n_agents
    ]
    return TaskSetup(environment, bodies)
end

(::TorusTaskSetup)(; kwargs...) = _swarm_task_setup(false; kwargs...)
(::ForageTaskSetup)(; kwargs...) = _swarm_task_setup(true; kwargs...)

const TORUS_TASK = TaskSpec(
    :torus,
    TorusTaskSetup();
    env_type=SituatedEnvironment{CollectiveMode},
    n_receptors=DEFAULT_BEARING_BANK_RECEPTORS,
    n_effectors=3,
    default_ticks=1000,
    default_window=1000,
    score_key=nothing,
)

const FORAGE_TASK = TaskSpec(
    :forage,
    ForageTaskSetup();
    env_type=SituatedEnvironment{ForageMode},
    n_receptors=DEFAULT_FORAGE_RECEPTORS,
    n_effectors=3,
    default_ticks=1000,
    default_window=1000,
    floor=FORAGE_FLOOR_ANCHOR,
    ceiling=FORAGE_CEILING_ANCHOR,
    score_key=:forage_score,
)

function _require_situated_width(m::AbstractSituatedEnvironment, bodies)
    n = length(m.positions)
    length(bodies) == n ||
        throw(DimensionMismatch("environment has $(n) agents, got $(length(bodies))"))
    length(m.history) == n ||
        throw(DimensionMismatch("environment history has width $(length(m.history)), expected $(n)"))
    return nothing
end

# Effective sense-cone encoding. The canonical source is `config.sensor.encoding`;
# the legacy `sens_agent_dist` knob still works — a non-zero value forces :graded
# (its historical meaning), mirroring how `_resolve_norm_mode` honours the legacy
# `sensory_scaling` flag. The default (sens_agent_dist=0, default sensor) is :binary.
function _resolve_encoding(config::SwarmConfig)
    config.sens_agent_dist != 0 && return :graded
    return encoding(config.sensor)
end

function _conspecific_sensors(m::AbstractSituatedEnvironment, i::Integer)
    nb = length(m.sens_angles_rad)
    if !m.active_agents[Int(i)]
        return m.config.colour_sensing ?
            zeros(Float64, max(1, Int(m.config.n_colours)) * nb) :
            zeros(Float64, nb)
    end
    if m.visual_coupling && m.config.conspecific_vision
        enc = _resolve_encoding(m.config)
        if m.config.colour_sensing
            return sense_agents_coloured(
                m.positions[i],
                m.headings[i],
                m.positions,
                m.colours,
                Int(i),
                m.config.agent_radius,
                m.torus,
                m.sens_angles_rad,
                enc,
                m.sensory_noise,
                m.rng;
                n_colours=m.config.n_colours,
                vision_range=m.config.vision_range,
                active_mask=m.active_agents,
            )
        end
        return sense_agents(
            m.positions[i],
            m.headings[i],
            m.positions,
            Int(i),
            m.config.agent_radius,
            m.torus,
            m.sens_angles_rad,
            enc,
            m.sensory_noise,
            m.rng;
            vision_range=m.config.vision_range,
            active_mask=m.active_agents,
        )
    end
    # Blind: zeros wide enough for the (possibly coloured) conspecific layout.
    return m.config.colour_sensing ? zeros(Float64, max(1, Int(m.config.n_colours)) * nb) : zeros(Float64, nb)
end

function _collective_percepts(m::SituatedEnvironment, bodies)
    _require_situated_width(m, bodies)
    _sync_active_agents!(m, bodies)
    n = length(m.positions)
    inputs = Vector{NamedTuple{(:conspecific,),Tuple{Vector{Float64}}}}(undef, n)
    @inbounds for i in 1:n
        inputs[i] = (conspecific=_conspecific_sensors(m, i),)
    end
    return inputs
end

sample!(m::SituatedEnvironment{CollectiveMode}, bodies) = _collective_percepts(m, bodies)

function _acoustic_percept(m::SituatedEnvironment, i::Int)
    m.config.signalling || return 0.0
    intensity = 0.0
    pos_i = m.positions[i]
    @inbounds for j in eachindex(m.positions)
        (i == j || !m.active_agents[j]) && continue
        d = arena_distance(m.arena, pos_i, m.positions[j])
        intensity += m.last_signal[j] * exp(-d / Float64(m.config.signal_range))
    end
    return Float64(m.config.signal_gain) * clamp(intensity, 0.0, 1.0)
end

function sample!(m::SituatedEnvironment{ForageMode}, bodies)
    _require_situated_width(m, bodies)
    _sync_active_agents!(m, bodies)
    n = length(m.positions)
    T = NamedTuple{(:conspecific,:source,:source_gain,:acoustic),Tuple{Vector{Float64},Vector{Float64},Float64,Float64}}
    inputs = Vector{T}(undef, n)

    @inbounds for i in 1:n
        conspecific = _conspecific_sensors(m, i)
        source = m.active_agents[i] ? sense_source(
            m.positions[i],
            m.headings[i],
            m.source_position,
            m.arena,
            m.sens_angles_rad,
            _resolve_encoding(m.config),
            m.sensory_noise,
            m.rng;
            vision_range=m.config.source_vision_range === nothing ? m.config.vision_range : m.config.source_vision_range,
            source_radius=m.config.capture_radius,
        ) : zeros(Float64, length(m.sens_angles_rad))
        inputs[i] = (
            conspecific=conspecific,
            source=source,
            source_gain=m.source_gains[i],
            acoustic=_acoustic_percept(m, i),
        )
    end
    return inputs
end

function _compat_observe(m::Union{TorusEnvironment,ForageEnvironment}, bodies)
    raw = sample!(m.world, bodies)
    config = m.config
    layout = SituatedSensorLayout(
        sensory_scaling=config.sensory_scaling,
        source_bank=m isa ForageEnvironment,
        source_gain=config.source_gain,
        signalling=m isa ForageEnvironment && config.signalling,
        norm_mode=config.norm_mode,
        norm_sigma=config.norm_sigma,
        conspecific_gain=config.conspecific_gain,
        n_colours=config.n_colours,
        colour_sensing=config.colour_sensing,
        sensor=config.sensor,
    )
    encoder = SituatedEncoder(layout)
    inputs = [encode!(encoder, raw[i]) for i in eachindex(raw)]
    remember_receptors!(m.world, inputs)
    return inputs
end

sample!(m::TorusEnvironment, bodies) = _compat_observe(m, bodies)
sample!(m::ForageEnvironment, bodies) = _compat_observe(m, bodies)

function remember_receptors!(m::SituatedEnvironment, inputs)
    m.last_inputs = [Vector{Float64}(input) for input in inputs]
    return nothing
end

remember_receptors!(m::Union{TorusEnvironment,ForageEnvironment}, inputs) =
    remember_receptors!(m.world, inputs)

# Set (speed, heading) from a velocity vector after a collision.
function _velocity_to_state(velocity::NTuple{2,Float64}, heading::Float64)
    speed = hypot(velocity[1], velocity[2])
    new_heading = speed > 1e-12 ? mod(atan(velocity[2], velocity[1]), _TWO_PI) : heading
    return Float64(speed), new_heading
end

function _resolve_collisions!(m::AbstractSituatedEnvironment)
    m.physical_coupling || return nothing

    radius = Float64(m.config.agent_radius)
    min_d = 2.0 * radius
    n = length(m.positions)

    for i in 1:n
        m.active_agents[i] || continue
        for j in (i + 1):n
            m.active_agents[j] || continue
            dx, dy = arena_delta(m.arena, m.positions[i], m.positions[j])
            dist = hypot(dx, dy)
            dist >= min_d && continue

            normal =
                dist <= 1e-12 ?
                (1.0, 0.0) :
                (Float64(dx / dist), Float64(dy / dist))

            overlap = min_d - dist
            m.positions[i] = first(arena_position(
                m.arena,
                m.positions[i][1] - 0.5 * overlap * normal[1],
                m.positions[i][2] - 0.5 * overlap * normal[2],
                radius,
            ))
            m.positions[j] = first(arena_position(
                m.arena,
                m.positions[j][1] + 0.5 * overlap * normal[1],
                m.positions[j][2] + 0.5 * overlap * normal[2],
                radius,
            ))

            va_hat = velocity_hat(m.headings[i])
            vb_hat = velocity_hat(m.headings[j])
            va = (m.speeds[i] * va_hat[1], m.speeds[i] * va_hat[2])
            vb = (m.speeds[j] * vb_hat[1], m.speeds[j] * vb_hat[2])
            va_n = va[1] * normal[1] + va[2] * normal[2]
            vb_n = vb[1] * normal[1] + vb[2] * normal[2]
            va_new = (
                va[1] + (vb_n - va_n) * normal[1],
                va[2] + (vb_n - va_n) * normal[2],
            )
            vb_new = (
                vb[1] + (va_n - vb_n) * normal[1],
                vb[2] + (va_n - vb_n) * normal[2],
            )
            m.speeds[i], m.headings[i] = _velocity_to_state(va_new, m.headings[i])
            m.speeds[j], m.headings[j] = _velocity_to_state(vb_new, m.headings[j])
        end
    end

    return nothing
end

_capture_signals!(::AbstractSituatedEnvironment, Es) = nothing

function _capture_signals!(m::ForageEnvironment, Es)
    m.config.signalling || return nothing
    @inbounds for i in eachindex(Es)
        values = Es[i] isa DirectCommand ? command_values(Es[i]) : Es[i]
        m.last_signal[i] = emitted_signal(values)
    end
    return nothing
end

function _capture_signals!(m::SituatedEnvironment{ForageMode}, Es)
    m.config.signalling || return nothing
    @inbounds for i in eachindex(Es)
        values = Es[i] isa DirectCommand ? command_values(Es[i]) : Es[i]
        m.last_signal[i] = m.active_agents[i] ? emitted_signal(values) : 0.0
    end
    return nothing
end

function _integrate_situated(motor_, pos, heading, speed, heading_rate, e, arena::Torus, radius)
    return integrate!(motor_, pos, heading, speed, heading_rate, e, arena)
end

function _integrate_situated(motor_, pos, heading, speed, heading_rate, e, arena::WalledArena, radius)
    return integrate!(
        motor_, pos, heading, speed, heading_rate, e, arena; radius=radius,
    )
end

_resolve_object_interactions!(::AbstractSituatedEnvironment, bodies) = nothing

function _resolve_conspecific_interactions!(m::AbstractSituatedEnvironment, bodies, effects)
    fill!(m.last_conspecific_contacts, false)
    radius = m.config.conspecific_contact_radius
    radius === nothing && return effects

    resolved = if effects === nothing
        @inbounds for agent_effects in m.interaction_effects
            empty!(agent_effects)
        end
        m.interaction_effects
    else
        effects
    end
    radius_ = Float64(radius)
    @inbounds for i in eachindex(bodies)
        m.active_agents[i] || continue
        for j in (i + 1):length(bodies)
            m.active_agents[j] || continue
            arena_distance(m.arena, m.positions[i], m.positions[j]) <= radius_ || continue
            m.last_conspecific_contacts[i] = true
            m.last_conspecific_contacts[j] = true
        end
    end
    contact_effects = m.config.conspecific_contact_effects
    isempty(contact_effects) && return resolved
    @inbounds for i in eachindex(bodies)
        m.last_conspecific_contacts[i] || continue
        append!(resolved[i], contact_effects)
    end
    return resolved
end

function _sync_active_agents!(m::AbstractSituatedEnvironment, bodies)
    @inbounds for i in eachindex(bodies)
        m.active_agents[i] = alive(bodies[i])
    end
    return nothing
end

function apply_commands!(m::AbstractSituatedEnvironment, bodies, Es)
    _require_situated_width(m, bodies)
    n = length(m.positions)
    length(Es) == n ||
        throw(DimensionMismatch("expected one effector vector per agent"))
    _sync_active_agents!(m, bodies)

    @inbounds for i in 1:n
        m.active_agents[i] || continue
        command = Es[i] isa DirectCommand ? command_values(Es[i]) : Es[i]
        new_pos, new_heading, new_speed, new_hr = _integrate_situated(
            readout_policy(bodies[i]),
            m.positions[i],
            m.headings[i],
            m.speeds[i],
            m.heading_rates[i],
            command,
            m.arena,
            m.config.agent_radius,
        )
        m.positions[i] = new_pos
        m.headings[i] = new_heading
        m.speeds[i] = new_speed
        m.heading_rates[i] = new_hr
    end

    _capture_signals!(m, Es)
    _resolve_collisions!(m)

    @inbounds for i in 1:n
        push!(m.history[i], (m.positions[i][1], m.positions[i][2], m.headings[i]))
    end

    inputs = m.last_inputs
    if m.config.record_inputs && inputs !== nothing
        @inbounds for i in eachindex(inputs)
            push!(m.input_history[i], copy(inputs[i]))
        end
    end

    effects = _resolve_object_interactions!(m, bodies)
    effects = _resolve_conspecific_interactions!(m, bodies, effects)
    m.tick += 1
    return effects
end

function _default_situated_window(m::AbstractSituatedEnvironment)
    isempty(m.history) && return 0
    return minimum(length, m.history)
end

conspecific_contacts(m::AbstractSituatedEnvironment) =
    copy(m.last_conspecific_contacts)
