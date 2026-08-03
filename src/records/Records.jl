using Dates
import SHA
using TOML

const RECORD_FORMAT = "brainlesslab-record"
const RECORD_FORMAT_VERSION = 1
const _RECORD_MANIFEST_ARTIFACT = joinpath("environment", "Manifest.toml")

operation_kind(::ProfilePlan) = :profile
operation_kind(::SweepPlan) = :sweep
operation_kind(::AblationPlan) = :ablate
operation_kind(::EvolutionPlan) = :evolve
operation_kind(::BenchmarkPlan) = :benchmark

function _record_id(plan::AbstractOperationPlan)
    timestamp = Dates.format(now(UTC), dateformat"yyyymmddTHHMMSS")
    suffix = string(time_ns(); base=16)
    return string(plan.id, "-", timestamp, "-", last(suffix, min(8, length(suffix))))
end

_record_repo_root() = normpath(joinpath(@__DIR__, "..", ".."))

function _record_manifest_path()
    project_path = Base.active_project()
    project_path === nothing && throw(ArgumentError(
        "recording requires an active Julia project with a resolved Manifest.toml; " *
        "start Julia with `--project=PATH` and run `using Pkg; Pkg.instantiate()` first",
    ))
    manifest_path = joinpath(dirname(project_path), "Manifest.toml")
    isfile(manifest_path) || throw(ArgumentError(
        "recording requires the active project's resolved Manifest.toml; run " *
        "`julia --project=$(dirname(project_path)) -e 'using Pkg; Pkg.instantiate()'` first",
    ))
    return manifest_path
end

function _record_git()
    root = _record_repo_root()
    sha = try
        readchomp(Cmd(`git rev-parse HEAD`; dir=root))
    catch
        "unknown"
    end
    state = try
        isempty(readchomp(Cmd(`git status --porcelain`; dir=root))) ? "clean" : "dirty"
    catch
        "unknown"
    end
    manifest_path = _record_manifest_path()
    manifest = read(manifest_path)
    manifest_sha256 = bytes2hex(SHA.sha256(manifest))
    return (;
        sha,
        state,
        manifest_sha256,
        manifest,
    )
end

function _write_record_manifest(directory::AbstractString, git)
    bytes2hex(SHA.sha256(git.manifest)) == git.manifest_sha256 ||
        throw(ArgumentError("resolved manifest does not match its recorded digest"))
    path = joinpath(directory, _RECORD_MANIFEST_ARTIFACT)
    islink(path) && throw(ArgumentError(
        "record manifest path must not be a symbolic link",
    ))
    mkpath(dirname(path))
    staging = joinpath(
        dirname(path),
        string(".", basename(path), ".staging-", string(time_ns(); base=16)),
    )
    try
        open(staging, "w") do io
            write(io, git.manifest)
        end
        mv(staging, path; force=true)
    finally
        ispath(staging) && rm(staging)
    end
    return path
end

function _csv_escape(value)
    text = if ismissing(value)
        ""
    elseif value isa Symbol
        String(value)
    elseif value isa AbstractString
        String(value)
    elseif value isa Tuple || value isa NamedTuple || value isa AbstractVector || value isa AbstractDict
        _json(value)
    else
        string(value)
    end
    return occursin(r"[\",\n\r]", text) ? "\"" * replace(text, '"' => "\"\"") * "\"" : text
end

_row_names(row::NamedTuple) = propertynames(row)
_row_names(row) = propertynames(row)

function _write_csv(path::AbstractString, rows; columns=nothing)
    data = collect(rows)
    names = if columns !== nothing
        Tuple(Symbol(column) for column in columns)
    elseif isempty(data)
        ()
    else
        ordered = Symbol[]
        seen = Set{Symbol}()
        for row in data, name in _row_names(row)
            name in seen && continue
            push!(ordered, name)
            push!(seen, name)
        end
        Tuple(ordered)
    end
    open(path, "w") do io
        isempty(names) && return
        println(io, join(String.(names), ','))
        for row in data
            println(io, join((
                _csv_escape(name in propertynames(row) ? getproperty(row, name) : missing)
                for name in names
            ), ','))
        end
    end
    return String(path)
end

function _write_csv_atomic(path::AbstractString, rows; columns=nothing)
    staging = joinpath(
        dirname(path),
        string(".", basename(path), ".staging-", string(time_ns(); base=16)),
    )
    try
        _write_csv(staging, rows; columns)
        mv(staging, path; force=true)
    finally
        ispath(staging) && rm(staging)
    end
    return String(path)
end

function _read_record_csv(path::AbstractString)
    isfile(path) || throw(ArgumentError("evolution record is missing $(path)"))
    text = read(path, String)
    parsed = Vector{Vector{String}}()
    fields = String[]
    field = IOBuffer()
    quoted = false
    closed_quote = false
    field_started = false
    index = firstindex(text)
    while index <= lastindex(text)
        character = text[index]
        if quoted
            if character == '"'
                following = nextind(text, index)
                if following <= lastindex(text) && text[following] == '"'
                    write(field, '"')
                    index = following
                else
                    quoted = false
                    closed_quote = true
                end
            else
                write(field, character)
            end
        elseif character == '"'
            field_started && throw(ArgumentError(
                "CSV quote appears inside an unquoted field in $(path)",
            ))
            quoted = true
            field_started = true
        elseif character == ','
            push!(fields, String(take!(field)))
            field_started = false
            closed_quote = false
        elseif character == '\n'
            push!(fields, String(take!(field)))
            push!(parsed, fields)
            fields = String[]
            field_started = false
            closed_quote = false
        elseif character == '\r'
            following = nextind(text, index)
            if following > lastindex(text) || text[following] != '\n'
                push!(fields, String(take!(field)))
                push!(parsed, fields)
                fields = String[]
                field_started = false
                closed_quote = false
            end
        else
            closed_quote && throw(ArgumentError(
                "CSV quoted field has trailing content in $(path)",
            ))
            write(field, character)
            field_started = true
        end
        index = nextind(text, index)
    end
    quoted && throw(ArgumentError("CSV has an unterminated quoted field in $(path)"))
    if field_started || closed_quote || !isempty(fields)
        push!(fields, String(take!(field)))
        push!(parsed, fields)
    end
    isempty(parsed) && throw(ArgumentError("evolution CSV is empty: $(path)"))
    header_text = first(parsed)
    any(isempty, header_text) && throw(ArgumentError(
        "evolution CSV has an empty header in $(path)",
    ))
    header = Tuple(Symbol.(header_text))
    length(unique(header)) == length(header) || throw(ArgumentError(
        "evolution CSV has duplicate headers in $(path)",
    ))
    rows = NamedTuple[]
    for values in Iterators.drop(parsed, 1)
        length(values) == length(header) || throw(ArgumentError(
            "evolution CSV row in $(path) has $(length(values)) fields; " *
            "expected $(length(header))",
        ))
        push!(rows, NamedTuple{header}(Tuple(values)))
    end
    return rows
end

function _require_record_columns(rows, required, path::AbstractString)
    names = isempty(rows) ? begin
        text = readline(path)
        Tuple(Symbol.(split(chomp(text), ',')))
    end : propertynames(first(rows))
    missing_columns = setdiff(collect(required), collect(names))
    isempty(missing_columns) || throw(ArgumentError(
        "evolution CSV $(path) is missing columns " * join(string.(missing_columns), ", "),
    ))
    return rows
end

function _record_json_escape(text::AbstractString)
    escaped = replace(String(text), '\\' => "\\\\", '"' => "\\\"")
    escaped = replace(escaped, '\n' => "\\n", '\r' => "\\r", '\t' => "\\t")
    return '"' * escaped * '"'
end

function _json(value)
    value === nothing && return "null"
    ismissing(value) && return "null"
    value isa Bool && return value ? "true" : "false"
    value isa Integer && return string(value)
    value isa AbstractFloat && return isfinite(value) ? string(value) : "null"
    value isa Symbol && return _record_json_escape(String(value))
    value isa AbstractString && return _record_json_escape(value)
    value isa Pair && return _json(Dict(string(first(value)) => last(value)))
    if value isa NamedTuple
        return "{" * join(
            (_record_json_escape(String(name)) * ":" * _json(getproperty(value, name)) for name in propertynames(value)),
            ',',
        ) * "}"
    end
    if value isa AbstractDict
        entries = sort!(collect(pairs(value)); by=pair -> string(first(pair)))
        return "{" * join(
            (_record_json_escape(string(first(pair))) * ":" * _json(last(pair)) for pair in entries),
            ',',
        ) * "}"
    end
    if value isa Tuple || value isa AbstractVector
        return "[" * join((_json(item) for item in value), ',') * "]"
    end
    names = propertynames(value)
    isempty(names) && return _record_json_escape(string(value))
    return _json(NamedTuple{names}(Tuple(getproperty(value, name) for name in names)))
end

function _primary_trials(result::ProfileResult)
    return result.task_rows
end
_primary_trials(result::SweepResult) = result.trial_rows
_primary_trials(result::AblationResult) = result.trial_rows
_primary_trials(result::BenchmarkResult) = tables(result).trials
function _primary_trials(result::EvolutionResult)
    output = tables(result)
    return vcat(output.candidate_trials, output.heldout_trials)
end

function _record_statistics(result::AbstractOperationResult)
    output = tables(result)
    hasproperty(output, :statistics) && return output.statistics
    hasproperty(output, :cells) && return output.cells
    hasproperty(output, :cases) && return output.cases
    if result isa ProfileResult
        return [(
            analysis=row.analysis,
            statistic=row.statistic,
            n_trials=row.n_trials,
            n_finite=row.n_finite,
            mean=row.mean,
            std=row.std,
            minimum=row.minimum,
            maximum=row.maximum,
        ) for row in result.profile_summary.analysis_statistics]
    end
    if result isa EvolutionResult
        return [(
            strategy=result.plan.strategy.key,
            iterations=result.plan.run.iterations,
            candidates=length(result.candidates),
            valid_candidates=count(candidate -> candidate.valid, result.candidates),
            models=Tuple(model.model_id for model in result.models),
            heldout_targets=Tuple(evaluation.target for evaluation in result.heldout),
            heldout_scores=Tuple(evaluation.aggregate for evaluation in result.heldout),
        )]
    end
    return NamedTuple[]
end

function _record_contrasts(result::AbstractOperationResult)
    output = tables(result)
    return hasproperty(output, :contrasts) ? output.contrasts : NamedTuple[]
end

const _SEED_ROW_NAMES = (
    :phase,
    :case,
    :cell,
    :ablation,
    :heldout_target,
    :generation,
    :individual,
    :condition,
    :block,
    :trial,
    :agent,
    :stream,
    :seed,
)

function _append_seed_rows!(rows, batch::EvaluationBatch; context=NamedTuple())
    for trial in batch.trials, (agent, ledger) in enumerate(trial.seeds), stream in propertynames(ledger)
        values = merge(
            (
                phase=missing,
                case=missing,
                cell=missing,
                ablation=missing,
                heldout_target=missing,
                generation=missing,
                individual=missing,
            ),
            context,
            (
                condition=trial.condition,
                block=trial.block,
                trial=trial.trial,
                agent=agent,
                stream=stream,
                seed=getproperty(ledger, stream),
            ),
        )
        push!(rows, NamedTuple{_SEED_ROW_NAMES}(Tuple(values[name] for name in _SEED_ROW_NAMES)))
    end
    return rows
end

function _record_seed_rows(result::ProfileResult)
    return _append_seed_rows!(NamedTuple[], result.batch)
end

function _record_seed_rows(result::SweepResult)
    rows = NamedTuple[]
    for (cell, batch) in zip(result.plan.cells, result.batches)
        _append_seed_rows!(rows, batch; context=(cell=cell.id,))
    end
    return rows
end

function _record_seed_rows(result::AblationResult)
    rows = NamedTuple[]
    for (case, batch) in zip(result.plan.cases, result.batches)
        _append_seed_rows!(
            rows,
            batch;
            context=(
                case=case.id,
                ablation=case.ablation === nothing ? :none : case.ablation.id,
            ),
        )
    end
    return rows
end

function _evolution_seed_rows(candidates, heldout=EvolutionEvaluation[])
    rows = NamedTuple[]
    for candidate in candidates, evaluation in candidate.evaluations
        for row in evaluation.seed_rows
            values = (
                phase=:development,
                case=missing,
                cell=missing,
                ablation=missing,
                heldout_target=missing,
                generation=candidate.iteration,
                individual=candidate.id,
                condition=row.condition,
                block=row.block,
                trial=row.trial,
                agent=row.agent,
                stream=row.stream,
                seed=row.seed,
            )
            push!(rows, NamedTuple{_SEED_ROW_NAMES}(
                Tuple(values[name] for name in _SEED_ROW_NAMES),
            ))
        end
    end
    for evaluation in heldout
        for row in evaluation.seed_rows
            values = (
                phase=:heldout,
                case=missing,
                cell=missing,
                ablation=missing,
                heldout_target=evaluation.target,
                generation=missing,
                individual=missing,
                condition=row.condition,
                block=row.block,
                trial=row.trial,
                agent=row.agent,
                stream=row.stream,
                seed=row.seed,
            )
            push!(rows, NamedTuple{_SEED_ROW_NAMES}(
                Tuple(values[name] for name in _SEED_ROW_NAMES),
            ))
        end
    end
    return rows
end

_record_seed_rows(result::EvolutionResult) =
    _evolution_seed_rows(result.candidates, result.heldout)

function _record_seed_rows(result::BenchmarkResult)
    rows = NamedTuple[]
    for case in result.batches, condition in case.conditions
        _append_seed_rows!(rows, condition.batch; context=(case=case.case,))
    end
    return rows
end

function _record_task_metric_rows(trials)
    names = (
        :phase,
        :case,
        :cell,
        :ablation,
        :heldout_target,
        :condition,
        :block,
        :trial,
        :window,
        :score_key,
        :raw_score,
        :normalized_score,
        :normalized_bound,
        :viable,
        :liveness,
    )
    return [NamedTuple{names}(Tuple(
        name in propertynames(row) ? getproperty(row, name) : missing
        for name in names
    )) for row in trials]
end

function _table_path(name::Symbol)
    name === :trials && return joinpath("data", "trials.csv")
    name === :task && return joinpath("data", "task_metrics.csv")
    name === :analyses && return joinpath("data", "analyses.csv")
    name === :cells && return joinpath("data", "sweep_cells.csv")
    name === :convergence && return joinpath("data", "evolution_history.csv")
    name === :candidate_trials && return joinpath("data", "candidate_trials.csv")
    name === :champion_parameters && return joinpath("data", "evolved_parameters.csv")
    name === :statistics && return joinpath("summary", "statistics.csv")
    name === :contrasts && return joinpath("summary", "contrasts.csv")
    return joinpath("data", string(name, ".csv"))
end

function _empty_table_columns(name::Symbol)
    name === :analyses && return (:condition, :block, :trial, :analysis, :statistic, :value)
    name === :convergence && return (
        :iteration, :target, :candidates, :valid_candidates,
        :score_best, :score_mean, :score_worst,
    )
    name === :candidates && return (
        :iteration, :candidate, :valid, :coordinates, :scores,
    )
    name === :candidate_trials && return (
        :phase, :iteration, :candidate, :condition, :block, :trial,
        :window, :seed_ledger_agents, :topology_seed, :world_seed, :initial_state, :score_key,
        :raw_score, :normalized_score, :normalized_bound, :viable, :liveness,
        :measure_value,
    )
    name === :candidate_scores && return (
        :iteration, :candidate, :target, :measure, :valid, :score,
    )
    name === :models && return (
        :model_id, :role, :coordinates, :scores, :metadata,
    )
    name === :heldout && return (:target, :measure, :score, :trials)
    name === :heldout_trials && return (
        :phase, :heldout_target,
        :condition, :block, :trial, :window, :seed_ledger_agents, :topology_seed,
        :world_seed, :initial_state, :score_key,
        :raw_score, :normalized_score, :normalized_bound, :viable, :liveness,
    )
    name === :contrasts && return (
        :case, :condition, :baseline, :n, :raw_difference, :raw_ci_lower,
        :raw_ci_upper, :normalized_difference, :normalized_ci_lower,
        :normalized_ci_upper, :condition_normalized_floor_count,
        :condition_normalized_ceiling_count, :baseline_normalized_floor_count,
        :baseline_normalized_ceiling_count, :normalized_censored_pair_count,
        :normalized_censored_pair_fraction, :normalized_interval_calibrated,
        :interval_method,
    )
    return (:empty,)
end

function _html_escape(value)
    return replace(
        string(value),
        '&' => "&amp;",
        '<' => "&lt;",
        '>' => "&gt;",
        '"' => "&quot;",
    )
end

function _html_table(title::AbstractString, rows; limit::Integer=200)
    data = collect(rows)
    isempty(data) && return "<section><h2>$(_html_escape(title))</h2><p>No rows.</p></section>"
    names = propertynames(first(data))
    header = join(("<th>$(_html_escape(name))</th>" for name in names))
    body = join((
        "<tr>" * join(("<td>$(_html_escape(getproperty(row, name)))</td>" for name in names)) * "</tr>"
        for row in Iterators.take(data, Int(limit))
    ))
    note = length(data) > limit ? "<p>Showing $(limit) of $(length(data)) rows; CSV is authoritative.</p>" : ""
    return "<section><h2>$(_html_escape(title))</h2>$(note)<div class=table-wrap><table><thead><tr>$(header)</tr></thead><tbody>$(body)</tbody></table></div></section>"
end

function _svg_series(rows, x_name::Symbol, y_name::Symbol; title="")
    points = Tuple{Float64,Float64}[]
    for row in rows
        names = propertynames(row)
        x_name in names && y_name in names || continue
        x = getproperty(row, x_name)
        y = getproperty(row, y_name)
        (x isa Real && y isa Real && isfinite(x) && isfinite(y)) || continue
        push!(points, (Float64(x), Float64(y)))
    end
    isempty(points) && return ""
    xs = first.(points)
    ys = last.(points)
    xmin, xmax = extrema(xs)
    ymin, ymax = extrema(ys)
    sx(x) = 40 + 700 * (x - xmin) / max(xmax - xmin, eps())
    sy(y) = 250 - 200 * (y - ymin) / max(ymax - ymin, eps())
    path = join((string(sx(x), ",", sy(y)) for (x, y) in points), ' ')
    return "<section><h2>$(_html_escape(title))</h2><svg viewBox='0 0 780 280' role=img><line x1=40 y1=250 x2=740 y2=250 class=axis /><line x1=40 y1=50 x2=40 y2=250 class=axis /><polyline points='$path' class=series /></svg></section>"
end

function _operation_method(kind::Symbol)
    kind === :profile && return "Runs the declared analyses over every raw evaluation trial. Analysis tables are descriptive and do not change the task outcome contract."
    kind === :sweep && return "Evaluates declared parameter cells under paired block and trial seeds. Cells are development results, not confirmed optima."
    kind === :ablate && return "Compares an implicit baseline with declared capability-checked interventions under paired evaluation seeds."
    kind === :evolve && return "Searches a fixed experimental node design, records every candidate and seed, and emits selected, Pareto, or archive model artifacts. Cells are development results, not confirmed optima. Scalar SepCMA models may then be evaluated on held-out targets."
    kind === :benchmark && return "Reports each task separately with 95% Student-t intervals and counts at each normalised-score bound. Intervals over censored normalised values are descriptive, not calibrated. Cases with a declared baseline also report paired within-task contrasts. No cross-task aggregate is formed."
    return "Executes the declared BrainlessLab operation."
end

function _plan_targets(plan::ProfilePlan)
    return (plan.target,)
end
_plan_targets(plan::SweepPlan) = (plan.target,)
_plan_targets(plan::AblationPlan) = (plan.target,)
_plan_targets(plan::EvolutionPlan) = (
    plan.training_targets...,
    plan.heldout_targets...,
)
function _plan_targets(plan::BenchmarkPlan)
    output = EvaluationTarget[]
    seen = Set{Symbol}()
    for case in plan.cases, target in case.conditions
        target.id in seen && continue
        push!(output, target)
        push!(seen, target.id)
    end
    return Tuple(output)
end

function _equations_html(plan::AbstractOperationPlan, registry::RegistrySet)
    ids = unique(target.composition.node for target in _plan_targets(plan))
    sections = String[]
    for id in ids
        node = node_spec(registry, id)
        isempty(node.equations) && continue
        equations = join((
            "<article><h3>$(_html_escape(equation.title))</h3><div class=equation><code>$(_html_escape(equation.latex))</code></div><p>$(_html_escape(equation.description))</p></article>"
            for equation in node.equations
        ))
        push!(sections, "<section><h2>$(_html_escape(titlecase(String(id)))) equations</h2>$(equations)</section>")
    end
    return join(sections)
end

function _render_report(
    path::AbstractString,
    plan::AbstractOperationPlan,
    result::AbstractOperationResult,
    registry::RegistrySet,
)
    kind = operation_kind(plan)
    output = tables(result)
    sections = String[]
    for name in propertynames(output)
        push!(sections, _html_table(replace(String(name), '_' => ' '), getproperty(output, name)))
    end
    chart = hasproperty(output, :convergence) ?
        _svg_series(output.convergence, :iteration, :score_best; title="Convergence") : ""
    html = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(_html_escape(plan.id)) · BrainlessLab</title>
<style>
:root{color-scheme:light dark;--paper:#f5f2ea;--ink:#181b1c;--muted:#657074;--accent:#087f8c;--line:#c9cec9}*{box-sizing:border-box}body{margin:0;font:16px/1.55 ui-sans-serif,system-ui;background:var(--paper);color:var(--ink)}main{max-width:1120px;margin:auto;padding:64px 32px 120px}header{border-bottom:1px solid var(--line);padding-bottom:36px;margin-bottom:48px}h1{font:600 clamp(2.4rem,7vw,5.4rem)/.96 ui-serif,Georgia;margin:.2em 0}h2{font:500 2rem/1.1 ui-serif,Georgia;margin-top:2.5em}h3{margin-top:2em}.eyebrow{letter-spacing:.13em;text-transform:uppercase;color:var(--accent);font-size:.76rem}nav a{margin-right:1.2rem;color:var(--accent)}.table-wrap{overflow:auto;border:1px solid var(--line)}table{border-collapse:collapse;width:100%;font-size:.82rem}th,td{padding:.6rem .75rem;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}th{position:sticky;top:0;background:var(--paper)}.equation{overflow:auto;padding:1rem;border-left:3px solid var(--accent);font-family:ui-monospace,monospace}.axis{stroke:var(--muted);stroke-width:1}.series{fill:none;stroke:var(--accent);stroke-width:3}svg{width:100%;background:rgba(255,255,255,.35);border:1px solid var(--line)}code{font-family:ui-monospace,monospace}@media(prefers-color-scheme:dark){:root{--paper:#121718;--ink:#edf1ee;--muted:#9aa5a5;--line:#354041}}
</style></head><body><main><header><div class=eyebrow>BrainlessLab · $(_html_escape(kind))</div><h1>$(_html_escape(plan.id))</h1><p>$(_html_escape(_operation_method(kind)))</p><nav><a href=#method>Method</a><a href=#results>Results</a><a href=#equations>Equations</a></nav></header>
<section id=method><h2>Method</h2><p>$(_html_escape(_operation_method(kind)))</p><p>Normalised task scores are clamped to their declared anchors. Bound counts remain visible beside aggregate scores; a Student-t interval over censored values is not a calibrated interval.</p><p>The CSV tables are the authoritative tabular outputs. They and this report are generated from the same typed result.</p></section>
<div id=results>$(chart)$(join(sections))</div><div id=equations>$(_equations_html(plan, registry))</div>
</main></body></html>"""
    open(path, "w") do io
        write(io, html)
    end
    return String(path)
end

_result_source(result::ProfileResult) = result.plan.plan
_result_source(result::SweepResult) = result.plan.source
_result_source(result::AblationResult) = result.plan.source
_result_source(result::EvolutionResult) = result.plan.plan
_result_source(result::BenchmarkResult) = result.plan.source

function _assert_record_pair(plan::AbstractOperationPlan, result::AbstractOperationResult)
    source = _result_source(result)
    plan_document(plan) == plan_document(source) || throw(ArgumentError(
        "record plan does not match the operation plan that produced the result",
    ))
    return result
end

_record_batches(result::ProfileResult) = (result.batch,)
_record_batches(result::SweepResult) = result.batches
_record_batches(result::AblationResult) = result.batches
function _record_batches(result::EvolutionResult)
    batches = EvaluationBatch[]
    seen = Set{Symbol}()
    for candidate in result.candidates, evaluation in candidate.evaluations
        evaluation.batch isa EvaluationBatch || continue
        evaluation.target in seen && continue
        push!(batches, evaluation.batch)
        push!(seen, evaluation.target)
    end
    for evaluation in result.heldout
        evaluation.batch isa EvaluationBatch || continue
        push!(batches, evaluation.batch)
    end
    return Tuple(batches)
end
function _record_batches(result::BenchmarkResult)
    batches = EvaluationBatch[]
    for case in result.batches, condition in case.conditions
        push!(batches, condition.batch)
    end
    return Tuple(batches)
end

function _resolved_cycle_document(cycle)
    cycle === nothing && return Dict{String,Any}("kind" => "reservoir_default")
    return _interaction_cycle_document(cycle)
end

function _resolved_target_document(batch::EvaluationBatch)
    resolved = batch.resolved
    target = batch.target
    document = Dict{String,Any}(
        "id" => String(target.id),
        "composition_id" => String(resolved.id),
        "node" => String(resolved.node.id),
        "task" => String(resolved.task.name),
        "n_nodes" => resolved.n_nodes,
        "parameters" => _string_dict(resolved.parameters),
        "task_options" => _string_dict(resolved.task_options),
        "body_options" => _string_dict(resolved.body_options),
        "interaction_cycle" => _resolved_cycle_document(resolved.interaction_cycle),
        "evaluation" => _evaluation_document(target.evaluation),
        "effective_window" => target.evaluation.horizon - target.evaluation.warmup,
    )
    resolved.body === nothing || (document["body"] = String(resolved.body.key))
    resolved.n_agents === nothing || (document["n_agents"] = resolved.n_agents)
    return document
end

function _resolved_target_document(
    target::EvaluationTarget,
    registry::RegistrySet,
)
    resolved = resolve_composition(target.composition, registry)
    document = Dict{String,Any}(
        "id" => String(target.id),
        "composition_id" => String(resolved.id),
        "node" => String(resolved.node.id),
        "task" => String(resolved.task.name),
        "n_nodes" => resolved.n_nodes,
        "parameters" => _string_dict(resolved.parameters),
        "task_options" => _string_dict(resolved.task_options),
        "body_options" => _string_dict(resolved.body_options),
        "interaction_cycle" => _resolved_cycle_document(resolved.interaction_cycle),
        "evaluation" => _evaluation_document(target.evaluation),
        "effective_window" => target.evaluation.horizon - target.evaluation.warmup,
    )
    resolved.body === nothing || (document["body"] = String(resolved.body.key))
    resolved.n_agents === nothing || (document["n_agents"] = resolved.n_agents)
    return document
end

function _resolution_details(result::ProfileResult)
    return Dict{String,Any}(
        "analyses" => collect(String.(getfield.(result.plan.analyses, :key))),
        "record_channels" => collect(String.(result.plan.record_channels)),
        "record_every" => result.plan.plan.record_every,
    )
end

function _resolution_details(result::SweepResult)
    return Dict{String,Any}(
        "mode" => String(result.plan.source.mode),
        "rollouts" => result.plan.rollouts,
        "axes" => [Dict{String,Any}(
            "parameter" => String(axis.parameter),
            "values" => [_plan_toml_value(value) for value in axis.values],
        ) for axis in result.plan.axes],
        "cells" => [Dict{String,Any}(
            "id" => String(cell.id),
            "parameters" => _string_dict(cell.parameters),
        ) for cell in result.plan.cells],
    )
end

function _resolution_details(result::AblationResult)
    return Dict{String,Any}(
        "cases" => [Dict{String,Any}(
            "id" => String(case.id),
            "ablation" => case.ablation === nothing ? "baseline" : String(case.ablation.id),
            "stage" => case.ablation === nothing ? "none" : String(case.ablation.stage),
        ) for case in result.plan.cases],
    )
end

function _evolution_resolution_details(plan::ResolvedEvolutionPlan)
    return Dict{String,Any}(
        "strategy" => String(plan.strategy.key),
        "run" => Evolution.run_config_document(plan.run),
        "node" => String(plan.node.id),
        "model_type" => string(plan.design.model_type),
        "dimension" => plan.design.dimension,
        "blocks" => [
            Dict{String,Any}(
                "name" => String(block.name),
                "shape" => collect(block.shape),
                "first" => first(block.range),
                "last" => last(block.range),
            )
            for block in plan.design.blocks
        ],
    )
end

_resolution_details(result::EvolutionResult) =
    _evolution_resolution_details(result.plan)

function _resolution_details(result::BenchmarkResult)
    return Dict{String,Any}(
        "cases" => [
            begin
                case_document = Dict{String,Any}(
                    "id" => String(case.id),
                    "conditions" => [String(condition.target.id) for condition in case.conditions],
                )
                case.baseline === nothing ||
                    (case_document["baseline"] = String(case.baseline))
                case_document
            end
            for case in result.plan.cases
        ],
    )
end

function _resolved_document(plan::AbstractOperationPlan, result::AbstractOperationResult)
    return Dict{String,Any}(
        "format" => "brainlesslab-resolution",
        "format_version" => 1,
        "operation" => String(operation_kind(plan)),
        "id" => String(plan.id),
        "result_type" => string(nameof(typeof(result))),
        "targets" => [_resolved_target_document(batch) for batch in _record_batches(result)],
        "operation_settings" => _resolution_details(result),
    )
end

function _resolved_document(
    plan::EvolutionPlan,
    result::EvolutionResult,
)
    return Dict{String,Any}(
        "format" => "brainlesslab-resolution",
        "format_version" => 1,
        "operation" => "evolve",
        "id" => String(plan.id),
        "result_type" => string(nameof(typeof(result))),
        "targets" => [
            _resolved_target_document(target, result.plan.registry)
            for target in operation_targets(plan)
        ],
        "operation_settings" => _resolution_details(result),
    )
end

function _resolved_document(
    plan::EvolutionPlan,
    resolved::ResolvedEvolutionPlan,
)
    return Dict{String,Any}(
        "format" => "brainlesslab-resolution",
        "format_version" => 1,
        "operation" => "evolve",
        "id" => String(plan.id),
        "result_type" => "pending",
        "targets" => [
            _resolved_target_document(target, resolved.registry)
            for target in operation_targets(plan)
        ],
        "operation_settings" => _evolution_resolution_details(resolved),
    )
end

function _write_or_reuse_evolution_models(
    directory::AbstractString,
    result::EvolutionResult,
)
    path = joinpath(directory, "models")
    expected_ids = Set(model.model_id for model in result.models)
    if islink(path)
        throw(ArgumentError("model record models/ must not be a symbolic link"))
    elseif ispath(path)
        isdir(path) || throw(ArgumentError(
            "model artifact path is not a directory: $(path)",
        ))
        references = try
            index = _evolution_read_index(joinpath(path, "models.csv"))
            Set(keys(index)) == expected_ids || throw(ArgumentError(
                "model artifact index does not match the completed result",
            ))
            restored = [
                Evolution.model_reference(directory, model.model_id)
                for model in result.models
            ]
            all(reference -> reference.node === result.plan.node.id, restored) ||
                throw(ArgumentError(
                    "model artifact node does not match the completed result",
                ))
            restored
        catch error
            error isa InterruptException && rethrow()
            nothing
        end
        references === nothing || return references
        rm(path; recursive=true)
    end
    return Evolution.write_models(
        directory,
        result.plan.node.id,
        result.plan.design,
        [
            (
                model_id=model.model_id,
                role=model.role,
                model=model.model,
            )
            for model in result.models
        ],
    )
end

function _write_record_contents(
    directory::AbstractString,
    plan::AbstractOperationPlan,
    result::AbstractOperationResult;
    registry::RegistrySet=DEFAULT_REGISTRY,
    git=_record_git(),
)
    mkpath(joinpath(directory, "data"))
    mkpath(joinpath(directory, "summary"))
    mkpath(joinpath(directory, "figures"))
    mkpath(joinpath(directory, "report"))
    _write_record_manifest(directory, git)

    write_plan(joinpath(directory, "request.toml"), plan)
    open(joinpath(directory, "resolved.toml"), "w") do io
        TOML.print(io, _resolved_document(plan, result); sorted=true)
    end

    primary = _primary_trials(result)
    _write_csv(joinpath(directory, "data", "trials.csv"), primary)
    _write_csv(
        joinpath(directory, "data", "task_metrics.csv"),
        _record_task_metric_rows(primary),
    )
    if result isa EvolutionResult
        _write_csv_atomic(
            joinpath(directory, "seeds.csv"),
            _record_seed_rows(result),
        )
    else
        _write_csv(joinpath(directory, "seeds.csv"), _record_seed_rows(result))
    end

    output = tables(result)
    for name in propertynames(output)
        name in (:trials, :task, :statistics, :contrasts) && continue
        rows = getproperty(output, name)
        path = joinpath(directory, _table_path(name))
        columns = isempty(rows) ? _empty_table_columns(name) : nothing
        if result isa EvolutionResult &&
           name in (:candidates, :candidate_scores, :candidate_trials)
            _write_csv_atomic(path, rows; columns)
        else
            _write_csv(path, rows; columns)
        end
    end
    statistics = _record_statistics(result)
    contrasts = _record_contrasts(result)
    _write_csv(joinpath(directory, "summary", "statistics.csv"), statistics)
    _write_csv(
        joinpath(directory, "summary", "contrasts.csv"),
        contrasts;
        columns=isempty(contrasts) ? _empty_table_columns(:contrasts) : nothing,
    )
    open(joinpath(directory, "summary", "summary.json"), "w") do io
        write(io, _json(summary(result)))
        write(io, '\n')
    end
    _render_report(joinpath(directory, "report", "index.html"), plan, result, registry)

    if result isa EvolutionResult
        references = _write_or_reuse_evolution_models(directory, result)
        empty!(result.model_references)
        append!(result.model_references, references)
    end

    artifacts = String[]
    checksums = Dict{String,String}()
    for (root, _, files) in walkdir(directory), file in sort(files)
        relative = replace(relpath(joinpath(root, file), directory), '\\' => '/')
        relative in ("record.toml", "DONE", "FAILED") && continue
        push!(artifacts, relative)
        checksums[relative] = open(joinpath(root, file), "r") do io
            bytes2hex(SHA.sha256(io))
        end
    end
    sort!(artifacts)
    open(joinpath(directory, "record.toml"), "w") do io
        TOML.print(io, Dict{String,Any}(
            "format" => RECORD_FORMAT,
            "format_version" => RECORD_FORMAT_VERSION,
            "kind" => String(operation_kind(plan)),
            "id" => basename(directory),
            "created_utc" => string(now(UTC)),
            "package_version" => string(Base.pkgversion(@__MODULE__)),
            "julia_version" => string(VERSION),
            "threads" => Threads.nthreads(),
            "git_sha" => git.sha,
            "git_state" => git.state,
            "manifest_sha256" => git.manifest_sha256,
            "artifacts" => artifacts,
            "artifact_sha256" => checksums,
            "completion_marker" => "DONE",
        ); sorted=true)
    end
    open(joinpath(directory, "DONE"), "w") do io
        write(io, "complete\n")
    end
    return String(directory)
end

function write_record(
    plan::AbstractOperationPlan,
    result::AbstractOperationResult;
    root::AbstractString="records",
    id::Union{Nothing,AbstractString}=nothing,
    registry::RegistrySet=DEFAULT_REGISTRY,
)
    _assert_record_pair(plan, result)
    git = _record_git()
    directory = _reserve_operation_record_directory(plan, root, id)
    try
        return _write_record_contents(
            directory,
            plan,
            result;
            registry=registry,
            git=git,
        )
    catch error
        open(joinpath(directory, "FAILED"), "w") do io
            write(io, string(nameof(typeof(error))), "\n")
            write(io, "The calling process contains the detailed error.\n")
        end
        rethrow()
    end
end

function run_operation(
    plan::AbstractOperationPlan;
    registry::RegistrySet=DEFAULT_REGISTRY,
    root::AbstractString="records",
    id::Union{Nothing,AbstractString}=nothing,
)
    git = _record_git()
    directory = _reserve_operation_record_directory(plan, root, id)
    try
        write_plan(joinpath(directory, "request.toml"), plan)
        resolved = resolve(plan, registry)
        result = execute(resolved)
        _write_record_contents(
            directory,
            plan,
            result;
            registry,
            git,
        )
        return (result=result, directory=String(directory))
    catch error
        open(joinpath(directory, "FAILED"), "w") do io
            write(io, string(nameof(typeof(error))), "\n")
            write(io, "The calling process contains the detailed error.\n")
        end
        rethrow()
    end
end

function _evolution_digest(value)
    return bytes2hex(SHA.sha256(codeunits(_json(value))))
end

function _evolution_operation_digests(
    plan::EvolutionPlan,
    resolved::ResolvedEvolutionPlan,
    git,
)
    run_digest = _evolution_digest(Evolution.run_config_document(resolved.run))
    resolution_digest = _evolution_digest((
        id=plan.id,
        node=resolved.node.id,
        model_type=string(resolved.design.model_type),
        dimension=resolved.design.dimension,
        blocks=Tuple(
            (
                name=block.name,
                shape=block.shape,
                first=first(block.range),
                last=last(block.range),
            )
            for block in resolved.design.blocks
        ),
        training_targets=Tuple(target.id for target in plan.training_targets),
        heldout_targets=Tuple(target.id for target in plan.heldout_targets),
    ))
    provenance_digest = _evolution_digest((
        git_sha=git.sha,
        manifest_sha256=git.manifest_sha256,
        julia_version=string(VERSION),
        package_version=string(Base.pkgversion(@__MODULE__)),
    ))
    return (
        run=run_digest,
        resolution=resolution_digest,
        provenance=provenance_digest,
    )
end

function _operation_record_directory(
    plan::AbstractOperationPlan,
    root::AbstractString,
    id::Union{Nothing,AbstractString},
)
    record_id = id === nothing ? _record_id(plan) : String(id)
    isempty(record_id) && throw(ArgumentError("record id must not be empty"))
    record_id in (".", "..") &&
        throw(ArgumentError("record id must not be . or .."))
    (occursin('/', record_id) || occursin('\\', record_id)) &&
        throw(ArgumentError("record id must be one path component"))
    directory = joinpath(root, record_id)
    ispath(directory) && throw(ArgumentError(
        "record directory already exists: $(directory)",
    ))
    return directory
end

function _reserve_operation_record_directory(
    plan::AbstractOperationPlan,
    root::AbstractString,
    id::Union{Nothing,AbstractString},
)
    directory = _operation_record_directory(plan, root, id)
    mkpath(dirname(directory))
    mkdir(directory)
    return directory
end

function _mark_incomplete(directory::AbstractString)
    open(joinpath(directory, "INCOMPLETE"), "w") do io
        write(io, "resume with Evolution.resume(\"", directory, "\")\n")
    end
    return directory
end

function _clear_evolution_markers(directory::AbstractString)
    for name in ("INCOMPLETE", "FAILED")
        path = joinpath(directory, name)
        isfile(path) && rm(path)
    end
    return directory
end

function _partial_candidate_trials(candidates)
    rows = NamedTuple[]
    for candidate in candidates, evaluation in candidate.evaluations
        length(evaluation.trial_rows) == length(evaluation.values) ||
            throw(ArgumentError(
                "evolution trial rows and measure values must have equal lengths",
            ))
        for (row, value) in zip(evaluation.trial_rows, evaluation.values)
            push!(rows, merge(
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
    return rows
end

function _partial_candidates(candidates)
    return [
        (
            iteration=candidate.iteration,
            candidate=candidate.id,
            valid=candidate.valid,
            coordinates=Tuple(candidate.coordinates),
            scores=Tuple(_candidate_scores(candidate)),
        )
        for candidate in candidates
    ]
end

function _partial_candidate_scores(candidates)
    rows = NamedTuple[]
    for candidate in candidates, evaluation in candidate.evaluations
        push!(rows, (
            iteration=candidate.iteration,
            candidate=candidate.id,
            target=evaluation.target,
            measure=evaluation.measure,
            valid=candidate.valid && !ismissing(evaluation.aggregate),
            score=evaluation.aggregate,
        ))
    end
    return rows
end

function _record_integer(text::AbstractString, context::AbstractString)
    isempty(text) && throw(ArgumentError("$(context) must not be empty"))
    value = tryparse(Int, text)
    value === nothing && throw(ArgumentError("$(context) must be an integer"))
    return value
end

function _record_uint64(text::AbstractString, context::AbstractString)
    isempty(text) && throw(ArgumentError("$(context) must not be empty"))
    value = tryparse(UInt64, text)
    value === nothing && throw(ArgumentError("$(context) must be a UInt64"))
    return value
end

function _record_bool(text::AbstractString, context::AbstractString)
    text == "true" && return true
    text == "false" && return false
    throw(ArgumentError("$(context) must be true or false"))
end

function _record_float(text::AbstractString, context::AbstractString)
    isempty(text) && return missing
    value = tryparse(Float64, text)
    value === nothing && throw(ArgumentError("$(context) must be a Float64"))
    isfinite(value) || throw(ArgumentError("$(context) must be finite"))
    return value
end

function _record_symbol(text::AbstractString, context::AbstractString)
    isempty(text) && throw(ArgumentError("$(context) must not be empty"))
    return Symbol(text)
end

function _record_optional_symbol(text::AbstractString)
    return isempty(text) ? missing : Symbol(text)
end

function _record_optional_bool(text::AbstractString, context::AbstractString)
    return isempty(text) ? missing : _record_bool(text, context)
end

function _record_optional_uint64(text::AbstractString, context::AbstractString)
    return isempty(text) ? missing : _record_uint64(text, context)
end

_record_initial_state_value(value::Vector) =
    Tuple(_record_initial_state_value(item) for item in value)
_record_initial_state_value(value) = value

function _record_initial_state(text::AbstractString, context::AbstractString)
    isempty(text) && return missing
    text == "nothing" && return nothing
    value = try
        TOML.parse("value = " * text)["value"]
    catch error
        throw(ArgumentError(
            "$(context) is not a supported portable initial state: " *
            sprint(showerror, error),
        ))
    end
    return _record_initial_state_value(value)
end

function _record_coordinates(
    text::AbstractString,
    dimension::Integer,
    context::AbstractString,
)
    value = try
        TOML.parse("value = " * text)["value"]
    catch error
        throw(ArgumentError(
            "$(context) is not a portable coordinate vector: " *
            sprint(showerror, error),
        ))
    end
    value isa AbstractVector || throw(ArgumentError(
        "$(context) must be a coordinate vector",
    ))
    length(value) == dimension || throw(ArgumentError(
        "$(context) has dimension $(length(value)); expected $(dimension)",
    ))
    all(item -> item isa Real && !(item isa Bool), value) ||
        throw(ArgumentError("$(context) must contain only real values"))
    coordinates = Float64.(value)
    all(isfinite, coordinates) || throw(ArgumentError(
        "$(context) must contain only finite values",
    ))
    return coordinates
end

function _restored_trial_row(row, context::AbstractString)
    return (
        condition=_record_symbol(row.condition, "$(context) condition"),
        block=_record_integer(row.block, "$(context) block"),
        trial=_record_integer(row.trial, "$(context) trial"),
        window=_record_integer(row.window, "$(context) window"),
        seed_ledger_agents=_record_integer(
            row.seed_ledger_agents,
            "$(context) seed_ledger_agents",
        ),
        topology_seed=_record_optional_uint64(
            row.topology_seed,
            "$(context) topology_seed",
        ),
        world_seed=_record_optional_uint64(
            row.world_seed,
            "$(context) world_seed",
        ),
        initial_state=_record_initial_state(
            row.initial_state,
            "$(context) initial_state",
        ),
        score_key=_record_optional_symbol(row.score_key),
        raw_score=_record_float(row.raw_score, "$(context) raw_score"),
        normalized_score=_record_float(
            row.normalized_score,
            "$(context) normalized_score",
        ),
        normalized_bound=_record_optional_symbol(row.normalized_bound),
        viable=_record_optional_bool(row.viable, "$(context) viable"),
        liveness=_record_optional_bool(row.liveness, "$(context) liveness"),
    )
end

function _restore_evolution_candidates(
    directory::AbstractString,
    plan::EvolutionPlan,
    completed_iteration::Integer,
    committed_candidate_count::Integer,
    dimension::Integer,
)
    data_directory = joinpath(directory, "data")
    candidate_path = joinpath(data_directory, "candidates.csv")
    score_path = joinpath(data_directory, "candidate_scores.csv")
    trial_path = joinpath(data_directory, "candidate_trials.csv")
    seed_path = joinpath(directory, "seeds.csv")

    candidate_rows = _require_record_columns(
        _read_record_csv(candidate_path),
        (:iteration, :candidate, :valid, :coordinates, :scores),
        candidate_path,
    )
    candidate_order = Tuple{Int,Int}[]
    candidate_metadata = Dict{Tuple{Int,Int},NamedTuple}()
    completed = Int(completed_iteration)
    for row in candidate_rows
        iteration = _record_integer(row.iteration, "candidate iteration")
        iteration > completed && continue
        1 <= iteration || throw(ArgumentError(
            "candidate iteration must be positive",
        ))
        candidate = _record_integer(row.candidate, "candidate id")
        key = (iteration, candidate)
        haskey(candidate_metadata, key) && throw(ArgumentError(
            "duplicate evolution candidate $(key)",
        ))
        candidate_metadata[key] = (
            valid=_record_bool(row.valid, "candidate $(key) valid"),
            coordinates=_record_coordinates(
                row.coordinates,
                dimension,
                "candidate $(key) coordinates",
            ),
        )
        push!(candidate_order, key)
    end
    length(candidate_order) == committed_candidate_count ||
        throw(ArgumentError(
            "checkpoint candidate count does not match the incremental candidate tables",
        ))
    any(key -> first(key) == completed, candidate_order) || throw(ArgumentError(
        "incremental candidate tables do not contain the checkpoint generation",
    ))

    targets = Dict(target.id => target for target in plan.training_targets)
    expected_target_order = Tuple(target.id for target in plan.training_targets)
    score_rows = _require_record_columns(
        _read_record_csv(score_path),
        (:iteration, :candidate, :target, :measure, :valid, :score),
        score_path,
    )
    evaluation_metadata = Dict{Tuple{Int,Int,Symbol},NamedTuple}()
    evaluation_order = Dict(key => Symbol[] for key in candidate_order)
    for row in score_rows
        iteration = _record_integer(row.iteration, "candidate score iteration")
        iteration > completed && continue
        candidate = _record_integer(row.candidate, "candidate score id")
        candidate_key = (iteration, candidate)
        haskey(candidate_metadata, candidate_key) || throw(ArgumentError(
            "candidate score references unknown candidate $(candidate_key)",
        ))
        target = _record_symbol(row.target, "candidate score target")
        haskey(targets, target) || throw(ArgumentError(
            "candidate score references unknown training target :$(target)",
        ))
        key = (iteration, candidate, target)
        haskey(evaluation_metadata, key) && throw(ArgumentError(
            "duplicate candidate score for $(key)",
        ))
        measure = _record_symbol(row.measure, "candidate score measure")
        measure === plan.run.measure || throw(ArgumentError(
            "candidate score measure :$(measure) does not match plan measure " *
            ":$(plan.run.measure)",
        ))
        aggregate = _record_float(row.score, "candidate score $(key)")
        valid = _record_bool(row.valid, "candidate score $(key) valid")
        evaluation_metadata[key] = (
            measure=measure,
            aggregate=aggregate,
            valid=valid,
            trial_rows=NamedTuple[],
            values=Union{Missing,Float64}[],
            seed_rows=NamedTuple[],
        )
        push!(evaluation_order[candidate_key], target)
    end

    trial_columns = (
        :phase, :iteration, :candidate, :condition, :block, :trial,
        :window, :seed_ledger_agents, :topology_seed, :world_seed,
        :initial_state, :score_key, :raw_score, :normalized_score,
        :normalized_bound, :viable, :liveness, :measure_value,
    )
    trial_rows = _require_record_columns(
        _read_record_csv(trial_path),
        trial_columns,
        trial_path,
    )
    for row in trial_rows
        iteration = _record_integer(row.iteration, "candidate trial iteration")
        iteration > completed && continue
        row.phase == "development" || throw(ArgumentError(
            "candidate trial phase must be development",
        ))
        candidate = _record_integer(row.candidate, "candidate trial id")
        target = _record_symbol(row.condition, "candidate trial condition")
        key = (iteration, candidate, target)
        haskey(evaluation_metadata, key) || throw(ArgumentError(
            "candidate trial references unknown evaluation $(key)",
        ))
        context = "candidate trial $(key) block $(row.block) trial $(row.trial)"
        trial_row = _restored_trial_row(row, context)
        push!(evaluation_metadata[key].trial_rows, trial_row)
        push!(
            evaluation_metadata[key].values,
            _record_float(row.measure_value, "$(context) measure_value"),
        )
    end

    seed_rows = _require_record_columns(
        _read_record_csv(seed_path),
        _SEED_ROW_NAMES,
        seed_path,
    )
    for row in seed_rows
        row.phase == "development" || continue
        iteration = _record_integer(row.generation, "candidate seed generation")
        iteration > completed && continue
        candidate = _record_integer(row.individual, "candidate seed individual")
        target = _record_symbol(row.condition, "candidate seed condition")
        key = (iteration, candidate, target)
        haskey(evaluation_metadata, key) || throw(ArgumentError(
            "candidate seed references unknown evaluation $(key)",
        ))
        push!(evaluation_metadata[key].seed_rows, (
            condition=target,
            block=_record_integer(row.block, "candidate seed block"),
            trial=_record_integer(row.trial, "candidate seed trial"),
            agent=_record_integer(row.agent, "candidate seed agent"),
            stream=_record_symbol(row.stream, "candidate seed stream"),
            seed=_record_uint64(row.seed, "candidate seed"),
        ))
    end

    restored = EvolutionCandidate[]
    for candidate_key in candidate_order
        Tuple(evaluation_order[candidate_key]) == expected_target_order ||
            throw(ArgumentError(
                "candidate $(candidate_key) evaluations do not match the plan target order",
            ))
        candidate_evaluations = EvolutionEvaluation[]
        for target_id in expected_target_order
            key = (candidate_key[1], candidate_key[2], target_id)
            metadata = evaluation_metadata[key]
            target = targets[target_id]
            expected_trials =
                target.evaluation.blocks * target.evaluation.trials_per_block
            length(metadata.trial_rows) == expected_trials || throw(ArgumentError(
                "candidate evaluation $(key) has $(length(metadata.trial_rows)) trials; " *
                "expected $(expected_trials)",
            ))
            length(metadata.values) == length(metadata.trial_rows) ||
                throw(ArgumentError(
                    "candidate evaluation $(key) measure values do not match its trials",
                ))
            trial_ids = [
                (row.block, row.trial)
                for row in metadata.trial_rows
            ]
            expected_trial_ids = [
                (block, trial)
                for block in 1:target.evaluation.blocks
                for trial in 1:target.evaluation.trials_per_block
            ]
            trial_ids == expected_trial_ids || throw(ArgumentError(
                "candidate evaluation $(key) trials are incomplete or out of order",
            ))
            seed_ids = [
                (row.block, row.trial, row.agent, row.stream)
                for row in metadata.seed_rows
            ]
            streams = seed_stream_names(target.evaluation)
            expected_seed_ids = [
                (row.block, row.trial, agent, stream)
                for row in metadata.trial_rows
                for agent in 1:row.seed_ledger_agents
                for stream in streams
            ]
            seed_ids == expected_seed_ids || throw(ArgumentError(
                "candidate evaluation $(key) seeds are incomplete or out of order",
            ))
            aggregate = _evolution_aggregate(
                metadata.values,
                target.evaluation.aggregate,
            )
            isequal(aggregate, metadata.aggregate) || throw(ArgumentError(
                "candidate evaluation $(key) aggregate does not match its trial values",
            ))
            candidate_valid = candidate_metadata[candidate_key].valid
            metadata.valid == (candidate_valid && !ismissing(metadata.aggregate)) ||
                throw(ArgumentError(
                    "candidate evaluation $(key) validity is inconsistent",
                ))
            push!(candidate_evaluations, EvolutionEvaluation(
                target_id,
                metadata.measure,
                copy(metadata.values),
                metadata.aggregate,
                nothing,
                copy(metadata.trial_rows),
                copy(metadata.seed_rows),
            ))
        end
        metadata = candidate_metadata[candidate_key]
        push!(restored, EvolutionCandidate(
            candidate_key[1],
            candidate_key[2],
            copy(metadata.coordinates),
            metadata.valid,
            candidate_evaluations,
        ))
    end
    return restored
end

function _write_incomplete_record_manifest(
    directory::AbstractString,
    plan::EvolutionPlan,
    git,
)
    _write_record_manifest(directory, git)
    artifacts = String[]
    checksums = Dict{String,String}()
    for (root, _, files) in walkdir(directory), file in sort(files)
        relative = replace(relpath(joinpath(root, file), directory), '\\' => '/')
        relative in ("record.toml", "DONE", "FAILED", "INCOMPLETE") &&
            continue
        push!(artifacts, relative)
        checksums[relative] = open(joinpath(root, file), "r") do io
            bytes2hex(SHA.sha256(io))
        end
    end
    sort!(artifacts)
    created = if isfile(joinpath(directory, "record.toml"))
        get(
            TOML.parsefile(joinpath(directory, "record.toml")),
            "created_utc",
            string(now(UTC)),
        )
    else
        string(now(UTC))
    end
    open(joinpath(directory, "record.toml"), "w") do io
        TOML.print(io, Dict{String,Any}(
            "format" => RECORD_FORMAT,
            "format_version" => RECORD_FORMAT_VERSION,
            "kind" => "evolve",
            "id" => basename(directory),
            "plan_id" => String(plan.id),
            "created_utc" => created,
            "package_version" => string(Base.pkgversion(@__MODULE__)),
            "julia_version" => string(VERSION),
            "threads" => Threads.nthreads(),
            "git_sha" => git.sha,
            "git_state" => git.state,
            "manifest_sha256" => git.manifest_sha256,
            "artifacts" => artifacts,
            "artifact_sha256" => checksums,
            "completion_marker" => "INCOMPLETE",
        ); sorted=true)
    end
    return directory
end

function _write_partial_evolution_state(
    directory::AbstractString,
    candidates,
)
    mkpath(joinpath(directory, "data"))
    _write_csv_atomic(
        joinpath(directory, "data", "candidates.csv"),
        _partial_candidates(candidates);
        columns=isempty(candidates) ?
            _empty_table_columns(:candidates) : nothing,
    )
    _write_csv_atomic(
        joinpath(directory, "data", "candidate_trials.csv"),
        _partial_candidate_trials(candidates);
        columns=isempty(candidates) ?
            _empty_table_columns(:candidate_trials) : nothing,
    )
    _write_csv_atomic(
        joinpath(directory, "data", "candidate_scores.csv"),
        _partial_candidate_scores(candidates);
        columns=isempty(candidates) ?
            _empty_table_columns(:candidate_scores) : nothing,
    )
    _write_csv_atomic(
        joinpath(directory, "seeds.csv"),
        _evolution_seed_rows(candidates),
        columns=_SEED_ROW_NAMES,
    )
    return directory
end

function _evolution_checkpoint_callback(
    directory::AbstractString,
    digests,
    strategy::Symbol,
    plan::EvolutionPlan,
    git,
)
    return function (iteration, state, candidates)
        _write_partial_evolution_state(directory, candidates)
        Evolution.write_checkpoint(
            directory;
            completed_iteration=iteration,
            run_digest=digests.run,
            resolution_digest=digests.resolution,
            provenance_digest=digests.provenance,
            strategy_key=strategy,
            strategy_snapshot=Evolution.snapshot(state),
            committed_candidate_count=length(candidates),
        )
        _write_incomplete_record_manifest(directory, plan, git)
    end
end

function run_operation(
    plan::EvolutionPlan;
    registry::RegistrySet=DEFAULT_REGISTRY,
    root::AbstractString="records",
    id::Union{Nothing,AbstractString}=nothing,
)
    git = _record_git()
    directory = _reserve_operation_record_directory(plan, root, id)
    try
        write_plan(joinpath(directory, "request.toml"), plan)
        resolved = resolve(plan, registry)
        open(joinpath(directory, "resolved.toml"), "w") do io
            TOML.print(io, _resolved_document(plan, resolved); sorted=true)
        end
        _mark_incomplete(directory)
        digests = _evolution_operation_digests(plan, resolved, git)
        checkpoint = _evolution_checkpoint_callback(
            directory,
            digests,
            resolved.strategy.key,
            plan,
            git,
        )
        result = execute(resolved; checkpoint)
        _clear_evolution_markers(directory)
        _write_record_contents(
            directory,
            plan,
            result;
            registry,
            git,
        )
        return (result=result, directory=String(directory))
    catch error
        open(joinpath(directory, "FAILED"), "w") do io
            write(io, string(nameof(typeof(error))), "\n")
            write(io, "The calling process contains the detailed error.\n")
        end
        rethrow()
    end
end

isdefined(Evolution, :resume) ||
    Core.eval(Evolution, :(function resume end))

function Evolution.resume(
    record_directory::AbstractString;
    registry::RegistrySet=DEFAULT_REGISTRY,
)
    directory = String(record_directory)
    isdir(directory) || throw(ArgumentError(
        "evolution record directory does not exist: $(directory)",
    ))
    isfile(joinpath(directory, "DONE")) && throw(ArgumentError(
        "evolution record is already complete",
    ))
    request = joinpath(directory, "request.toml")
    isfile(request) || throw(ArgumentError(
        "evolution record is missing request.toml",
    ))
    plan = read_plan(request; registry)
    plan isa EvolutionPlan || throw(ArgumentError(
        "record request is not an EvolutionPlan",
    ))
    resolved = resolve(plan, registry)
    git = _record_git()
    digests = _evolution_operation_digests(plan, resolved, git)
    checkpoint = Evolution.latest_checkpoint(
        directory;
        run_digest=digests.run,
        resolution_digest=digests.resolution,
        provenance_digest=digests.provenance,
        strategy_key=resolved.strategy.key,
    )
    checkpoint === nothing && throw(ArgumentError(
        "evolution record has no complete generation checkpoint",
    ))
    state = Evolution.restore(
        resolved.strategy,
        checkpoint.strategy_snapshot,
    )
    candidates = if haskey(checkpoint.runner_document, "candidates")
        restored = EvolutionCandidate[
            _restored_checkpoint_candidate(document)
            for document in checkpoint.runner_document["candidates"]
        ]
        length(restored) == checkpoint.committed_candidate_count ||
            throw(ArgumentError(
                "checkpoint candidate count does not match its runner document",
            ))
        restored
    else
        _restore_evolution_candidates(
            directory,
            plan,
            checkpoint.completed_iteration,
            checkpoint.committed_candidate_count,
            resolved.design.dimension,
        )
    end
    _clear_evolution_markers(directory)
    _mark_incomplete(directory)
    callback = _evolution_checkpoint_callback(
        directory,
        digests,
        resolved.strategy.key,
        plan,
        git,
    )
    try
        result = execute(
            resolved;
            state,
            candidates,
            checkpoint=callback,
        )
        _clear_evolution_markers(directory)
        _write_record_contents(
            directory,
            plan,
            result;
            registry,
            git,
        )
        return (result=result, directory=directory)
    catch error
        open(joinpath(directory, "FAILED"), "w") do io
            write(io, string(nameof(typeof(error))), "\n")
            write(io, "The calling process contains the detailed error.\n")
        end
        rethrow()
    end
end

function _experiment_run_id(experiment::ExperimentSpec)
    timestamp = Dates.format(now(UTC), dateformat"yyyymmddTHHMMSS")
    suffix = string(time_ns(); base=16)
    return string(
        experiment.id,
        "-v",
        experiment.version,
        "-",
        timestamp,
        "-",
        last(suffix, min(8, length(suffix))),
    )
end

function run_experiment(
    experiment::ExperimentSpec;
    registry::RegistrySet=DEFAULT_REGISTRY,
    root::AbstractString="experiment-records",
    id::Union{Nothing,AbstractString}=nothing,
)
    validate(experiment, registry)
    run_id = id === nothing ? _experiment_run_id(experiment) : String(id)
    isempty(run_id) && throw(ArgumentError("experiment run id must not be empty"))
    run_id in (".", "..") && throw(ArgumentError("experiment run id must not be . or .."))
    (occursin('/', run_id) || occursin('\\', run_id)) && throw(ArgumentError(
        "experiment run id must be one path component",
    ))
    directory = joinpath(root, run_id)
    ispath(directory) && throw(ArgumentError(
        "experiment run directory already exists: $(directory)",
    ))
    mkpath(directory)
    results = AbstractOperationResult[]
    record_directories = String[]
    try
        write_experiment(
            joinpath(directory, "protocol"),
            experiment;
            registry=registry,
        )
        records_root = joinpath(directory, "operations")
        for (index, plan) in enumerate(experiment.operations)
            record_id = string(lpad(index, 2, '0'), "-", plan.id)
            run = run_operation(
                plan;
                registry=registry,
                root=records_root,
                id=record_id,
            )
            push!(results, run.result)
            push!(record_directories, relpath(run.directory, directory))
        end
        open(joinpath(directory, "experiment-run.toml"), "w") do io
            TOML.print(io, Dict{String,Any}(
                "format" => "brainlesslab-experiment-run",
                "format_version" => 1,
                "id" => run_id,
                "experiment" => String(experiment.id),
                "experiment_version" => string(experiment.version),
                "evidence_state" => String(experiment.evidence_state),
                "protocol" => "protocol/experiment.toml",
                "operation_records" => replace.(record_directories, '\\' => '/'),
            ); sorted=true)
        end
        open(joinpath(directory, "DONE"), "w") do io
            write(io, "complete\n")
        end
    catch error
        open(joinpath(directory, "FAILED"), "w") do io
            write(io, string(nameof(typeof(error))), "\n")
            write(io, "The calling process contains the detailed error.\n")
        end
        rethrow()
    end
    return (
        experiment=experiment,
        results=Tuple(results),
        records=Tuple(record_directories),
        directory=String(directory),
    )
end
