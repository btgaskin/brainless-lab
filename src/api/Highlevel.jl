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

const _DEFAULT_RECORD_CHANNELS = (:spikes, :rate, :poses, :polarization, :milling)

const _NODE_DEFAULT_N = Dict{Symbol,Int}(
    :falandays => 100,
    :falandays_oosawa => 100,
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
    return SORNReservoir(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); seed=seed, kwargs...)
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
        OosawaDrive(membrane_noise=Float64(membrane_noise), noise_gain=Float64(noise_gain)),
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

# Copy a FalandaysParams with the target learning rate overridden.
function _with_lrate_targ(p::FalandaysParams, value::Real)
    fields = (; (f => getfield(p, f) for f in fieldnames(FalandaysParams))...)
    return FalandaysParams(; fields..., lrate_targ=Float64(value))
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
    drive::Drive=NoDrive(),
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
        FalandaysModel(params, drive, axis, Bool(rectify)),
        connectome,
        FalandaysConnState(wmat),
        FalandaysNodeState(acts, targets, spikes, errors, prev_spikes, source),
        PortSpec(n_receptors_, n_effectors_),
    )
end

# `:falandays_ablated` -- target homeostasis ablated: lrate_targ=0 pins every
# node's target at its init (1.0), so the firing threshold stays fixed at 2.0;
# recurrent weights still learn. Tests the homeostatic-target mechanism.
function _falandays_ablated_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    kwargs...,
)
    options = _kwdict(kwargs)
    base_params = _as_falandays_params(pop!(options, :params, FalandaysParams()))
    pinned = _with_lrate_targ(base_params, 0.0)
    return _falandays_native(n_nodes, n_receptors_, n_effectors_;
                             seed=seed, params=pinned, _kwargs_tuple(options)...)
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
)
    options = _merge_kwdicts(node_kwargs)
    options[:seed] = _sim_seed(seed)
    kwargs = _kwargs_tuple(options)

    try
        return node_ctor(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); kwargs...)
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

function _make_task_collective(
    task_spec::TaskSpec,
    node::Symbol,
    node_ctor;
    seed=0,
    record=Symbol[],
    every::Integer=1,
    n_nodes::Integer=100,
    node_kwargs=NamedTuple(),
    env_kwargs=NamedTuple(),
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
    )
    agent = _make_agent(reservoir, PassthroughBody(), morphology)
    recorder = Recorder(enabled=record, every=every)
    collective = Collective([agent], TaskMedium(env); recorder=recorder)
    return collective, recorder
end

function _make_swarm_collective(
    node::Symbol,
    node_ctor;
    seed=0,
    record=Symbol[],
    every::Integer=1,
    n_agents::Integer=8,
    n_nodes::Integer=100,
    node_kwargs=NamedTuple(),
    swarm_kwargs=NamedTuple(),
)
    swarm_options = _merge_kwdicts(swarm_kwargs)
    swarm_options[:n_agents] = Int(n_agents)
    swarm_options[:n_nodes] = Int(n_nodes)
    swarm_options[:seed] = seed === nothing ? 0 : Int(seed)
    config = SwarmConfig(; _kwargs_tuple(swarm_options)...)
    medium = TorusMedium(config; rng=_sim_rng(seed))

    agents = Vector{Agent}(undef, config.n_agents)
    @inbounds for i in 1:config.n_agents
        body = medium.bodies[i]
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
        )
        agents[i] = _make_agent(reservoir, body, morphology)
    end

    recorder = Recorder(enabled=record, every=every)
    collective = Collective(agents, medium; recorder=recorder)
    return collective, recorder
end

function _medium_config(m::TaskMedium)
    env = m.env
    if hasproperty(env, :box)
        box = getproperty(env, :box)
        return (
            kind=:task,
            env=Symbol(lowercase(string(nameof(typeof(env))))),
            bounds=(0.0, Float64(box.size), 0.0, Float64(box.size)),
            size=Float64(box.size),
        )
    elseif hasproperty(env, :width) && hasproperty(env, :height)
        return (
            kind=:task,
            env=Symbol(lowercase(string(nameof(typeof(env))))),
            bounds=(0.0, Float64(getproperty(env, :width)), 0.0, Float64(getproperty(env, :height))),
            size=nothing,
        )
    end

    return (
        kind=:task,
        env=Symbol(lowercase(string(nameof(typeof(env))))),
        bounds=nothing,
        size=nothing,
    )
end

function _medium_config(m::TorusMedium)
    size = Float64(m.torus.size)
    return (
        kind=:torus,
        bounds=(0.0, size, 0.0, size),
        size=size,
        n_agents=length(m.bodies),
    )
end

_medium_config(m::Medium) = (kind=Symbol(lowercase(string(nameof(typeof(m))))), bounds=nothing, size=nothing)

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

function _simulation_config(c::Collective; ticks::Integer, seed, record, every::Integer, window::Integer, n_nodes::Integer)
    return (
        ticks=Int(ticks),
        seed=seed,
        record=Tuple(record),
        every=Int(every),
        window=Int(window),
        n_agents=length(c.agents),
        n_nodes=Int(n_nodes),
        medium=_medium_config(c.medium),
        network=_network_snapshot(c.agents[1].reservoir),
    )
end

function _build_collective(task::Symbol, node::Symbol; ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, kwargs...)
    options = _kwdict(kwargs)
    record_channels = _record_symbols(record)

    n_agents = haskey(options, :n_agents) ? pop!(options, :n_agents) : nothing
    explicit_n_nodes = haskey(options, :n_nodes) ? pop!(options, :n_nodes) : nothing
    window_arg = haskey(options, :window) ? pop!(options, :window) : nothing
    env_kwargs = haskey(options, :env_kwargs) ? pop!(options, :env_kwargs) : NamedTuple()
    node_kwargs = haskey(options, :node_kwargs) ? pop!(options, :node_kwargs) : NamedTuple()

    swarm_kwargs =
        haskey(options, :swarm_kwargs) ? pop!(options, :swarm_kwargs) :
        haskey(options, :medium_kwargs) ? pop!(options, :medium_kwargs) :
        NamedTuple()

    node_kwargs = _merge_kwdicts(node_kwargs, options)
    n_nodes = _resolve_n_nodes!(node, explicit_n_nodes, node_kwargs)

    node_ctor = resolve_node(node)
    is_swarm = task in (:torus, :swarm) || n_agents !== nothing

    if is_swarm
        n_agents_ = n_agents === nothing ? 8 : Int(n_agents)
        collective, recorder = _make_swarm_collective(
            node,
            node_ctor;
            seed=seed,
            record=record_channels,
            every=every,
            n_agents=n_agents_,
            n_nodes=n_nodes,
            node_kwargs=node_kwargs,
            swarm_kwargs=swarm_kwargs,
        )
        tick_count = ticks === nothing ? 1000 : Int(ticks)
        window = window_arg === nothing ? tick_count : Int(window_arg)
        return (
            collective=collective,
            recorder=recorder,
            task=:torus,
            node=node,
            ticks=tick_count,
            window=window,
            record=record_channels,
            every=Int(every),
            seed=seed,
            n_nodes=n_nodes,
        )
    end

    task_spec = resolve_task(task)
    task_spec isa TaskSpec ||
        throw(ArgumentError("Registered task :$(task) is not a TaskSpec and is not handled by simulate."))
    collective, recorder = _make_task_collective(
        task_spec,
        node,
        node_ctor;
        seed=seed,
        record=record_channels,
        every=every,
        n_nodes=n_nodes,
        node_kwargs=node_kwargs,
        env_kwargs=env_kwargs,
    )
    tick_count = ticks === nothing ? task_spec.default_ticks : Int(ticks)
    window = window_arg === nothing ? min(tick_count, task_spec.default_window) : Int(window_arg)

    return (
        collective=collective,
        recorder=recorder,
        task=task_spec.name,
        node=node,
        ticks=tick_count,
        window=window,
        record=record_channels,
        every=Int(every),
        seed=seed,
        n_nodes=n_nodes,
    )
end

"""
    simulate(task; node=:falandays, ticks=nothing, seed=0, record=..., every=1, kwargs...)

Run a single-agent task such as `:wall`, `:tracking`, `:pong`, or `:cartpole`,
or run a swarm with `simulate(:torus; node=:falandays, n_agents=5)`.
"""
function simulate(task::Symbol; node=:falandays, ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, kwargs...)
    node_sym = Symbol(node)
    setup = _build_collective(task, node_sym; ticks=ticks, seed=seed, record=record, every=every, kwargs...)
    result_metrics = rollout!(setup.collective, setup.ticks; window=setup.window)
    config = _simulation_config(
        setup.collective;
        ticks=setup.ticks,
        seed=setup.seed,
        record=setup.record,
        every=setup.every,
        window=setup.window,
        n_nodes=setup.n_nodes,
    )
    return SimResult(setup.recorder, result_metrics, setup.task, setup.node, config)
end

simulate(task::AbstractString; kwargs...) = simulate(Symbol(task); kwargs...)
