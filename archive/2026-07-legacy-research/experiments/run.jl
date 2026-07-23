# experiments/run.jl — run a registered experiment by name.
#
#   julia --project=. experiments/run.jl --list
#   julia --project=. experiments/run.jl <name> [key=val ...]
#   julia --project=. experiments/run.jl freeze_onset seeds=0:9 tasks=tracking,pong window=600
#
# key=val values parse as: Int (600) · Float (0.5) · range (0:9) · comma-list
# (tracking,pong -> Symbols; 1,2,4,8 -> Ints) · otherwise a Symbol.

include(joinpath(@__DIR__, "harness.jl"))
include(joinpath(@__DIR__, "registry.jl"))
using .ExpHarness, .ExpRegistry
using BrainlessLab

# --- register experiments (each file self-registers at include time) ---
include(joinpath(@__DIR__, "freeze_onset.jl"))
include(joinpath(@__DIR__, "tracking_param_sweep.jl"))
include(joinpath(@__DIR__, "tracking_leak_lrate_factorial.jl"))
include(joinpath(@__DIR__, "shoal_vision_sweep.jl"))
# add new experiments here:  include(joinpath(@__DIR__, "<name>.jl"))

function _parse_val(s::AbstractString)
    if occursin(":", s)
        p = parse.(Int, split(s, ":"))
        return length(p) == 2 ? (p[1]:p[2]) : (p[1]:p[2]:p[3])
    elseif occursin(",", s)
        parts = split(s, ",")
        ints = tryparse.(Int, parts)
        return all(!isnothing, ints) ? Int.(ints) : Symbol.(parts)
    end
    let i = tryparse(Int, s); i !== nothing && return i end
    let f = tryparse(Float64, s); f !== nothing && return f end
    lower = lowercase(s)
    lower == "true" && return true
    lower == "false" && return false
    return Symbol(s)
end

function _parse_kwargs(args)
    kw = Dict{Symbol,Any}()
    for a in args
        parts = split(a, "=", limit=2)
        length(parts) == 2 || error("expected key=val, got '$(a)'")
        kw[Symbol(parts[1])] = _parse_val(String(parts[2]))
    end
    return kw
end

function main(args)
    if isempty(args) || first(args) in ("--list", "-l", "list", "--help", "-h")
        println("Registered experiments  (experiments/run.jl <name> [key=val ...]):\n")
        for name in ExpRegistry.experiments()
            println(
                "  ",
                rpad(string(name), 18),
                "  ",
                ExpRegistry.experiment_description(name),
            )
        end
        return
    end
    name = Symbol(first(args))
    kw = _parse_kwargs(args[2:end])
    println("running :", name, "  ", isempty(kw) ? "(defaults)" : kw, "\n")
    dir = ExpRegistry.resolve_experiment(name).run(; kw...)
    println("\nwrote ", dir)
end

main(ARGS)
