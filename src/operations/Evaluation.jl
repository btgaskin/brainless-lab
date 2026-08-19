"""Explicit initial state retained for audit when an environment exposes one."""
realized_initial_state(::Environment) = nothing
realized_initial_state(environment::PlankCartPoleEnv) = Tuple(environment.state)

struct EvaluationTrial{S<:SimResult,I,L}
    condition::Symbol
    block::Int
    trial::Int
    seeds::L
    initial_state::I
    simulation::S
end

struct EvaluationBatch{T<:EvaluationTarget,R<:ResolvedComposition,E<:Tuple}
    target::T
    resolved::R
    trials::E
end

function _construction_coordinates(
    evaluation::EvaluationSpec,
    block::Integer,
    trial::Integer,
)
    evaluation.construction_scope === :evaluation && return (0, 0)
    evaluation.construction_scope === :block && return (Int(block), 0)
    return (Int(block), Int(trial))
end

function _trial_liveness(metrics)
    hasproperty(metrics, :alive) && return Bool(getproperty(metrics, :alive))
    hasproperty(metrics, :liveness) && return Bool(getproperty(metrics, :liveness))
    return missing
end

function _trial_viability(metrics)
    hasproperty(metrics, :viable) && return Bool(getproperty(metrics, :viable))
    hasproperty(metrics, :achieved) && return Bool(getproperty(metrics, :achieved))
    return missing
end

function _intervention_segment(interventions, first_tick::Integer, last_tick::Integer)
    first_ = Int(first_tick)
    last_ = Int(last_tick)
    first_ <= last_ || return nothing
    segment = Tuple{Int,Symbol}[]
    for item in interventions
        first_ <= item.tick <= last_ || continue
        push!(segment, (item.tick - first_ + 1, item.verb))
    end
    return isempty(segment) ? nothing : segment
end

function _combined_resource_report(reports)
    isempty(reports) && throw(ArgumentError("evaluation trial has no resource reports"))
    total(field) = all(report -> getfield(report, field) !== nothing, reports) ?
        sum(getfield(report, field) for report in reports) : nothing
    return ResourceReport(
        sum(report.dynamic_nodes for report in reports);
        excitatory_nodes=total(:excitatory_nodes),
        inhibitory_nodes=total(:inhibitory_nodes),
        recurrent_edges=total(:recurrent_edges),
        input_edges=total(:input_edges),
        output_edges=total(:output_edges),
    )
end

function _trial_profile_coordinate(simulation::SimResult)
    contract = simulation.config.task_contract
    contract === nothing && return (
        profile_metric=missing,
        profile_value=missing,
        profile_label=missing,
        profile_unit=missing,
        profile_direction=missing,
    )
    protocol = contract.protocol
    hasproperty(protocol, :benchmark_profile) || return (
        profile_metric=missing,
        profile_value=missing,
        profile_label=missing,
        profile_unit=missing,
        profile_direction=missing,
    )
    profile = protocol.benchmark_profile
    required = (:metric, :label, :unit, :direction)
    all(name -> hasproperty(profile, name), required) || throw(ArgumentError(
        "task :$(contract.name) benchmark profile requires metric, label, unit, and direction",
    ))
    metric = Symbol(profile.metric)
    hasproperty(simulation.metrics, metric) || throw(ArgumentError(
        "task :$(contract.name) benchmark profile metric :$(metric) is absent from task metrics",
    ))
    value = Float64(getproperty(simulation.metrics, metric))
    isfinite(value) || throw(ArgumentError(
        "task :$(contract.name) benchmark profile metric :$(metric) must be finite",
    ))
    direction = Symbol(profile.direction)
    direction in (:lower, :higher) || throw(ArgumentError(
        "task :$(contract.name) benchmark profile direction must be :lower or :higher",
    ))
    return (
        profile_metric=metric,
        profile_value=value,
        profile_label=String(profile.label),
        profile_unit=String(profile.unit),
        profile_direction=direction,
    )
end

function _normalized_censoring_summary(rows)
    bounds = Symbol[]
    for row in rows
        :normalized_bound in propertynames(row) || continue
        bound = row.normalized_bound
        ismissing(bound) && continue
        bound in (:none, :floor, :ceiling) || throw(ArgumentError(
            "normalized_bound must be :none, :floor, :ceiling, or missing",
        ))
        push!(bounds, bound)
    end
    n = length(bounds)
    floor_count = count(==(:floor), bounds)
    ceiling_count = count(==(:ceiling), bounds)
    censored_count = floor_count + ceiling_count
    fraction = n == 0 ? missing : censored_count / n
    display = n == 0 ?
        missing :
        "$(floor_count)/$(n) at floor; $(ceiling_count)/$(n) at ceiling"
    return (
        normalized_n=n,
        normalized_floor_count=floor_count,
        normalized_ceiling_count=ceiling_count,
        normalized_censored_count=censored_count,
        normalized_censored_fraction=fraction,
        normalized_censoring=display,
    )
end

function _evaluate_trial(
    target::EvaluationTarget,
    resolved::ResolvedComposition,
    block::Integer,
    trial::Integer;
    registry::RegistrySet,
    model=nothing,
    record=(),
    record_every::Integer=1,
    compute_every=Dict{Symbol,Int}(),
    metrics=nothing,
)
    evaluation = target.evaluation
    construction_block, construction_trial = _construction_coordinates(
        evaluation,
        block,
        trial,
    )
    setup = _build_composition(
        resolved,
        evaluation;
        block=block,
        trial=trial,
        construction_block=construction_block,
        construction_trial=construction_trial,
        topology_key=target.topology_key,
        model=model,
        record=record,
        every=record_every,
        compute_every=compute_every,
    )
    initial_state = realized_initial_state(setup.ensemble.environment)
    warmup_interventions = _intervention_segment(
        target.interventions,
        1,
        evaluation.warmup,
    )
    if evaluation.warmup > 0
        recorder = setup.ensemble.recorder
        setup.ensemble.recorder = nothing
        rollout!(
            setup.ensemble,
            evaluation.warmup;
            window=evaluation.warmup,
            interventions=warmup_interventions,
            intervention_registry=registry,
        )
        setup.ensemble.recorder = recorder
        reset!(recorder)
    end
    scored_ticks = evaluation.horizon - evaluation.warmup
    scored_interventions = _intervention_segment(
        target.interventions,
        evaluation.warmup + 1,
        evaluation.horizon,
    )
    outcome = rollout!(
        setup.ensemble,
        scored_ticks;
        window=scored_ticks,
        metrics=metrics,
        interventions=scored_interventions,
        intervention_registry=registry,
    )
    base_config = _simulation_config(
        setup.ensemble;
        ticks=evaluation.horizon,
        seed=Int(evaluation.root_seed),
        record=_record_symbols(record),
        every=Int(record_every),
        window=scored_ticks,
        n_nodes=resolved.n_nodes,
        ablation=:none,
        ablation_notes=(),
        interventions=Tuple(
            (item.tick, item.verb)
            for item in target.interventions
        ),
        task_spec=resolved.task,
    )
    config = merge(
        base_config,
        (
            composition=target.composition.id,
            condition=target.id,
            block=Int(block),
            trial=Int(trial),
            parameters=_composition_namedtuple(resolved.parameters),
            interface=resolved.interface,
            resources=setup.resources,
            seed_ledger=setup.seed_ledger,
            evaluation=evaluation,
            compute_every=Dict{Symbol,Int}(compute_every),
            executed_scored_ticks=outcome.rollout_ticks,
            terminated=outcome.terminated,
        ),
    )
    simulation = SimResult(
        setup.recorder,
        outcome,
        resolved.task.name,
        resolved.node.id,
        config,
    )
    return EvaluationTrial(
        target.id,
        Int(block),
        Int(trial),
        setup.seed_ledger,
        initial_state,
        simulation,
    )
end

"""
    evaluate(target; registry=DEFAULT_REGISTRY, ...)

Execute every declared block and trial, retaining each raw `SimResult`, named
seed ledger, and realized initial state. `:full` reset is implemented by a
fresh runtime construction whose topology/node-state seeds respect the chosen
construction scope. Stateful `:body_environment` and `:none` policies are
rejected until the composed task declares the corresponding reset hooks.
"""
function evaluate(
    target::EvaluationTarget;
    registry::RegistrySet=DEFAULT_REGISTRY,
    model=nothing,
    record=(),
    record_every::Integer=1,
    compute_every=Dict{Symbol,Int}(),
    metrics=nothing,
)
    evaluation = target.evaluation
    evaluation.reset === :full || throw(ArgumentError(
        "generic evaluation currently requires reset=:full; task-specific state retention " *
        "must be exposed through a declared reset hook before using :$(evaluation.reset)",
    ))
    resolved = resolve_composition(target.composition, registry)
    _validate_target_interventions(target, resolved.node, registry)
    _validate_minimum_scored_ticks(
        resolved.task,
        evaluation.horizon - evaluation.warmup;
        typed_evaluation=true,
    )
    requested_model = model === nothing ? target.model : model
    resolved_model = if requested_model isa Evolution.ModelReference
        resolved.node.design === nothing && throw(ArgumentError(
            "node :$(resolved.node.id) does not declare a searchable design",
        ))
        Evolution.read_model(requested_model, resolved.node.id, resolved.node.design)
    else
        requested_model
    end
    if resolved.node.design !== nothing && resolved_model !== nothing
        resolved_model isa resolved.node.design.model_type || throw(ArgumentError(
            "node :$(resolved.node.id) requires model type " *
            "$(resolved.node.design.model_type), got $(typeof(resolved_model))",
        ))
    elseif resolved_model !== nothing
        throw(ArgumentError(
            "node :$(resolved.node.id) does not accept an explicit node model",
        ))
    end
    count = evaluation.blocks * evaluation.trials_per_block
    trial_results = Vector{EvaluationTrial}(undef, count)
    index = 1
    for block in 1:evaluation.blocks
        for trial in 1:evaluation.trials_per_block
            trial_results[index] = _evaluate_trial(
                target,
                resolved,
                block,
                trial;
                registry=registry,
                model=resolved_model,
                record=record,
                record_every=record_every,
                compute_every=compute_every,
                metrics=metrics,
            )
            index += 1
        end
    end
    return EvaluationBatch(target, resolved, Tuple(trial_results))
end

function trial_row(trial::EvaluationTrial)
    outcome = task_outcome(trial.simulation)
    resources = _combined_resource_report(trial.simulation.config.resources)
    profile = _trial_profile_coordinate(trial.simulation)
    single_ledger = length(trial.seeds) == 1 ? first(trial.seeds) : nothing
    seed(name) = single_ledger !== nothing && hasproperty(single_ledger, name) ?
        getproperty(single_ledger, name) : missing
    return merge((
        condition=trial.condition,
        block=trial.block,
        trial=trial.trial,
        window=Int(trial.simulation.config.window),
        executed_scored_ticks=trial.simulation.config.executed_scored_ticks,
        terminated=trial.simulation.config.terminated,
        aggregate=trial.simulation.config.evaluation.aggregate,
        input_gain=trial.simulation.config.interface.input_gain,
        dynamic_nodes=resources.dynamic_nodes,
        excitatory_nodes=resources.excitatory_nodes,
        inhibitory_nodes=resources.inhibitory_nodes,
        recurrent_edges=resources.recurrent_edges,
        input_edges=resources.input_edges,
        output_edges=resources.output_edges,
        seed_ledger_agents=length(trial.seeds),
        topology_seed=seed(:topology),
        world_seed=seed(:world),
        initial_state=trial.initial_state,
        score_key=outcome === nothing ? missing : outcome.key,
        raw_score=outcome === nothing ? missing : outcome.raw,
        normalized_score=outcome === nothing ? missing : outcome.normalized,
        normalized_bound=outcome === nothing ? missing : outcome.normalized_bound,
        normalization_status=outcome === nothing ? missing : outcome.normalization_status,
        anchor_scored_ticks=outcome === nothing || outcome.anchor_scored_ticks === nothing ?
            missing : outcome.anchor_scored_ticks,
        viable=_trial_viability(trial.simulation.metrics),
        liveness=_trial_liveness(trial.simulation.metrics),
    ), profile)
end

trial_table(batch::EvaluationBatch) = [trial_row(trial) for trial in batch.trials]
