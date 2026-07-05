#!/usr/bin/env julia

# Re-exec with a higher thread count so independent rollouts spread across
# cores. Unlike the other entry scripts' `-t auto` (measured only 4 threads on
# this 10-core box), default to a fixed floor of 8 -- override with
# BRAINLESSLAB_THREADS, or pin JULIA_NUM_THREADS yourself to skip this.
if Threads.nthreads() == 1 &&
   !haskey(ENV, "JULIA_NUM_THREADS") &&
   get(ENV, "BRAINLESSLAB_AUTOTHREADS", "1") != "0"
    n = get(ENV, "BRAINLESSLAB_THREADS", "8")
    _cmd = addenv(
        `$(Base.julia_cmd()) --threads=$(n) --project=$(Base.active_project()) $(abspath(PROGRAM_FILE)) $(ARGS)`,
        "BRAINLESSLAB_AUTOTHREADS" => "0",
    )
    _proc = run(ignorestatus(_cmd))
    exit(_proc.exitcode)
end

include("Benchmark.jl")

using .Benchmark
using BrainlessLab

function usage()
    println("usage: julia --project=. train.jl <neuron> <task> [--generations N --popsize N --seed N --N n --ticks t --k-trials N --sigma0 X]")
end

function parse_args(args)
    opts = Dict{Symbol,Any}(
        :generations => 30,
        :popsize => 16,
        :seed => 0,
        :N => 120,
        :ticks => 300,
        :k_trials => 8,
        :sigma0 => 2.5,
    )
    positional = String[]

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--generations"
            i += 1
            opts[:generations] = parse(Int, args[i])
        elseif arg == "--popsize"
            i += 1
            opts[:popsize] = parse(Int, args[i])
        elseif arg == "--seed"
            i += 1
            opts[:seed] = parse(Int, args[i])
        elseif arg == "--N" || arg == "--n"
            i += 1
            opts[:N] = parse(Int, args[i])
        elseif arg == "--ticks"
            i += 1
            opts[:ticks] = parse(Int, args[i])
        elseif arg == "--k-trials" || arg == "--k_trials"
            i += 1
            opts[:k_trials] = parse(Int, args[i])
        elseif arg == "--sigma0"
            i += 1
            opts[:sigma0] = parse(Float64, args[i])
        elseif startswith(arg, "--")
            error("unknown option $arg")
        else
            push!(positional, arg)
        end
        i += 1
    end

    length(positional) == 2 || return nothing
    return (
        neuron=Symbol(positional[1]),
        task=Symbol(positional[2]),
        generations=Int(opts[:generations]),
        popsize=Int(opts[:popsize]),
        seed=Int(opts[:seed]),
        N=Int(opts[:N]),
        ticks=Int(opts[:ticks]),
        k_trials=Int(opts[:k_trials]),
        sigma0=Float64(opts[:sigma0]),
    )
end

function train_one(opts)
    result = BrainlessLab.evolve(
        model_sym=opts.neuron,
        train_tasks=(opts.task,),
        generations=opts.generations,
        popsize=opts.popsize,
        k_trials=opts.k_trials,
        N=opts.N,
        ticks=opts.ticks,
        sigma0=opts.sigma0,
        seed=opts.seed,
    )

    genome = Vector{Float64}(Float64.(result.best))
    tag = Benchmark.Store.genome_tag(genome)
    git = Benchmark.Store.git_sha(Benchmark.Store.repo_root())

    manifest = Dict{String,Any}(
        "git_sha" => git,
        "neuron" => String(opts.neuron),
        "task" => String(opts.task),
        "seed" => opts.seed,
        "generations" => opts.generations,
        "popsize" => opts.popsize,
        "k_trials" => opts.k_trials,
        "N" => opts.N,
        "ticks" => opts.ticks,
        "sigma0" => opts.sigma0,
        "best_fitness" => Float64(result.best_fitness),
        "timestamp_utc" => Benchmark.Store.timestamp_utc(),
        "tag" => tag,
    )

    entry = Benchmark.Store.save_genome_entry(
        Benchmark.Store.bench_dir(),
        opts.neuron,
        opts.task,
        genome,
        manifest,
    )

    println("tag=", tag, " best_fitness=", Float64(result.best_fitness))
    println(entry.dir)
    return entry
end

function main(args)
    opts = parse_args(args)
    if opts === nothing
        usage()
        exit(1)
    end
    train_one(opts)
end

main(ARGS)
