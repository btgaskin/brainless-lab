using Statistics

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

"""One aligned numeric series returned by a registered analysis."""
struct AnalysisSeries{X<:AbstractVector,V<:NamedTuple,M<:NamedTuple}
    id::Symbol
    coordinate::Symbol
    coordinates::X
    values::V
    metadata::M
end

function AnalysisSeries(
    id::Union{Symbol,AbstractString},
    coordinate::Union{Symbol,AbstractString},
    coordinates::AbstractVector{<:Real},
    values::NamedTuple;
    metadata::NamedTuple=NamedTuple(),
)
    id_ = _nonempty_symbol(id, "analysis series id")
    coordinate_ = _nonempty_symbol(coordinate, "analysis series coordinate")
    coordinates_ = Float64.(collect(coordinates))
    isempty(coordinates_) && throw(ArgumentError("analysis series must not be empty"))
    for statistic in propertynames(values)
        series = getproperty(values, statistic)
        series isa AbstractVector{<:Real} || throw(ArgumentError(
            "analysis series :$(id_) statistic :$(statistic) must be a numeric vector",
        ))
        length(series) == length(coordinates_) || throw(DimensionMismatch(
            "analysis series :$(id_) statistic :$(statistic) has length " *
            "$(length(series)); expected $(length(coordinates_))",
        ))
    end
    values_ = NamedTuple{propertynames(values)}(Tuple(
        Float64.(collect(getproperty(values, name)))
        for name in propertynames(values)
    ))
    return AnalysisSeries{
        typeof(coordinates_),
        typeof(values_),
        typeof(metadata),
    }(id_, coordinate_, coordinates_, values_, metadata)
end

"""Scalar statistics and aligned series emitted by one analysis call."""
struct AnalysisResult{S<:NamedTuple,R<:Tuple}
    statistics::S
    series::R
end

function AnalysisResult(;
    statistics::NamedTuple=NamedTuple(),
    series=(),
)
    series_ = series isa AnalysisSeries ? (series,) : Tuple(series)
    all(item -> item isa AnalysisSeries, series_) || throw(ArgumentError(
        "analysis result series must all be AnalysisSeries values",
    ))
    return AnalysisResult{typeof(statistics),typeof(series_)}(statistics, series_)
end

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
    analysis_options::Dict{Symbol,Dict{Symbol,Any}}
    record_channels::H
    compute_every::Dict{Symbol,Int}
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

"""One per-trial value from an aligned registered analysis series."""
struct ProfileAnalysisSeriesRow
    condition::Symbol
    block::Int
    trial::Int
    analysis::Symbol
    series::Symbol
    coordinate::Symbol
    index::Int
    coordinate_value::Float64
    statistic::Symbol
    value::Float64
end

"""Across-trial summary for one point in an aligned analysis series."""
struct ProfileAnalysisSeriesSummary
    condition::Symbol
    analysis::Symbol
    series::Symbol
    coordinate::Symbol
    index::Int
    coordinate_value::Float64
    statistic::Symbol
    n_trials::Int
    n_finite::Int
    mean::Float64
    std::Float64
    median::Float64
    q25::Float64
    q75::Float64
    minimum::Float64
    maximum::Float64
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
    normalized_n::Int
    normalized_floor_count::Int
    normalized_ceiling_count::Int
    normalized_censored_count::Int
    normalized_censored_fraction::Union{Missing,Float64}
    normalized_censoring::Union{Missing,String}
    analysis_statistics::S
end

"""Typed result retaining raw trials and both tabular profile surfaces."""
struct ProfileResult{
    P<:ResolvedProfilePlan,
    B<:EvaluationBatch,
    T<:AbstractVector,
    A<:Vector{ProfileAnalysisRow},
    R<:Vector{ProfileAnalysisSeriesRow},
    G<:Vector{ProfileAnalysisSeriesSummary},
    S<:ProfileSummary,
} <: AbstractOperationResult
    plan::P
    batch::B
    task_rows::T
    analysis_rows::A
    analysis_series_rows::R
    analysis_series_summaries::G
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
        isempty(channels) || return channels
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

function _resolve_profile_analysis_options(plan::ProfilePlan, specs::Tuple)
    selected = Set(spec.key for spec in specs)
    unknown = sort!(
        collect(setdiff(Set(keys(plan.analysis_options)), selected));
        by=string,
    )
    isempty(unknown) || throw(ArgumentError(
        "profile analysis_options reference unrequested analyses $(unknown)",
    ))
    return Dict{Symbol,Dict{Symbol,Any}}(
        spec.key => _resolve_options(
            "analysis",
            spec.key,
            spec.options,
            get(plan.analysis_options, spec.key, Dict{Symbol,Any}()),
        )
        for spec in specs
    )
end

function _profile_record_channels(specs::Tuple)
    channels = Set{Symbol}()
    for spec in specs
        union!(channels, _profile_required_channels(spec))
    end
    return Tuple(sort!(collect(channels); by=string))
end


function _validate_profile_compute_every(plan::ProfilePlan, channels::Tuple)
    unknown = sort!(
        collect(setdiff(Set(keys(plan.compute_every)), Set(channels)));
        by=string,
    )
    isempty(unknown) || throw(ArgumentError(
        "profile compute_every references channels not required by its analyses " *
        "$(unknown)",
    ))
    return plan.compute_every
end

function validate(plan::ProfilePlan, registry::RegistrySet)
    resolve_composition(plan.target.composition, registry)
    specs = _resolve_profile_analyses(plan, registry)
    _resolve_profile_analysis_options(plan, specs)
    channels = _profile_record_channels(specs)
    _validate_profile_compute_every(plan, channels)
    return _validate_plan_evaluations(plan, registry)
end

function resolve(plan::ProfilePlan, registry::RegistrySet)
    validate(plan, registry)
    composition = resolve_composition(plan.target.composition, registry)
    specs = _resolve_profile_analyses(plan, registry)
    options = _resolve_profile_analysis_options(plan, specs)
    channels = _profile_record_channels(specs)
    _validate_profile_compute_every(plan, channels)
    return ResolvedProfilePlan(
        plan,
        registry,
        composition,
        specs,
        options,
        channels,
        copy(plan.compute_every),
    )
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

_profile_result_statistics(output::AnalysisResult) = _profile_statistics(output.statistics)
_profile_result_statistics(output) = _profile_statistics(output)
_profile_result_series(output::AnalysisResult) = output.series
_profile_result_series(output) = ()

function _append_profile_series_rows!(
    rows::Vector{ProfileAnalysisSeriesRow},
    trial::EvaluationTrial,
    analysis::Symbol,
    series::AnalysisSeries,
)
    for statistic in propertynames(series.values)
        values = getproperty(series.values, statistic)
        for index in eachindex(series.coordinates, values)
            push!(rows, ProfileAnalysisSeriesRow(
                trial.condition,
                trial.block,
                trial.trial,
                analysis,
                series.id,
                series.coordinate,
                Int(index),
                Float64(series.coordinates[index]),
                statistic,
                Float64(values[index]),
            ))
        end
    end
    return rows
end

function _profile_analysis_rows(
    plan::ResolvedProfilePlan,
    batch::EvaluationBatch,
)
    rows = ProfileAnalysisRow[]
    series_rows = ProfileAnalysisSeriesRow[]
    for trial in batch.trials
        for spec in plan.analyses
            output = try
                options = plan.analysis_options[spec.key]
                spec.implementation(trial.simulation; options...)
            catch error
                throw(ProfileAnalysisError(
                    plan.plan.id,
                    spec.key,
                    trial.block,
                    trial.trial,
                    error,
                ))
            end
            statistics = _profile_result_statistics(output)
            series = _profile_result_series(output)
            isempty(statistics) && isempty(series) && throw(ProfileAnalysisError(
                plan.plan.id,
                spec.key,
                trial.block,
                trial.trial,
                ArgumentError(
                    "analysis returned no numeric scalar statistics or aligned series",
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
            for item in series
                _append_profile_series_rows!(
                    series_rows,
                    trial,
                    spec.key,
                    item,
                )
            end
        end
    end
    return rows, series_rows
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

function _profile_analysis_series_summaries(
    rows::Vector{ProfileAnalysisSeriesRow},
)
    key(row) = (
        row.condition,
        row.analysis,
        row.series,
        row.coordinate,
        row.index,
        row.statistic,
    )
    groups = Dict{Tuple{Symbol,Symbol,Symbol,Symbol,Int,Symbol},Vector{ProfileAnalysisSeriesRow}}()
    for row in rows
        push!(get!(groups, key(row), ProfileAnalysisSeriesRow[]), row)
    end
    summaries = ProfileAnalysisSeriesSummary[]
    for group_key in sort!(collect(keys(groups)); by=item -> (
        string(item[1]), string(item[2]), string(item[3]), item[5], string(item[6]),
    ))
        group = groups[group_key]
        coordinates = unique(row.coordinate_value for row in group)
        length(coordinates) == 1 || throw(ArgumentError(
            "analysis :$(group_key[2]) series :$(group_key[3]) coordinate values " *
            "do not align at index $(group_key[5])",
        ))
        values = sort!(Float64[row.value for row in group if isfinite(row.value)])
        n_trials = length(unique((row.block, row.trial) for row in group))
        if isempty(values)
            push!(summaries, ProfileAnalysisSeriesSummary(
                group_key[1],
                group_key[2],
                group_key[3],
                group_key[4],
                group_key[5],
                only(coordinates),
                group_key[6],
                n_trials,
                0,
                NaN,
                NaN,
                NaN,
                NaN,
                NaN,
                NaN,
                NaN,
            ))
            continue
        end
        push!(summaries, ProfileAnalysisSeriesSummary(
            group_key[1],
            group_key[2],
            group_key[3],
            group_key[4],
            group_key[5],
            only(coordinates),
            group_key[6],
            n_trials,
            length(values),
            mean(values),
            length(values) <= 1 ? 0.0 : std(values),
            median(values),
            quantile(values, 0.25),
            quantile(values, 0.75),
            first(values),
            last(values),
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
    censoring = _normalized_censoring_summary(task_rows)
    return ProfileSummary(
        plan.plan.id,
        plan.plan.target.id,
        evaluation.blocks,
        length(task_rows),
        Tuple(spec.key for spec in plan.analyses),
        plan.record_channels,
        _profile_optional_mean(task_rows, :raw_score),
        _profile_optional_mean(task_rows, :normalized_score),
        censoring.normalized_n,
        censoring.normalized_floor_count,
        censoring.normalized_ceiling_count,
        censoring.normalized_censored_count,
        censoring.normalized_censored_fraction,
        censoring.normalized_censoring,
        _profile_analysis_summaries(analysis_rows),
    )
end

function execute(plan::ResolvedProfilePlan)
    batch = evaluate(
        plan.plan.target;
        registry=plan.registry,
        record=plan.record_channels,
        record_every=plan.plan.record_every,
        compute_every=plan.compute_every,
    )
    task_rows = trial_table(batch)
    analysis_rows, analysis_series_rows = _profile_analysis_rows(plan, batch)
    analysis_series_summaries = _profile_analysis_series_summaries(
        analysis_series_rows,
    )
    profile_summary = _profile_summary(plan, task_rows, analysis_rows)
    return ProfileResult(
        plan,
        batch,
        task_rows,
        analysis_rows,
        analysis_series_rows,
        analysis_series_summaries,
        profile_summary,
    )
end

tables(result::ProfileResult) = (
    task=result.task_rows,
    analyses=result.analysis_rows,
    analysis_series=result.analysis_series_summaries,
)

summary(result::ProfileResult) = result.profile_summary
