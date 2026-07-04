#!/usr/bin/env julia

# Re-exec with `-t auto` so independent rollouts can use all performance cores
# when Julia was launched single-threaded and the user did not pin a count.
if Threads.nthreads() == 1 &&
   !haskey(ENV, "JULIA_NUM_THREADS") &&
   get(ENV, "BRAINLESSLAB_AUTOTHREADS", "1") != "0"
    _cmd = addenv(
        `$(Base.julia_cmd()) --threads=auto --project=$(Base.active_project()) $(abspath(PROGRAM_FILE)) $(ARGS)`,
        "BRAINLESSLAB_AUTOTHREADS" => "0",
    )
    _proc = run(ignorestatus(_cmd))
    exit(_proc.exitcode)
end

using CairoMakie

include("Benchmark.jl")

using .Benchmark

function usage()
    println("usage: julia --project=. run.jl [--config core.toml] [--neurons a,b] [--tasks x,y] [--no-gifs]")
end

function resolve_config_path(path::AbstractString)
    if isfile(path)
        return path
    end
    candidate = joinpath(@__DIR__, "configs", path)
    isfile(candidate) && return candidate
    return path
end

function parse_args(args)
    opts = Dict{Symbol,Any}(
        :config => joinpath(@__DIR__, "configs", "core.toml"),
        :neurons => nothing,
        :tasks => nothing,
        :gifs => nothing,
    )

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--config"
            i += 1
            opts[:config] = resolve_config_path(args[i])
        elseif arg == "--neurons"
            i += 1
            opts[:neurons] = Benchmark.parse_symbol_list(args[i])
        elseif arg == "--tasks"
            i += 1
            opts[:tasks] = Benchmark.parse_symbol_list(args[i])
        elseif arg == "--no-gifs"
            opts[:gifs] = false
        elseif arg == "--help" || arg == "-h"
            usage()
            exit(0)
        else
            error("unknown option $arg")
        end
        i += 1
    end

    return opts
end

function main(args)
    opts = parse_args(args)
    cfg = Benchmark.read_bench_config(
        opts[:config];
        neurons_override=opts[:neurons],
        tasks_override=opts[:tasks],
        gifs_override=opts[:gifs],
    )
    result = Benchmark.run_benchmark(cfg)
    println(result.dir)
    Benchmark.print_short_summary(result.summaries)
end

main(ARGS)
