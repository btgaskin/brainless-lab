using Statistics

struct ResolvedSweepCell{T<:EvaluationTarget}
    id::Symbol
    parameters::Dict{Symbol,Any}
    target::T
end

struct ResolvedSweepPlan{P<:SweepPlan,A<:Tuple,C<:Tuple,R<:RegistrySet} <:
       AbstractResolvedOperationPlan
    source::P
    axes::A
    cells::C
    registry::R
    rollouts::Int
end

struct SweepResult{P<:ResolvedSweepPlan,B<:Tuple} <: AbstractOperationResult
    plan::P
    batches::B
    trial_rows::Vector{NamedTuple}
    cell_summaries::Vector{NamedTuple}
end

function _sweep_axes(plan::SweepPlan, node::NodeSpec)
    if !isempty(plan.axes)
        return plan.axes
    end
    names = node_parameter_set(node, :sweep)
    isempty(names) && throw(ArgumentError(
        "node :$(node.id) has an empty :sweep parameter set",
    ))
    return Tuple(begin
        parameter = node_parameter(node, name)
        parameter.sweep === nothing && throw(ArgumentError(
            "node :$(node.id) parameter :$(name) is in :sweep but has no sweep values",
        ))
        SweepAxis(name, parameter.sweep)
    end for name in names)
end

function _validate_sweep_axes(axes::Tuple, node::NodeSpec)
    for axis in axes
        parameter = node_parameter(node, axis.parameter)
        foreach(value -> validate_parameter(parameter, value), axis.values)
    end
    return axes
end

function validate(plan::SweepPlan, registry::RegistrySet)
    resolved = resolve_composition(plan.target.composition, registry)
    axes = _sweep_axes(plan, resolved.node)
    _validate_sweep_axes(axes, resolved.node)
    return plan
end

function _factorial_parameter_cells(axes::Tuple)
    cells = [Dict{Symbol,Any}()]
    for axis in axes
        next = Dict{Symbol,Any}[]
        for cell in cells, value in axis.values
            parameters = copy(cell)
            parameters[axis.parameter] = value
            push!(next, parameters)
        end
        cells = next
    end
    return cells
end

function _one_at_a_time_parameter_cells(axes::Tuple)
    cells = Dict{Symbol,Any}[]
    for axis in axes, value in axis.values
        push!(cells, Dict{Symbol,Any}(axis.parameter => value))
    end
    return cells
end

function _sweep_composition(
    source::CompositionSpec,
    id::Symbol,
    parameter_updates,
)
    parameters = copy(source.parameters)
    merge!(parameters, parameter_updates)
    return CompositionSpec(
        id,
        source.node,
        source.task;
        body=source.body,
        n_agents=source.n_agents,
        n_nodes=source.n_nodes,
        parameters=parameters,
        task_options=source.task_options,
        body_options=source.body_options,
        interaction_cycle=source.interaction_cycle,
    )
end

function resolve(plan::SweepPlan, registry::RegistrySet)
    validate(plan, registry)
    node = node_spec(registry, plan.target.composition.node)
    axes = _sweep_axes(plan, node)
    parameter_cells = if plan.mode === :factorial
        _factorial_parameter_cells(axes)
    else
        _one_at_a_time_parameter_cells(axes)
    end
    isempty(parameter_cells) && throw(ArgumentError("sweep resolved to no cells"))

    rollout_count = BigInt(length(parameter_cells)) *
                    plan.target.evaluation.blocks *
                    plan.target.evaluation.trials_per_block
    rollout_count <= plan.max_rollouts || throw(ArgumentError(
        "sweep requires $(rollout_count) rollouts above max_rollouts=$(plan.max_rollouts)",
    ))

    cells = Vector{ResolvedSweepCell}(undef, length(parameter_cells))
    for (index, parameters) in enumerate(parameter_cells)
        cell_id = Symbol("cell_", lpad(index, 3, '0'))
        composition = _sweep_composition(
            plan.target.composition,
            Symbol(plan.target.composition.id, "__", cell_id),
            parameters,
        )
        resolve_composition(composition, registry)
        target = EvaluationTarget(cell_id, composition, plan.target.evaluation)
        cells[index] = ResolvedSweepCell(cell_id, parameters, target)
    end
    return ResolvedSweepPlan(
        plan,
        axes,
        Tuple(cells),
        registry,
        Int(rollout_count),
    )
end

_sweep_parameter_pairs(parameters::Dict{Symbol,Any}) =
    Tuple(key => parameters[key] for key in sort!(collect(keys(parameters)); by=string))

function _sweep_aggregate(values, policy::Symbol)
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

function _sweep_trial_rows(
    plan::ResolvedSweepPlan,
    batches::Tuple,
)
    rows = NamedTuple[]
    for (cell, batch) in zip(plan.cells, batches)
        parameters = _sweep_parameter_pairs(cell.parameters)
        for row in trial_table(batch)
            push!(rows, merge(
                (
                    operation=plan.source.id,
                    cell=cell.id,
                    parameters=parameters,
                ),
                row,
            ))
        end
    end
    return rows
end

function _sweep_cell_summaries(
    plan::ResolvedSweepPlan,
    rows::Vector{NamedTuple},
)
    summaries = NamedTuple[]
    policy = plan.source.target.evaluation.aggregate
    for cell in plan.cells
        selected = filter(row -> row.cell === cell.id, rows)
        viability = [row.viable for row in selected if !ismissing(row.viable)]
        push!(summaries, (
            operation=plan.source.id,
            cell=cell.id,
            parameters=_sweep_parameter_pairs(cell.parameters),
            n_trials=length(selected),
            aggregate=policy,
            raw_score=_sweep_aggregate((row.raw_score for row in selected), policy),
            normalized_score=_sweep_aggregate(
                (row.normalized_score for row in selected),
                policy,
            ),
            viable_fraction=isempty(viability) ? missing : mean(viability),
        ))
    end
    return summaries
end

function execute(plan::ResolvedSweepPlan)
    batches = Tuple(evaluate(cell.target; registry=plan.registry) for cell in plan.cells)
    rows = _sweep_trial_rows(plan, batches)
    summaries = _sweep_cell_summaries(plan, rows)
    return SweepResult(plan, batches, rows, summaries)
end

tables(result::SweepResult) = (
    trials=result.trial_rows,
    cells=result.cell_summaries,
)

summary(result::SweepResult) = (
    operation=:sweep,
    id=result.plan.source.id,
    mode=result.plan.source.mode,
    n_axes=length(result.plan.axes),
    n_cells=length(result.plan.cells),
    n_rollouts=length(result.trial_rows),
    aggregate=result.plan.source.target.evaluation.aggregate,
    cells=result.cell_summaries,
)
