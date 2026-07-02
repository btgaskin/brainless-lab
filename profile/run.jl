#!/usr/bin/env julia
#
# BrainlessLab per-node profile runner -- builds a self-contained HTML report
# of per-task branching-ratio (criticality) behaviour for a registered node
# variant, seed-averaged over independent random-wiring rollouts.
#
# Setup (once):
#   cd brainless-lab/profile
#   julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add(["CairoMakie","Statistics","Printf","Base64","TOML"]); Pkg.instantiate()'
#
# Usage:
#   julia --project=. run.jl falandays_base
#   julia --project=. run.jl falandays_base --seeds 12
#   julia --project=. run.jl falandays_oosawa --out output/oosawa_run
#
# Flags: --seeds <n> --out <dir>

include("Profile.jl")
using .NodeProfile

function parse_args(args)
    opts = Dict{Symbol,Any}(:node => :falandays_base, :seeds => 8, :out => nothing)
    positional = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--seeds"
            i += 1
            opts[:seeds] = parse(Int, args[i])
        elseif a == "--out"
            i += 1
            opts[:out] = args[i]
        elseif startswith(a, "--")
            @warn "ignoring unrecognised flag" flag = a
        else
            push!(positional, a)
        end
        i += 1
    end
    if !isempty(positional)
        opts[:node] = Symbol(positional[1])
    end
    return opts
end

function main(args)
    o = parse_args(args)
    node_sym = o[:node]::Symbol
    n_seeds = o[:seeds]::Int
    out_dir = o[:out] === nothing ? joinpath(@__DIR__, "output", string(node_sym)) : o[:out]

    println("Profiling :$node_sym across ", join(string.(NodeProfile.DEFAULT_TASKS), ", "),
            " (n_seeds=$n_seeds) …")
    t0 = time()
    path = node_profile(node_sym; n_seeds=n_seeds, out_dir=out_dir)
    dt = round(time() - t0; digits=1)
    println("Wrote $path  (", round(filesize(path) / 1024; digits=1), " KiB, $(dt)s)")
end

main(ARGS)
