struct ResolvedBenchmarkCase{C<:Tuple}
    id::Symbol
    conditions::C
    baseline::Symbol
end

struct ResolvedBenchmarkPlan{C<:Tuple} <: AbstractResolvedOperationPlan
    id::Symbol
    cases::C
    registry::RegistrySet
end

struct BenchmarkResult{P<:ResolvedBenchmarkPlan,B<:Tuple} <: AbstractOperationResult
    plan::P
    batches::B
end

function _validate_benchmark_case(case::BenchmarkCasePlan, registry::RegistrySet)
    baseline = only(condition for condition in case.conditions if condition.id === case.baseline)
    reference = baseline.evaluation
    for condition in case.conditions
        resolve_composition(condition.composition, registry)
        evaluation = condition.evaluation
        evaluation.blocks == reference.blocks || throw(ArgumentError(
            "benchmark case :$(case.id) conditions must use the same block count",
        ))
        evaluation.trials_per_block == reference.trials_per_block || throw(ArgumentError(
            "benchmark case :$(case.id) conditions must use the same trials_per_block",
        ))
        evaluation.root_seed == reference.root_seed || throw(ArgumentError(
            "benchmark case :$(case.id) conditions must share a root_seed for pairing",
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
    return ResolvedBenchmarkPlan(plan.id, cases, registry)
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

function _benchmark_mean_std(values)
    data = Float64[value for value in values if !ismissing(value)]
    isempty(data) && return (mean=missing, std=missing, n=0, lower=missing, upper=missing)
    mean_value = sum(data) / length(data)
    std_value = length(data) > 1 ? sqrt(sum((value - mean_value)^2 for value in data) / (length(data) - 1)) : 0.0
    half_width = length(data) > 1 ? 1.96 * std_value / sqrt(length(data)) : 0.0
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
            normalized_mean=normalized.mean,
            normalized_std=normalized.std,
            normalized_ci_lower=normalized.lower,
            normalized_ci_upper=normalized.upper,
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
                normalized_difference=normalized.mean,
                normalized_ci_lower=normalized.lower,
                normalized_ci_upper=normalized.upper,
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
