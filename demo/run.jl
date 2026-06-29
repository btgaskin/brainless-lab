#!/usr/bin/env julia
#
# BrainlessLab demo runner — visualise the standard Falandays models on the
# standard tasks. Each saved run is archived to its own timestamped run
# directory (config + manifest + figure + GIF + metrics), reusing the library's
# run-artifacts system; the interactive mode opens a live GLMakie window.
#
# Setup (once):
#   cd brainless-lab/demo
#   julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add(["CairoMakie"]); Pkg.instantiate()'
#   # for the interactive window also: julia --project=. -e 'using Pkg; Pkg.add("GLMakie")'
#
# Usage:
#   julia --project=. run.jl wall                 # interactive window (needs GLMakie)
#   julia --project=. run.jl wall --save          # archive a run dir (figure + activity.gif)
#   julia --project=. run.jl torus --n-agents 6 --save
#   julia --project=. run.jl wall --save --no-gif # skip the (slower) GIF
#   julia --project=. run.jl --list               # list tasks and node variants
#
# Flags: --node <name> --ticks <n> --seed <n> --n-agents <n> --save --no-gif --out <runs-root>

using BrainlessLab
import TOML

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

# Channels needed so both the static panels and the animation have data.
const RECORD = [:spikes, :rate, :poses, :polarization, :milling, :scene]

function parse_args(args)
    opts = Dict{Symbol,Any}(:task=>nothing, :node=>:falandays, :ticks=>nothing,
                            :seed=>0, :n_agents=>nothing, :save=>false, :gif=>true,
                            :out=>joinpath(@__DIR__, "runs"), :list=>false)
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--list";        opts[:list] = true
        elseif a == "--save";    opts[:save] = true
        elseif a == "--no-gif";  opts[:gif] = false
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

_family(node) = startswith(String(node), "compartmental") ? :compartmental : :falandays

# Build a RunConfig for this demo run (driver :fixed — a single fixed-model rollout).
function _demo_config(task, o)
    BrainlessLab.RunConfig(
        run = BrainlessLab.RunSection(; name="demo_$(task)_$(o[:node])", driver=:fixed,
                                      seed_base=max(0, o[:seed]), profile=:teaching),
        model = BrainlessLab.ModelSection(; family=_family(o[:node]), node=o[:node]),
        task = BrainlessLab.TaskSection(; train=(task,),
                                        ticks=(o[:ticks] === nothing ? nothing : o[:ticks])),
    )
end

function _write_metrics(path, metrics)
    open(path, "w") do io
        for (k, v) in pairs(metrics)
            if v isa Bool;             println(io, "$k = $v")
            elseif v isa Real;         println(io, "$k = $(Float64(v))")
            elseif v isa AbstractString; println(io, "$k = \"$v\"")
            end
        end
    end
end

function save_run_dir(task, sim, o)
    cfg = _demo_config(task, o)
    dir = BrainlessLab.run_dir(cfg; root=o[:out])
    write_config(resolve(cfg), joinpath(dir, "config.resolved.toml"))
    open(joinpath(dir, "manifest.toml"), "w") do io
        TOML.print(io, capture_manifest(cfg))
    end
    _write_metrics(joinpath(dir, "metrics.toml"), sim.metrics)

    panels = get(PANELS, task, [:raster, :rate])
    fig = Base.invokelatest(visualize, sim; panels=panels)
    Base.invokelatest(Main.CairoMakie.save, joinpath(dir, "figure.png"), fig)
    if o[:gif]
        Base.invokelatest(animate, sim; path=joinpath(dir, "activity.gif"), framerate=20)
    end
    return dir
end

function main(args)
    o = parse_args(args)
    if o[:list]
        println("Tasks:    ", join(string.(sort(collect(tasks()))), ", "))
        println("Node variants: ", join(string.(sort(collect(variants()))), ", "))
        println("\nExamples:\n  julia --project=. run.jl wall\n  julia --project=. run.jl wall --save\n  julia --project=. run.jl torus --n-agents 6 --save")
        return
    end
    task = o[:task] === nothing ? :wall : o[:task]
    kw = Dict{Symbol,Any}(:node=>o[:node], :seed=>o[:seed])
    o[:ticks] !== nothing && (kw[:ticks] = o[:ticks])
    o[:n_agents] !== nothing && (kw[:n_agents] = o[:n_agents])

    # The viz backend is loaded at TOP LEVEL (below) before main runs; calls go
    # through invokelatest to be robust to that load being a newer world age.
    if o[:save]
        println("Simulating :$task with node :$(o[:node]) …")
        sim = simulate(task; record=RECORD, kw...)
        dir = save_run_dir(task, sim, o)
        sc = hasproperty(sim.metrics, :score) ? "   score=$(round(sim.metrics.score, digits=3))" : ""
        println("Archived run → $dir$sc")
        for f in sort(readdir(dir)); println("    $f"); end
    else
        println("Opening interactive window for :$task (node :$(o[:node])). Close the window to exit.")
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
                error("Interactive mode needs GLMakie. Use --save for archived figures/GIF, " *
                      "or install it once: julia --project=. -e 'using Pkg; Pkg.add(\"GLMakie\")'")
            end
        end
    end
end

main(ARGS)
