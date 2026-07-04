#!/usr/bin/env julia
#
# BrainlessLab per-node profile runner -- builds a timestamped characterization
# run directory for one registered node variant: metrics.csv, house-palette
# figures, representative behaviour GIFs, manifest, and README. HTML is an
# opt-in stub behind --report.
#
# Setup (once):
#   cd brainless-lab/profile
#   julia --project=. -e 'using Pkg; Pkg.develop(path=".."); Pkg.add(["CairoMakie","Statistics","Printf","TOML"]); Pkg.instantiate()'
#
# Usage:
#   julia --project=. run.jl falandays_base
#   julia --project=. run.jl falandays_base --seeds 12
#   julia --project=. run.jl falandays_oosawa --out runs
#   julia --project=. run.jl falandays_base --report
#
# Flags: --seeds <n> --out <runs-root> --no-gifs --report

include("Profile.jl")
using .NodeProfile

function parse_args(args)
    opts = Dict{Symbol,Any}(
        :node => :falandays_base,
        :seeds => 8,
        :out => joinpath(@__DIR__, "runs"),
        :gifs => true,
        :report => false,
    )
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
        elseif a == "--no-gifs"
            opts[:gifs] = false
        elseif a == "--report"
            opts[:report] = true
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

    println("Profiling :$node_sym across ", join(string.(NodeProfile.DEFAULT_TASKS), ", "),
            " (n_seeds=$n_seeds) …")
    t0 = time()
    out = node_profile(
        node_sym;
        n_seeds=n_seeds,
        out_root=String(o[:out]),
        gifs=Bool(o[:gifs]),
        report=Bool(o[:report]),
    )
    dt = round(time() - t0; digits=1)
    println("Wrote ", out.dir, "  (metrics ", round(filesize(out.metrics) / 1024; digits=1), " KiB, $(dt)s)")
end

main(ARGS)
