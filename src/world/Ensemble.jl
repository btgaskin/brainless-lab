struct Agent{R<:Reservoir,B<:Body}
    reservoir::R
    body::B
end

mutable struct Ensemble{E<:Environment,A<:Agent,B<:Body}
    agents::Vector{A}
    bodies::Vector{B}
    environment::E
    t::Int
    recorder::Union{Nothing,Recorder}
end

function _typed_agents(agents::AbstractVector{<:Agent})
    isempty(agents) && throw(ArgumentError("Ensemble requires at least one agent"))

    A = typeof(first(agents))
    out = Vector{A}(undef, length(agents))
    @inbounds for i in eachindex(agents)
        agent = agents[i]
        agent isa A ||
            throw(ArgumentError("Ensemble requires homogeneous agents; agent $i has $(typeof(agent)), expected $A"))
        out[i] = agent
    end
    return out
end

function _typed_agent_bodies(agents::AbstractVector{<:Agent})
    B = typeof(first(agents).body)
    out = Vector{B}(undef, length(agents))
    @inbounds for i in eachindex(agents)
        out[i] = agents[i].body
    end
    return out
end

function Ensemble(
    agents::AbstractVector{<:Agent},
    environment::E;
    t::Integer=0,
    recorder::Union{Nothing,Recorder}=nothing,
) where {E<:Environment}
    agent_vec = _typed_agents(agents)
    body_vec = _typed_agent_bodies(agent_vec)
    return Ensemble{E,eltype(agent_vec),eltype(body_vec)}(agent_vec, body_vec, environment, Int(t), recorder)
end

_agent_bodies(c::Ensemble) = c.bodies

function _spike_rate(spikes::Vector{Float64})
    isempty(spikes) && return 0.0
    return sum(spikes) / length(spikes)
end

function _spike_rate(spikes)
    values = Float64.(vec(collect(spikes)))
    isempty(values) && return 0.0
    return sum(values) / length(values)
end

function _record_payload(x)
    if x isa AbstractArray && eltype(x) <: Number
        return copy(x)
    elseif x isa AbstractVector
        return [_record_payload(v) for v in x]
    elseif x isa Tuple
        return map(_record_payload, x)
    end
    return x
end

record_state!(channels::Dict{Symbol,Vector{Any}}, ::Reservoir) = channels
record_state!(::Recorder, ::Reservoir) = nothing

function record_state!(channels::Dict{Symbol,Vector{Any}}, r::FalandaysReservoir)
    push!(get!(channels, :acts, Any[]), copy(r.acts))
    push!(get!(channels, :targets, Any[]), copy(r.targets))
    return channels
end

function record_state!(channels::Dict{Symbol,Vector{Any}}, r::CompartmentalReservoir)
    push!(get!(channels, :soma, Any[]), copy(r.soma_y))
    push!(get!(channels, :V, Any[]), copy(r.V))
    return channels
end

_record_active(rec) = rec isa Recorder && !isempty(rec.enabled)
_record_sample(rec::Recorder) = rem(rec.tick, rec.every) == 0
_record_wants(rec::Recorder, channel::Symbol) = channel in rec.enabled
_record_wants_any(rec::Recorder, channels) = any(channel -> channel in rec.enabled, channels)

function _pose_payload(m::TaskEnvironment, bodies)
    p = pose(m.world)
    return p === nothing ? nothing : [p]
end

# Per-task visualizable scene (tracking/pong/cartpole expose one; swarm/wall use poses).
_scene_payload(m::TaskEnvironment) = scene(m.world)
_scene_payload(::Environment) = nothing

function _pose_payload(::Environment, bodies)
    poses = NTuple{3,Float64}[]
    for body in bodies
        if body isa VENBody
            push!(poses, (body.pos[1], body.pos[2], body.heading))
        elseif hasproperty(body, :pos) && hasproperty(body, :heading)
            pos = getproperty(body, :pos)
            push!(poses, (Float64(pos[1]), Float64(pos[2]), Float64(getproperty(body, :heading))))
        end
    end
    return isempty(poses) ? nothing : poses
end

function _record_swarm_metrics!(rec::Recorder, m::AbstractTorusEnvironment, poses)
    if poses === nothing || isempty(poses)
        return rec
    end

    wants_polarization = _record_wants(rec, :polarization)
    wants_milling = _record_wants(rec, :milling)
    (wants_polarization || wants_milling) || return rec

    headings = [pose[3] for pose in poses]
    if wants_polarization
        record!(rec, :polarization, polarization(headings))
    end

    if wants_milling
        positions = [(pose[1], pose[2]) for pose in poses]
        centroid = circular_centroid(positions, m.torus)
        record!(rec, :milling, milling(positions, headings, centroid, m.torus))
    end

    return rec
end

function _record_state_channels!(rec::Recorder, agents)
    _record_wants_any(rec, (:acts, :targets, :soma, :V)) || return rec

    channels = Dict{Symbol,Vector{Any}}()
    for agent in agents
        record_state!(channels, agent.reservoir)
    end

    for (channel, payload) in channels
        if _record_wants(rec, channel)
            record!(rec, channel, _record_payload(payload))
        end
    end

    return rec
end

_spectral_radius_payload(::Reservoir) = nothing
_spectral_radius_payload(r::FalandaysReservoir) = _spectral_radius(r)

function _record_spectral!(rec::Recorder, agents)
    # The eigendecomposition behind each payload is the single most expensive
    # per-tick record. Honour the recorder's compute stride: recompute every K
    # ticks and re-record the cached value in between, so the stored series
    # keeps one sample per tick while paying eigvals only 1/K of the time.
    stride = compute_stride(rec, :spectral_radius)
    if stride > 1 && rem(rec.tick, stride) != 0 && haskey(rec.cache, :spectral_radius)
        payload = rec.cache[:spectral_radius]
        payload === nothing && return rec
        record!(rec, :spectral_radius, payload)
        return rec
    end

    values = Float64[]
    for agent in agents
        rho = _spectral_radius_payload(agent.reservoir)
        if rho === nothing
            rec.cache[:spectral_radius] = nothing
            return rec
        end
        push!(values, Float64(rho))
    end
    payload = length(values) == 1 ? values[1] : values
    rec.cache[:spectral_radius] = payload
    record!(rec, :spectral_radius, payload)
    return rec
end

function _record_ensemble!(rec::Recorder, c::Ensemble, bodies, percepts, spikes, rates, Es)
    if !_record_active(rec)
        tick!(rec)
        return rec
    end

    if !_record_sample(rec)
        tick!(rec)
        return rec
    end

    if _record_wants(rec, :spikes)
        record!(rec, :spikes, _record_payload(spikes))
    end
    if _record_wants(rec, :rate)
        record!(rec, :rate, copy(rates))
    end
    if _record_wants(rec, :rates)
        record!(rec, :rates, copy(rates))
    end
    if _record_wants(rec, :spectral_radius)
        _record_spectral!(rec, c.agents)
    end
    if _record_wants(rec, :effectors)
        record!(rec, :effectors, _record_payload(Es))
    end
    if _record_wants(rec, :percepts)
        record!(rec, :percepts, _record_payload(percepts))
    end
    if _record_wants(rec, :sensors)
        record!(rec, :sensors, _record_payload(percepts))
    end

    poses = _record_wants_any(rec, (:poses, :polarization, :milling)) ?
        _pose_payload(c.environment, bodies) :
        nothing
    if poses !== nothing && _record_wants(rec, :poses)
        record!(rec, :poses, _record_payload(poses))
    end
    if _record_wants(rec, :scene)
        sc = _scene_payload(c.environment)
        sc === nothing || record!(rec, :scene, sc)
    end
    if c.environment isa AbstractTorusEnvironment
        _record_swarm_metrics!(rec, c.environment, poses)
    end

    _record_state_channels!(rec, c.agents)
    tick!(rec)
    return rec
end

function step!(c::Ensemble)
    bodies = _agent_bodies(c)
    percepts = observe(c.environment, bodies)
    length(percepts) == length(c.agents) ||
        throw(DimensionMismatch("environment returned $(length(percepts)) percepts for $(length(c.agents)) agents"))

    spikes = Vector{Vector{Float64}}(undef, length(c.agents))
    rates = Vector{Float64}(undef, length(c.agents))
    Es = Vector{Vector{Float64}}(undef, length(c.agents))

    @inbounds for i in eachindex(c.agents)
        agent = c.agents[i]
        R = receptors(agent.body, percepts[i])
        s = step!(agent.reservoir, R)
        E = effectors(agent.reservoir, s)
        spikes[i] = s
        rates[i] = _spike_rate(s)
        Es[i] = decode_effectors(agent.body, E)
    end

    actuate!(c.environment, bodies, Es)
    c.t += 1

    if c.recorder isa Recorder
        _record_ensemble!(c.recorder, c, bodies, percepts, spikes, rates, Es)
    end

    return spikes
end

function _rollout_rate_and_width(spikes::Vector{Vector{Float64}})
    total = 0.0
    width = 0
    for s in spikes
        total += sum(s)
        width += length(s)
    end
    return width == 0 ? 0.0 : total / width, width
end

function _rollout_rate_and_width(spikes)
    total = 0.0
    width = 0
    for s in spikes
        values = Float64.(vec(collect(s)))
        total += sum(values)
        width += length(values)
    end
    return width == 0 ? 0.0 : total / width, width
end

function _metric_symbols(selection)
    selection === nothing && return Symbol[]
    selection isa Symbol && return [selection]
    selection isa AbstractString && return [Symbol(selection)]
    return Symbol.(collect(selection))
end

function _push_metric!(names::Vector{Symbol}, values::Vector{Any}, name::Symbol, value)
    name in names && return names, values
    push!(names, name)
    push!(values, value)
    return names, values
end

function _append_metric_result!(names::Vector{Symbol}, values::Vector{Any}, default_name::Symbol, value)
    if value isa NamedTuple
        for (key, item) in pairs(value)
            _push_metric!(names, values, Symbol(key), item)
        end
    elseif value isa Pair
        _push_metric!(names, values, Symbol(value.first), value.second)
    else
        _push_metric!(names, values, default_name, value)
    end
    return names, values
end

function _registered_metric_value(c::Ensemble, base_metrics, sym::Symbol, window::Integer)
    sym in propertynames(base_metrics) && return getproperty(base_metrics, sym)

    f = resolve_metric(sym)
    if applicable(f, c, Int(window))
        return f(c, Int(window))
    elseif applicable(f, c.environment, Int(window))
        return f(c.environment, Int(window))
    elseif applicable(f, base_metrics)
        return f(base_metrics)
    end

    throw(ArgumentError("registered metric :$(sym) is not applicable to Ensemble, Environment, or current metric tuple"))
end

function _selected_environment_metrics(c::Ensemble, window::Integer, selection)
    base = environment_metrics(c.environment, Int(window))
    selection === nothing && return base

    names = Symbol[]
    values = Any[]
    for (key, value) in pairs(base)
        _push_metric!(names, values, Symbol(key), value)
    end

    for sym in _metric_symbols(selection)
        value = _registered_metric_value(c, base, sym, Int(window))
        _append_metric_result!(names, values, sym, value)
    end

    return NamedTuple{Tuple(names)}(Tuple(values))
end

# Mid-rollout interventions: apply a scheduled verb (e.g. :freeze_plasticity) to
# every agent's reservoir at its scheduled tick. Steps 1..T-1 run with the
# pre-intervention configuration; the verb takes effect at tick T (inclusive).
# Reuses the guarded build-time verb dispatch (`_apply_postbuild_ablation!`), so a
# verb that does not apply to a given node is a documented no-op. `schedule` is a
# tick-sorted `Vector{Tuple{Int,Symbol}}` resolved in `_build_ensemble`.
function _apply_tick_interventions!(c::Ensemble, t::Integer, schedule)
    @inbounds for entry in schedule
        first(entry) == t || continue
        sym = last(entry)
        for agent in c.agents
            _apply_postbuild_ablation!(agent.reservoir, sym)
        end
    end
    return c
end

function rollout!(c::Ensemble, ticks::Integer; window::Integer=ticks, metrics=nothing, interventions=nothing)
    ticks = Int(ticks)
    ticks >= 0 || throw(ArgumentError("ticks must be non-negative"))
    window = Int(window)

    rates = zeros(Float64, ticks)
    node_count = 0
    for t in 1:ticks
        interventions === nothing || _apply_tick_interventions!(c, t, interventions)
        spikes = step!(c)
        rates[t], width = _rollout_rate_and_width(spikes)
        node_count = max(node_count, width)
    end

    return (;
        _selected_environment_metrics(c, window, metrics)...,
        liveness(rates, node_count, window)...,
    )
end
