using Random

abstract type AbstractTorusMedium <: Medium end

"""
    TaskMedium(env)

Single-agent medium wrapper around one task `Environment`.
"""
struct TaskMedium{E<:Environment} <: Medium
    env::E
end

function _require_single_body(bodies)
    length(bodies) == 1 ||
        throw(ArgumentError("TaskMedium wraps one Environment and requires exactly one body"))
    return nothing
end

function observe(m::TaskMedium, bodies)
    _require_single_body(bodies)
    return [sense(m.env)]
end

function actuate!(m::TaskMedium, bodies, Es)
    _require_single_body(bodies)
    length(Es) == 1 ||
        throw(ArgumentError("TaskMedium requires exactly one effector command"))
    return step!(m.env, Es[1])
end

medium_metrics(m::TaskMedium, window::Integer=default_window(m.env)) =
    metrics(m.env, Int(window))

Base.@kwdef struct SwarmConfig
    n_agents::Int
    space_size::Float64 = 15.0
    n_nodes::Int = 250
    link_p::Float64 = 0.1
    sens_agent_dist::Int = 0
    vision_range::Union{Nothing,Float64} = nothing
    sensory_noise::Float64 = 0.1
    membrane_noise::Float64 = 0.0
    noise_gain::Float64 = 0.0
    sensory_scaling::Bool = true
    visual_coupling::Bool = true
    physical_coupling::Bool = false
    conspecific_vision::Bool = true
    source_position::Union{Nothing,NTuple{2,Float64}} = nothing
    source_gain::Float64 = 1.0
    capture_radius::Float64 = 1.0
    ven::VENParams = VENParams()
    node_params::Any = nothing
    seed::Int = 0
    record_inputs::Bool = true
    node_kind::String = "standard"
    n_dendrites::Int = 4
    soma_drive::Float64 = 0.0
    dend_drive::Float64 = 0.0
end

mutable struct TorusMedium{R<:AbstractRNG} <: AbstractTorusMedium
    torus::Torus
    config::SwarmConfig
    bodies::Vector{VENBody}
    visual_coupling::Bool
    physical_coupling::Bool
    sensory_noise::Float64
    rng::R
    sens_angles_rad::Vector{Float64}
    history::Vector{Vector{NTuple{3,Float64}}}
    input_history::Vector{Vector{Vector{Float64}}}
    last_inputs::Union{Nothing,Vector{Vector{Float64}}}
end

mutable struct ForageMedium{R<:AbstractRNG} <: AbstractTorusMedium
    torus::Torus
    config::SwarmConfig
    source_position::NTuple{2,Float64}
    bodies::Vector{VENBody}
    visual_coupling::Bool
    physical_coupling::Bool
    sensory_noise::Float64
    rng::R
    sens_angles_rad::Vector{Float64}
    history::Vector{Vector{NTuple{3,Float64}}}
    input_history::Vector{Vector{Vector{Float64}}}
    last_inputs::Union{Nothing,Vector{Vector{Float64}}}
end

function _as_ven_body_vector(bodies::AbstractVector)
    out = Vector{VENBody}(undef, length(bodies))
    @inbounds for i in eachindex(bodies)
        bodies[i] isa VENBody ||
            throw(ArgumentError("TorusMedium requires VENBody bodies"))
        out[i] = bodies[i]
    end
    return out
end

function _medium_named_tuple(dict::Dict{Symbol,Any})
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
    return SwarmConfig(; _medium_named_tuple(values)...)
end

function _configure_ven_bodies!(bodies::Vector{VENBody}, config::SwarmConfig; source_bank::Bool=false)
    @inbounds for body in bodies
        body.sensory_scaling = Bool(config.sensory_scaling)
        body.source_bank = Bool(source_bank)
        body.source_gain = Float64(config.source_gain)
    end
    return bodies
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
    return nothing
end

function _empty_torus_histories(n::Integer)
    n_ = Int(n)
    history = [NTuple{3,Float64}[] for _ in 1:n_]
    input_history = [Vector{Float64}[] for _ in 1:n_]
    return history, input_history
end

function _sample_open_position(rng::AbstractRNG, torus::Torus, config::SwarmConfig, bodies, min_separation)
    for _ in 1:10000
        pos = (rand(rng) * config.space_size, rand(rng) * config.space_size)
        open = true
        for body in bodies
            if tdistance(torus, pos, body.pos) < min_separation
                open = false
                break
            end
        end
        open && return pos
    end
    throw(ArgumentError("could not place non-overlapping agents in the torus"))
end

function _sample_bodies(config::SwarmConfig, torus::Torus, rng::AbstractRNG; source_bank::Bool=false)
    Int(config.n_agents) >= 1 || throw(ArgumentError("n_agents must be at least 1"))
    bodies = VENBody[]
    min_separation = 2.0 * config.ven.agent_radius + 0.2

    for _ in 1:config.n_agents
        pos = _sample_open_position(rng, torus, config, bodies, min_separation)
        heading = rand(rng) * _TWO_PI
        push!(
            bodies,
            VENBody(
                pos,
                heading;
                params=config.ven,
                sensory_scaling=config.sensory_scaling,
                source_bank=source_bank,
                source_gain=config.source_gain,
            ),
        )
    end

    return bodies
end

function TorusMedium(
    torus::Torus,
    bodies::AbstractVector;
    visual_coupling::Bool=true,
    physical_coupling::Bool=false,
    sensory_noise::Real=0.0,
    sensory_scaling::Bool=true,
    sens_agent_dist::Integer=0,
    vision_range=nothing,
    record_inputs::Bool=true,
    rng::AbstractRNG=MersenneTwister(0),
    config=nothing,
)
    body_vec = _as_ven_body_vector(bodies)
    !isempty(body_vec) || throw(ArgumentError("TorusMedium requires at least one body"))

    config_ =
        config === nothing ?
        SwarmConfig(
            n_agents=length(body_vec),
            space_size=torus.size,
            sens_agent_dist=Int(sens_agent_dist),
            vision_range=vision_range === nothing ? nothing : Float64(vision_range),
            sensory_noise=Float64(sensory_noise),
            sensory_scaling=Bool(sensory_scaling),
            visual_coupling=Bool(visual_coupling),
            physical_coupling=Bool(physical_coupling),
            ven=body_vec[1].params,
            record_inputs=Bool(record_inputs),
        ) :
        config

    config_ isa SwarmConfig || throw(ArgumentError("config must be a SwarmConfig"))
    config_.n_agents == length(body_vec) ||
        throw(DimensionMismatch("SwarmConfig expects $(config_.n_agents) bodies, got $(length(body_vec))"))

    _configure_ven_bodies!(body_vec, config_; source_bank=false)
    history, input_history = _empty_torus_histories(length(body_vec))

    return TorusMedium(
        torus,
        config_,
        body_vec,
        Bool(config_.visual_coupling),
        Bool(config_.physical_coupling),
        Float64(config_.sensory_noise),
        rng,
        copy(SENS_ANGLES_RAD),
        history,
        input_history,
        nothing,
    )
end

function TorusMedium(config::SwarmConfig; bodies=nothing, rng::AbstractRNG=MersenneTwister(config.seed))
    torus = Torus(config.space_size)
    body_vec = bodies === nothing ?
        _sample_bodies(config, torus, rng; source_bank=false) :
        _as_ven_body_vector(bodies)
    return TorusMedium(torus, body_vec; config=config, rng=rng)
end

function ForageMedium(
    torus::Torus,
    bodies::AbstractVector;
    visual_coupling::Bool=true,
    physical_coupling::Bool=false,
    sensory_noise::Real=0.0,
    sensory_scaling::Bool=true,
    sens_agent_dist::Integer=0,
    vision_range=nothing,
    source_position=nothing,
    source_gain::Real=1.0,
    conspecific_vision::Bool=true,
    capture_radius::Real=1.0,
    record_inputs::Bool=true,
    rng::AbstractRNG=MersenneTwister(0),
    config=nothing,
)
    body_vec = _as_ven_body_vector(bodies)
    !isempty(body_vec) || throw(ArgumentError("ForageMedium requires at least one body"))

    config_ =
        config === nothing ?
        SwarmConfig(
            n_agents=length(body_vec),
            space_size=torus.size,
            sens_agent_dist=Int(sens_agent_dist),
            vision_range=vision_range === nothing ? nothing : Float64(vision_range),
            sensory_noise=Float64(sensory_noise),
            sensory_scaling=Bool(sensory_scaling),
            visual_coupling=Bool(visual_coupling),
            physical_coupling=Bool(physical_coupling),
            conspecific_vision=Bool(conspecific_vision),
            source_position=_source_position_tuple(source_position),
            source_gain=Float64(source_gain),
            capture_radius=Float64(capture_radius),
            ven=body_vec[1].params,
            record_inputs=Bool(record_inputs),
        ) :
        config

    config_ isa SwarmConfig || throw(ArgumentError("config must be a SwarmConfig"))
    config_.n_agents == length(body_vec) ||
        throw(DimensionMismatch("SwarmConfig expects $(config_.n_agents) bodies, got $(length(body_vec))"))
    _validate_forage_config(config_)

    source_pos = _resolve_source_position(config_, torus, rng)
    config_ = _swarm_config_with(config_; source_position=source_pos)
    _configure_ven_bodies!(body_vec, config_; source_bank=true)
    history, input_history = _empty_torus_histories(length(body_vec))

    return ForageMedium(
        torus,
        config_,
        source_pos,
        body_vec,
        Bool(config_.visual_coupling),
        Bool(config_.physical_coupling),
        Float64(config_.sensory_noise),
        rng,
        copy(SENS_ANGLES_RAD),
        history,
        input_history,
        nothing,
    )
end

function ForageMedium(config::SwarmConfig; bodies=nothing, rng::AbstractRNG=MersenneTwister(config.seed))
    torus = Torus(config.space_size)
    body_vec = bodies === nothing ?
        _sample_bodies(config, torus, rng; source_bank=true) :
        _as_ven_body_vector(bodies)
    return ForageMedium(torus, body_vec; config=config, rng=rng)
end

function _require_torus_width(m::AbstractTorusMedium, bodies)
    length(bodies) == length(m.bodies) ||
        throw(DimensionMismatch("TorusMedium has $(length(m.bodies)) bodies, got $(length(bodies))"))
    length(m.history) == length(bodies) ||
        throw(DimensionMismatch("TorusMedium history has width $(length(m.history)), got $(length(bodies))"))
    return nothing
end

function _conspecific_sensors(m::AbstractTorusMedium, body_vec::Vector{VENBody}, i::Integer)
    if m.visual_coupling && m.config.conspecific_vision
        others = VENBody[body_vec[j] for j in eachindex(body_vec) if j != i]
        return sense_agents(
            body_vec[i],
            others,
            m.torus,
            body_vec[i].params,
            m.sens_angles_rad,
            m.config.sens_agent_dist,
            m.sensory_noise,
            m.rng;
            vision_range=m.config.vision_range,
        )
    end

    return zeros(Float64, length(m.sens_angles_rad))
end

function observe(m::TorusMedium, bodies)
    body_vec = _as_ven_body_vector(bodies)
    _require_torus_width(m, body_vec)

    percepts = Vector{Vector{Float64}}(undef, length(body_vec))
    inputs = Vector{Vector{Float64}}(undef, length(body_vec))

    @inbounds for i in eachindex(body_vec)
        sens = _conspecific_sensors(m, body_vec, i)
        percepts[i] = sens
        inputs[i] = receptors(body_vec[i], sens)
    end

    m.last_inputs = inputs
    return percepts
end

function observe(m::ForageMedium, bodies)
    body_vec = _as_ven_body_vector(bodies)
    _require_torus_width(m, body_vec)

    percepts = Vector{Vector{Float64}}(undef, length(body_vec))
    inputs = Vector{Vector{Float64}}(undef, length(body_vec))

    @inbounds for i in eachindex(body_vec)
        conspecific = _conspecific_sensors(m, body_vec, i)
        source = sense_source(
            body_vec[i],
            m.source_position,
            m.torus,
            body_vec[i].params,
            m.sens_angles_rad,
            m.config.sens_agent_dist,
            m.sensory_noise,
            m.rng;
            vision_range=m.config.vision_range,
            source_radius=m.config.capture_radius,
        )

        percept = Vector{Float64}(undef, 2 * VEN_BEARING_SENSOR_COUNT)
        copyto!(@view(percept[1:VEN_BEARING_SENSOR_COUNT]), conspecific)
        copyto!(@view(percept[(VEN_BEARING_SENSOR_COUNT + 1):(2 * VEN_BEARING_SENSOR_COUNT)]), source)
        percepts[i] = percept
        inputs[i] = receptors(body_vec[i], percept)
    end

    m.last_inputs = inputs
    return percepts
end

function _apply_velocity!(body::VENBody, velocity::NTuple{2,Float64})
    speed = hypot(velocity[1], velocity[2])
    body.speed = Float64(speed)
    if speed > 1e-12
        body.heading = mod(atan(velocity[2], velocity[1]), _TWO_PI)
    end
    return body
end

function _resolve_collisions!(m::AbstractTorusMedium, bodies::Vector{VENBody})
    m.physical_coupling || return nothing
    m.config.conspecific_vision || return nothing

    radius = Float64(m.config.ven.agent_radius)
    min_d = 2.0 * radius

    for i in eachindex(bodies)
        for j in (i + 1):length(bodies)
            a = bodies[i]
            b = bodies[j]
            dx, dy = tdelta(m.torus, a.pos, b.pos)
            dist = hypot(dx, dy)
            dist >= min_d && continue

            normal =
                dist <= 1e-12 ?
                (1.0, 0.0) :
                (Float64(dx / dist), Float64(dy / dist))

            overlap = min_d - dist
            a.pos = wrap(
                m.torus,
                a.pos[1] - 0.5 * overlap * normal[1],
                a.pos[2] - 0.5 * overlap * normal[2],
            )
            b.pos = wrap(
                m.torus,
                b.pos[1] + 0.5 * overlap * normal[1],
                b.pos[2] + 0.5 * overlap * normal[2],
            )

            va_hat = velocity_hat(a)
            vb_hat = velocity_hat(b)
            va = (a.speed * va_hat[1], a.speed * va_hat[2])
            vb = (b.speed * vb_hat[1], b.speed * vb_hat[2])
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
            _apply_velocity!(a, va_new)
            _apply_velocity!(b, vb_new)
        end
    end

    return nothing
end

function actuate!(m::AbstractTorusMedium, bodies, Es)
    body_vec = _as_ven_body_vector(bodies)
    _require_torus_width(m, body_vec)
    length(Es) == length(body_vec) ||
        throw(DimensionMismatch("expected one effector vector per body"))

    @inbounds for i in eachindex(body_vec)
        motor(body_vec[i], Es[i], m.torus)
    end

    _resolve_collisions!(m, body_vec)

    @inbounds for i in eachindex(body_vec)
        body = body_vec[i]
        push!(m.history[i], (body.pos[1], body.pos[2], body.heading))
    end

    inputs = m.last_inputs
    if m.config.record_inputs && inputs !== nothing
        @inbounds for i in eachindex(inputs)
            push!(m.input_history[i], copy(inputs[i]))
        end
    end

    return nothing
end

function _default_torus_window(m::AbstractTorusMedium)
    isempty(m.history) && return 0
    return minimum(length, m.history)
end

medium_metrics(m::TorusMedium, window::Integer=_default_torus_window(m)) =
    swarm_metrics(m, Int(window))

medium_metrics(m::ForageMedium, window::Integer=_default_torus_window(m)) =
    forage_metrics(m, Int(window))
