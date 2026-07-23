#!/usr/bin/env julia

using BrainlessLab

function usage(io=stdout)
    println(io, "Usage:")
    println(io, "  julia --project=. bin/brainlesslab.jl check PLAN.toml")
    println(io, "  julia --project=. bin/brainlesslab.jl run PLAN.toml [--root DIR]")
    println(io, "  julia --project=. bin/brainlesslab.jl check-experiment PROTOCOL_DIR")
    println(io, "  julia --project=. bin/brainlesslab.jl run-experiment PROTOCOL_DIR [--root DIR]")
end

function parse_run_options(args)
    root = "records"
    index = 1
    while index <= length(args)
        args[index] == "--root" || throw(ArgumentError(
            "unknown run option $(repr(args[index]))",
        ))
        index < length(args) || throw(ArgumentError("--root requires a directory"))
        root = args[index + 1]
        index += 2
    end
    return root
end

function main(args=ARGS)
    length(args) >= 2 || begin
        usage(stderr)
        return 2
    end
    command = args[1]
    command in ("check", "run", "check-experiment", "run-experiment") || begin
        usage(stderr)
        return 2
    end
    source_path = args[2]

    if command in ("check-experiment", "run-experiment")
        isdir(source_path) || throw(ArgumentError(
            "experiment protocol directory does not exist: $(source_path)",
        ))
        experiment = read_experiment(source_path)
        if command == "check-experiment"
            println("valid experiment: ", experiment.id)
            println("version: ", experiment.version)
            println("evidence state: ", experiment.evidence_state)
            println("operations: ", join(string.(getfield.(experiment.operations, :id)), ", "))
            return 0
        end
        root = parse_run_options(args[3:end])
        run = run_experiment(experiment; root=root)
        println("experiment record: ", run.directory)
        println("operation records: ", join(run.records, ", "))
        return 0
    end

    isfile(source_path) || throw(ArgumentError("plan does not exist: $(source_path)"))
    plan = read_plan(source_path)
    resolved = resolve(plan, DEFAULT_REGISTRY)

    if command == "check"
        println("valid plan: ", plan.id)
        println("operation: ", operation_kind(plan))
        println("targets: ", join(string.(getfield.(operation_targets(plan), :id)), ", "))
        println("resolved: ", nameof(typeof(resolved)))
        return 0
    end

    root = parse_run_options(args[3:end])
    run = run_operation(plan; root=root)
    println("record: ", run.directory)
    println("summary: ", summary(run.result))
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
