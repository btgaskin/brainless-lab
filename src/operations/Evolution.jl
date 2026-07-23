using Statistics

"""
    ResolvedEvolutionPlan

An `EvolutionPlan` after its node parameter set, optimizer, starting point, and
registry have been resolved. The optimizer seed is deliberately retained
outside `EvaluationSpec`: optimizer sampling and evaluation trial streams are
separate stochastic processes.
"""
struct ResolvedEvolutionPlan{
    P<:EvolutionPlan,
    N<:NodeSpec,
    O<:ImplementationSpec,
    S<:Tuple,
} <: AbstractResolvedOperationPlan
    plan::P
    registry::RegistrySet
    node::N
    optimizer::O
    parameters::S
    x0::Vector{Float64}
    optimizer_seed::UInt64
end

"""One evaluated member of one evolutionary generation."""
struct EvolutionCandidate
    generation::Int
    individual::Int
    coordinates::Vector{Float64}
    parameters::Dict{Symbol,Any}
    objective_values::Vector{Float64}
    fitness::Float64
end

"""Compact convergence statistics for one evolutionary generation."""
struct EvolutionGeneration
    generation::Int
    best_individual::Int
    fitness_best::Float64
    fitness_median::Float64
    fitness_mean::Float64
    fitness_worst::Float64
end

"""A champion evaluated once under a declared target protocol."""
struct EvolutionEvaluation{B<:EvaluationBatch}
    target::Symbol
    objective::Symbol
    objective_values::Vector{Float64}
    aggregate::Float64
    batch::B
end

"""
    EvolutionResult

Typed result of parameter evolution. Candidate and convergence histories
contain training information only. Held-out targets are evaluated only after
the champion has been selected.
"""
struct EvolutionResult{
    P<:ResolvedEvolutionPlan,
    O,
    T<:EvolutionEvaluation,
    H<:Tuple,
} <: AbstractOperationResult
    plan::P
    optimizer_result::O
    optimizer_seed::UInt64
    candidates::Vector{EvolutionCandidate}
    candidate_batches::Vector{EvaluationBatch}
    convergence::Vector{EvolutionGeneration}
    champion_coordinates::Vector{Float64}
    champion_parameters::Dict{Symbol,Any}
    champion_training_fitness::Float64
    training::T
    heldout::H
end

function _evolution_mutation_scale(parameter::ParameterSpec)
    metadata = parameter.evolve
    hasproperty(metadata, :values) && begin
        count = length(metadata.values)
        return count == 1 ? 1.0 : inv(Float64(count - 1))
    end
    metadata.mutation_scale === nothing && return 0.2
    return Float64(metadata.mutation_scale)
end

function _bounded_unit(parameter::ParameterSpec, value)
    metadata = parameter.evolve
    lower = Float64(metadata.lower)
    upper = Float64(metadata.upper)
    numeric = Float64(value)
    lower <= numeric <= upper || throw(ArgumentError(
        "starting value $(repr(value)) for parameter :$(parameter.name) lies outside " *
        "its evolution bounds [$(metadata.lower), $(metadata.upper)]",
    ))
    lower == upper && return 0.0
    if metadata.scale === :log
        return (log(numeric) - log(lower)) / (log(upper) - log(lower))
    end
    return (numeric - lower) / (upper - lower)
end

function _encode_evolution_parameter(parameter::ParameterSpec, value)
    metadata = parameter.evolve
    if hasproperty(metadata, :values)
        index = findfirst(candidate -> isequal(candidate, value), metadata.values)
        index === nothing && throw(ArgumentError(
            "starting value $(repr(value)) for parameter :$(parameter.name) is not one " *
            "of its evolvable values $(metadata.values)",
        ))
        count = length(metadata.values)
        unit = count == 1 ? 0.0 : (index - 1) / (count - 1)
    else
        unit = _bounded_unit(parameter, value)
    end
    return unit / _evolution_mutation_scale(parameter)
end

function _convert_evolution_value(parameter::ParameterSpec, value)
    converted = if parameter.datatype <: Integer
        convert(parameter.datatype, round(Int, value))
    else
        convert(parameter.datatype, value)
    end
    return validate_parameter(parameter, converted)
end

function _decode_evolution_parameter(parameter::ParameterSpec, coordinate::Real)
    metadata = parameter.evolve
    unit = clamp(
        Float64(coordinate) * _evolution_mutation_scale(parameter),
        0.0,
        1.0,
    )
    if hasproperty(metadata, :values)
        count = length(metadata.values)
        index = count == 1 ? 1 : clamp(round(Int, 1 + unit * (count - 1)), 1, count)
        return validate_parameter(parameter, metadata.values[index])
    end

    lower = Float64(metadata.lower)
    upper = Float64(metadata.upper)
    value = if metadata.scale === :log
        exp(log(lower) + unit * (log(upper) - log(lower)))
    else
        lower + unit * (upper - lower)
    end
    metadata.scale === :integer && (value = round(value))
    return _convert_evolution_value(parameter, value)
end

function _decode_evolution_parameters(
    parameters::Tuple,
    coordinates::AbstractVector{<:Real},
)
    length(parameters) == length(coordinates) || throw(DimensionMismatch(
        "candidate has $(length(coordinates)) coordinates; expected $(length(parameters))",
    ))
    values = Dict{Symbol,Any}()
    for index in eachindex(parameters)
        parameter = parameters[index]
        values[parameter.name] = _decode_evolution_parameter(
            parameter,
            coordinates[index],
        )
    end
    return values
end

function _evolution_optimizer_seed(plan::EvolutionPlan)
    seed = _splitmix64(
        plan.training.evaluation.root_seed ⊻ _stable_symbol_word(:optimizer),
    )
    seed = _splitmix64(seed ⊻ _stable_symbol_word(plan.id))
    return _splitmix64(seed ⊻ _stable_symbol_word(plan.optimizer))
end

function _validate_evolution_target(
    target::EvaluationTarget,
    node_id::Symbol,
    label::AbstractString,
)
    target.composition.node === node_id || throw(ArgumentError(
        "$(label) target :$(target.id) uses node :$(target.composition.node), " *
        "but evolution is selecting parameters for node :$(node_id)",
    ))
    target.evaluation.reset === :full || throw(ArgumentError(
        "$(label) target :$(target.id) must use reset=:full",
    ))
    target.evaluation.aggregate === :none && throw(ArgumentError(
        "$(label) target :$(target.id) must declare a scalar aggregation policy",
    ))
    return target
end

function validate(plan::EvolutionPlan, registry::RegistrySet)
    resolved_training = resolve_composition(plan.training.composition, registry)
    node = resolved_training.node
    names = node_parameter_set(node, plan.parameter_set)
    isempty(names) && throw(ArgumentError(
        "evolution parameter set :$(plan.parameter_set) on node :$(node.id) is empty",
    ))
    parameters = Tuple(node_parameter(node, name) for name in names)
    for parameter in parameters
        evolvable(parameter) || throw(ArgumentError(
            "parameter :$(parameter.name) in set :$(plan.parameter_set) on node " *
            ":$(node.id) has no evolution metadata",
        ))
        _encode_evolution_parameter(
            parameter,
            resolved_training.parameters[parameter.name],
        )
    end
    _validate_evolution_target(plan.training, node.id, "training")
    for target in plan.heldout_targets
        _validate_evolution_target(target, node.id, "held-out")
        resolved_heldout = resolve_composition(target.composition, registry)
        for parameter in parameters
            haskey(resolved_heldout.parameters, parameter.name) || throw(ArgumentError(
                "held-out target :$(target.id) does not accept evolved parameter " *
                ":$(parameter.name)",
            ))
        end
    end
    resolve(registry.optimizers, plan.optimizer)
    return plan
end

function resolve(plan::EvolutionPlan, registry::RegistrySet)
    validate(plan, registry)
    resolved_training = resolve_composition(plan.training.composition, registry)
    node = resolved_training.node
    parameters = Tuple(
        node_parameter(node, name)
        for name in node_parameter_set(node, plan.parameter_set)
    )
    x0 = Float64[
        _encode_evolution_parameter(
            parameter,
            resolved_training.parameters[parameter.name],
        )
        for parameter in parameters
    ]
    optimizer = resolve(registry.optimizers, plan.optimizer)
    return ResolvedEvolutionPlan(
        plan,
        registry,
        node,
        optimizer,
        parameters,
        x0,
        _evolution_optimizer_seed(plan),
    )
end

function _evolution_target(
    target::EvaluationTarget,
    parameter_values::Dict{Symbol,Any},
    suffix::AbstractString,
)
    source = target.composition
    values = copy(source.parameters)
    merge!(values, parameter_values)
    composition = CompositionSpec(
        Symbol(String(source.id) * "_" * suffix),
        source.node,
        source.task;
        body=source.body,
        n_agents=source.n_agents,
        n_nodes=source.n_nodes,
        parameters=values,
        task_options=source.task_options,
        body_options=source.body_options,
        interaction_cycle=source.interaction_cycle,
    )
    return EvaluationTarget(target.id, composition, target.evaluation)
end

function _evolution_trial_value(trial::EvaluationTrial, objective::Symbol)
    outcome = task_outcome(trial.simulation)
    value = if objective === :normalized_score
        outcome === nothing ? missing : outcome.normalized
    elseif objective === :raw_score
        outcome === nothing ? missing : outcome.raw
    elseif outcome !== nothing && objective === outcome.key
        outcome.raw
    elseif hasproperty(trial.simulation.metrics, objective)
        getproperty(trial.simulation.metrics, objective)
    else
        missing
    end
    value isa Real || throw(ArgumentError(
        "objective :$(objective) is unavailable or non-numeric for target " *
        ":$(trial.condition), block $(trial.block), trial $(trial.trial)",
    ))
    numeric = Float64(value)
    isfinite(numeric) || throw(ArgumentError(
        "objective :$(objective) is non-finite for target :$(trial.condition), " *
        "block $(trial.block), trial $(trial.trial)",
    ))
    return numeric
end

function _evolution_aggregate(values::AbstractVector{<:Real}, policy::Symbol)
    isempty(values) && throw(ArgumentError("cannot aggregate an empty objective vector"))
    policy === :mean && return sum(values) / length(values)
    policy === :median && return median(values)
    policy === :sum && return sum(values)
    policy === :minimum && return minimum(values)
    policy === :maximum && return maximum(values)
    throw(ArgumentError("unsupported evolution aggregation policy :$(policy)"))
end

function _evaluate_evolution_target(
    target::EvaluationTarget,
    objective::Symbol,
    registry::RegistrySet,
)
    batch = evaluate(target; registry=registry)
    values = Float64[
        _evolution_trial_value(trial, objective)
        for trial in batch.trials
    ]
    aggregate = Float64(_evolution_aggregate(values, target.evaluation.aggregate))
    return EvolutionEvaluation(target.id, objective, values, aggregate, batch)
end

function _instantiate_evolution_optimizer(plan::ResolvedEvolutionPlan)
    constructor = plan.optimizer.implementation
    optimizer = constructor(
        copy(plan.x0),
        plan.plan.sigma0;
        popsize=plan.plan.popsize,
        seed=_seed_to_int(plan.optimizer_seed),
    )
    optimizer isa AbstractEvolutionStrategy || throw(ArgumentError(
        "optimizer :$(plan.plan.optimizer) returned $(typeof(optimizer)), not " *
        "AbstractEvolutionStrategy",
    ))
    return optimizer
end

function execute(plan::ResolvedEvolutionPlan)
    init_parallelism!()
    optimizer = _instantiate_evolution_optimizer(plan)
    candidate_history = EvolutionCandidate[]
    candidate_batches = EvaluationBatch[]
    convergence = EvolutionGeneration[]
    champion_coordinates = copy(plan.x0)
    champion_parameters = _decode_evolution_parameters(plan.parameters, plan.x0)
    champion_fitness = -Inf

    for generation in 1:plan.plan.generations
        proposed = ask(optimizer)
        length(proposed) == plan.plan.popsize || throw(ArgumentError(
            "optimizer :$(plan.plan.optimizer) proposed $(length(proposed)) candidates; " *
            "EvolutionPlan requires popsize=$(plan.plan.popsize)",
        ))
        losses = Vector{Float64}(undef, length(proposed))
        fitnesses = Vector{Float64}(undef, length(proposed))

        evaluated = parallel_map(eachindex(proposed)) do individual
            coordinates = Vector{Float64}(Float64.(proposed[individual]))
            parameters = _decode_evolution_parameters(plan.parameters, coordinates)
            target = _evolution_target(
                plan.plan.training,
                parameters,
                "generation_$(generation)_individual_$(individual)",
            )
            evaluation = _evaluate_evolution_target(
                target,
                plan.plan.objective,
                plan.registry,
            )
            fitness = evaluation.aggregate
            return (
                candidate=EvolutionCandidate(
                    generation,
                    individual,
                    coordinates,
                    parameters,
                    copy(evaluation.objective_values),
                    fitness,
                ),
                fitness=fitness,
                batch=evaluation.batch,
            )
        end

        for (individual, outcome) in enumerate(evaluated)
            candidate = outcome.candidate
            fitness = outcome.fitness
            fitnesses[individual] = fitness
            losses[individual] = -fitness
            push!(candidate_history, candidate)
            push!(candidate_batches, outcome.batch)
            if fitness > champion_fitness
                champion_fitness = fitness
                champion_coordinates = copy(candidate.coordinates)
                champion_parameters = copy(candidate.parameters)
            end
        end

        tell!(optimizer, proposed, losses)
        best_individual = argmax(fitnesses)
        push!(
            convergence,
            EvolutionGeneration(
                generation,
                best_individual,
                maximum(fitnesses),
                median(fitnesses),
                sum(fitnesses) / length(fitnesses),
                minimum(fitnesses),
            ),
        )
    end

    optimizer_summary = result(optimizer)
    training_target = _evolution_target(
        plan.plan.training,
        champion_parameters,
        "champion",
    )
    training = _evaluate_evolution_target(
        training_target,
        plan.plan.objective,
        plan.registry,
    )
    heldout = Tuple(
        _evaluate_evolution_target(
            _evolution_target(target, champion_parameters, "champion"),
            plan.plan.objective,
            plan.registry,
        )
        for target in plan.plan.heldout_targets
    )
    return EvolutionResult(
        plan,
        optimizer_summary,
        plan.optimizer_seed,
        candidate_history,
        candidate_batches,
        convergence,
        champion_coordinates,
        champion_parameters,
        champion_fitness,
        training,
        heldout,
    )
end

function _evolution_metadata_row(parameter::ParameterSpec, value)
    evolution = parameter.evolve
    if hasproperty(evolution, :values)
        return (
            parameter=parameter.name,
            owner=parameter.owner,
            value=value,
            default=parameter.default,
            scale=:categorical,
            lower=missing,
            upper=missing,
            mutation_scale=_evolution_mutation_scale(parameter),
            values=evolution.values,
        )
    end
    return (
        parameter=parameter.name,
        owner=parameter.owner,
        value=value,
        default=parameter.default,
        scale=evolution.scale,
        lower=evolution.lower,
        upper=evolution.upper,
        mutation_scale=_evolution_mutation_scale(parameter),
        values=missing,
    )
end

function tables(result::EvolutionResult)
    convergence = [
        (
            generation=row.generation,
            best_individual=row.best_individual,
            fitness_best=row.fitness_best,
            fitness_median=row.fitness_median,
            fitness_mean=row.fitness_mean,
            fitness_worst=row.fitness_worst,
        )
        for row in result.convergence
    ]
    candidates = [
        (
            generation=row.generation,
            individual=row.individual,
            coordinates=Tuple(row.coordinates),
            parameters=_composition_namedtuple(row.parameters),
            objective_values=Tuple(row.objective_values),
            fitness=row.fitness,
        )
        for row in result.candidates
    ]
    candidate_trials = NamedTuple[]
    for (candidate, batch) in zip(result.candidates, result.candidate_batches)
        for row in trial_table(batch)
            push!(candidate_trials, merge(
                (
                    generation=candidate.generation,
                    individual=candidate.individual,
                    candidate_fitness=candidate.fitness,
                ),
                row,
            ))
        end
    end
    champion_parameters = [
        _evolution_metadata_row(
            parameter,
            result.champion_parameters[parameter.name],
        )
        for parameter in result.plan.parameters
    ]
    heldout_trials = NamedTuple[]
    for evaluation in result.heldout
        append!(heldout_trials, trial_table(evaluation.batch))
    end
    return (
        convergence=convergence,
        candidates=candidates,
        candidate_trials=candidate_trials,
        champion_parameters=champion_parameters,
        training_trials=trial_table(result.training.batch),
        heldout_trials=heldout_trials,
        optimizer=[(
            optimizer=result.plan.plan.optimizer,
            optimizer_seed=result.optimizer_seed,
            generations=result.plan.plan.generations,
            popsize=result.plan.plan.popsize,
        )],
    )
end

function summary(result::EvolutionResult)
    heldout = Tuple(
        (
            target=evaluation.target,
            objective=evaluation.objective,
            score=evaluation.aggregate,
            trials=length(evaluation.objective_values),
        )
        for evaluation in result.heldout
    )
    return (
        plan=result.plan.plan.id,
        node=result.plan.node.id,
        training_target=result.training.target,
        objective=result.plan.plan.objective,
        optimizer=result.plan.plan.optimizer,
        optimizer_seed=result.optimizer_seed,
        generations=result.plan.plan.generations,
        popsize=result.plan.plan.popsize,
        champion_training_score=result.training.aggregate,
        champion_parameters=_composition_namedtuple(result.champion_parameters),
        heldout=heldout,
    )
end
