#!/usr/bin/env julia
#
# BrainlessLab demo runner — visualise the standard Falandays models on the
# standard tasks, either as an interactive window or as saved figures.
#
# Setup (once):
#   cd brainless-lab/demo
#   julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.instantiate()'
#   # for the interactive window also: julia --project=. -e 'using Pkg; Pkg.add("GLMakie")'
#
# Usage:
#   julia --project=. run.jl wall                 # interactive window (needs GLMakie)
#   julia --project=. run.jl wall --save          # save static panels to demo/output/
#   julia --project=. run.jl torus --n-agents 6 --save
#   julia --project=. run.jl --list               # list tasks and node variants
#
# Flags: --node <name>  --ticks <n>  --seed <n>  --n-agents <n>  --save  --out <dir>

using BrainlessLab

const PANELS = Dict(
    :wall     => [:raster, :rate, :trajectory],
    :tracking => [:raster, :rate],
    :pong     => [:raster, :rate],
    :cartpole => [:raster, :rate],
    :cartpole_hard => [:raster, :rate],
    :cartpole_swingup => [:raster, :rate],
    :cartpole_long => [:raster, :rate],
    :torus    => [:raster, :rate, :swarm],
)

function parse_args(args)
    opts = Dict{Symbol,Any}(:task=>nothing, :node=>:falandays, :ticks=>nothing,
                            :seed=>0, :n_agents=>nothing, :save=>false,
                            :out=>joinpath(@__DIR__, "output"), :list=>false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--list";        opts[:list] = true
        elseif a == "--save";    opts[:save] = true
        elseif a == "--node";    opts[:node] = Symbol(args[i+=1])
        elseif a == "--ticks";   opts[:ticks] = parse(Int, args[i+=1])
        elseif a == "--seed";    opts[:seed] = parse(Int, args[i+=1])
        elseif a == "--n-agents";opts[:n_agents] = parse(Int, args[i+=1])
        elseif a == "--out";     opts[:out] = args[i+=1]
        elseif !startswith(a, "--") && opts[:task] === nothing; opts[:task] = Symbol(a)
        else; @warn "ignoring unrecognised arg" arg=a
        end
        i += 1
    end
    return opts
end

function main(args)
    o = parse_args(args)
    if o[:list]
        println("Tasks:    ", join(string.(sort(collect(tasks()))), ", "))
        println("Node variants: ", join(string.(sort(collect(variants()))), ", "))
        println("\nExamples:\n  julia --project=. run.jl wall\n  julia --project=. run.jl wall --node falandays_oosawa --save\n  julia --project=. run.jl torus --n-agents 6 --save")
        return
    end
    task = o[:task] === nothing ? :wall : o[:task]
    node = o[:node]
    kw = Dict{Symbol,Any}(:node=>node, :seed=>o[:seed])
    o[:ticks] !== nothing && (kw[:ticks] = o[:ticks])
    o[:n_agents] !== nothing && (kw[:n_agents] = o[:n_agents])

    # NOTE: the visualization backend is loaded at TOP LEVEL (below) before main
    # runs, so its methods are visible here; calls go through invokelatest to be
    # robust to that load happening in a newer world age than this function.
    if o[:save]
        # Headless: simulate + static panels (CairoMakie), saved to PNG.
        println("Simulating :$task with node :$node …")
        sim = simulate(task; kw...)
        panels = get(PANELS, task, [:raster, :rate])
        fig = Base.invokelatest(visualize, sim; panels=panels)
        mkpath(o[:out])
        path = joinpath(o[:out], "demo_$(task)_$(node).png")
        Base.invokelatest(Main.CairoMakie.save, path, fig)
        sc = hasproperty(sim.metrics, :score) ? sim.metrics.score : nothing
        println("Saved $path", sc === nothing ? "" : "   (score=$(round(sc, digits=3)))")
    else
        # Interactive: live GLMakie window with Play / Step / speed.
        println("Opening interactive window for :$task (node :$node). Close the window to exit.")
        Base.invokelatest(explore, task; kw...)
    end
end

# Load the viz backend at top level (avoids world-age problems): CairoMakie for
# --save, GLMakie for the interactive window. --list needs neither.
let a = ARGS
    if !("--list" in a)
        if "--save" in a
            @eval using CairoMakie
        else
            try
                @eval using GLMakie
            catch
                error("Interactive mode needs GLMakie. Use --save for static panels, " *
                      "or install it once: julia --project=. -e 'using Pkg; Pkg.add(\"GLMakie\")'")
            end
        end
    end
end

main(ARGS)
