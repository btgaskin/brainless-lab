#!/usr/bin/env julia

# Independent calibration cells are safe to run on Julia threads. Re-launch a
# direct CLI invocation with automatic threading unless the user pinned or
# disabled the thread count. Including this file from tests never re-launches.
if abspath(PROGRAM_FILE) == (@__FILE__) &&
   Threads.nthreads() == 1 &&
   !haskey(ENV, "JULIA_NUM_THREADS") &&
   get(ENV, "BRAINLESSLAB_AUTOTHREADS", "1") != "0"
    command = addenv(
        `$(Base.julia_cmd()) --threads=auto --project=$(Base.active_project()) $(abspath(PROGRAM_FILE)) $(ARGS)`,
        "BRAINLESSLAB_AUTOTHREADS" => "0",
    )
    process = run(ignorestatus(command))
    exit(process.exitcode)
end

using BrainlessLab
using Dates
using Random
using Statistics
using TOML

const CORE_TASKS = (:tracking, :pong)
const CORE_CONDITIONS = (:falandays, :blind, :random, :reference)

_calibration_stamp() = Dates.format(Dates.now(Dates.UTC), dateformat"yyyymmddTHHMMSS")

function _argument_value(args, flag, default)
    index = findfirst(==(flag), args)
    index === nothing && return default
    index < length(args) || throw(ArgumentError("$(flag) requires a value"))
    return args[index + 1]
end

function _evidence_config(config)
    table = get(config, "evidence", nothing)
    table isa AbstractDict || throw(ArgumentError(
        "core calibration config requires an [evidence] table",
    ))
    required = ("stage", "independent_unit", "claim", "not_supported")
    unknown = sort!(collect(setdiff(Set(keys(table)), Set(required))))
    isempty(unknown) || throw(ArgumentError(
        "unknown core calibration evidence key(s): $(unknown)",
    ))
    missing = [key for key in required if !haskey(table, key)]
    isempty(missing) || throw(ArgumentError(
        "missing core calibration evidence key(s): $(missing)",
    ))
    evidence_values = Dict(key => strip(String(table[key])) for key in required)
    all(!isempty, values(evidence_values)) || throw(ArgumentError(
        "core calibration evidence values must not be empty",
    ))
    evidence_values["stage"] == "development" || throw(ArgumentError(
        "core task calibration is development-only; evidence.stage must be development",
    ))
    return (
        stage=evidence_values["stage"],
        independent_unit=evidence_values["independent_unit"],
        claim=evidence_values["claim"],
        not_supported=evidence_values["not_supported"],
    )
end

function _reference_rollout(task::Symbol, seed::Integer, ticks::Integer)
    env = if task === :tracking
        make_env(task; rng=MersenneTwister(seed), randomize_start=true)
    else
        make_env(task; rng=MersenneTwister(seed))
    end
    policy =
        task === :tracking ? tracking_reference_policy :
        task === :pong ? pong_reference_policy :
        throw(ArgumentError("no core reference policy for :$(task)"))
    for _ in 1:Int(ticks)
        step!(env, policy(env))
    end
    task_spec = resolve_task(task)
    result = metrics(env, ticks)
    raw = Float64(getproperty(result, task_spec.score_key))
    opportunities =
        task === :pong ? Int(result.hits + result.misses) :
        Int(ticks)
    return (
        raw=raw,
        normalized=normalized_score(task_spec, raw),
        opportunities=opportunities,
    )
end

function _simulated_rollout(
    task::Symbol,
    condition::Symbol,
    seed::Integer,
    ticks::Integer,
)
    node = condition === :random ? :null_random : :falandays
    env_kwargs = if task === :tracking
        condition === :blind ?
            (sensory_gain=0.0, randomize_start=true) :
            (randomize_start=true,)
    elseif condition === :blind
        (sensory_gain=0.0,)
    else
        NamedTuple()
    end
    sim = simulate(
        task;
        node,
        seed,
        ticks,
        window=ticks,
        record=Symbol[],
        env_kwargs,
    )
    outcome = task_outcome(sim)
    outcome === nothing && error("core task :$(task) has no objective")
    opportunities =
        task === :pong ? Int(sim.metrics.hits + sim.metrics.misses) :
        Int(ticks)
    return (
        raw=outcome.raw,
        normalized=outcome.normalized,
        opportunities=opportunities,
    )
end

function _paired_bootstrap_interval(
    first::Vector{Float64},
    second::Vector{Float64};
    draws::Integer=10_000,
    seed::Integer=20_260_720,
)
    length(first) == length(second) || throw(DimensionMismatch("paired samples differ in length"))
    differences = first .- second
    rng = MersenneTwister(seed)
    estimates = Vector{Float64}(undef, Int(draws))
    for draw in eachindex(estimates)
        total = 0.0
        for _ in eachindex(differences)
            total += differences[rand(rng, eachindex(differences))]
        end
        estimates[draw] = total / length(differences)
    end
    return (
        mean=mean(differences),
        lower=quantile(estimates, 0.025),
        upper=quantile(estimates, 0.975),
    )
end

function _write_csv(path, rows)
    open(path, "w") do io
        println(io, "task,condition,seed,score_key,raw,normalized,opportunities")
        for row in rows
            println(
                io,
                join((
                    row.task,
                    row.condition,
                    row.seed,
                    row.score_key,
                    repr(row.raw),
                    repr(row.normalized),
                    row.opportunities,
                ), ","),
            )
        end
    end
    return path
end

function _write_manifest(
    path;
    seeds,
    ticks,
    git_sha,
    git_dirty,
    config_path,
    bootstrap_draws,
    bootstrap_seed,
    julia_threads,
    evidence,
)
    manifest = Dict(
        "calibration" => Dict(
            "id" => "core-task-opportunity",
            "evidence_status" => evidence.stage,
            "generated_utc" => string(Dates.now(Dates.UTC)),
            "git_sha" => git_sha,
            "git_dirty" => git_dirty,
            "config_path" => config_path,
            "tasks" => [string(task) for task in CORE_TASKS],
            "conditions" => [string(condition) for condition in CORE_CONDITIONS],
            "seeds" => collect(Int, seeds),
            "ticks" => Int(ticks),
            "bootstrap_draws" => Int(bootstrap_draws),
            "bootstrap_seed" => Int(bootstrap_seed),
            "julia_threads" => Int(julia_threads),
            "independent_unit" => evidence.independent_unit,
            "claim" => evidence.claim,
            "not_supported" => evidence.not_supported,
        ),
    )
    open(path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    return path
end

function _write_report(
    path,
    rows,
    intervals,
    seeds,
    ticks,
    git_sha,
    git_dirty,
    config_path,
    julia_threads,
    evidence,
)
    open(path, "w") do io
        println(io, "# Core task opportunity calibration")
        println(io)
        println(io, "> $(uppercasefirst(evidence.stage)) calibration only. This is not confirmatory evidence.")
        println(io)
        println(io, "- Tasks: `:tracking`, `:pong`")
        println(io, "- Conditions: `:falandays`, `:blind`, `:random`, `:reference`")
        println(io, "- Independent unit: $(evidence.independent_unit)")
        println(io, "- Declared claim: $(evidence.claim)")
        println(io, "- Not supported: $(evidence.not_supported)")
        println(io, "- Paired development seeds: `$(first(seeds)):$(last(seeds))`")
        println(io, "- Ticks per run: $(ticks)")
        println(io, "- Revision: `$(git_sha)`")
        println(io, "- Worktree dirty: `$(git_dirty)`")
        println(io, "- Julia threads: $(julia_threads)")
        println(io, "- Configuration: `$(config_path)`")
        println(io, "- Generated: $(Dates.now(Dates.UTC))")
        println(io)
        println(io, "| Task | Condition | Mean normalized outcome | Mean opportunities |")
        println(io, "| --- | --- | ---: | ---: |")
        for task in CORE_TASKS, condition in CORE_CONDITIONS
            selected = filter(row -> row.task === task && row.condition === condition, rows)
            println(
                io,
                "| `:$(task)` | `:$(condition)` | ",
                round(mean(row.normalized for row in selected); digits=4),
                " | ",
                round(mean(row.opportunities for row in selected); digits=2),
                " |",
            )
        end
        println(io)
        println(io, "## Opportunity gates")
        println(io)
        for task in CORE_TASKS
            interval = intervals[task]
            println(
                io,
                "- `:$(task)` reference minus random: mean ",
                round(interval.mean; digits=4),
                ", paired bootstrap 95% interval [",
                round(interval.lower; digits=4),
                ", ",
                round(interval.upper; digits=4),
                "]. Gate: ",
                interval.lower > 0.0 ? "PASS" : "FAIL",
                ".",
            )
        end
        pong_rows = filter(row -> row.task === :pong, rows)
        event_fraction = mean(row.opportunities >= 5 for row in pong_rows)
        println(
            io,
            "- Pong runs with at least five scoring opportunities: ",
            round(100event_fraction; digits=1),
            "%. Gate (at least 90%): ",
            event_fraction >= 0.9 ? "PASS" : "FAIL",
            ".",
        )
        println(io)
        println(io, "The Falandays and blind comparisons are descriptive development results.")
        println(io, "The calibration establishes task opportunity. It does not establish a neural mechanism or general advantage.")
    end
    return path
end

function _git_provenance(repository_root)
    root = abspath(repository_root)
    git_sha = try
        readchomp(Cmd(`git rev-parse --short HEAD`; dir=root))
    catch
        "unknown"
    end
    git_dirty = try
        !isempty(strip(readchomp(Cmd(`git status --short`; dir=root))))
    catch
        true
    end
    return (sha=git_sha, dirty=git_dirty)
end

function main(args=ARGS)
    config_path = abspath(_argument_value(
        args,
        "--config",
        joinpath(pkgdir(BrainlessLab), "configs", "core_task_calibration.toml"),
    ))
    config = TOML.parsefile(config_path)
    calibration = config["calibration"]
    evidence = _evidence_config(config)
    Symbol.(calibration["tasks"]) == collect(CORE_TASKS) ||
        throw(ArgumentError("core calibration config tasks must be tracking, pong"))
    Symbol.(calibration["conditions"]) == collect(CORE_CONDITIONS) ||
        throw(ArgumentError("core calibration config conditions must be falandays, blind, random, reference"))
    n_seeds = parse(Int, _argument_value(args, "--seeds", string(calibration["seeds"])))
    ticks = parse(Int, _argument_value(args, "--ticks", string(calibration["ticks"])))
    bootstrap_draws = Int(calibration["bootstrap_draws"])
    bootstrap_seed = Int(calibration["bootstrap_seed"])
    n_seeds >= 2 || throw(ArgumentError("--seeds must be at least 2"))
    ticks >= 1 || throw(ArgumentError("--ticks must be positive"))
    output = abspath(_argument_value(
        args,
        "--output",
        joinpath(@__DIR__, "results", "core_tasks", _calibration_stamp()),
    ))
    force = "--force" in args
    if isdir(output) && !isempty(readdir(output)) && !force
        throw(ArgumentError(
            "calibration output is not empty: $(output); choose another --output or pass --force",
        ))
    end
    seeds = collect(0:(n_seeds - 1))
    parallelism = init_parallelism!(; verbose=true)
    jobs = [
        (task=task, seed=seed, condition=condition)
        for task in CORE_TASKS
        for seed in seeds
        for condition in CORE_CONDITIONS
    ]
    rows = parallel_map(jobs) do job
        task_spec = resolve_task(job.task)
        result = job.condition === :reference ?
            _reference_rollout(job.task, job.seed, ticks) :
            _simulated_rollout(job.task, job.condition, job.seed, ticks)
        return (
            task=job.task,
            condition=job.condition,
            seed=job.seed,
            score_key=task_spec.score_key,
            raw=result.raw,
            normalized=result.normalized,
            opportunities=result.opportunities,
        )
    end

    intervals = Dict{Symbol,NamedTuple}()
    for task in CORE_TASKS
        reference = [
            row.normalized for row in rows
            if row.task === task && row.condition === :reference
        ]
        random = [
            row.normalized for row in rows
            if row.task === task && row.condition === :random
        ]
        intervals[task] = _paired_bootstrap_interval(
            reference,
            random;
            draws=bootstrap_draws,
            seed=bootstrap_seed,
        )
    end

    mkpath(output)
    provenance = _git_provenance(pkgdir(BrainlessLab))
    git_sha = provenance.sha
    git_dirty = provenance.dirty
    config_relative = relpath(config_path, pkgdir(BrainlessLab))
    _write_csv(joinpath(output, "results.csv"), rows)
    _write_manifest(
        joinpath(output, "manifest.toml");
        seeds,
        ticks,
        git_sha,
        git_dirty,
        config_path=config_relative,
        bootstrap_draws,
        bootstrap_seed,
        julia_threads=parallelism.julia_threads,
        evidence,
    )
    _write_report(
        joinpath(output, "README.md"),
        rows,
        intervals,
        seeds,
        ticks,
        git_sha,
        git_dirty,
        config_relative,
        parallelism.julia_threads,
        evidence,
    )
    println(output)
    return output
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
