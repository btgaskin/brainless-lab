struct ResolvedBenchmarkCase{C<:Tuple}
    id::Symbol
    conditions::C
    baseline::Symbol
end

struct ResolvedBenchmarkPlan{P<:BenchmarkPlan,C<:Tuple} <: AbstractResolvedOperationPlan
    source::P
    id::Symbol
    cases::C
    registry::RegistrySet
end

struct BenchmarkResult{P<:ResolvedBenchmarkPlan,B<:Tuple} <: AbstractOperationResult
    plan::P
    batches::B
end

function _benchmark_evaluation_signature(evaluation::EvaluationSpec)
    return (
        blocks=evaluation.blocks,
        trials_per_block=evaluation.trials_per_block,
        horizon=evaluation.horizon,
        warmup=evaluation.warmup,
        construction_scope=evaluation.construction_scope,
        reset=evaluation.reset,
        root_seed=evaluation.root_seed,
        streams=seed_stream_names(evaluation),
        aggregate=evaluation.aggregate,
    )
end

function _validate_benchmark_case(case::BenchmarkCasePlan, registry::RegistrySet)
    baseline = only(condition for condition in case.conditions if condition.id === case.baseline)
    reference_task = baseline.composition.task
    reference = _benchmark_evaluation_signature(baseline.evaluation)
    for condition in case.conditions
        resolve_composition(condition.composition, registry)
        condition.composition.task === reference_task || throw(ArgumentError(
            "benchmark case :$(case.id) must compare conditions on one task; " *
            ":$(condition.id) uses :$(condition.composition.task), while the baseline " *
            "uses :$(reference_task)",
        ))
        _benchmark_evaluation_signature(condition.evaluation) == reference ||
            throw(ArgumentError(
                "benchmark case :$(case.id) conditions must share the complete " *
                "evaluation protocol for paired comparison",
            ))
        task = task_spec(registry, condition.composition.task)
        task.score_key === nothing && throw(ArgumentError(
            "benchmark case :$(case.id) task :$(task.name) has no scalar outcome contract",
        ))
    end
    return case
end

function validate(plan::BenchmarkPlan, registry::RegistrySet)
    foreach(case -> _validate_benchmark_case(case, registry), plan.cases)
    return plan
end

function resolve(plan::BenchmarkPlan, registry::RegistrySet)
    validate(plan, registry)
    cases = Tuple(
        ResolvedBenchmarkCase(
            case.id,
            Tuple(
                (
                    target=condition,
                    composition=resolve_composition(condition.composition, registry),
                )
                for condition in case.conditions
            ),
            case.baseline,
        )
        for case in plan.cases
    )
    return ResolvedBenchmarkPlan(plan, plan.id, cases, registry)
end

function execute(plan::ResolvedBenchmarkPlan)
    batches = Tuple(
        (
            case=case.id,
            baseline=case.baseline,
            conditions=Tuple(
                (
                    id=condition.target.id,
                    batch=evaluate(condition.target; registry=plan.registry),
                )
                for condition in case.conditions
            ),
        )
        for case in plan.cases
    )
    return BenchmarkResult(plan, batches)
end

execute(plan::BenchmarkPlan; registry::RegistrySet=DEFAULT_REGISTRY) =
    execute(resolve(plan, registry))

function _benchmark_trial_rows(result::BenchmarkResult)
    rows = NamedTuple[]
    for case in result.batches
        for condition in case.conditions
            for row in trial_table(condition.batch)
                push!(rows, merge((case=case.case,), row))
            end
        end
    end
    return rows
end

const _T975_DF_1_TO_30 = (
    12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
    2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
    2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042,
)

function _t975(degrees_of_freedom::Integer)
    degrees_of_freedom > 0 || throw(ArgumentError("degrees of freedom must be positive"))
    degrees_of_freedom <= 30 && return _T975_DF_1_TO_30[degrees_of_freedom]
    degrees_of_freedom <= 40 && return 2.021
    degrees_of_freedom <= 60 && return 2.000
    degrees_of_freedom <= 120 && return 1.980
    return 1.960
end

function _benchmark_mean_std(values)
    data = Float64[value for value in values if !ismissing(value)]
    isempty(data) && return (mean=missing, std=missing, n=0, lower=missing, upper=missing)
    mean_value = sum(data) / length(data)
    std_value = length(data) > 1 ? sqrt(sum((value - mean_value)^2 for value in data) / (length(data) - 1)) : 0.0
    if length(data) == 1
        return (mean=mean_value, std=std_value, n=1, lower=missing, upper=missing)
    end
    half_width = _t975(length(data) - 1) * std_value / sqrt(length(data))
    return (
        mean=mean_value,
        std=std_value,
        n=length(data),
        lower=mean_value - half_width,
        upper=mean_value + half_width,
    )
end

function _benchmark_statistics(rows)
    groups = Dict{Tuple{Symbol,Symbol},Vector{NamedTuple}}()
    for row in rows
        push!(get!(groups, (row.case, row.condition), NamedTuple[]), row)
    end
    output = NamedTuple[]
    for ((case, condition), group) in sort!(collect(groups); by=pair -> string(first(pair)))
        raw = _benchmark_mean_std(row.raw_score for row in group)
        normalized = _benchmark_mean_std(row.normalized_score for row in group)
        push!(output, (
            case=case,
            condition=condition,
            n=normalized.n,
            raw_mean=raw.mean,
            raw_std=raw.std,
            raw_ci_lower=raw.lower,
            raw_ci_upper=raw.upper,
            normalized_mean=normalized.mean,
            normalized_std=normalized.std,
            normalized_ci_lower=normalized.lower,
            normalized_ci_upper=normalized.upper,
            interval_method=:student_t_95,
        ))
    end
    return output
end

function _benchmark_contrasts(result::BenchmarkResult)
    output = NamedTuple[]
    for case in result.batches
        condition_rows = Dict(
            condition.id => Dict(
                (row.block, row.trial) => row
                for row in trial_table(condition.batch)
            )
            for condition in case.conditions
        )
        baseline_rows = condition_rows[case.baseline]
        for condition in case.conditions
            condition.id === case.baseline && continue
            differences = Float64[]
            raw_differences = Float64[]
            for key in sort!(collect(keys(baseline_rows)))
                baseline = baseline_rows[key]
                candidate = condition_rows[condition.id][key]
                if !ismissing(baseline.normalized_score) && !ismissing(candidate.normalized_score)
                    push!(differences, candidate.normalized_score - baseline.normalized_score)
                end
                if !ismissing(baseline.raw_score) && !ismissing(candidate.raw_score)
                    push!(raw_differences, candidate.raw_score - baseline.raw_score)
                end
            end
            normalized = _benchmark_mean_std(differences)
            raw = _benchmark_mean_std(raw_differences)
            push!(output, (
                case=case.case,
                condition=condition.id,
                baseline=case.baseline,
                n=normalized.n,
                raw_difference=raw.mean,
                raw_ci_lower=raw.lower,
                raw_ci_upper=raw.upper,
                normalized_difference=normalized.mean,
                normalized_ci_lower=normalized.lower,
                normalized_ci_upper=normalized.upper,
                interval_method=:paired_student_t_95,
            ))
        end
    end
    return output
end

function tables(result::BenchmarkResult)
    trials = _benchmark_trial_rows(result)
    return (
        trials=trials,
        statistics=_benchmark_statistics(trials),
        contrasts=_benchmark_contrasts(result),
    )
end

function summary(result::BenchmarkResult)
    result_tables = tables(result)
    return (
        benchmark=result.plan.id,
        cases=Tuple(case.id for case in result.plan.cases),
        statistics=result_tables.statistics,
        contrasts=result_tables.contrasts,
    )
end
