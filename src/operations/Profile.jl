const _PROFILE_BUILTIN_CHANNELS = Dict{Symbol,Tuple{Vararg{Symbol}}}(
    :branching_ratio => (:rate,),
    :branching_ratio_mr => (:rate,),
    :branching_ratio_mr_windowed => (:rate,),
    :branching_ratio_mr_conditioned => (:rate, :percepts),
    :avalanches => (:spikes,),
    :node_transfer_entropy => (:spikes,),
    :agent_transfer_entropy => (:poses,),
    :node_target_error => (:acts, :targets),
    :spectral_radius => (:spectral_radius,),
    :susceptibility => (:spikes,),
    :susceptibility_windowed => (:spikes,),
    :fano_factor => (:spikes,),
    :participation_ratio => (:spikes,),
    :swarm_regime => (:poses, :polarization, :milling),
    :correlation_length => (:poses,),
    :correlation_length_windowed => (:poses,),
    :contact_graph_clusters => (:poses,),
    :contact_graph_clusters_windowed => (:poses,),
    :distance_to_source => (:poses,),
    :forage_alignment => (:poses,),
    :lookout_follower_te => (:poses,),
    :own_colour_decodability => (:acts, :spikes),
    :wall_distance => (:poses,),
    :heading_error => (:scene,),
    :object_in_view => (:percepts,),
    :ball_paddle_distance => (:scene,),
    :shoal_need_satisfaction => (:needs,),
    :shoal_contact_summary => (:interactions,),
    :shoal_movement_summary => (:poses,),
    :shoal_group_movement_summary => (:poses,),
    :shoal_perceptual_graph => (:poses,),
)

"""A validated profile plan with its analysis and recorder contracts resolved."""
struct ResolvedProfilePlan{
    P<:ProfilePlan,
    R<:RegistrySet,
    C<:ResolvedComposition,
    A<:Tuple,
    H<:Tuple,
} <: AbstractResolvedOperationPlan
    plan::P
    registry::R
    composition::C
    analyses::A
    record_channels::H
end

"""One numeric statistic emitted by one analysis for one evaluation trial."""
struct ProfileAnalysisRow
    condition::Symbol
    block::Int
    trial::Int
    analysis::Symbol
    statistic::Symbol
    value::Float64
end

"""Across-trial descriptive summary for one analysis statistic."""
struct ProfileAnalysisSummary
    analysis::Symbol
    statistic::Symbol
    n_trials::Int
    n_finite::Int
    mean::Float64
    std::Float64
    minimum::Float64
    maximum::Float64
end

"""Compact descriptive summary of one completed profile operation."""
struct ProfileSummary{A<:Tuple,H<:Tuple,S<:Vector{ProfileAnalysisSummary}}
    plan::Symbol
    condition::Symbol
    blocks::Int
    trials::Int
    analyses::A
    record_channels::H
    raw_score_mean::Union{Missing,Float64}
    normalized_score_mean::Union{Missing,Float64}
    analysis_statistics::S
end

"""Typed result retaining raw trials and both tabular profile surfaces."""
struct ProfileResult{
    P<:ResolvedProfilePlan,
    B<:EvaluationBatch,
    T<:AbstractVector,
    A<:Vector{ProfileAnalysisRow},
    S<:ProfileSummary,
} <: AbstractOperationResult
    plan::P
    batch::B
    task_rows::T
    analysis_rows::A
    profile_summary::S
end

"""Context-rich wrapper for an analysis that could not produce profile rows."""
struct ProfileAnalysisError <: Exception
    plan::Symbol
    analysis::Symbol
    block::Int
    trial::Int
    cause::Any
end

function Base.showerror(io::IO, error::ProfileAnalysisError)
    print(
        io,
        "profile :",
        error.plan,
        " analysis :",
        error.analysis,
        " failed at block ",
        error.block,
        ", trial ",
        error.trial,
        ": ",
    )
    showerror(io, error.cause)
end

function _profile_analysis_ids(plan::ProfilePlan, registry::RegistrySet)
    isempty(plan.analyses) || return plan.analyses
    return node_spec(registry, plan.target.composition.node).default_analyses
end

function _profile_task_scope(spec::ImplementationSpec)
    metadata = spec.metadata
    hasproperty(metadata, :task) || return nothing
    scope = getproperty(metadata, :task)
    scope === nothing && return nothing
    scope isa Symbol || throw(ArgumentError(
        "analysis :$(spec.key) metadata.task must be a Symbol or nothing",
    ))
    return scope
end

function _profile_required_channels(spec::ImplementationSpec)
    metadata = spec.metadata
    if hasproperty(metadata, :required_channels)
        raw = getproperty(metadata, :required_channels)
        channels = _symbol_tuple(raw, "analysis :$(spec.key) required channels")
        return channels
    end
    return get(_PROFILE_BUILTIN_CHANNELS, spec.key, ())
end

function _resolve_profile_analyses(plan::ProfilePlan, registry::RegistrySet)
    task = plan.target.composition.task
    ids = _profile_analysis_ids(plan, registry)
    specs = Tuple(resolve(registry.analyses, id) for id in ids)
    for spec in specs
        scope = _profile_task_scope(spec)
        scope === nothing || scope === task || throw(ArgumentError(
            "analysis :$(spec.key) is scoped to task :$(scope), not :$(task)",
        ))
    end
    return specs
end

function _profile_record_channels(specs::Tuple)
    channels = Set{Symbol}()
    for spec in specs
        union!(channels, _profile_required_channels(spec))
    end
    return Tuple(sort!(collect(channels); by=string))
end

function validate(plan::ProfilePlan, registry::RegistrySet)
    resolve_composition(plan.target.composition, registry)
    specs = _resolve_profile_analyses(plan, registry)
    _profile_record_channels(specs)
    return plan
end

function resolve(plan::ProfilePlan, registry::RegistrySet)
    composition = resolve_composition(plan.target.composition, registry)
    specs = _resolve_profile_analyses(plan, registry)
    channels = _profile_record_channels(specs)
    return ResolvedProfilePlan(plan, registry, composition, specs, channels)
end

function _profile_finite_summary(values)
    raw = Float64.(vec(collect(values)))
    finite = filter(isfinite, raw)
    n = length(raw)
    n_finite = length(finite)
    if isempty(finite)
        return (
            n=Float64(n),
            finite_n=0.0,
            mean=NaN,
            std=NaN,
            minimum=NaN,
            maximum=NaN,
        )
    end
    mean = sum(finite) / n_finite
    variance = if n_finite <= 1
        0.0
    else
        sum((value - mean)^2 for value in finite) / (n_finite - 1)
    end
    return (
        n=Float64(n),
        finite_n=Float64(n_finite),
        mean=mean,
        std=sqrt(variance),
        minimum=minimum(finite),
        maximum=maximum(finite),
    )
end

function _profile_array_statistics!(out, prefix::Symbol, values)
    summary = _profile_finite_summary(values)
    for field in propertynames(summary)
        push!(out, Symbol(prefix, :_, field) => Float64(getproperty(summary, field)))
    end
    return out
end

function _profile_named_statistics(output::NamedTuple)
    source = if hasproperty(output, :summary) && getproperty(output, :summary) isa NamedTuple
        getproperty(output, :summary)
    else
        output
    end
    out = Pair{Symbol,Float64}[]
    for field in propertynames(source)
        value = getproperty(source, field)
        value isa Real || continue
        push!(out, field => Float64(value))
    end
    isempty(out) || return out

    for field in propertynames(source)
        value = getproperty(source, field)
        if value isa AbstractArray{<:Real} || (
            value isa Tuple && all(item -> item isa Real, value)
        )
            _profile_array_statistics!(out, field, value)
        end
    end
    return out
end

function _profile_statistics(output)
    if output isa Real
        return Pair{Symbol,Float64}[:value => Float64(output)]
    elseif output isa NamedTuple
        return _profile_named_statistics(output)
    elseif output isa AbstractArray{<:Real} || (
        output isa Tuple && all(item -> item isa Real, output)
    )
        out = Pair{Symbol,Float64}[]
        summary = _profile_finite_summary(output)
        for field in propertynames(summary)
            push!(out, field => Float64(getproperty(summary, field)))
        end
        return out
    end
    return Pair{Symbol,Float64}[]
end

function _profile_analysis_rows(
    plan::ResolvedProfilePlan,
    batch::EvaluationBatch,
)
    rows = ProfileAnalysisRow[]
    for trial in batch.trials
        for spec in plan.analyses
            statistics = try
                _profile_statistics(spec.implementation(trial.simulation))
            catch error
                throw(ProfileAnalysisError(
                    plan.plan.id,
                    spec.key,
                    trial.block,
                    trial.trial,
                    error,
                ))
            end
            isempty(statistics) && throw(ProfileAnalysisError(
                plan.plan.id,
                spec.key,
                trial.block,
                trial.trial,
                ArgumentError(
                    "analysis returned no numeric scalar or numeric-array statistics",
                ),
            ))
            for (statistic, value) in statistics
                push!(rows, ProfileAnalysisRow(
                    trial.condition,
                    trial.block,
                    trial.trial,
                    spec.key,
                    statistic,
                    value,
                ))
            end
        end
    end
    return rows
end

function _profile_optional_mean(rows, field::Symbol)
    values = Float64[]
    for row in rows
        value = getproperty(row, field)
        value === missing && continue
        number = Float64(value)
        isfinite(number) && push!(values, number)
    end
    isempty(values) && return missing
    return sum(values) / length(values)
end

function _profile_analysis_summaries(rows::Vector{ProfileAnalysisRow})
    groups = Dict{Tuple{Symbol,Symbol},Vector{ProfileAnalysisRow}}()
    for row in rows
        push!(get!(groups, (row.analysis, row.statistic), ProfileAnalysisRow[]), row)
    end
    summaries = ProfileAnalysisSummary[]
    for key in sort!(collect(keys(groups)); by=item -> (string(item[1]), string(item[2])))
        group = groups[key]
        values = [row.value for row in group]
        finite = filter(isfinite, values)
        trial_count = length(unique((row.block, row.trial) for row in group))
        if isempty(finite)
            push!(summaries, ProfileAnalysisSummary(
                key[1],
                key[2],
                trial_count,
                0,
                NaN,
                NaN,
                NaN,
                NaN,
            ))
            continue
        end
        mean = sum(finite) / length(finite)
        variance = length(finite) <= 1 ?
            0.0 :
            sum((value - mean)^2 for value in finite) / (length(finite) - 1)
        push!(summaries, ProfileAnalysisSummary(
            key[1],
            key[2],
            trial_count,
            length(finite),
            mean,
            sqrt(variance),
            minimum(finite),
            maximum(finite),
        ))
    end
    return summaries
end

function _profile_summary(
    plan::ResolvedProfilePlan,
    task_rows,
    analysis_rows::Vector{ProfileAnalysisRow},
)
    evaluation = plan.plan.target.evaluation
    return ProfileSummary(
        plan.plan.id,
        plan.plan.target.id,
        evaluation.blocks,
        length(task_rows),
        Tuple(spec.key for spec in plan.analyses),
        plan.record_channels,
        _profile_optional_mean(task_rows, :raw_score),
        _profile_optional_mean(task_rows, :normalized_score),
        _profile_analysis_summaries(analysis_rows),
    )
end

function execute(plan::ResolvedProfilePlan)
    batch = evaluate(
        plan.plan.target;
        registry=plan.registry,
        record=plan.record_channels,
        record_every=plan.plan.record_every,
    )
    task_rows = trial_table(batch)
    analysis_rows = _profile_analysis_rows(plan, batch)
    profile_summary = _profile_summary(plan, task_rows, analysis_rows)
    return ProfileResult(plan, batch, task_rows, analysis_rows, profile_summary)
end

tables(result::ProfileResult) = (
    task=result.task_rows,
    analyses=result.analysis_rows,
)

summary(result::ProfileResult) = result.profile_summary
