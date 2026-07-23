using Dates
import SHA
using TOML

const RECORD_FORMAT = "brainlesslab-record"
const RECORD_FORMAT_VERSION = 1

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
    return (sha=sha, state=state)
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
    rows = NamedTuple[]
    for row in trial_table(result.training.batch)
        push!(rows, merge((phase=:training,), row))
    end
    for evaluation in result.heldout, row in trial_table(evaluation.batch)
        push!(rows, merge((phase=:heldout, heldout_target=evaluation.target), row))
    end
    return rows
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
            training_target=result.training.target,
            training_score=result.training.aggregate,
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

function _record_seed_rows(result::EvolutionResult)
    rows = NamedTuple[]
    for (candidate, batch) in zip(result.candidates, result.candidate_batches)
        _append_seed_rows!(
            rows,
            batch;
            context=(
                phase=:development,
                generation=candidate.generation,
                individual=candidate.individual,
            ),
        )
    end
    _append_seed_rows!(rows, result.training.batch; context=(phase=:training,))
    for evaluation in result.heldout
        _append_seed_rows!(
            rows,
            evaluation.batch;
            context=(phase=:heldout, heldout_target=evaluation.target),
        )
    end
    return rows
end

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
        :score_key,
        :raw_score,
        :normalized_score,
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
        :generation, :best_individual, :fitness_best, :fitness_median,
        :fitness_mean, :fitness_worst,
    )
    name === :candidates && return (
        :generation, :individual, :coordinates, :parameters, :objective_values, :fitness,
    )
    name === :candidate_trials && return (
        :generation, :individual, :candidate_fitness, :condition, :block, :trial,
        :seed_ledger_agents, :topology_seed, :node_state_seed, :world_seed,
        :body_seed, :task_seed, :mechanism_seed, :initial_state, :score_key,
        :raw_score, :normalized_score, :viable, :liveness,
    )
    name === :champion_parameters && return (
        :parameter, :owner, :value, :default, :scale, :lower, :upper,
        :mutation_scale, :values,
    )
    name in (:training_trials, :heldout_trials) && return (
        :condition, :block, :trial, :seed_ledger_agents, :topology_seed,
        :node_state_seed, :world_seed, :body_seed, :task_seed, :mechanism_seed,
        :initial_state, :score_key,
        :raw_score, :normalized_score, :viable, :liveness,
    )
    name === :optimizer && return (:optimizer, :optimizer_seed, :generations, :popsize)
    name === :contrasts && return (
        :case, :condition, :baseline, :n, :raw_difference, :raw_ci_lower,
        :raw_ci_upper, :normalized_difference, :normalized_ci_lower,
        :normalized_ci_upper, :interval_method,
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
    kind === :ablation && return "Compares an implicit baseline with declared capability-checked interventions under paired evaluation seeds."
    kind === :evolution && return "Selects parameters on the training target, records convergence, then evaluates the selected parameters on held-out targets without tuning on them."
    kind === :benchmark && return "Reports each task separately and computes paired within-task contrasts with 95% Student-t intervals against its declared baseline. No cross-task aggregate is formed."
    return "Executes the declared BrainlessLab operation."
end

function _plan_targets(plan::ProfilePlan)
    return (plan.target,)
end
_plan_targets(plan::SweepPlan) = (plan.target,)
_plan_targets(plan::AblationPlan) = (plan.target,)
_plan_targets(plan::EvolutionPlan) = (plan.training, plan.heldout_targets...)
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
        _svg_series(output.convergence, :generation, :fitness_best; title="Convergence") : ""
    html = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$(_html_escape(plan.id)) · BrainlessLab</title>
<style>
:root{color-scheme:light dark;--paper:#f5f2ea;--ink:#181b1c;--muted:#657074;--accent:#087f8c;--line:#c9cec9}*{box-sizing:border-box}body{margin:0;font:16px/1.55 ui-sans-serif,system-ui;background:var(--paper);color:var(--ink)}main{max-width:1120px;margin:auto;padding:64px 32px 120px}header{border-bottom:1px solid var(--line);padding-bottom:36px;margin-bottom:48px}h1{font:600 clamp(2.4rem,7vw,5.4rem)/.96 ui-serif,Georgia;margin:.2em 0}h2{font:500 2rem/1.1 ui-serif,Georgia;margin-top:2.5em}h3{margin-top:2em}.eyebrow{letter-spacing:.13em;text-transform:uppercase;color:var(--accent);font-size:.76rem}nav a{margin-right:1.2rem;color:var(--accent)}.table-wrap{overflow:auto;border:1px solid var(--line)}table{border-collapse:collapse;width:100%;font-size:.82rem}th,td{padding:.6rem .75rem;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}th{position:sticky;top:0;background:var(--paper)}.equation{overflow:auto;padding:1rem;border-left:3px solid var(--accent);font-family:ui-monospace,monospace}.axis{stroke:var(--muted);stroke-width:1}.series{fill:none;stroke:var(--accent);stroke-width:3}svg{width:100%;background:rgba(255,255,255,.35);border:1px solid var(--line)}code{font-family:ui-monospace,monospace}@media(prefers-color-scheme:dark){:root{--paper:#121718;--ink:#edf1ee;--muted:#9aa5a5;--line:#354041}}
</style></head><body><main><header><div class=eyebrow>BrainlessLab · $(_html_escape(kind))</div><h1>$(_html_escape(plan.id))</h1><p>$(_html_escape(_operation_method(kind)))</p><nav><a href=#method>Method</a><a href=#results>Results</a><a href=#equations>Equations</a></nav></header>
<section id=method><h2>Method</h2><p>$(_html_escape(_operation_method(kind)))</p><p>The CSV tables are the authoritative tabular outputs. They and this report are generated from the same typed result.</p></section>
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
_record_batches(result::EvolutionResult) = (
    result.training.batch,
    (evaluation.batch for evaluation in result.heldout)...,
)
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

function _resolution_details(result::EvolutionResult)
    return Dict{String,Any}(
        "optimizer" => String(result.plan.optimizer.key),
        "optimizer_seed" => _plan_toml_value(result.optimizer_seed),
        "parameter_set" => String(result.plan.plan.parameter_set),
        "parameters" => collect(String.(getfield.(result.plan.parameters, :name))),
        "x0" => result.plan.x0,
        "generations" => result.plan.plan.generations,
        "popsize" => result.plan.plan.popsize,
        "sigma0" => result.plan.plan.sigma0,
        "objective" => String(result.plan.plan.objective),
    )
end

function _resolution_details(result::BenchmarkResult)
    return Dict{String,Any}(
        "cases" => [Dict{String,Any}(
            "id" => String(case.id),
            "baseline" => String(case.baseline),
            "conditions" => [String(condition.target.id) for condition in case.conditions],
        ) for case in result.plan.cases],
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
    _write_csv(joinpath(directory, "seeds.csv"), _record_seed_rows(result))

    output = tables(result)
    for name in propertynames(output)
        name in (:trials, :task, :statistics, :contrasts) && continue
        rows = getproperty(output, name)
        _write_csv(
            joinpath(directory, _table_path(name)),
            rows;
            columns=isempty(rows) ? _empty_table_columns(name) : nothing,
        )
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
    record_id = id === nothing ? _record_id(plan) : String(id)
    isempty(record_id) && throw(ArgumentError("record id must not be empty"))
    record_id in (".", "..") && throw(ArgumentError("record id must not be . or .."))
    (occursin('/', record_id) || occursin('\\', record_id)) && throw(ArgumentError(
        "record id must be one path component",
    ))
    directory = joinpath(root, record_id)
    ispath(directory) && throw(ArgumentError("record directory already exists: $(directory)"))
    mkpath(directory)
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
    resolved = resolve(plan, registry)
    result = execute(resolved)
    directory = write_record(plan, result; root=root, id=id, registry=registry)
    return (result=result, directory=directory)
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
