using Random

"""
    SimResult

High-level simulation output. `recorder` stores sampled channels for plotting,
`metrics` stores task or swarm diagnostics, and `task`/`node` retain the
registered symbols that produced the run.
"""
struct SimResult{R,M,C}
    recorder::R
    metrics::M
    task::Symbol
    node::Symbol
    config::C
end

function view(sim::SimResult, sym::Union{Symbol,AbstractString}; kwargs...)
    return resolve_view(Symbol(sym))(sim; kwargs...)
end

function view(rec::Recorder, sym::Union{Symbol,AbstractString}; kwargs...)
    return resolve_view(Symbol(sym))(rec; kwargs...)
end

const _DEFAULT_RECORD_CHANNELS = (:spikes, :rate, :poses, :polarization, :milling)

const _NODE_DEFAULT_N = Dict{Symbol,Int}(
    :falandays => 100,
    :falandays_oosawa => 100,
    :falandays_dendritic => 100,
    :falandays_spatial => 100,
    :falandays_delayed => 100,
    :compartmental_dense => 60,
    :compartmental_structured => 60,
)

"""
    variants()

Return the registered high-level node variant symbols.
"""
variants() = sort!(collect(keys(NODES)))

"""
    tasks()

Return the registered high-level task symbols.
"""
tasks() = sort!(collect(keys(TASKS)))

function _record_symbols(record)
    record === nothing && return Symbol[]
    record isa Symbol && return [record]
    return Symbol.(collect(record))
end

function _kwdict(kwargs)
    out = Dict{Symbol,Any}()
    for (key, value) in pairs(kwargs)
        out[Symbol(key)] = value
    end
    return out
end

function _merge_kwdicts(args...)
    out = Dict{Symbol,Any}()
    for arg in args
        arg === nothing && continue
        for (key, value) in pairs(arg)
            out[Symbol(key)] = value
        end
    end
    return out
end

function _kwargs_tuple(dict::Dict{Symbol,Any})
    isempty(dict) && return NamedTuple()
    keys_ = Tuple(keys(dict))
    values_ = Tuple(dict[key] for key in keys_)
    return NamedTuple{keys_}(values_)
end

_sim_seed(seed, offset::Integer=0) = seed === nothing ? nothing : Int(seed) + Int(offset)
_sim_rng(seed) = seed === nothing ? MersenneTwister() : MersenneTwister(Int(seed))

_default_node_count(node::Symbol) = get(_NODE_DEFAULT_N, node, 100)

const _FALANDAYS_PARAM_KEYS = Set(fieldnames(FalandaysParams))
const _DRIVE_PARAM_KEYS = Set{Symbol}((:membrane_noise, :noise_gain))

function _is_falandays_node(node::Symbol)
    try
        return genome_type(node) === FalandaysParams
    catch
        return false
    end
end

function _is_compartmental_node(node::Symbol)
    try
        T = genome_type(node)
        return T isa Type && T <: AbstractCompartmental
    catch
        return false
    end
end

function _take_falandays_params!(options::Dict{Symbol,Any})
    has_updates = false
    params = haskey(options, :params) ? _as_falandays_params(pop!(options, :params)) : FalandaysParams()
    updates = Dict{Symbol,Any}()
    for key in fieldnames(FalandaysParams)
        if haskey(options, key)
            updates[key] = pop!(options, key)
            has_updates = true
        end
    end
    return has_updates ? _falandays_params_with(params; updates...) : params
end

function _normalize_drive_options!(options::Dict{Symbol,Any})
    has_drive_params = any(key -> haskey(options, key), _DRIVE_PARAM_KEYS)
    has_drive = haskey(options, :drive)
    (has_drive || has_drive_params) || return options

    membrane_noise = haskey(options, :membrane_noise) ? Float64(pop!(options, :membrane_noise)) : 0.0
    noise_gain = haskey(options, :noise_gain) ? Float64(pop!(options, :noise_gain)) : 0.0
    drive = has_drive ? pop!(options, :drive) : :oosawa
    options[:drive] = _resolve_drive_instance(drive; membrane_noise=membrane_noise, noise_gain=noise_gain)
    return options
end

function _normalize_node_options!(node::Symbol, options::Dict{Symbol,Any})
    if _is_falandays_node(node)
        options[:params] = _take_falandays_params!(options)
        _normalize_drive_options!(options)
    elseif node == :sorn
        # SORN accepts learn_on directly; leave it in place for freeze_plasticity.
        _normalize_drive_options!(options)
    end
    return options
end

_ablation_symbol(::Nothing) = :none
_ablation_symbol(name::Symbol) = name
_ablation_symbol(name::AbstractString) = Symbol(name)
_ablation_symbol(::Type{T}) where {T<:Intervention} = Symbol(nameof(T))
_ablation_symbol(i::Intervention) = Symbol(nameof(typeof(i)))

function _is_swarm_task(task::Symbol, n_agents)
    return task in (:torus, :swarm, :forage) || n_agents !== nothing
end

function _ablation_notes(sym::Symbol, node::Symbol, task::Symbol, is_swarm::Bool)
    sym === :none && return String[]
    notes = String[]
    if sym === :freeze_plasticity
        if _is_falandays_node(node) || node === :sorn
            push!(notes, "freeze_plasticity applied: learn_on=false")
        elseif _is_compartmental_node(node)
            push!(notes, "freeze_plasticity no-op: compartmental nodes have no online plasticity")
        else
            push!(notes, "freeze_plasticity no-op for node :$(node)")
        end
    elseif sym === :zero_recurrent
        if _is_falandays_node(node) || _is_compartmental_node(node)
            push!(notes, "zero_recurrent applied: recurrent weights removed at build")
        else
            push!(notes, "zero_recurrent no-op for node :$(node)")
        end
    elseif sym === :clamp_target
        if _is_falandays_node(node)
            push!(notes, "clamp_target applied: lrate_targ=0")
        else
            push!(notes, "clamp_target no-op: target homeostasis is Falandays-specific")
        end
    elseif sym === :disable_vision
        if is_swarm
            push!(notes, "disable_vision applied: conspecific_vision=false")
        else
            push!(notes, "disable_vision no-op: task :$(task) is not a swarm task")
        end
    elseif sym in (:reset_dendrites, :no_soma_back, :no_hillock_back)
        if _is_compartmental_node(node)
            push!(notes, "$(sym) applied: compartmental intervention")
        else
            push!(notes, "$(sym) no-op: compartmental-specific ablation")
        end
    else
        push!(notes, "ablation :$(sym) passed through registered intervention hooks")
    end
    return notes
end

function _prepare_ablation_options!(node::Symbol, task::Symbol, is_swarm::Bool, node_options::Dict{Symbol,Any}, swarm_options::Dict{Symbol,Any}, ablation)
    sym = _ablation_symbol(ablation)
    sym === :none && return sym
    resolve_ablation(sym)

    if sym === :freeze_plasticity
        if _is_falandays_node(node)
            node_options[:learn_on] = false
        elseif node === :sorn
            node_options[:learn_on] = false
        end
    elseif sym === :clamp_target
        _is_falandays_node(node) && (node_options[:lrate_targ] = 0.0)
    elseif sym === :disable_vision
        is_swarm && (swarm_options[:conspecific_vision] = false)
    elseif sym in (:zero_recurrent, :reset_dendrites, :no_soma_back, :no_hillock_back)
        if _is_compartmental_node(node)
            node_options[:ablation] = sym
        end
    end

    return sym
end

function _apply_postbuild_ablation!(reservoir::Reservoir, sym::Symbol)
    sym === :none && return reservoir
    if sym === :zero_recurrent
        (reservoir isa FalandaysReservoir || reservoir isa CompartmentalReservoir) &&
            apply!(ZeroRecurrent(), reservoir)
    elseif sym === :freeze_plasticity
        reservoir isa FalandaysReservoir && apply!(FreezePlasticity(), reservoir)
    elseif sym === :clamp_target
        reservoir isa FalandaysReservoir && apply!(ClampTarget(), reservoir)
    end
    return reservoir
end

function _resolve_n_nodes!(node::Symbol, explicit_n_nodes, node_kwargs::Dict{Symbol,Any})
    node_kw_n = haskey(node_kwargs, :n_nodes) ? pop!(node_kwargs, :n_nodes) : nothing
    explicit_n_nodes !== nothing && return Int(explicit_n_nodes)
    node_kw_n !== nothing && return Int(node_kw_n)
    return _default_node_count(node)
end

function _falandays_native(n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer; seed=nothing, kwargs...)
    return FalandaysReservoir(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); seed=seed, kwargs...)
end

function _sorn_native(n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer; seed=nothing, kwargs...)
    options = _kwdict(kwargs)
    if haskey(options, :params)
        params = _as_sorn_params(pop!(options, :params))
        for name in fieldnames(SORNParams)
            haskey(options, name) || (options[name] = getfield(params, name))
        end
    end
    return SORNReservoir(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); seed=seed, _kwargs_tuple(options)...)
end

function _falandays_oosawa_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    membrane_noise::Real=0.0,
    noise_gain::Real=0.8,
    kwargs...,
)
    options = _kwdict(kwargs)
    drive = pop!(
        options,
        :drive,
        :oosawa,
    )
    drive = _resolve_drive_instance(
        drive;
        membrane_noise=Float64(membrane_noise),
        noise_gain=Float64(noise_gain),
    )
    return FalandaysReservoir(
        Int(n_nodes),
        Int(n_receptors_),
        Int(n_effectors_);
        seed=seed,
        drive=drive,
        _kwargs_tuple(options)...,
    )
end

# `:falandays_dendritic` — the homeostatic Falandays neuron with per-dendrite
# eligibility-tag plasticity and a logistic endogenous drive (port of v0.2's
# `DendriticReservoir`). Distinct from the biophysical `compartmental_*` nodes.
# `dend_drive` defaults active so dendritic spikes occur and widen the plastic
# gate; `eligibility_only=true` keeps the soma behaving like the base node.
function _falandays_dendritic_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    n_dendrites::Integer=4,
    soma_drive::Real=0.0,
    dend_drive::Real=0.6,
    drive_floor::Real=0.0,
    drive_d0::Real=1.0,
    drive_w::Real=0.4,
    dend_threshold::Real=1.0,
    eligibility_only::Bool=true,
    kwargs...,
)
    options = _kwdict(kwargs)
    return DendriticReservoir(
        Int(n_nodes),
        Int(n_receptors_),
        Int(n_effectors_);
        seed=seed,
        n_dendrites=Int(n_dendrites),
        soma_drive=Float64(soma_drive),
        dend_drive=Float64(dend_drive),
        drive_floor=Float64(drive_floor),
        drive_d0=Float64(drive_d0),
        drive_w=Float64(drive_w),
        dend_threshold=Float64(dend_threshold),
        eligibility_only=Bool(eligibility_only),
        _kwargs_tuple(options)...,
    )
end

# `:falandays_noisy` — the base reservoir wrapped with sensory input noise
# (Uniform(±sensory_noise), clip >= 0). Distinct from `:falandays_oosawa`, which
# is membrane noise. `sensory_noise` defaults to the v0.2 body value of 0.1.
function _falandays_noisy_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    sensory_noise::Real=0.1,
    kwargs...,
)
    inner = _falandays_native(n_nodes, n_receptors_, n_effectors_; seed=seed, kwargs...)
    return NoisyInput(inner; sensory_noise=Float64(sensory_noise), seed=(seed === nothing ? 0 : Int(seed)))
end

# `:falandays_extended` — the paper's extended model: the base homeostatic reservoir
# with sensory input noise, Watts–Strogatz small-world recurrent wiring, and Dale's
# law (excitatory/inhibitory sign). Same neuron update as base; a richer substrate.
function _falandays_extended_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    sensory_noise::Real=0.1,
    topology=:watts_strogatz,
    sign=:dale,
    kwargs...,
)
    inner = _falandays_native(n_nodes, n_receptors_, n_effectors_;
                              seed=seed, topology=topology, sign=sign, kwargs...)
    return NoisyInput(inner; sensory_noise=Float64(sensory_noise), seed=(seed === nothing ? 0 : Int(seed)))
end

function _falandays_hemispheric_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    callosum_density::Real=0.0,
    contralateral=true,
    p0::Real=0.5,
    lambda::Real=0.3,
    link_p::Real=0.1,
    extent::Real=1.0,
    params=FalandaysParams(),
    drive=NoDrive(),
    sign=Unsigned(),
    rectify=true,
    noise_source=nothing,
    kwargs...,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_receptors_ >= 2 || throw(ArgumentError("hemispheric node needs >= 2 receptors to split left/right"))
    n_effectors_ >= 2 || throw(ArgumentError("hemispheric node needs >= 2 effectors to split left/right"))
    n_nodes >= 2 || throw(ArgumentError("hemispheric node needs >= 2 nodes"))

    params = _as_falandays_params(params)
    input_weight, inhibitory_frac = _spatial_native_options(params, kwargs)

    rng = _rng_from_seed(seed)
    axis = _native_axis(sign, n_nodes, rng, inhibitory_frac)
    connectome = build_hemispheric_connectome(
        n_nodes,
        n_receptors_,
        n_effectors_;
        rng=rng,
        p0=p0,
        lambda=lambda,
        link_p=link_p,
        extent=extent,
        callosum_density=callosum_density,
        contralateral=Bool(contralateral),
        weight_init_std=params.weight_init_std,
        input_weight=input_weight,
    )

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source
    wmat = copy(connectome.wmat0)
    acts = zeros(Float64, n_nodes)
    targets = ones(Float64, n_nodes)
    spikes = zeros(Float64, n_nodes)
    errors = zeros(Float64, n_nodes)
    prev_spikes = zeros(Float64, n_nodes)

    return ReservoirInstance(
        FalandaysModel(params, _resolve_drive_instance(drive), axis, Bool(rectify)),
        connectome,
        FalandaysConnState(wmat),
        FalandaysNodeState(acts, targets, spikes, errors, prev_spikes, source),
        PortSpec(n_receptors_, n_effectors_),
    )
end

# `:falandays_ablated` is the packaged node preset for the canonical
# `clamp_target` intervention: lrate_targ=0 pins every node's target at its
# init (1.0), so the firing threshold stays fixed at 2.0; recurrent weights
# still learn.
function _falandays_ablated_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    kwargs...,
)
    options = _kwdict(kwargs)
    reservoir = _falandays_native(n_nodes, n_receptors_, n_effectors_;
                                  seed=seed, _kwargs_tuple(options)...)
    return apply!(ClampTarget(), reservoir)
end

function _native_compartmental_wiring(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    mode::Symbol,
    link_p::Real=0.1,
    rho::Real=0.2,
    k_rec=nothing,
    k_in=nothing,
    output_fanout=nothing,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_nodes >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    link_p_ = k_rec === nothing ? Float64(link_p) : Float64(Int(k_rec)) / Float64(max(n_nodes - 1, 1))
    K_rec_ = min(n_nodes - 1, max(1, round(Int, link_p_ * (n_nodes - 1))))
    rho_ = k_in === nothing ? Float64(rho) : Float64(Int(k_in)) / Float64(max(K_rec_, 1))

    return build_wiring(
        n_nodes,
        seed;
        link_p=link_p_,
        n_receptors=n_receptors_,
        n_effectors=n_effectors_,
        rho=rho_,
        mode=mode,
    )
end

function _randomize_compartmental_state!(r::CompartmentalReservoir, rng::AbstractRNG, scale::Real)
    scale = Float64(scale)
    scale <= 0.0 && return r

    r.dend_y .= scale .* randn(rng, size(r.dend_y)...)
    r.soma_y .= scale .* randn(rng, size(r.soma_y)...)
    r.V .= 0.5 .* rand(rng, length(r.V))
    r.spike_buffer .= Float64.(rand(rng, length(r.spike_buffer)) .< 0.03)
    copyto!(r.prev_spike, r.spike_buffer)
    copyto!(r.prev_soma_y, r.soma_y)
    return r
end

function _resolve_compartmental_intervention(ablation, intervention)
    intervention !== nothing && return _compartmental_intervention(intervention)
    ablation === nothing && return nothing
    return _compartmental_intervention(ablation)
end

function _compartmental_native(
    genome_type::Type{<:AbstractCompartmental},
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    raw=nothing,
    raw_scale::Real=0.25,
    genome=nothing,
    wiring=nothing,
    link_p::Real=0.1,
    rho::Real=0.2,
    k_rec=nothing,
    k_in=nothing,
    output_fanout=nothing,
    init_random::Bool=true,
    state_scale::Real=0.05,
    dt::Real=1.0,
    hill_tau::Real=HILL_TAU,
    hill_reset::Real=HILL_RESET,
    ablation=nothing,
    intervention=nothing,
    kwargs...,
)
    rng = _sim_rng(seed)
    mode = _compartmental_mode(genome_type)

    genome_ =
        genome === nothing ?
        unpack_params(genome_type, raw === nothing ? Float64(raw_scale) .* randn(rng, paramdim(genome_type)) : raw) :
        genome

    wiring_ =
        wiring === nothing ?
        _native_compartmental_wiring(
            n_nodes,
            n_receptors_,
            n_effectors_;
            seed=seed,
            mode=mode,
            link_p=link_p,
            rho=rho,
            k_rec=k_rec,
            k_in=k_in,
            output_fanout=output_fanout,
        ) :
        wiring

    reservoir = CompartmentalReservoir(
        genome_,
        wiring_;
        dt=dt,
        hill_tau=hill_tau,
        hill_reset=hill_reset,
        intervention=_resolve_compartmental_intervention(ablation, intervention),
    )
    init_random && _randomize_compartmental_state!(reservoir, rng, state_scale)
    return reservoir
end

function _compartmental_dense_native(args...; kwargs...)
    return _compartmental_native(DenseCompartmental, args...; kwargs...)
end

function _compartmental_structured_native(args...; kwargs...)
    return _compartmental_native(StructuredCompartmental, args...; kwargs...)
end

function _build_reservoir(
    node::Symbol,
    node_ctor,
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    node_kwargs=NamedTuple(),
    ablation=:none,
)
    options = _merge_kwdicts(node_kwargs)
    _normalize_node_options!(node, options)
    options[:seed] = _sim_seed(seed)
    kwargs = _kwargs_tuple(options)

    try
        reservoir = node_ctor(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); kwargs...)
        return _apply_postbuild_ablation!(reservoir, Symbol(ablation))
    catch err
        msg = "Registered node :$(node) must accept (n_nodes, n_receptors, n_effectors; seed, kwargs...). Original error: $(sprint(showerror, err))"
        throw(ArgumentError(msg))
    end
end

function _validate_agent_ports(reservoir::Reservoir, body::Body, morphology::Morphology)
    spec = portspec(morphology)
    reservoir_receptors = n_receptors(reservoir)
    reservoir_effectors = n_effectors(reservoir)
    morphology_receptors = n_receptors(spec)
    morphology_effectors = n_effectors(spec)

    if reservoir_receptors != morphology_receptors || reservoir_effectors != morphology_effectors
        msg =
            "Agent port mismatch for $(typeof(body)) / $(typeof(morphology)): " *
            "reservoir has ($(reservoir_receptors), $(reservoir_effectors)) " *
            "but morphology expects ($(morphology_receptors), $(morphology_effectors))"
        throw(DimensionMismatch(msg))
    end

    return nothing
end

function _make_agent(reservoir::Reservoir, body::Body, morphology::Morphology)
    _validate_agent_ports(reservoir, body, morphology)
    return Agent(reservoir, body)
end

function _resolve_task_body(body)
    body isa Body && return body
    ctor =
        body isa Symbol ? resolve_body(body) :
        body isa AbstractString ? resolve_body(Symbol(body)) :
        body
    if applicable(ctor)
        body_obj = ctor()
        body_obj isa Body ||
            throw(ArgumentError("task body constructor returned $(typeof(body_obj)), not a Body"))
        return body_obj
    end
    throw(ArgumentError("task body must be a Body instance, registered body symbol, or zero-argument Body constructor"))
end

function _make_task_ensemble(
    task_spec::TaskSpec,
    node::Symbol,
    node_ctor;
    seed=0,
    record=Symbol[],
    every::Integer=1,
    n_nodes::Integer=100,
    node_kwargs=NamedTuple(),
    env_kwargs=NamedTuple(),
    body=:passthrough,
    ablation=:none,
)
    env_options = _kwargs_tuple(_merge_kwdicts(env_kwargs))
    env = make_env(task_spec; rng=_sim_rng(seed), env_options...)
    morphology = default_morphology(env)
    spec = portspec(morphology)
    reservoir = _build_reservoir(
        node,
        node_ctor,
        n_nodes,
        n_receptors(spec),
        n_effectors(spec);
        seed=seed,
        node_kwargs=node_kwargs,
        ablation=ablation,
    )
    agent = _make_agent(reservoir, _resolve_task_body(body), morphology)
    recorder = Recorder(enabled=record, every=every)
    ensemble = Ensemble([agent], TaskEnvironment(env); recorder=recorder)
    return ensemble, recorder
end

function _make_swarm_ensemble(
    node::Symbol,
    node_ctor;
    seed=0,
    record=Symbol[],
    every::Integer=1,
    n_agents::Integer=8,
    n_nodes::Integer=100,
    node_kwargs=NamedTuple(),
    swarm_kwargs=NamedTuple(),
    forage::Bool=false,
    body=:ven,
    ablation=:none,
)
    swarm_options = _merge_kwdicts(swarm_kwargs)
    swarm_options[:n_agents] = Int(n_agents)
    swarm_options[:n_nodes] = Int(n_nodes)
    swarm_options[:seed] = seed === nothing ? 0 : Int(seed)
    config = SwarmConfig(; _kwargs_tuple(swarm_options)...)
    environment = forage ? ForageEnvironment(config; rng=_sim_rng(seed), body=body) : TorusEnvironment(config; rng=_sim_rng(seed), body=body)

    agents = Vector{Agent}(undef, config.n_agents)
    @inbounds for i in 1:config.n_agents
        body = environment.bodies[i]
        morphology = default_morphology(body)
        spec = portspec(morphology)
        reservoir = _build_reservoir(
            node,
            node_ctor,
            config.n_nodes,
            n_receptors(spec),
            n_effectors(spec);
            seed=_sim_seed(seed, i - 1),
            node_kwargs=node_kwargs,
            ablation=ablation,
        )
        agents[i] = _make_agent(reservoir, body, morphology)
    end

    recorder = Recorder(enabled=record, every=every)
    ensemble = Ensemble(agents, environment; recorder=recorder)
    return ensemble, recorder
end

_environment_size(::TaskWorld) = nothing
_environment_size(env::WallEnv) = Float64(env.box.size)

function _environment_config(m::TaskEnvironment)
    world = m.world
    return (
        kind=:task,
        world=Symbol(lowercase(string(nameof(typeof(world))))),
        bounds=bounds(world),
        size=_environment_size(world),
    )
end

function _environment_config(m::TorusEnvironment)
    size = Float64(m.torus.size)
    return (
        kind=:torus,
        bounds=(0.0, size, 0.0, size),
        size=size,
        n_agents=length(m.bodies),
        vision_range=m.config.vision_range,
    )
end

function _environment_config(m::ForageEnvironment)
    size = Float64(m.torus.size)
    return (
        kind=:forage,
        bounds=(0.0, size, 0.0, size),
        size=size,
        n_agents=length(m.bodies),
        vision_range=m.config.vision_range,
        source_position=m.source_position,
        source_gain=Float64(m.config.source_gain),
        signalling=Bool(m.config.signalling),
        signal_range=Float64(m.config.signal_range),
        signal_gain=Float64(m.config.signal_gain),
        capture_radius=Float64(m.config.capture_radius),
        conspecific_vision=Bool(m.config.conspecific_vision),
    )
end

_environment_config(m::Environment) = (kind=Symbol(lowercase(string(nameof(typeof(m))))), bounds=nothing, size=nothing)

function _network_snapshot(r::FalandaysReservoir)
    return (
        kind=:falandays,
        adjacency=Float64.(r.recurrent_mask),
        state=copy(r.acts),
        spikes=copy(r.spikes),
    )
end

function _network_snapshot(r::CompartmentalReservoir)
    n = r.wiring.N
    adjacency = zeros(Float64, n, n)
    @inbounds for dst in 1:n, src0 in r.wiring.node_sources[dst, :]
        if 0 <= src0 < n
            adjacency[src0 + 1, dst] = 1.0
        end
    end
    return (
        kind=:compartmental,
        adjacency=adjacency,
        state=copy(r.V),
        spikes=copy(r.spike_buffer),
    )
end

_network_snapshot(::Reservoir) = nothing

const _SWARM_ENVIRONMENT_KWARGS = Set{Symbol}((
    :space_size,
    :sens_agent_dist,
    :vision_range,
    :sensory_noise,
    :sensory_scaling,
    :visual_coupling,
    :physical_coupling,
    :conspecific_vision,
    :source_position,
    :source_gain,
    :signalling,
    :signal_range,
    :signal_gain,
    :capture_radius,
    :ven,
    :record_inputs,
))

function _extract_swarm_environment_kwargs!(options::Dict{Symbol,Any}, swarm_kwargs)
    out = _merge_kwdicts(swarm_kwargs)
    for key in _SWARM_ENVIRONMENT_KWARGS
        if haskey(options, key)
            out[key] = pop!(options, key)
        end
    end
    return out
end

function _simulation_config(
    c::Ensemble;
    ticks::Integer,
    seed,
    record,
    every::Integer,
    window::Integer,
    n_nodes::Integer,
    ablation::Symbol=:none,
    ablation_notes=(),
)
    return (
        ticks=Int(ticks),
        seed=seed,
        record=Tuple(record),
        every=Int(every),
        window=Int(window),
        n_agents=length(c.agents),
        n_nodes=Int(n_nodes),
        environment=_environment_config(c.environment),
        network=_network_snapshot(c.agents[1].reservoir),
        ablation=ablation,
        ablation_notes=Tuple(ablation_notes),
    )
end

function _build_ensemble(task::Symbol, node::Symbol; ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, kwargs...)
    options = _kwdict(kwargs)
    record_channels = _record_symbols(record)

    n_agents = haskey(options, :n_agents) ? pop!(options, :n_agents) : nothing
    explicit_n_nodes =
        haskey(options, :n_nodes) ? pop!(options, :n_nodes) :
        haskey(options, :N) ? pop!(options, :N) :
        nothing
    window_arg = haskey(options, :window) ? pop!(options, :window) : nothing
    env_kwargs = haskey(options, :env_kwargs) ? pop!(options, :env_kwargs) : NamedTuple()
    node_kwargs = haskey(options, :node_kwargs) ? pop!(options, :node_kwargs) : NamedTuple()
    body = haskey(options, :body) ? pop!(options, :body) : nothing
    ablation_arg = haskey(options, :ablation) ? pop!(options, :ablation) : nothing

    swarm_kwargs =
        haskey(options, :swarm_kwargs) ? pop!(options, :swarm_kwargs) :
        haskey(options, :environment_kwargs) ? pop!(options, :environment_kwargs) :
        NamedTuple()

    is_swarm = _is_swarm_task(task, n_agents)
    if is_swarm
        swarm_kwargs = _extract_swarm_environment_kwargs!(options, swarm_kwargs)
    end

    node_kwargs = _merge_kwdicts(node_kwargs, options)
    swarm_options = _merge_kwdicts(swarm_kwargs)
    ablation_sym = _prepare_ablation_options!(node, task, is_swarm, node_kwargs, swarm_options, ablation_arg)
    ablation_notes = _ablation_notes(ablation_sym, node, task, is_swarm)
    n_nodes = _resolve_n_nodes!(node, explicit_n_nodes, node_kwargs)

    node_ctor = resolve_node(node)

    if is_swarm
        n_agents_ = n_agents === nothing ? 8 : Int(n_agents)
        forage = task == :forage
        ensemble, recorder = _make_swarm_ensemble(
            node,
            node_ctor;
            seed=seed,
            record=record_channels,
            every=every,
            n_agents=n_agents_,
            n_nodes=n_nodes,
            node_kwargs=node_kwargs,
            swarm_kwargs=swarm_options,
            forage=forage,
            body=body === nothing ? :ven : body,
            ablation=ablation_sym,
        )
        tick_count = ticks === nothing ? 1000 : Int(ticks)
        window = window_arg === nothing ? tick_count : Int(window_arg)
        result_task = forage ? :forage : :torus
        return (
            ensemble=ensemble,
            recorder=recorder,
            task=result_task,
            node=node,
            ticks=tick_count,
            window=window,
            record=record_channels,
            every=Int(every),
            seed=seed,
            n_nodes=n_nodes,
            ablation=ablation_sym,
            ablation_notes=Tuple(ablation_notes),
        )
    end

    task_spec = resolve_task(task)
    task_spec isa TaskSpec ||
        throw(ArgumentError("Registered task :$(task) is not a TaskSpec and is not handled by simulate."))
    ensemble, recorder = _make_task_ensemble(
        task_spec,
        node,
        node_ctor;
        seed=seed,
        record=record_channels,
        every=every,
        n_nodes=n_nodes,
        node_kwargs=node_kwargs,
        env_kwargs=env_kwargs,
        body=body === nothing ? :passthrough : body,
        ablation=ablation_sym,
    )
    tick_count = ticks === nothing ? task_spec.default_ticks : Int(ticks)
    window = window_arg === nothing ? min(tick_count, task_spec.default_window) : Int(window_arg)

    return (
        ensemble=ensemble,
        recorder=recorder,
        task=task_spec.name,
        node=node,
        ticks=tick_count,
        window=window,
        record=record_channels,
        every=Int(every),
        seed=seed,
        n_nodes=n_nodes,
        ablation=ablation_sym,
        ablation_notes=Tuple(ablation_notes),
    )
end

"""
    simulate(task; node=:falandays, ticks=nothing, seed=0, record=..., every=1, kwargs...)

Run a single-agent task such as `:wall`, `:tracking`, `:pong`, or `:cartpole`,
or run a swarm with `simulate(:torus; node=:falandays, n_agents=5)`.
"""
function simulate(task::Symbol; node=:falandays, ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, metrics=nothing, kwargs...)
    node_sym = Symbol(node)
    setup = _build_ensemble(task, node_sym; ticks=ticks, seed=seed, record=record, every=every, kwargs...)
    result_metrics = rollout!(setup.ensemble, setup.ticks; window=setup.window, metrics=metrics)
    config = _simulation_config(
        setup.ensemble;
        ticks=setup.ticks,
        seed=setup.seed,
        record=setup.record,
        every=setup.every,
        window=setup.window,
        n_nodes=setup.n_nodes,
        ablation=setup.ablation,
        ablation_notes=setup.ablation_notes,
    )
    return SimResult(setup.recorder, result_metrics, setup.task, setup.node, config)
end

simulate(task::AbstractString; kwargs...) = simulate(Symbol(task); kwargs...)
