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

function _evaluate_trial(
    target::EvaluationTarget,
    resolved::ResolvedComposition,
    block::Integer,
    trial::Integer;
    record=(),
    record_every::Integer=1,
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
        record=record,
        every=record_every,
    )
    initial_state = realized_initial_state(setup.ensemble.environment)
    if evaluation.warmup > 0
        recorder = setup.ensemble.recorder
        setup.ensemble.recorder = nothing
        rollout!(setup.ensemble, evaluation.warmup; window=evaluation.warmup)
        setup.ensemble.recorder = recorder
        reset!(recorder)
    end
    scored_ticks = evaluation.horizon - evaluation.warmup
    outcome = rollout!(
        setup.ensemble,
        scored_ticks;
        window=scored_ticks,
        metrics=metrics,
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
        interventions=nothing,
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
            seed_ledger=setup.seed_ledger,
            evaluation=evaluation,
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
    record=(),
    record_every::Integer=1,
    metrics=nothing,
)
    evaluation = target.evaluation
    evaluation.reset === :full || throw(ArgumentError(
        "generic evaluation currently requires reset=:full; task-specific state retention " *
        "must be exposed through a declared reset hook before using :$(evaluation.reset)",
    ))
    resolved = resolve_composition(target.composition, registry)
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
                record=record,
                record_every=record_every,
                metrics=metrics,
            )
            index += 1
        end
    end
    return EvaluationBatch(target, resolved, Tuple(trial_results))
end

function trial_row(trial::EvaluationTrial)
    outcome = task_outcome(trial.simulation)
    single_ledger = length(trial.seeds) == 1 ? first(trial.seeds) : nothing
    seed(name) = single_ledger !== nothing && hasproperty(single_ledger, name) ?
        getproperty(single_ledger, name) : missing
    return (
        condition=trial.condition,
        block=trial.block,
        trial=trial.trial,
        seed_ledger_agents=length(trial.seeds),
        topology_seed=seed(:topology),
        node_state_seed=seed(:node_state),
        world_seed=seed(:world),
        body_seed=seed(:body),
        task_seed=seed(:task),
        mechanism_seed=seed(:mechanism),
        initial_state=trial.initial_state,
        score_key=outcome === nothing ? missing : outcome.key,
        raw_score=outcome === nothing ? missing : outcome.raw,
        normalized_score=outcome === nothing ? missing : outcome.normalized,
        viable=_trial_viability(trial.simulation.metrics),
        liveness=_trial_liveness(trial.simulation.metrics),
    )
end

trial_table(batch::EvaluationBatch) = [trial_row(trial) for trial in batch.trials]
