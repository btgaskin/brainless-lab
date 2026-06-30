#!/usr/bin/env julia

using Dates
using TOML

struct SummaryCell
    neuron::String
    task::String
    metric::String
    mean::Union{Float64,Missing}
    ci_lo::Union{Float64,Missing}
    ci_hi::Union{Float64,Missing}
end

mutable struct RunSummary
    dir::String
    label::String
    manifest::Dict{String,Any}
    rows::Dict{Tuple{String,String,String},SummaryCell}
end

function usage(io=stdout)
    println(io, "usage: julia --project=. compare.jl <runDirA> <runDirB> [<runDirC> ...] [--out <dir>]")
end

function parse_args(args)
    run_dirs = String[]
    out_dir = nothing
    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--out"
            i += 1
            i <= length(args) || throw(ArgumentError("--out requires a directory"))
            out_dir = args[i]
        elseif arg == "--help" || arg == "-h"
            usage()
            exit(0)
        elseif startswith(arg, "--")
            throw(ArgumentError("unknown option $arg"))
        else
            push!(run_dirs, arg)
        end
        i += 1
    end
    length(run_dirs) >= 2 || throw(ArgumentError("compare requires at least two run directories"))
    return (run_dirs=run_dirs, out_dir=out_dir)
end

function _parse_csv_line(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    quoted = false
    i = firstindex(line)
    while i <= lastindex(line)
        c = line[i]
        if quoted
            if c == '"'
                ni = nextind(line, i)
                if ni <= lastindex(line) && line[ni] == '"'
                    print(buf, '"')
                    i = ni
                else
                    quoted = false
                end
            else
                print(buf, c)
            end
        else
            if c == '"'
                quoted = true
            elseif c == ','
                push!(fields, String(take!(buf)))
            else
                print(buf, c)
            end
        end
        i = nextind(line, i)
    end
    push!(fields, String(take!(buf)))
    return fields
end

function _read_csv(path::AbstractString)
    isfile(path) || throw(ArgumentError("CSV not found: $path"))
    rows = Dict{String,String}[]
    open(path, "r") do io
        eof(io) && return rows
        header = _parse_csv_line(readline(io))
        while !eof(io)
            line = readline(io)
            isempty(strip(line)) && continue
            fields = _parse_csv_line(line)
            row = Dict{String,String}()
            for (i, name) in enumerate(header)
                row[name] = i <= length(fields) ? fields[i] : ""
            end
            push!(rows, row)
        end
    end
    return rows
end

function _csv_cell(value)
    value === nothing && return ""
    value === missing && return ""
    text = string(value)
    if occursin("\"", text) || occursin(",", text) || occursin("\n", text) || occursin("\r", text)
        return "\"" * replace(text, "\"" => "\"\"") * "\""
    end
    return text
end

function _write_csv(path::AbstractString, header, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, join(_csv_cell.(header), ","))
        for row in rows
            println(io, join(_csv_cell.(row), ","))
        end
    end
    return path
end

function _parse_float(value)
    text = strip(String(value))
    isempty(text) && return missing
    parsed = tryparse(Float64, text)
    return parsed === nothing ? missing : parsed
end

function _read_manifest(run_dir::AbstractString)
    path = joinpath(run_dir, "manifest.toml")
    isfile(path) || return Dict{String,Any}()
    try
        return TOML.parsefile(path)
    catch err
        return Dict{String,Any}("manifest_error" => sprint(showerror, err))
    end
end

function _short_sha(value)
    value === nothing && return "nogit"
    sha = string(value)
    isempty(sha) || sha == "unknown" ? "nogit" : sha[1:min(lastindex(sha), 7)]
end

function _sanitize_label(value)
    label = replace(string(value), r"[^A-Za-z0-9_.+-]" => "_")
    return isempty(label) ? "run" : label
end

function _manifest_label(manifest::AbstractDict)
    timestamp = get(manifest, "timestamp_utc", nothing)
    git_sha = get(manifest, "git_sha", nothing)
    timestamp === nothing && return nothing

    stamp = replace(string(timestamp), r"[^A-Za-z0-9]" => "")
    isempty(stamp) && return nothing
    stamp = stamp[1:min(lastindex(stamp), 16)]

    run_id = get(manifest, "run_id", nothing)
    if run_id !== nothing
        return _sanitize_label("$(stamp)_$(_short_sha(git_sha))_$(run_id)")
    end
    return _sanitize_label("$(stamp)_$(_short_sha(git_sha))")
end

function _run_label(run_dir::AbstractString, manifest::AbstractDict)
    label = _manifest_label(manifest)
    label === nothing || return label
    base = basename(normpath(run_dir))
    return _sanitize_label(isempty(base) ? "run" : base)
end

function _make_labels_unique!(runs)
    counts = Dict{String,Int}()
    for run in runs
        n = get(counts, run.label, 0) + 1
        counts[run.label] = n
        n == 1 || (run.label = "$(run.label)_$n")
    end
    return runs
end

function _summary_key(row::AbstractDict)
    neuron = strip(get(row, "neuron", ""))
    task = strip(get(row, "task", ""))
    metric = strip(get(row, "metric", ""))
    isempty(metric) && (metric = "norm_score")
    isempty(neuron) && throw(ArgumentError("summary.csv row is missing neuron"))
    isempty(task) && throw(ArgumentError("summary.csv row is missing task"))
    return (neuron, task, metric)
end

function _read_run_summary(run_dir::AbstractString)
    dir = abspath(run_dir)
    summary_path = joinpath(dir, "summary.csv")
    rows = _read_csv(summary_path)
    manifest = _read_manifest(dir)
    data = Dict{Tuple{String,String,String},SummaryCell}()
    for row in rows
        key = _summary_key(row)
        data[key] = SummaryCell(
            key[1],
            key[2],
            key[3],
            _parse_float(get(row, "mean", "")),
            _parse_float(get(row, "ci_lo", "")),
            _parse_float(get(row, "ci_hi", "")),
        )
    end
    return RunSummary(dir, _run_label(dir, manifest), manifest, data)
end

function _all_keys(runs)
    all = Set{Tuple{String,String,String}}()
    for run in runs
        union!(all, keys(run.rows))
    end
    return sort(collect(all); by=key -> (key[2], key[1], key[3]))
end

function _fmt_float(value; digits::Integer=4)
    value === missing && return ""
    if value isa Real && isfinite(Float64(value))
        return string(round(Float64(value); digits=digits))
    end
    return ""
end

function _mean_ci(cell)
    cell === nothing && return "missing"
    cell.mean === missing && return "missing"
    if cell.ci_lo === missing || cell.ci_hi === missing
        return _fmt_float(cell.mean)
    end
    return "$(_fmt_float(cell.mean)) [$(_fmt_float(cell.ci_lo)), $(_fmt_float(cell.ci_hi))]"
end

function _delta(base, cell)
    (base === nothing || cell === nothing) && return missing
    (base.mean === missing || cell.mean === missing) && return missing
    return Float64(cell.mean) - Float64(base.mean)
end

function _ci_ready(cell)
    cell === nothing && return false
    return cell.mean !== missing && cell.ci_lo !== missing && cell.ci_hi !== missing
end

function _ci_overlap(a, b)
    (_ci_ready(a) && _ci_ready(b)) || return false
    return max(Float64(a.ci_lo), Float64(b.ci_lo)) <= min(Float64(a.ci_hi), Float64(b.ci_hi))
end

function _flag_vs_base(base, cell)
    cell === nothing && return "missing"
    base === nothing && return "no base"
    (_ci_ready(base) && _ci_ready(cell)) || return "no CI"
    _ci_overlap(base, cell) && return ""
    direction = Float64(cell.mean) > Float64(base.mean) ? "higher" : "lower"
    return "DIFF $direction"
end

function _comparison_csv_rows(runs, keys)
    rows = Vector{Any}[]
    for key in keys
        base_cell = get(runs[1].rows, key, nothing)
        row = Any[key[2], key[1], key[3], _mean_ci(base_cell)]
        for run in runs[2:end]
            cell = get(run.rows, key, nothing)
            push!(row, _mean_ci(cell))
            push!(row, _fmt_float(_delta(base_cell, cell); digits=6))
        end
        push!(rows, row)
    end
    return rows
end

function _write_comparison_csv(path::AbstractString, runs, keys)
    header = Any["task", "neuron", "metric", runs[1].label]
    for run in runs[2:end]
        push!(header, run.label)
        push!(header, "$(run.label)_delta_vs_$(runs[1].label)")
    end
    return _write_csv(path, header, _comparison_csv_rows(runs, keys))
end

function _md_cell(value)
    return replace(String(value), "|" => "\\|", "\n" => " ")
end

function _manifest_value(manifest::AbstractDict, key::AbstractString)
    value = get(manifest, key, nothing)
    value === nothing && return ""
    return string(value)
end

function _write_run_table(io, runs)
    println(io, "| label | path | timestamp_utc | git_sha |")
    println(io, "|---|---|---|---|")
    for run in runs
        println(
            io,
            "| $(_md_cell(run.label)) | $(_md_cell(run.dir)) | $(_md_cell(_manifest_value(run.manifest, "timestamp_utc"))) | $(_md_cell(_manifest_value(run.manifest, "git_sha"))) |",
        )
    end
end

function _write_task_table(io, runs, keys)
    header = String["neuron", runs[1].label]
    for run in runs[2:end]
        push!(header, run.label)
        push!(header, "delta")
        push!(header, "flag")
    end
    println(io, "| " * join(_md_cell.(header), " | ") * " |")
    println(io, "|" * join(fill("---", length(header)), "|") * "|")

    for key in keys
        base_cell = get(runs[1].rows, key, nothing)
        row = String[key[1], _mean_ci(base_cell)]
        for run in runs[2:end]
            cell = get(run.rows, key, nothing)
            push!(row, _mean_ci(cell))
            push!(row, _fmt_float(_delta(base_cell, cell); digits=4))
            push!(row, _flag_vs_base(base_cell, cell))
        end
        println(io, "| " * join(_md_cell.(row), " | ") * " |")
    end
end

function _write_comparison_md(path::AbstractString, runs, keys)
    mkpath(dirname(path))
    tasks = sort(unique(key[2] for key in keys))
    open(path, "w") do io
        println(io, "# BrainlessLab benchmark comparison")
        println(io)
        println(io, "Generated $(Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS.sss"))Z.")
        println(io)
        println(io, "Cells show mean with CI from each run's `summary.csv`. Delta and flag columns compare each run against `$(runs[1].label)`. `DIFF` means the two CIs do not overlap.")
        println(io)
        println(io, "## Runs")
        println(io)
        _write_run_table(io, runs)

        for task in tasks
            task_keys = [key for key in keys if key[2] == task]
            metrics = sort(unique(key[3] for key in task_keys))
            for metric in metrics
                metric_keys = [key for key in task_keys if key[3] == metric]
                println(io)
                if length(metrics) == 1 && metric == "norm_score"
                    println(io, "## $task")
                else
                    println(io, "## $task / $metric")
                end
                println(io)
                _write_task_table(io, runs, metric_keys)
            end
        end
    end
    return path
end

function _default_out_dir()
    stamp = Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSSsss") * "Z"
    return joinpath(pwd(), "comparison_$stamp")
end

function compare_runs(run_dirs; out_dir=nothing)
    runs = [_read_run_summary(dir) for dir in run_dirs]
    _make_labels_unique!(runs)
    keys = _all_keys(runs)
    out = out_dir === nothing ? _default_out_dir() : String(out_dir)
    mkpath(out)
    csv_path = _write_comparison_csv(joinpath(out, "comparison.csv"), runs, keys)
    md_path = _write_comparison_md(joinpath(out, "comparison.md"), runs, keys)
    return (dir=out, csv=csv_path, markdown=md_path)
end

function main(args)
    try
        opts = parse_args(args)
        result = compare_runs(opts.run_dirs; out_dir=opts.out_dir)
        println(result.dir)
    catch err
        println(stderr, "error: ", sprint(showerror, err))
        usage(stderr)
        exit(1)
    end
end

main(ARGS)
