using Random
using Statistics

"""
    ResolvedEvolutionPlan

An experimental node-design search after its fixed node design, search
strategy, and model-centred initialisation have been resolved.
"""
struct ResolvedEvolutionPlan{
    P<:EvolutionPlan,
    N<:NodeSpec,
    D<:Evolution.NodeDesignSpec,
    S<:Evolution.SearchStrategySpec,
    R<:Evolution.RunConfig,
} <: AbstractResolvedOperationPlan
    plan::P
    registry::RegistrySet
    node::N
    design::D
    strategy::S
    run::R
end

"""One target score and its raw trial and seed records for a candidate."""
struct EvolutionEvaluation
    target::Symbol
    measure::Symbol
    values::Vector{Union{Missing,Float64}}
    aggregate::Union{Missing,Float64}
    batch
    trial_rows::Vector{NamedTuple}
    seed_rows::Vector{NamedTuple}
end

"""One proposed node model and every training evaluation made for it."""
struct EvolutionCandidate
    iteration::Int
    id::Int
    coordinates::Vector{Float64}
    valid::Bool
    evaluations::Vector{EvolutionEvaluation}
end

"""Target-wise convergence statistics for one completed search iteration."""
struct EvolutionGeneration
    iteration::Int
    candidates::Int
    valid_candidates::Int
    score_best::Vector{Union{Missing,Float64}}
    score_mean::Vector{Union{Missing,Float64}}
    score_worst::Vector{Union{Missing,Float64}}
end

"""A selected, Pareto, or archive model emitted by a search strategy."""
struct EvolutionModel
    model_id::String
    role::Symbol
    coordinates::Vector{Float64}
    model::NodeModel
    scores::Vector{Float64}
    metadata::NamedTuple
end

"""
    EvolutionResult

Complete experimental search output. Candidate histories contain development
data only. Held-out evaluations are made after scalar SepCMA selection.
"""
mutable struct EvolutionResult{
    P<:ResolvedEvolutionPlan,
    S<:Evolution.AbstractSearchState,
    O,
} <: AbstractOperationResult
    plan::P
    state::S
    strategy_outcome::O
    candidates::Vector{EvolutionCandidate}
    convergence::Vector{EvolutionGeneration}
    models::Vector{EvolutionModel}
    model_references::Vector{Evolution.ModelReference}
    heldout::Vector{EvolutionEvaluation}
end

function _validate_evolution_target(
    target::EvaluationTarget,
    node_id::Symbol,
    label::AbstractString,
)
    target.composition.node === node_id || throw(ArgumentError(
        "$(label) target :$(target.id) uses node :$(target.composition.node), " *
        "but the fixed design belongs to node :$(node_id)",
    ))
    target.model === nothing || throw(ArgumentError(
        "$(label) target :$(target.id) must not pre-bind a model during search",
    ))
    target.evaluation.aggregate === :none && throw(ArgumentError(
        "$(label) target :$(target.id) must declare a scalar aggregation policy",
    ))
    return target
end

function _resolved_run_config(
    run::Evolution.RunConfig,
    node::NodeSpec,
    design::Evolution.NodeDesignSpec,
)
    initialisation = run.initialisation
    if initialisation.centre === :model &&
       initialisation.coordinates === nothing
        reference = something(initialisation.reference)
        model = Evolution.read_model(reference, node.id, design)
        initialisation = Evolution.NormalInitialisation(
            reference,
            Evolution.encode(design, model);
            scale=initialisation.scale,
        )
    end
    return Evolution.RunConfig(
        ;
        strategy=run.strategy,
        iterations=run.iterations,
        search_seed=run.search_seed,
        measure=run.measure,
        direction=run.direction,
        initialisation,
        options=run.options,
    )
end

function validate(plan::EvolutionPlan, registry::RegistrySet)
    first_target = first(plan.training_targets)
    resolved = resolve_composition(first_target.composition, registry)
    node = resolved.node
    design = node.design
    design isa Evolution.NodeDesignSpec || throw(ArgumentError(
        "node :$(node.id) declares no experimental NodeDesignSpec",
    ))
    for target in plan.training_targets
        _validate_evolution_target(target, node.id, "training")
    end
    for target in plan.heldout_targets
        _validate_evolution_target(target, node.id, "held-out")
    end
    strategy = Evolution.search_strategy(registry, plan.run.strategy)
    Evolution.validate_strategy(
        strategy,
        plan.run,
        length(plan.training_targets),
    )
    if !isempty(plan.heldout_targets) && strategy.key !== :sepcma
        throw(ArgumentError(
            "held-out evaluation is available only for scalar :sepcma runs; " *
            "use a later BenchmarkPlan for Pareto or archive models",
        ))
    end
    _resolved_run_config(plan.run, node, design)
    _validate_plan_evaluations(plan, registry)
    return plan
end

function resolve(plan::EvolutionPlan, registry::RegistrySet)
    validate(plan, registry)
    resolved = resolve_composition(
        first(plan.training_targets).composition,
        registry,
    )
    node = resolved.node
    design = something(node.design)
    strategy = Evolution.search_strategy(registry, plan.run.strategy)
    run = _resolved_run_config(plan.run, node, design)
    return ResolvedEvolutionPlan(
        plan,
        registry,
        node,
        design,
        strategy,
        run,
    )
end

function _evolution_trial_value(trial::EvaluationTrial, measure::Symbol)
    outcome = task_outcome(trial.simulation)
    value = if measure === :normalized_score
        outcome === nothing ? missing : outcome.normalized
    elseif measure === :raw_score
        outcome === nothing ? missing : outcome.raw
    elseif outcome !== nothing && measure === outcome.key
        outcome.raw
    elseif hasproperty(trial.simulation.metrics, measure)
        getproperty(trial.simulation.metrics, measure)
    else
        missing
    end
    value isa Real || return missing
    numeric = Float64(value)
    return isfinite(numeric) ? numeric : missing
end

function _evolution_aggregate(values, policy::Symbol)
    any(ismissing, values) && return missing
    numeric = Float64[Float64(value) for value in values]
    isempty(numeric) && return missing
    policy === :mean && return sum(numeric) / length(numeric)
    policy === :median && return median(numeric)
    policy === :sum && return sum(numeric)
    policy === :minimum && return minimum(numeric)
    policy === :maximum && return maximum(numeric)
    throw(ArgumentError("unsupported evolution aggregation policy :$(policy)"))
end

function _evolution_censoring(evaluation::EvolutionEvaluation)
    evaluation.measure === :normalized_score ||
        return (
            normalized_n=missing,
            normalized_floor_count=missing,
            normalized_ceiling_count=missing,
            normalized_censored_count=missing,
            normalized_censored_fraction=missing,
            normalized_censoring=missing,
        )
    return _normalized_censoring_summary(evaluation.trial_rows)
end

function _evolution_seed_rows(batch::EvaluationBatch)
    rows = NamedTuple[]
    for trial in batch.trials
        for (agent, ledger) in enumerate(trial.seeds)
            for stream in propertynames(ledger)
                push!(rows, (
                    condition=trial.condition,
                    block=trial.block,
                    trial=trial.trial,
                    agent=agent,
                    stream=stream,
                    seed=getproperty(ledger, stream),
                ))
            end
        end
    end
    return rows
end

function _evaluate_evolution_target(
    target::EvaluationTarget,
    model::NodeModel,
    measure::Symbol,
    registry::RegistrySet,
)
    batch = evaluate(target; registry, model)
    values = Union{Missing,Float64}[
        _evolution_trial_value(trial, measure)
        for trial in batch.trials
    ]
    aggregate = _evolution_aggregate(values, target.evaluation.aggregate)
    return EvolutionEvaluation(
        target.id,
        measure,
        values,
        aggregate,
        batch,
        NamedTuple[trial_table(batch)...],
        _evolution_seed_rows(batch),
    )
end

function _candidate_observation(
    plan::ResolvedEvolutionPlan,
    proposal::Evolution.CandidateProposal,
)
    model = Evolution.decode(plan.design, proposal.coordinates)
    evaluations = EvolutionEvaluation[
        _evaluate_evolution_target(
            target,
            model,
            plan.run.measure,
            plan.registry,
        )
        for target in plan.plan.training_targets
    ]
    valid = all(evaluation -> !ismissing(evaluation.aggregate), evaluations)
    scores = Float64[
        ismissing(evaluation.aggregate) ? 0.0 : evaluation.aggregate
        for evaluation in evaluations
    ]
    if plan.strategy.key === :cmame
        valid &= all(score -> 0.0 <= score <= 1.0, scores)
        valid || fill!(scores, 0.0)
    end
    candidate = EvolutionCandidate(
        proposal.iteration,
        proposal.id,
        copy(proposal.coordinates),
        valid,
        evaluations,
    )
    return (
        candidate=candidate,
        observation=Evolution.Observation(proposal, scores; valid),
    )
end

function _evolution_rng(seed::UInt64, iteration::Integer)
    derived = _splitmix64(seed ⊻ UInt64(iteration))
    return Random.MersenneTwister(_seed_to_int(derived))
end

function _restored_checkpoint_candidate(document::AbstractDict)
    evaluations = EvolutionEvaluation[
        EvolutionEvaluation(
            Symbol(entry["target"]),
            Symbol(entry["measure"]),
            Union{Missing,Float64}[
                ismissing(value) ? missing : Float64(value)
                for value in entry["values"]
            ],
            ismissing(entry["aggregate"]) ?
                missing : Float64(entry["aggregate"]),
            nothing,
            NamedTuple[entry["trial_rows"]...],
            NamedTuple[entry["seed_rows"]...],
        )
        for entry in document["evaluations"]
    ]
    return EvolutionCandidate(
        Int(document["iteration"]),
        Int(document["id"]),
        Float64.(document["coordinates"]),
        Bool(document["valid"]),
        evaluations,
    )
end

function _candidate_scores(candidate::EvolutionCandidate)
    return Union{Missing,Float64}[
        evaluation.aggregate
        for evaluation in candidate.evaluations
    ]
end

function _convergence(
    candidates::Vector{EvolutionCandidate},
    n_targets::Integer,
    direction::Symbol,
)
    direction in (:maximise, :minimise) || throw(ArgumentError(
        "evolution direction must be :maximise or :minimise",
    ))
    output = EvolutionGeneration[]
    iterations = sort!(unique(candidate.iteration for candidate in candidates))
    for iteration in iterations
        rows = [
            candidate for candidate in candidates
            if candidate.iteration == iteration
        ]
        valid_rows = [candidate for candidate in rows if candidate.valid]
        best = Union{Missing,Float64}[]
        mean_ = Union{Missing,Float64}[]
        worst = Union{Missing,Float64}[]
        for target_index in 1:Int(n_targets)
            scores = Float64[
                Float64(_candidate_scores(candidate)[target_index])
                for candidate in valid_rows
                if !ismissing(_candidate_scores(candidate)[target_index])
            ]
            if isempty(scores)
                push!(best, missing)
                push!(mean_, missing)
                push!(worst, missing)
            else
                score_minimum, score_maximum = extrema(scores)
                push!(best, direction === :maximise ? score_maximum : score_minimum)
                push!(mean_, sum(scores) / length(scores))
                push!(worst, direction === :maximise ? score_minimum : score_maximum)
            end
        end
        push!(output, EvolutionGeneration(
            iteration,
            length(rows),
            length(valid_rows),
            best,
            mean_,
            worst,
        ))
    end
    return output
end

function _final_models(
    plan::ResolvedEvolutionPlan,
    strategy_outcome,
)
    entries = EvolutionModel[]
    if strategy_outcome.kind === :selected
        item = strategy_outcome.selected
        push!(entries, EvolutionModel(
            "selected",
            :selected,
            copy(item.coordinates),
            Evolution.decode(plan.design, item.coordinates),
            copy(item.scores),
            (candidate_id=item.id, value=item.value),
        ))
    elseif strategy_outcome.kind === :pareto
        valid = [item for item in strategy_outcome.pareto if item.valid]
        isempty(valid) && throw(ArgumentError(
            "nsga2 completed without a valid Pareto model",
        ))
        for (index, item) in enumerate(valid)
            push!(entries, EvolutionModel(
                string("pareto-", lpad(index, 4, '0')),
                :pareto,
                copy(item.coordinates),
                Evolution.decode(plan.design, item.coordinates),
                copy(item.scores),
                NamedTuple(),
            ))
        end
    elseif strategy_outcome.kind === :archive
        for (index, item) in enumerate(strategy_outcome.archive)
            push!(entries, EvolutionModel(
                string("cell-", lpad(index, 4, '0')),
                :archive,
                copy(item.coordinates),
                Evolution.decode(plan.design, item.coordinates),
                copy(item.descriptor),
                (cell=Tuple(item.cell), quality=item.quality),
            ))
        end
    else
        throw(ArgumentError(
            "unknown strategy outcome kind $(repr(strategy_outcome.kind))",
        ))
    end
    return entries
end

function execute(
    plan::ResolvedEvolutionPlan;
    state=nothing,
    candidates=EvolutionCandidate[],
    checkpoint=nothing,
)
    init_parallelism!()
    state_ = state === nothing ?
        Evolution.initialise(
            plan.strategy,
            plan.design,
            plan.run;
            n_scores=length(plan.plan.training_targets),
        ) :
        state
    history = copy(candidates)
    completed = Int(Evolution.snapshot(state_)["iteration"])
    while completed < plan.run.iterations
        iteration = completed + 1
        proposals = Evolution.propose!(
            state_,
            _evolution_rng(plan.run.search_seed, iteration),
        )
        evaluated = parallel_map(proposals) do proposal
            _candidate_observation(plan, proposal)
        end
        Evolution.observe!(
            state_,
            [item.observation for item in evaluated],
        )
        append!(history, (item.candidate for item in evaluated))
        completed = iteration
        checkpoint === nothing || checkpoint(
            completed,
            state_,
            history,
        )
    end
    strategy_outcome = Evolution.outcome(state_)
    models = _final_models(plan, strategy_outcome)
    heldout = EvolutionEvaluation[]
    if plan.strategy.key === :sepcma
        selected = only(models)
        for target in plan.plan.heldout_targets
            push!(heldout, _evaluate_evolution_target(
                target,
                selected.model,
                plan.run.measure,
                plan.registry,
            ))
        end
    end
    return EvolutionResult(
        plan,
        state_,
        strategy_outcome,
        history,
        _convergence(
            history,
            length(plan.plan.training_targets),
            plan.run.direction,
        ),
        models,
        Evolution.ModelReference[],
        heldout,
    )
end

function tables(result::EvolutionResult)
    target_ids = Tuple(target.id for target in result.plan.plan.training_targets)
    convergence = NamedTuple[]
    for generation in result.convergence
        for (index, target) in enumerate(target_ids)
            push!(convergence, (
                iteration=generation.iteration,
                target,
                candidates=generation.candidates,
                valid_candidates=generation.valid_candidates,
                score_best=generation.score_best[index],
                score_mean=generation.score_mean[index],
                score_worst=generation.score_worst[index],
            ))
        end
    end
    candidates = [
        (
            iteration=candidate.iteration,
            candidate=candidate.id,
            valid=candidate.valid,
            coordinates=Tuple(candidate.coordinates),
            scores=Tuple(_candidate_scores(candidate)),
        )
        for candidate in result.candidates
    ]
    candidate_scores = NamedTuple[]
    candidate_trials = NamedTuple[]
    for candidate in result.candidates
        for evaluation in candidate.evaluations
            censoring = _evolution_censoring(evaluation)
            push!(candidate_scores, (
                iteration=candidate.iteration,
                candidate=candidate.id,
                target=evaluation.target,
                measure=evaluation.measure,
                valid=candidate.valid && !ismissing(evaluation.aggregate),
                score=evaluation.aggregate,
                normalized_n=censoring.normalized_n,
                normalized_floor_count=censoring.normalized_floor_count,
                normalized_ceiling_count=censoring.normalized_ceiling_count,
                normalized_censored_count=censoring.normalized_censored_count,
                normalized_censored_fraction=censoring.normalized_censored_fraction,
                normalized_censoring=censoring.normalized_censoring,
            ))
            length(evaluation.trial_rows) == length(evaluation.values) ||
                throw(ArgumentError(
                    "evolution trial rows and measure values must have equal lengths",
                ))
            for (row, value) in zip(evaluation.trial_rows, evaluation.values)
                push!(candidate_trials, merge(
                    (
                        phase=:development,
                        iteration=candidate.iteration,
                        candidate=candidate.id,
                    ),
                    row,
                    (measure_value=value,),
                ))
            end
        end
    end
    models = [
        (
            model_id=model.model_id,
            role=model.role,
            coordinates=Tuple(model.coordinates),
            scores=Tuple(model.scores),
            metadata=model.metadata,
        )
        for model in result.models
    ]
    heldout_trials = NamedTuple[]
    for evaluation in result.heldout
        length(evaluation.trial_rows) == length(evaluation.values) ||
            throw(ArgumentError(
                "evolution trial rows and measure values must have equal lengths",
            ))
        for (row, value) in zip(evaluation.trial_rows, evaluation.values)
            push!(heldout_trials, merge(
                (phase=:heldout, heldout_target=evaluation.target),
                row,
                (measure_value=value,),
            ))
        end
    end
    heldout = [
        begin
            censoring = _evolution_censoring(evaluation)
            (
                target=evaluation.target,
                measure=evaluation.measure,
                score=evaluation.aggregate,
                trials=length(evaluation.values),
                normalized_n=censoring.normalized_n,
                normalized_floor_count=censoring.normalized_floor_count,
                normalized_ceiling_count=censoring.normalized_ceiling_count,
                normalized_censored_count=censoring.normalized_censored_count,
                normalized_censored_fraction=censoring.normalized_censored_fraction,
                normalized_censoring=censoring.normalized_censoring,
            )
        end
        for evaluation in result.heldout
    ]
    return (
        convergence=convergence,
        candidates=candidates,
        candidate_scores=candidate_scores,
        candidate_trials=candidate_trials,
        models=models,
        heldout=heldout,
        heldout_trials=heldout_trials,
    )
end

function summary(result::EvolutionResult)
    return (
        plan=result.plan.plan.id,
        node=result.plan.node.id,
        strategy=result.plan.strategy.key,
        iterations=result.plan.run.iterations,
        candidates=length(result.candidates),
        valid_candidates=count(candidate -> candidate.valid, result.candidates),
        models=Tuple(model.model_id for model in result.models),
        heldout=Tuple(
            begin
                censoring = _evolution_censoring(evaluation)
                (
                    target=evaluation.target,
                    measure=evaluation.measure,
                    score=evaluation.aggregate,
                    normalized_n=censoring.normalized_n,
                    normalized_floor_count=censoring.normalized_floor_count,
                    normalized_ceiling_count=censoring.normalized_ceiling_count,
                    normalized_censored_count=censoring.normalized_censored_count,
                    normalized_censored_fraction=censoring.normalized_censored_fraction,
                    normalized_censoring=censoring.normalized_censoring,
                )
            end
            for evaluation in result.heldout
        ),
    )
end
