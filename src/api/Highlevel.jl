using Random

struct SimResult{R,M,C}
    recorder::R
    metrics::M
    task::Symbol
    node::Symbol
    config::C
end

const _DEFAULT_RECORD_CHANNELS = (:spikes, :rate, :poses)

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

function _build_reservoir(node_ctor, n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer; seed=0, node_kwargs=NamedTuple())
    options = _merge_kwdicts(node_kwargs)
    options[:seed] = _sim_seed(seed)
    kwargs = _kwargs_tuple(options)

    try
        return node_ctor(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); kwargs...)
    catch err
        msg = "simulate expects registered node :$(node_ctor) to accept (n_nodes, n_receptors, n_effectors; seed, kwargs...)."
        throw(ArgumentError(msg))
    end
end

function _node_count(default_count, node_kwargs)
    options = _merge_kwdicts(node_kwargs)
    haskey(options, :n_nodes) && return Int(pop!(options, :n_nodes))
    return Int(default_count)
end

function _make_task_collective(task_spec::TaskSpec, node_ctor; seed=0, record=Symbol[], every::Integer=1, n_nodes::Integer=250, node_kwargs=NamedTuple(), env_kwargs=NamedTuple())
    env_options = _kwargs_tuple(_merge_kwdicts(env_kwargs))
    env = make_env(task_spec; rng=_sim_rng(seed), env_options...)
    reservoir = _build_reservoir(
        node_ctor,
        n_nodes,
        task_spec.n_receptors,
        task_spec.n_effectors;
        seed=seed,
        node_kwargs=node_kwargs,
    )
    agent = Agent(reservoir, PassthroughBody())
    recorder = Recorder(enabled=record, every=every)
    collective = Collective([agent], TaskMedium(env); recorder=recorder)
    return collective, recorder
end

function _make_swarm_collective(node_ctor; seed=0, record=Symbol[], every::Integer=1, n_agents::Integer=8, n_nodes::Integer=250, node_kwargs=NamedTuple(), swarm_kwargs=NamedTuple())
    swarm_options = _merge_kwdicts(swarm_kwargs)
    swarm_options[:n_agents] = Int(n_agents)
    swarm_options[:n_nodes] = Int(n_nodes)
    swarm_options[:seed] = seed === nothing ? 0 : Int(seed)
    config = SwarmConfig(; _kwargs_tuple(swarm_options)...)
    medium = TorusMedium(config; rng=_sim_rng(seed))

    agents = Vector{Agent}(undef, config.n_agents)
    @inbounds for i in 1:config.n_agents
        reservoir = _build_reservoir(
            node_ctor,
            config.n_nodes,
            64,
            3;
            seed=_sim_seed(seed, i - 1),
            node_kwargs=node_kwargs,
        )
        agents[i] = Agent(reservoir, medium.bodies[i])
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
    n_agents = pop!(options, :n_agents, nothing)
    n_nodes = Int(pop!(options, :n_nodes, 250))
    window_arg = pop!(options, :window, nothing)
    env_kwargs = pop!(options, :env_kwargs, NamedTuple())
    node_kwargs = pop!(options, :node_kwargs, NamedTuple())
    swarm_kwargs = pop!(options, :swarm_kwargs, pop!(options, :medium_kwargs, NamedTuple()))
    node_kwargs = _merge_kwdicts(node_kwargs, options)

    node_ctor = resolve_node(node)
    is_swarm = task == :swarm || n_agents !== nothing

    if is_swarm
        n_agents_ = n_agents === nothing ? 8 : Int(n_agents)
        collective, recorder = _make_swarm_collective(
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
            task=:swarm,
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
    collective, recorder = _make_task_collective(
        task_spec,
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

function simulate(task::Symbol; node::Symbol=:falandays, ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, kwargs...)
    setup = _build_collective(task, node; ticks=ticks, seed=seed, record=record, every=every, kwargs...)
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
