function _composition_namedtuple(values::Dict{Symbol,Any})
    names = Tuple(sort!(collect(keys(values)); by=string))
    return NamedTuple{names}(Tuple(values[name] for name in names))
end

function _composition_body(resolved::ResolvedComposition)
    resolved.body === nothing && return nothing
    return _materialize_registered_body(resolved.body, resolved.body_options)
end

function _composition_seed_ledger(
    evaluation::EvaluationSpec,
    block::Integer,
    trial::Integer,
    agent::Integer,
)
    return (
        topology=derive_seed(evaluation, :topology, block, trial, agent),
        node_state=derive_seed(evaluation, :node_state, block, trial, agent),
        world=derive_seed(evaluation, :world, block, trial),
        body=derive_seed(evaluation, :body, block, trial, agent),
        task=derive_seed(evaluation, :task, block, trial),
        mechanism=derive_seed(evaluation, :mechanism, block, trial, agent),
    )
end

function _build_composition(
    resolved::ResolvedComposition,
    evaluation::EvaluationSpec;
    block::Integer=1,
    trial::Integer=1,
    record=_DEFAULT_RECORD_CHANNELS,
    every::Integer=1,
)
    body = _composition_body(resolved)
    task_options = _composition_namedtuple(resolved.task_options)
    world_seed = _seed_to_int(derive_seed(evaluation, :world, block, trial))
    task_setup = _setup_for_node_count(
        resolved.task,
        resolved.n_nodes;
        seed=world_seed,
        body=body,
        task_options...,
    )
    bodies = task_setup.bodies
    agents = Vector{Agent}(undef, length(bodies))
    ledgers = Vector{NamedTuple}(undef, length(bodies))
    @inbounds for slot in eachindex(bodies)
        body_at_slot = bodies[slot]
        layout = portspec(body_at_slot)
        default_link_p = Float64(get(resolved.parameters, :link_p, 0.1))
        profile = receptor_link_profile(body_at_slot, default_link_p)
        seeds = _composition_seed_ledger(evaluation, block, trial, slot)
        context = NodeBuildContext(
            resolved.n_nodes,
            layout,
            seeds;
            receptor_profile=profile,
        )
        reservoir = resolved.node.build(context, resolved.parameters)
        reservoir isa Reservoir || throw(ArgumentError(
            "node :$(resolved.node.id) returned $(typeof(reservoir)), not Reservoir",
        ))
        agents[slot] = _make_agent(
            reservoir,
            body_at_slot;
            cycle=resolved.interaction_cycle,
        )
        ledgers[slot] = seeds
    end
    recorder = Recorder(enabled=_record_symbols(record), every=Int(every))
    ensemble = Ensemble(agents, task_setup.environment; recorder=recorder)
    return (
        ensemble=ensemble,
        recorder=recorder,
        seed_ledger=Tuple(ledgers),
    )
end

"""
    simulate(composition::CompositionSpec; registry=DEFAULT_REGISTRY, ...)

Resolve and run one explicit composition. Task horizon, replication, resets,
and inferential aggregation belong to `EvaluationSpec`; this convenience method
runs one trial and accepts a temporary `ticks` override for interactive use.
"""
function simulate(
    composition::CompositionSpec;
    registry::RegistrySet=DEFAULT_REGISTRY,
    ticks=nothing,
    seed::Integer=0,
    record=_DEFAULT_RECORD_CHANNELS,
    every::Integer=1,
    window=nothing,
    metrics=nothing,
)
    resolved = resolve_composition(composition, registry)
    tick_count = ticks === nothing ? resolved.task.default_ticks : Int(ticks)
    tick_count > 0 || throw(ArgumentError("simulation ticks must be positive"))
    window_ = window === nothing ? min(tick_count, resolved.task.default_window) : Int(window)
    0 < window_ <= tick_count || throw(ArgumentError(
        "simulation window must lie in 1:ticks",
    ))
    evaluation = EvaluationSpec(horizon=tick_count, root_seed=seed)
    setup = _build_composition(
        resolved,
        evaluation;
        block=1,
        trial=1,
        record=record,
        every=every,
    )
    outcome = rollout!(setup.ensemble, tick_count; window=window_, metrics=metrics)
    base_config = _simulation_config(
        setup.ensemble;
        ticks=tick_count,
        seed=Int(seed),
        record=_record_symbols(record),
        every=Int(every),
        window=window_,
        n_nodes=resolved.n_nodes,
        ablation=:none,
        ablation_notes=(),
        interventions=nothing,
        task_spec=resolved.task,
    )
    config = merge(
        base_config,
        (
            composition=composition.id,
            parameters=_composition_namedtuple(resolved.parameters),
            seed_ledger=setup.seed_ledger,
        ),
    )
    return SimResult(
        setup.recorder,
        outcome,
        resolved.task.name,
        resolved.node.id,
        config,
    )
end

simulate(
    composition::Union{Symbol,AbstractString},
    registry::RegistrySet;
    kwargs...,
) = simulate(composition_spec(registry, composition); registry=registry, kwargs...)

