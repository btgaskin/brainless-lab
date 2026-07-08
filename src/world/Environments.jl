using Random

abstract type AbstractTorusEnvironment <: Environment end

"""
    TaskEnvironment(world)

Single-agent environment adapter around one `TaskWorld`.
"""
struct TaskEnvironment{W<:TaskWorld} <: Environment
    world::W
end

function _require_single_body(bodies)
    length(bodies) == 1 ||
        throw(ArgumentError("TaskEnvironment wraps one TaskWorld and requires exactly one body"))
    return nothing
end

function observe(m::TaskEnvironment, bodies)
    _require_single_body(bodies)
    return [sense(m.world)]
end

function actuate!(m::TaskEnvironment, bodies, Es)
    _require_single_body(bodies)
    length(Es) == 1 ||
        throw(ArgumentError("TaskEnvironment requires exactly one effector command"))
    return step!(m.world, Es[1])
end

environment_metrics(m::TaskEnvironment, window::Integer=default_window(m.world)) =
    metrics(m.world, Int(window))

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
    ven::VENParams = VENParams()
    node_params::Any = nothing
    seed::Int = 0
    record_inputs::Bool = true
    node_kind::String = "standard"
    n_dendrites::Int = 4
    soma_drive::Float64 = 0.0
    dend_drive::Float64 = 0.0
end

# Per-agent physical state lives on the environment as index-addressed arrays
# (positions/headings/speeds/heading_rates), the way WallEnv owns env.box. Agents
# carry a shared, stateless PassthroughBody{VENMorphology}.
mutable struct TorusEnvironment{R<:AbstractRNG} <: AbstractTorusEnvironment
    torus::Torus
    config::SwarmConfig
    positions::Vector{NTuple{2,Float64}}
    headings::Vector{Float64}
    speeds::Vector{Float64}
    heading_rates::Vector{Float64}
    visual_coupling::Bool
    physical_coupling::Bool
    sensory_noise::Float64
    rng::R
    sens_angles_rad::Vector{Float64}
    history::Vector{Vector{NTuple{3,Float64}}}
    input_history::Vector{Vector{Vector{Float64}}}
    last_inputs::Union{Nothing,Vector{Vector{Float64}}}
end

mutable struct ForageEnvironment{R<:AbstractRNG} <: AbstractTorusEnvironment
    torus::Torus
    config::SwarmConfig
    source_position::NTuple{2,Float64}
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
end

n_agents(m::AbstractTorusEnvironment) = length(m.positions)

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

function _empty_torus_histories(n::Integer)
    n_ = Int(n)
    history = [NTuple{3,Float64}[] for _ in 1:n_]
    input_history = [Vector{Float64}[] for _ in 1:n_]
    return history, input_history
end

function _sample_open_position(rng::AbstractRNG, torus::Torus, config::SwarmConfig, positions, min_separation)
    for _ in 1:10000
        pos = (rand(rng) * config.space_size, rand(rng) * config.space_size)
        open = true
        for p in positions
            if tdistance(torus, pos, p) < min_separation
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
function _sample_states(config::SwarmConfig, torus::Torus, rng::AbstractRNG)
    Int(config.n_agents) >= 1 || throw(ArgumentError("n_agents must be at least 1"))
    positions = NTuple{2,Float64}[]
    headings = Float64[]
    min_separation = 2.0 * config.ven.agent_radius + 0.2
    for _ in 1:config.n_agents
        pos = _sample_open_position(rng, torus, config, positions, min_separation)
        push!(positions, pos)
        push!(headings, rand(rng) * _TWO_PI)
    end
    return positions, headings
end

function _coerce_positions(positions)
    return NTuple{2,Float64}[(Float64(p[1]), Float64(p[2])) for p in positions]
end

function _coerce_headings(headings, n::Integer)
    headings === nothing && return zeros(Float64, Int(n))
    heads = Float64.(collect(headings))
    length(heads) == Int(n) ||
        throw(DimensionMismatch("expected $(n) headings, got $(length(heads))"))
    return heads
end

# --- TorusEnvironment constructors ---

function _make_torus_environment(torus::Torus, config::SwarmConfig, positions, headings, rng::AbstractRNG)
    pos = _coerce_positions(positions)
    n = length(pos)
    heads = _coerce_headings(headings, n)
    history, input_history = _empty_torus_histories(n)
    return TorusEnvironment(
        torus,
        config,
        pos,
        heads,
        zeros(Float64, n),
        zeros(Float64, n),
        Bool(config.visual_coupling),
        Bool(config.physical_coupling),
        Float64(config.sensory_noise),
        rng,
        copy(SENS_ANGLES_RAD),
        history,
        input_history,
        nothing,
    )
end

function TorusEnvironment(config::SwarmConfig; rng::AbstractRNG=MersenneTwister(config.seed))
    torus = Torus(config.space_size)
    positions, headings = _sample_states(config, torus, rng)
    return _make_torus_environment(torus, config, positions, headings, rng)
end

# Bring-your-own-state. The narrow `NTuple{2,Float64}` element type makes a stale
# `Vector{VENBody}` caller fail loudly (no compat alias).
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

function _make_forage_environment(torus::Torus, config::SwarmConfig, positions, headings, source_pos::NTuple{2,Float64}, rng::AbstractRNG)
    pos = _coerce_positions(positions)
    n = length(pos)
    heads = _coerce_headings(headings, n)
    source_gains = _source_gains(config, n)
    history, input_history = _empty_torus_histories(n)
    return ForageEnvironment(
        torus,
        config,
        source_pos,
        pos,
        heads,
        zeros(Float64, n),
        zeros(Float64, n),
        source_gains,
        zeros(Float64, n),
        Bool(config.visual_coupling),
        Bool(config.physical_coupling),
        Float64(config.sensory_noise),
        rng,
        copy(SENS_ANGLES_RAD),
        history,
        input_history,
        nothing,
    )
end

function ForageEnvironment(config::SwarmConfig; rng::AbstractRNG=MersenneTwister(config.seed))
    _validate_forage_config(config)
    torus = Torus(config.space_size)
    positions, headings = _sample_states(config, torus, rng)
    source_pos = _resolve_source_position(config, torus, rng)
    config_ = _swarm_config_with(config; source_position=source_pos)
    return _make_forage_environment(torus, config_, positions, headings, source_pos, rng)
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
    return _make_forage_environment(torus, config_, positions, headings, source_pos, rng)
end

function _require_torus_width(m::AbstractTorusEnvironment, bodies)
    n = length(m.positions)
    length(bodies) == n ||
        throw(DimensionMismatch("environment has $(n) agents, got $(length(bodies))"))
    length(m.history) == n ||
        throw(DimensionMismatch("environment history has width $(length(m.history)), expected $(n)"))
    return nothing
end

function _conspecific_sensors(m::AbstractTorusEnvironment, i::Integer)
    if m.visual_coupling && m.config.conspecific_vision
        return sense_agents(
            m.positions[i],
            m.headings[i],
            m.positions,
            Int(i),
            m.config.ven.agent_radius,
            m.torus,
            m.sens_angles_rad,
            m.config.sens_agent_dist,
            m.sensory_noise,
            m.rng;
            vision_range=m.config.vision_range,
        )
    end
    return zeros(Float64, length(m.sens_angles_rad))
end

# observe returns the fully-encoded reservoir inputs (so the per-agent source_gain
# env array is applied here); the agent's PassthroughBody{VENMorphology} passes
# them through in Ensemble.step!.
function observe(m::TorusEnvironment, bodies)
    _require_torus_width(m, bodies)
    n = length(m.positions)
    inputs = Vector{Vector{Float64}}(undef, n)

    @inbounds for i in 1:n
        sens = _conspecific_sensors(m, i)
        inputs[i] = assemble_inputs(
            sens,
            m.config.sensory_scaling;
            norm_mode=m.config.norm_mode,
            norm_sigma=m.config.norm_sigma,
            gain=m.config.conspecific_gain,
        )
    end

    m.last_inputs = inputs
    return inputs
end

function observe(m::ForageEnvironment, bodies)
    _require_torus_width(m, bodies)
    n = length(m.positions)
    inputs = Vector{Vector{Float64}}(undef, n)

    @inbounds for i in 1:n
        conspecific = _conspecific_sensors(m, i)
        source = sense_source(
            m.positions[i],
            m.headings[i],
            m.source_position,
            m.torus,
            m.sens_angles_rad,
            m.config.sens_agent_dist,
            m.sensory_noise,
            m.rng;
            vision_range=m.config.vision_range,
            source_radius=m.config.capture_radius,
        )
        inputs[i] = assemble_forage_inputs(
            conspecific,
            source,
            m.config.sensory_scaling;
            source_gain=m.source_gains[i],
            norm_mode=m.config.norm_mode,
            norm_sigma=m.config.norm_sigma,
            conspecific_gain=m.config.conspecific_gain,
        )
    end

    if m.config.signalling
        signal_range = Float64(m.config.signal_range)
        signal_gain = Float64(m.config.signal_gain)
        @inbounds for i in 1:n
            intensity = 0.0
            pos_i = m.positions[i]
            for j in 1:n
                i == j && continue
                d = tdistance(m.torus, pos_i, m.positions[j])
                intensity += m.last_signal[j] * exp(-d / signal_range)
            end
            inputs[i][VEN_ACOUSTIC_RECEPTOR_INDEX] = signal_gain * clamp(intensity, 0.0, 1.0)
        end
    end

    m.last_inputs = inputs
    return inputs
end

# Set (speed, heading) from a velocity vector after a collision.
function _velocity_to_state(velocity::NTuple{2,Float64}, heading::Float64)
    speed = hypot(velocity[1], velocity[2])
    new_heading = speed > 1e-12 ? mod(atan(velocity[2], velocity[1]), _TWO_PI) : heading
    return Float64(speed), new_heading
end

function _resolve_collisions!(m::AbstractTorusEnvironment)
    m.physical_coupling || return nothing

    radius = Float64(m.config.ven.agent_radius)
    min_d = 2.0 * radius
    n = length(m.positions)

    for i in 1:n
        for j in (i + 1):n
            dx, dy = tdelta(m.torus, m.positions[i], m.positions[j])
            dist = hypot(dx, dy)
            dist >= min_d && continue

            normal =
                dist <= 1e-12 ?
                (1.0, 0.0) :
                (Float64(dx / dist), Float64(dy / dist))

            overlap = min_d - dist
            m.positions[i] = wrap(
                m.torus,
                m.positions[i][1] - 0.5 * overlap * normal[1],
                m.positions[i][2] - 0.5 * overlap * normal[2],
            )
            m.positions[j] = wrap(
                m.torus,
                m.positions[j][1] + 0.5 * overlap * normal[1],
                m.positions[j][2] + 0.5 * overlap * normal[2],
            )

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

_capture_signals!(::AbstractTorusEnvironment, Es) = nothing

function _capture_signals!(m::ForageEnvironment, Es)
    m.config.signalling || return nothing
    @inbounds for i in eachindex(Es)
        m.last_signal[i] = ven_emitted_signal(Es[i])
    end
    return nothing
end

function actuate!(m::AbstractTorusEnvironment, bodies, Es)
    _require_torus_width(m, bodies)
    n = length(m.positions)
    length(Es) == n ||
        throw(DimensionMismatch("expected one effector vector per agent"))

    params = m.config.ven
    @inbounds for i in 1:n
        new_pos, new_heading, new_speed, new_hr = integrate_motion(
            m.positions[i], m.headings[i], m.speeds[i], m.heading_rates[i], Es[i], params, m.torus,
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

    return nothing
end

function _default_torus_window(m::AbstractTorusEnvironment)
    isempty(m.history) && return 0
    return minimum(length, m.history)
end

environment_metrics(m::TorusEnvironment, window::Integer=_default_torus_window(m)) =
    swarm_metrics(m, Int(window))

environment_metrics(m::ForageEnvironment, window::Integer=_default_torus_window(m)) =
    forage_metrics(m, Int(window))
