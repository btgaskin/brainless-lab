using Statistics

struct ResolvedAblationCase{A,T<:EvaluationTarget}
    id::Symbol
    ablation::A
    target::T
end

struct ResolvedAblationPlan{P<:AblationPlan,C<:Tuple,R<:RegistrySet} <:
       AbstractResolvedOperationPlan
    source::P
    cases::C
    registry::R
end

struct AblationResult{P<:ResolvedAblationPlan,B<:Tuple} <: AbstractOperationResult
    plan::P
    batches::B
    trial_rows::Vector{NamedTuple}
    case_summaries::Vector{NamedTuple}
end

function _registered_ablation(registry::RegistrySet, id::Symbol)
    entry = resolve(registry.ablations, id)
    ablation = entry.implementation
    ablation isa AblationSpec || throw(ArgumentError(
        "registered ablation :$(id) must contain an AblationSpec, got $(typeof(ablation)); " *
        "raw intervention types are not executable operation contracts",
    ))
    ablation.id === id || throw(ArgumentError(
        "registered ablation key :$(id) does not match AblationSpec id :$(ablation.id)",
    ))
    return ablation
end

function _validate_ablation(
    ablation::AblationSpec,
    node::NodeSpec,
    composition::CompositionSpec,
)
    ablation.stage === :composition || throw(ArgumentError(
        "ablation :$(ablation.id) uses unsupported stage :$(ablation.stage); " *
        "the current executor supports only :composition",
    ))
    missing_capabilities = setdiff(ablation.required_capabilities, node.capabilities)
    isempty(missing_capabilities) || throw(ArgumentError(
        "ablation :$(ablation.id) requires node capabilities " *
        "$(Tuple(missing_capabilities)); node :$(node.id) declares $(node.capabilities)",
    ))
    applicable(ablation.apply, composition) || throw(ArgumentError(
        "composition-stage ablation :$(ablation.id) must accept one CompositionSpec",
    ))
    return ablation
end

function validate(plan::AblationPlan, registry::RegistrySet)
    resolved = resolve_composition(plan.target.composition, registry)
    :baseline in plan.ablations && throw(ArgumentError(
        "ablation id :baseline is reserved for the implicit baseline case",
    ))
    for id in plan.ablations
        _validate_ablation(
            _registered_ablation(registry, id),
            resolved.node,
            plan.target.composition,
        )
    end
    return plan
end

function _apply_composition_ablation(
    ablation::AblationSpec,
    source::CompositionSpec,
    registry::RegistrySet,
)
    transformed = ablation.apply(source)
    transformed isa CompositionSpec || throw(ArgumentError(
        "ablation :$(ablation.id) returned $(typeof(transformed)), not CompositionSpec",
    ))
    transformed === source && throw(ArgumentError(
        "ablation :$(ablation.id) returned its input composition unchanged",
    ))
    resolve_composition(transformed, registry)
    return transformed
end

function resolve(plan::AblationPlan, registry::RegistrySet)
    validate(plan, registry)
    cases = ResolvedAblationCase[
        ResolvedAblationCase(
            :baseline,
            nothing,
            EvaluationTarget(:baseline, plan.target.composition, plan.target.evaluation),
        ),
    ]
    for id in plan.ablations
        ablation = _registered_ablation(registry, id)
        composition = _apply_composition_ablation(
            ablation,
            plan.target.composition,
            registry,
        )
        push!(cases, ResolvedAblationCase(
            id,
            ablation,
            EvaluationTarget(id, composition, plan.target.evaluation),
        ))
    end
    return ResolvedAblationPlan(plan, Tuple(cases), registry)
end

function _ablation_aggregate(values, policy::Symbol)
    policy === :none && return missing
    observed = Float64[value for value in values if !ismissing(value)]
    isempty(observed) && return missing
    policy === :mean && return mean(observed)
    policy === :median && return median(observed)
    policy === :sum && return sum(observed)
    policy === :minimum && return minimum(observed)
    policy === :maximum && return maximum(observed)
    throw(ArgumentError("unsupported aggregate policy :$(policy)"))
end

function _ablation_trial_rows(
    plan::ResolvedAblationPlan,
    batches::Tuple,
)
    rows = NamedTuple[]
    for (case, batch) in zip(plan.cases, batches)
        for row in trial_table(batch)
            push!(rows, merge(
                (
                    operation=plan.source.id,
                    case=case.id,
                    ablation=case.ablation === nothing ? :none : case.ablation.id,
                ),
                row,
            ))
        end
    end
    return rows
end

function _ablation_case_summaries(
    plan::ResolvedAblationPlan,
    rows::Vector{NamedTuple},
)
    summaries = NamedTuple[]
    policy = plan.source.target.evaluation.aggregate
    for case in plan.cases
        selected = filter(row -> row.case === case.id, rows)
        viability = [row.viable for row in selected if !ismissing(row.viable)]
        push!(summaries, (
            operation=plan.source.id,
            case=case.id,
            ablation=case.ablation === nothing ? :none : case.ablation.id,
            n_trials=length(selected),
            aggregate=policy,
            raw_score=_ablation_aggregate((row.raw_score for row in selected), policy),
            normalized_score=_ablation_aggregate(
                (row.normalized_score for row in selected),
                policy,
            ),
            viable_fraction=isempty(viability) ? missing : mean(viability),
        ))
    end
    return summaries
end

function execute(plan::ResolvedAblationPlan)
    batches = Tuple(evaluate(case.target; registry=plan.registry) for case in plan.cases)
    rows = _ablation_trial_rows(plan, batches)
    summaries = _ablation_case_summaries(plan, rows)
    return AblationResult(plan, batches, rows, summaries)
end

tables(result::AblationResult) = (
    trials=result.trial_rows,
    cases=result.case_summaries,
)

summary(result::AblationResult) = (
    operation=:ablation,
    id=result.plan.source.id,
    n_cases=length(result.plan.cases),
    n_rollouts=length(result.trial_rows),
    aggregate=result.plan.source.target.evaluation.aggregate,
    cases=result.case_summaries,
)
