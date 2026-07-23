struct Agent{R<:Reservoir,B<:AbstractBody,C<:InteractionCycle,S<:InteractionState}
    reservoir::R
    body::B
    cycle::C
    interaction::S
end

function Agent(
    reservoir::Reservoir,
    body::AbstractBody;
    cycle::Union{Nothing,InteractionCycle}=nothing,
)
    cycle_ = cycle === nothing ? default_interaction_cycle(reservoir) : cycle
    cycle_ isa FixedRateCycle || throw(ArgumentError(
        "the standard runtime currently supports FixedRateCycle, got $(typeof(cycle_))",
    ))
    interaction = InteractionState(primary_readout(body), reservoir, body)
    return Agent(reservoir, body, cycle_, interaction)
end

Agent(reservoir::Reservoir, body::AbstractBody, cycle::InteractionCycle) =
    Agent(reservoir, body; cycle=cycle)

function reset!(agent::Agent)
    reset!(agent.reservoir)
    applicable(reset!, agent.body) && reset!(agent.body)
    begin_interaction!(agent.interaction, primary_readout(agent.body), agent.cycle)
    return agent
end

"""Stable identity for an ensemble entity, independent of its world slot."""
struct EntityID
    value::UInt64

    function EntityID(value::Integer)
        value >= 1 || throw(ArgumentError("EntityID must be positive, got $(value)"))
        return new(UInt64(value))
    end
end

Base.convert(::Type{UInt64}, id::EntityID) = id.value
Base.show(io::IO, id::EntityID) = print(io, "EntityID(", id.value, ")")

"""One recorder sample whose values remain explicitly aligned to entity IDs."""
struct EntityFrame{T,V<:AbstractVector{T}} <: AbstractVector{T}
    ids::Vector{EntityID}
    values::V

    function EntityFrame(ids, values::V) where {T,V<:AbstractVector{T}}
        ids_ = EntityID[id isa EntityID ? id : EntityID(id) for id in ids]
        length(ids_) == length(values) || throw(DimensionMismatch(
            "EntityFrame has $(length(ids_)) IDs but $(length(values)) values",
        ))
        allunique(ids_) || throw(ArgumentError(
            "EntityFrame IDs must be unique; got $(ids_)",
        ))
        return new{T,V}(ids_, values)
    end
end


Base.IndexStyle(::Type{<:EntityFrame}) = IndexLinear()
Base.size(frame::EntityFrame) = size(frame.values)
Base.length(frame::EntityFrame) = length(frame.values)
Base.getindex(frame::EntityFrame, index::Int) = frame.values[index]
Base.iterate(frame::EntityFrame, state...) = iterate(frame.values, state...)
Base.copy(frame::EntityFrame) = EntityFrame(copy(frame.ids), copy(frame.values))

_entity_id(id::EntityID) = id
_entity_id(id::Integer) = EntityID(id)

"""
    entity_index(frame, id)

Return the position of stable entity `id` in `frame`. Integer identifiers are
interpreted as `EntityID` values, never as positional indexes.
"""
function entity_index(frame::EntityFrame, id::Union{EntityID,Integer})
    id_ = _entity_id(id)
    index = findfirst(==(id_), frame.ids)
    index === nothing && throw(ArgumentError(
        "EntityFrame does not contain $(id_); available IDs are $(frame.ids)",
    ))
    return index
end

"""
    entity_value(frame, id)

Return the value associated with stable entity `id`.
"""
entity_value(frame::EntityFrame, id::Union{EntityID,Integer}) =
    frame.values[entity_index(frame, id)]

"""
    align_entities(frame, ids)

Return an `EntityFrame` ordered by the requested stable IDs. The requested IDs
must describe exactly the same entity set as `frame`; this prevents analyses
from silently dropping or duplicating entities when recorder order changes.
"""
function align_entities(frame::EntityFrame, ids)
    ids_ = EntityID[_entity_id(id) for id in ids]
    allunique(ids_) || throw(ArgumentError("requested entity IDs must be unique; got $(ids_)"))
    length(ids_) == length(frame) || throw(DimensionMismatch(
        "requested $(length(ids_)) entities from a frame containing $(length(frame))",
    ))
    values = [entity_value(frame, id) for id in ids_]
    return EntityFrame(ids_, values)
end

struct AgentGroupKey
    agent_type::DataType
    n_receptors::Int
    n_effectors::Int
end

function AgentGroupKey(agent::Agent)
    spec = portspec(agent.body)
    return AgentGroupKey(typeof(agent), n_receptors(spec), n_effectors(spec))
end

abstract type AbstractAgentStore end
abstract type AbstractAgentGroup end

"""Exact fast path for agents sharing one concrete type and port signature."""
struct HomogeneousStore{A<:Agent} <: AbstractAgentStore
    agents::Vector{A}
    ids::Vector{EntityID}
    key::AgentGroupKey
end

"""One concretely typed batch within a heterogeneous population."""
struct AgentGroup{A<:Agent} <: AbstractAgentGroup
    agents::Vector{A}
    slots::Vector{Int}
    ids::Vector{EntityID}
    key::AgentGroupKey
end

"""Type-grouped storage with stable world-slot and identity indexes."""
struct GroupedStore <: AbstractAgentStore
    groups::Vector{AbstractAgentGroup}
    slot_group::Vector{Int}
    slot_local::Vector{Int}
    ids::Vector{EntityID}
end

mutable struct Ensemble{E<:Environment,S<:AbstractAgentStore}
    store::S
    environment::E
    t::Int
    recorder::Union{Nothing,Recorder}
end

function _entity_ids(n::Integer, ids)
    values = ids === nothing ? EntityID.(1:Int(n)) : EntityID[id isa EntityID ? id : EntityID(id) for id in ids]
    length(values) == n || throw(DimensionMismatch("expected $(n) entity IDs, got $(length(values))"))
    length(unique(values)) == length(values) || throw(ArgumentError("entity IDs must be unique"))
    return values
end

function _typed_agents(agents::AbstractVector{<:Agent}, ::Type{A}) where {A<:Agent}
    out = Vector{A}(undef, length(agents))
    @inbounds for i in eachindex(agents)
        agents[i] isa A || throw(ArgumentError("agent $i has $(typeof(agents[i])), expected $A"))
        out[i] = agents[i]
    end
    return out
end

function HomogeneousStore(agents::AbstractVector{<:Agent}, ids)
    isempty(agents) && throw(ArgumentError("Ensemble requires at least one agent"))
    A = typeof(first(agents))
    key = AgentGroupKey(first(agents))
    ids_ = _entity_ids(length(agents), ids)
    @inbounds for i in eachindex(agents)
        AgentGroupKey(agents[i]) == key || throw(ArgumentError(
            "HomogeneousStore requires one concrete agent type and port signature; agent $i has $(AgentGroupKey(agents[i])), expected $(key)",
        ))
    end
    return HomogeneousStore{A}(_typed_agents(agents, A), ids_, key)
end

function _agent_group(::Type{A}, agents, slots, ids, key) where {A<:Agent}
    typed = Vector{A}(undef, length(slots))
    @inbounds for (local_index, slot) in enumerate(slots)
        typed[local_index] = agents[slot]
    end
    return AgentGroup{A}(typed, collect(slots), ids[slots], key)
end

function GroupedStore(agents::AbstractVector{<:Agent}, ids::Vector{EntityID})
    keys = AgentGroupKey[]
    for agent in agents
        key = AgentGroupKey(agent)
        key in keys || push!(keys, key)
    end
    groups = AbstractAgentGroup[]
    slot_group = zeros(Int, length(agents))
    slot_local = zeros(Int, length(agents))
    for key in keys
        slots = findall(i -> AgentGroupKey(agents[i]) == key, eachindex(agents))
        group = _agent_group(key.agent_type, agents, slots, ids, key)
        push!(groups, group)
        group_index = length(groups)
        @inbounds for (local_index, slot) in enumerate(slots)
            slot_group[slot] = group_index
            slot_local[slot] = local_index
        end
    end
    return GroupedStore(groups, slot_group, slot_local, ids)
end

function _agent_store(agents::AbstractVector{<:Agent}, ids)
    isempty(agents) && throw(ArgumentError("Ensemble requires at least one agent"))
    ids_ = _entity_ids(length(agents), ids)
    key = AgentGroupKey(first(agents))
    if all(agent -> AgentGroupKey(agent) == key, agents)
        return HomogeneousStore(agents, ids_)
    end
    return GroupedStore(agents, ids_)
end

function _require_agent_port_contract(agent::Agent, slot::Integer)
    reservoir_receptors = n_receptors(agent.reservoir)
    reservoir_effectors = n_effectors(agent.reservoir)
    body_spec = portspec(agent.body)
    body_receptors = n_receptors(body_spec)
    body_effectors = n_effectors(body_spec)
    (reservoir_receptors, reservoir_effectors) == (body_receptors, body_effectors) ||
        throw(DimensionMismatch(
            "agent slot $(slot) port mismatch: reservoir exposes " *
            "($(reservoir_receptors), $(reservoir_effectors)) but body expects " *
            "($(body_receptors), $(body_effectors))",
        ))
    return nothing
end

function Ensemble(
    agents::AbstractVector{<:Agent},
    environment::E;
    ids=nothing,
    t::Integer=0,
    recorder::Union{Nothing,Recorder}=nothing,
) where {E<:Environment}
    for (slot, agent) in pairs(agents)
        _require_agent_port_contract(agent, slot)
    end
    store = _agent_store(agents, ids)
    bind_entity_ids!(environment, entity_ids(store))
    return Ensemble{E,typeof(store)}(store, environment, Int(t), recorder)
end

nagents(store::HomogeneousStore) = length(store.agents)
nagents(store::GroupedStore) = length(store.ids)
nagents(c::Ensemble) = nagents(c.store)

entity_ids(store::AbstractAgentStore) = copy(store.ids)
entity_ids(c::Ensemble) = entity_ids(c.store)

group_agents(store::HomogeneousStore) = copy(store.agents)
group_slots(store::HomogeneousStore) = Base.OneTo(length(store.agents))
group_ids(store::HomogeneousStore) = copy(store.ids)
group_agents(group::AgentGroup) = copy(group.agents)
group_slots(group::AgentGroup) = copy(group.slots)
group_ids(group::AgentGroup) = copy(group.ids)

foreach_group(f, store::HomogeneousStore) = (f(store); store)
function foreach_group(f, store::GroupedStore)
    for group in store.groups
        f(group)
    end
    return store
end
foreach_group(f, c::Ensemble) = foreach_group(f, c.store)

agent_at_slot(store::HomogeneousStore, slot::Integer) = store.agents[Int(slot)]
_agent_at_local(group::AgentGroup, local_index::Int) = group.agents[local_index]
function agent_at_slot(store::GroupedStore, slot::Integer)
    slot_ = Int(slot)
    return _agent_at_local(store.groups[store.slot_group[slot_]], store.slot_local[slot_])
end
agent_at_slot(c::Ensemble, slot::Integer) = agent_at_slot(c.store, slot)
body_at_slot(store::AbstractAgentStore, slot::Integer) = agent_at_slot(store, slot).body
body_at_slot(c::Ensemble, slot::Integer) = body_at_slot(c.store, slot)

function _agents_by_slot(store::HomogeneousStore)
    return store.agents
end
function _agents_by_slot(store::GroupedStore)
    out = Vector{Agent}(undef, nagents(store))
    @inbounds for slot in eachindex(out)
        out[slot] = agent_at_slot(store, slot)
    end
    return out
end

function _agent_bodies(store::HomogeneousStore)
    B = typeof(first(store.agents).body)
    out = Vector{B}(undef, nagents(store))
    @inbounds for i in eachindex(out)
        out[i] = store.agents[i].body
    end
    return out
end
function _agent_bodies(store::GroupedStore)
    out = Vector{AbstractBody}(undef, nagents(store))
    @inbounds for slot in eachindex(out)
        out[slot] = body_at_slot(store, slot)
    end
    return out
end
_agent_bodies(c::Ensemble) = _agent_bodies(c.store)

# Transitional read-only access for analysis and experiment code. Runtime code
# uses the store protocol above, so mixed populations never depend on these
# allocating slot-ordered projections.
function Base.getproperty(c::Ensemble, name::Symbol)
    name === :agents && return _agents_by_slot(getfield(c, :store))
    name === :bodies && return _agent_bodies(getfield(c, :store))
    return getfield(c, name)
end

Base.propertynames(c::Ensemble, private::Bool=false) = (:store, :environment, :t, :recorder, :agents, :bodies)

Base.length(c::Ensemble) = nagents(c)

_entity_frame(c::Ensemble, values::AbstractVector) = EntityFrame(entity_ids(c), values)

_receptor_vector(values::Vector{Float64}) = copy(values)
_receptor_vector(values) = Vector{Float64}(values)

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
    if x isa AbstractCommand
        return _record_payload(command_values(x))
    elseif x isa AbstractArray && eltype(x) <: Number
        return copy(x)
    elseif x isa AbstractVector
        return [_record_payload(v) for v in x]
    elseif x isa Tuple
        return map(_record_payload, x)
    end
    return x
end

_inactive_command(body::AbstractBody) = inactive_command(body)

function _homogeneous_command_storage(bodies::AbstractVector{<:Embodiment})
    first_command = length(first(bodies).state.commands) == 1 ?
        only(first(bodies).state.commands) : first(bodies).state.commands
    return Vector{typeof(first_command)}(undef, length(bodies))
end
_homogeneous_command_storage(bodies::AbstractVector{<:AbstractBody}) =
    Vector{Any}(undef, length(bodies))

function _body_death(body::AbstractBody)
    state = component_state(body)
    return hasproperty(state, :death) ? state.death : nothing
end

_component_value(body::AbstractBody, name::Symbol, default) = begin
    state = component_state(body)
    hasproperty(state, name) ? getproperty(state, name) : default
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

record_state!(channels::Dict{Symbol,Vector{Any}}, w::NoisyInput) =
    record_state!(channels, getfield(w, :inner))

_record_active(rec) = rec isa Recorder && !isempty(rec.enabled)
_record_sample(rec::Recorder) = rem(rec.tick, rec.every) == 0
_record_wants(rec::Recorder, channel::Symbol) = channel in rec.enabled
_record_wants_any(rec::Recorder, channels) = any(channel -> channel in rec.enabled, channels)

function _pose_payload(m::TaskEnvironment, bodies)
    p = pose(m.world)
    return p === nothing ? nothing : [p]
end

function _pose_payload(m::TaskWorld, bodies)
    p = pose(m)
    return p === nothing ? nothing : [p]
end

# Per-task visualizable scene (tracking/pong/cartpole expose one; swarm/wall use poses).
_scene_payload(m::TaskEnvironment) = scene(m.world)
_scene_payload(m::TaskWorld) = scene(m)
_scene_payload(::Environment) = nothing

function _pose_payload(m::AbstractSituatedEnvironment, bodies)
    n = length(m.positions)
    n == 0 && return nothing
    return NTuple{3,Float64}[(m.positions[i][1], m.positions[i][2], m.headings[i]) for i in 1:n]
end

function _pose_payload(m::Environment, bodies)
    applicable(pose, m) || return nothing
    value = pose(m)
    value === nothing && return nothing
    length(bodies) == 1 && return [value]
    value isa AbstractVector && length(value) == length(bodies) ||
        throw(DimensionMismatch(
            "pose(environment) must return one value per body for a multi-agent environment",
        ))
    return value
end

function _record_swarm_metrics!(rec::Recorder, m::AbstractSituatedEnvironment, poses)
    if poses === nothing || isempty(poses)
        return rec
    end

    wants_polarization = _record_wants(rec, :polarization)
    wants_milling = _record_wants(rec, :milling)
    (wants_polarization || wants_milling) || return rec

    active = hasproperty(m, :active_agents) ? findall(m.active_agents) : collect(eachindex(poses))
    if isempty(active)
        wants_polarization && record!(rec, :polarization, 0.0)
        wants_milling && record!(rec, :milling, 0.0)
        return rec
    end
    active_poses = poses[active]
    headings = [pose[3] for pose in active_poses]
    if wants_polarization
        record!(rec, :polarization, polarization(headings))
    end

    if wants_milling
        positions = [(pose[1], pose[2]) for pose in active_poses]
        centroid = circular_centroid(positions, m.torus)
        record!(rec, :milling, milling(positions, headings, centroid, m.torus))
    end

    return rec
end

function _record_state_channels!(rec::Recorder, c::Ensemble)
    _record_wants_any(rec, (:acts, :targets, :soma, :V)) || return rec

    channels = Dict{Symbol,Vector{Any}}()
    for slot in 1:nagents(c)
        local_channels = Dict{Symbol,Vector{Any}}()
        record_state!(local_channels, agent_at_slot(c, slot).reservoir)
        for (channel, payload) in local_channels
            values = get!(channels, channel) do
                fill(nothing, nagents(c))
            end
            values[slot] = only(payload)
        end
    end

    for (channel, payload) in channels
        if _record_wants(rec, channel)
            record!(rec, channel, _entity_frame(c, _record_payload(payload)))
        end
    end

    return rec
end

_spectral_radius_payload(::Reservoir) = nothing
_spectral_radius_payload(r::FalandaysReservoir) = _spectral_radius(r)
_spectral_radius_payload(w::NoisyInput) =
    _spectral_radius_payload(getfield(w, :inner))

function _record_spectral!(rec::Recorder, c::Ensemble)
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

    values = Vector{Union{Nothing,Float64}}(undef, nagents(c))
    for slot in 1:nagents(c)
        rho = _spectral_radius_payload(agent_at_slot(c, slot).reservoir)
        if rho === nothing
            values[slot] = nothing
        else
            values[slot] = Float64(rho)
        end
    end
    payload = _entity_frame(c, values)
    rec.cache[:spectral_radius] = payload
    record!(rec, :spectral_radius, payload)
    return rec
end

function _record_ensemble!(rec::Recorder, c::Ensemble, bodies, percepts, receptor_vectors, spikes, rates, Es)
    if !_record_active(rec)
        tick!(rec)
        return rec
    end

    if !_record_sample(rec)
        tick!(rec)
        return rec
    end

    if _record_wants(rec, :spikes)
        record!(rec, :spikes, _entity_frame(c, _record_payload(spikes)))
    end
    if _record_wants(rec, :rate)
        record!(rec, :rate, _entity_frame(c, copy(rates)))
    end
    if _record_wants(rec, :rates)
        record!(rec, :rates, _entity_frame(c, copy(rates)))
    end
    if _record_wants(rec, :spectral_radius)
        _record_spectral!(rec, c)
    end
    if _record_wants(rec, :effectors)
        record!(rec, :effectors, _entity_frame(c, _record_payload(Es)))
    end
    if _record_wants(rec, :percepts)
        record!(rec, :percepts, _entity_frame(c, _record_payload(percepts)))
    end
    if _record_wants(rec, :sensors)
        record!(rec, :sensors, _entity_frame(c, _record_payload(percepts)))
    end
    if _record_wants(rec, :receptors)
        record!(rec, :receptors, _entity_frame(c, _record_payload(receptor_vectors)))
    end
    if _record_wants(rec, :components)
        values = [_component_value(body, :components, NamedTuple()) for body in bodies]
        record!(rec, :components, _entity_frame(c, _record_payload(values)))
    end
    if _record_wants(rec, :needs)
        values = [_component_value(body, :variables, NamedTuple()) for body in bodies]
        record!(rec, :needs, _entity_frame(c, values))
    end
    if _record_wants(rec, :body_alive)
        record!(rec, :body_alive, _entity_frame(c, Bool[alive(body) for body in bodies]))
    end
    if _record_wants(rec, :deaths)
        record!(rec, :deaths, _entity_frame(c, [_body_death(body) for body in bodies]))
    end
    if _record_wants(rec, :feedback)
        values = [_component_value(body, :feedback, Float64[]) for body in bodies]
        record!(rec, :feedback, _entity_frame(c, values))
    end
    if _record_wants(rec, :interactions) &&
            applicable(interaction_events, c.environment)
        record!(rec, :interactions, _record_payload(interaction_events(c.environment)))
    end
    if _record_wants(rec, :conspecific_contacts) &&
            applicable(conspecific_contacts, c.environment)
        record!(rec, :conspecific_contacts, _entity_frame(
            c,
            _record_payload(conspecific_contacts(c.environment)),
        ))
    end
    if _record_wants(rec, :objects) && applicable(object_snapshot, c.environment)
        record!(rec, :objects, _record_payload(object_snapshot(c.environment)))
    end
    poses = _record_wants_any(rec, (:poses, :polarization, :milling)) ?
        _pose_payload(c.environment, bodies) :
        nothing
    if poses !== nothing && _record_wants(rec, :poses)
        record!(rec, :poses, _entity_frame(c, _record_payload(poses)))
    end
    if _record_wants(rec, :scene)
        sc = _scene_payload(c.environment)
        sc === nothing || record!(rec, :scene, sc)
    end
    if c.environment isa AbstractSituatedEnvironment
        _record_swarm_metrics!(rec, c.environment, poses)
    end

    _record_state_channels!(rec, c)
    tick!(rec)
    return rec
end

# Run a reservoir for one environment step, applying its temporal-averaging
# window (`windowing`/`temporal_window`). `SteppedWindow` (the default) runs
# `step!` K times holding the afferent `R` and mean-reduces the spike outputs;
# `IntrinsicWindow` nodes own their sub-stepping internally, so `step!` is called
# once. At K == 1 (every existing node/task default) this is a single bare
# `step!` — behavior identical to before this seam existed.
step_window!(r::Reservoir, R) = _step_window!(windowing(r), r, R, temporal_window(r))

_step_window!(::IntrinsicWindow, r::Reservoir, R, K::Int) = step!(r, R)

function _step_window!(::SteppedWindow, r::Reservoir, R, K::Int)
    K <= 1 && return step!(r, R)
    acc = step!(r, R)
    @inbounds for _ in 2:K
        acc = acc .+ step!(r, R)
    end
    return acc ./ K
end

# Falandays readout specialization for the graded schemes (the default and the
# spike-based schemes fall through to `effectors`, as does every other reservoir).
# Both graded schemes re-express the reservoir's own graded internal state through
# the SAME `effectors` projection used for spikes, so the readout stays a
# memoryless, bias-free re-expression of the node's output — no leaky integrator,
# no threshold-on-turn, no baked heading. `:graded_state` substitutes the
# distance-to-threshold `acts ./ (targets · threshold_mult)` for the binary spike;
# `:graded_deviation` the signed homeostatic error `acts .- targets`. Lives here
# (not Motor.jl) because it dispatches on the node type, defined after Motor.jl.
function readout(m::Motor, r::FalandaysReservoir, spikes)
    scheme = m.readout
    if scheme === :graded_state
        return effectors(r, activations(r) ./ (r.targets .* r.params.threshold_mult))
    elseif scheme === :graded_deviation
        return effectors(r, activations(r) .- r.targets)
    end
    return effectors(r, spikes)
end

# Wrapped Falandays variants (:falandays_noisy / :falandays_extended) are
# NoisyInput{<:Reservoir} wrappers, not FalandaysReservoir; delegate the readout to
# the inner reservoir so the graded schemes work across the whole Falandays family
# (mirrors NoisyInput's transparent effectors/getproperty forwarding).
readout(m::Motor, w::NoisyInput, spikes) = readout(m, getfield(w, :inner), spikes)

function _run_interaction!(agent::Agent, percept)
    reservoir = agent.reservoir
    body = agent.body
    cycle = agent.cycle
    readout_component = primary_readout(body)
    state = agent.interaction
    encoding_state = begin_encoding!(body, percept, cycle)
    begin_interaction!(state, readout_component, cycle)

    @inbounds for frame in 1:neural_frames(cycle)
        receptors = encode_frame!(body, encoding_state, frame, cycle)
        observe_receptors!(state, receptors)
        neural_output = step!(reservoir, receptors)
        observe_frame!(state.readout, readout_component, reservoir, neural_output, frame)
    end

    receptor_mean = finish_receptors!(state, cycle)
    effector_signal = finish_readout!(state.readout, readout_component, reservoir, cycle)
    command = decode!(body, effector_signal)
    neural_mean = recorded_neural_output(state.readout, cycle)
    return receptor_mean, neural_mean, command
end

function _step_homogeneous!(c::Ensemble, store::HomogeneousStore)
    agents = store.agents
    bodies = _agent_bodies(store)
    sync_activity!(c.environment, bodies)
    prepare_step!(c.environment, bodies)
    percepts = sample!(c.environment, bodies)
    length(percepts) == length(agents) ||
        throw(DimensionMismatch("environment returned $(length(percepts)) percepts for $(length(agents)) agents"))

    spikes = Vector{Vector{Float64}}(undef, length(agents))
    receptor_vectors = Vector{Vector{Float64}}(undef, length(agents))
    rates = Vector{Float64}(undef, length(agents))
    Es = _homogeneous_command_storage(bodies)

    @inbounds for i in eachindex(agents)
        agent = agents[i]
        if alive(agent.body)
            receptors, s, command = _run_interaction!(agent, percepts[i])
            receptor_vectors[i] = _receptor_vector(receptors)
            Es[i] = command
        else
            receptor_vectors[i] = zeros(Float64, n_receptors(agent.body))
            s = zeros(Float64, n_nodes(agent.reservoir))
            Es[i] = _inactive_command(agent.body)
        end
        spikes[i] = s
        rates[i] = _spike_rate(s)
    end
    remember_receptors!(c.environment, receptor_vectors)

    effects = apply_commands!(c.environment, bodies, Es)
    @inbounds for i in eachindex(bodies)
        body_effects = effects === nothing ? () : effects[i]
        update!(bodies[i], body_effects)
    end
    sync_activity!(c.environment, bodies)
    c.t += 1

    if c.recorder isa Recorder
        _record_ensemble!(c.recorder, c, bodies, percepts, receptor_vectors, spikes, rates, Es)
    end

    return spikes
end

function _step_agent_group!(
    group::AgentGroup{A},
    percepts,
    receptor_vectors,
    spikes,
    rates,
    commands,
) where {A<:Agent}
    agents = group.agents
    @inbounds for (local_index, slot) in enumerate(group.slots)
        agent = agents[local_index]
        if alive(agent.body)
            receptors, s, command = _run_interaction!(agent, percepts[slot])
            receptor_vectors[slot] = _receptor_vector(receptors)
            commands[slot] = command
        else
            receptor_vectors[slot] = zeros(Float64, n_receptors(agent.body))
            s = zeros(Float64, n_nodes(agent.reservoir))
            commands[slot] = _inactive_command(agent.body)
        end
        spikes[slot] = s
        rates[slot] = _spike_rate(s)
    end
    return nothing
end

function _update_agent_group!(group::AgentGroup{A}, effects) where {A<:Agent}
    @inbounds for (local_index, slot) in enumerate(group.slots)
        body_effects = effects === nothing ? () : effects[slot]
        update!(group.agents[local_index].body, body_effects)
    end
    return nothing
end

function _step_grouped!(c::Ensemble, store::GroupedStore)
    bodies = _agent_bodies(store)
    sync_activity!(c.environment, bodies)
    prepare_step!(c.environment, bodies)
    percepts = sample!(c.environment, bodies)
    n = nagents(store)
    length(percepts) == n || throw(DimensionMismatch(
        "environment returned $(length(percepts)) percepts for $(n) agents",
    ))

    receptor_vectors = Vector{Vector{Float64}}(undef, n)
    spikes = Vector{Vector{Float64}}(undef, n)
    rates = Vector{Float64}(undef, n)
    # Heterogeneous command types meet only at this gather boundary; concrete
    # group decoding remains behind `_step_agent_group!`'s function barrier.
    commands = Vector{Any}(undef, n)
    foreach_group(store) do group
        _step_agent_group!(group, percepts, receptor_vectors, spikes, rates, commands)
    end
    remember_receptors!(c.environment, receptor_vectors)

    effects = apply_commands!(c.environment, bodies, commands)
    foreach_group(store) do group
        _update_agent_group!(group, effects)
    end
    sync_activity!(c.environment, bodies)
    c.t += 1

    if c.recorder isa Recorder
        _record_ensemble!(c.recorder, c, bodies, percepts, receptor_vectors, spikes, rates, commands)
    end
    return spikes
end

step!(c::Ensemble{<:Environment,<:HomogeneousStore}) = _step_homogeneous!(c, c.store)
step!(c::Ensemble{<:Environment,<:GroupedStore}) = _step_grouped!(c, c.store)

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
    base = metrics(c.environment, Int(window))
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
        foreach_group(c) do group
            for agent in group_agents(group)
                _apply_postbuild_ablation!(agent.reservoir, sym)
            end
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
