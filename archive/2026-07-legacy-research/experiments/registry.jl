"""
    ExpRegistry

A tiny by-name registry for composed experiments — the same pattern the core
library uses for nodes/tasks/analyses (`register_*!` + a symbol → resolve at run
time), but kept *here* in `experiments/` rather than in core, because experiments
are deliberately not part of the baseline.

An experiment is a name, a one-line description, and a `run(; kwargs...)` function
that writes a self-describing run directory and returns its path. Register at
include time; run by name via `experiments/run.jl <name> [key=val ...]`.
"""
module ExpRegistry

export Experiment, register_experiment!, experiments, resolve_experiment,
       experiment_description

struct Experiment
    name::Symbol
    description::String
    run::Function
end

const REGISTRY = Dict{Symbol,Experiment}()

"Register an experiment `run(; kwargs...)::String` (returns its run-dir path) under `name`."
function register_experiment!(name::Symbol, run::Function; description::AbstractString="")
    REGISTRY[name] = Experiment(name, String(description), run)
    return name
end

"Sorted list of registered experiment names."
experiments() = sort!(collect(keys(REGISTRY)))

function resolve_experiment(name::Symbol)
    haskey(REGISTRY, name) ||
        error("unknown experiment :$(name); registered: $(experiments())")
    return REGISTRY[name]
end

experiment_description(name::Symbol) = resolve_experiment(name).description

end # module
