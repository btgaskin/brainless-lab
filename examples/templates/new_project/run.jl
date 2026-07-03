#!/usr/bin/env julia

using BrainlessLab
using CairoMakie

include("my_node.jl")
include("my_task.jl")
include("my_metric.jl")

const RECORD = [:spikes, :rate, :effectors, :percepts]

function _parse_args(args)
    opts = Dict{Symbol,Any}(
        :ticks => 300,
        :seed => 1,
        :n_nodes => 80,
        :out => joinpath(@__DIR__, "output"),
    )

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--ticks"
            i += 1
            opts[:ticks] = parse(Int, args[i])
        elseif arg == "--seed"
            i += 1
            opts[:seed] = parse(Int, args[i])
        elseif arg == "--n-nodes"
            i += 1
            opts[:n_nodes] = parse(Int, args[i])
        elseif arg == "--out"
            i += 1
            opts[:out] = args[i]
        elseif arg == "--help" || arg == "-h"
            println("usage: julia --project=. run.jl [--ticks N] [--seed N] [--n-nodes N] [--out DIR]")
            exit(0)
        else
            error("unknown argument: $arg")
        end
        i += 1
    end

    return opts
end

function _print_metrics(metrics)
    println("metrics:")
    for (key, value) in pairs(metrics)
        if value isa Real || value isa AbstractString || value isa Bool
            println("  ", key, " = ", value)
        end
    end

    return nothing
end

function main(args)
    opts = _parse_args(args)
    mkpath(opts[:out])

    sim = simulate(
        :my_task;
        node=:my_node,
        ticks=opts[:ticks],
        seed=opts[:seed],
        n_nodes=opts[:n_nodes],
        record=RECORD,
        metrics=[:final_error_abs],
    )

    _print_metrics(sim.metrics)

    fig = visualize(sim; panels=[:raster, :rate, :drift], size=(900, 760))
    out_path = joinpath(opts[:out], "my_task_my_node_visualize.png")
    save(out_path, fig)
    println("saved figure: ", out_path)
    return sim
end

main(ARGS)
