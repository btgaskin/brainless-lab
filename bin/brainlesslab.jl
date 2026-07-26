#!/usr/bin/env julia

using BrainlessLab

function usage(io=stdout)
    println(io, "Usage:")
    println(io, "  julia --project=. bin/brainlesslab.jl check PLAN.toml")
    println(io, "  julia --project=. bin/brainlesslab.jl run PLAN.toml [--root DIR]")
    println(io, "  julia --project=. bin/brainlesslab.jl check-experiment PROTOCOL_DIR")
    println(io, "  julia --project=. bin/brainlesslab.jl run-experiment PROTOCOL_DIR [--root DIR]")
    println(io, "  julia --project=. bin/brainlesslab.jl check-contribution DIR [--repository DIR] [--main-ref REF] [--base REF]")
    println(io, "  julia --project=. bin/brainlesslab.jl compare-contribution DIR [--write]")
    println(io, "  julia --project=. bin/brainlesslab.jl index-research [--root DIR] [--output FILE] [--repository DIR] [--main-ref REF]")
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

function parse_named_options(args, allowed)
    options = Dict{String,String}()
    index = 1
    while index <= length(args)
        option = args[index]
        option in allowed || throw(ArgumentError("unknown option $(repr(option))"))
        index < length(args) || throw(ArgumentError("$(option) requires a value"))
        options[option] = args[index + 1]
        index += 2
    end
    return options
end

function main(args=ARGS)
    !isempty(args) || begin
        usage(stderr)
        return 2
    end
    command = args[1]
    command in (
        "check", "run", "check-experiment", "run-experiment",
        "check-contribution", "compare-contribution", "index-research",
    ) || begin
        usage(stderr)
        return 2
    end
    if command == "index-research"
        options = parse_named_options(
            args[2:end],
            ("--root", "--output", "--repository", "--main-ref"),
        )
        root = get(options, "--root", joinpath(pwd(), "research"))
        output = get(options, "--output", joinpath(root, "catalogue.json"))
        repository = get(options, "--repository", pwd())
        main_ref = get(options, "--main-ref", "origin/main")
        BrainlessLab.write_research_catalogue(output; root, repository, main_ref)
        println("research catalogue: ", output)
        return 0
    end
    length(args) >= 2 || begin
        usage(stderr)
        return 2
    end
    source_path = args[2]

    if command == "check-contribution"
        options = parse_named_options(
            args[3:end],
            ("--repository", "--main-ref", "--base"),
        )
        result = BrainlessLab.validate_contribution(
            source_path;
            repository=get(options, "--repository", pwd()),
            main_ref=get(options, "--main-ref", "origin/main"),
            base_ref=get(options, "--base", nothing),
        )
        println("valid contribution: ", result.manifest["id"])
        println("experiment: ", result.manifest["experiment_id"])
        println("version: ", result.manifest["experiment_version"])
        result.target_exceeded && println(
            "size note: the complete contribution exceeds the 1 MiB target",
        )
        return 0
    elseif command == "compare-contribution"
        write = false
        for option in args[3:end]
            option == "--write" || throw(ArgumentError(
                "unknown compare option $(repr(option))",
            ))
            write = true
        end
        comparison = BrainlessLab.compare_contribution(source_path; write)
        write && println("comparison: ", joinpath(source_path, "comparison.json"))
        println("configuration equal: ", comparison["configuration_equal"])
        println("seeds equal: ", comparison["seeds_equal"])
        println(
            "data equal: ",
            all(operation -> operation["data_equal"], comparison["operations"]),
        )
        return 0
    end

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
        println("operation: ", BrainlessLab.operation_kind(plan))
        println("targets: ", join(string.(getfield.(BrainlessLab.operation_targets(plan), :id)), ", "))
        println("resolved: ", nameof(typeof(resolved)))
        return 0
    end

    root = parse_run_options(args[3:end])
    run = run_operation(plan; root=root)
    println("record: ", run.directory)
    println("summary: ", BrainlessLab.summary(run.result))
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
