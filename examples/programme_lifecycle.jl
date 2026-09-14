using BrainlessLab
using BrainlessLab: attach_experiment_run!, add_experiment_note!, render_experiment
include(joinpath(@__DIR__,"..","experiments","initialisation-adaptation","build_programme.jl"))

"""Bounded software conformance only: 16 word trials and 16 Wall trials."""
function programme_lifecycle(root)
    ispath(root) && throw(ArgumentError("conformance destination must be new"))
    protocol=build_programme(joinpath(root,"programme");smoke=true)
    experiment=read_experiment(protocol)
    for branch in ("reproduction/words","reproduction/wall")
        run=run_experiment(experiment;branch,root=joinpath(root,"runs"))
        id=attach_experiment_run!(protocol,branch,run.directory)
        add_experiment_note!(protocol,branch;author="BrainlessLab conformance example",
            text="Software conformance only. This small run checks execution, diagnostics, pairing, record attachment and offline reporting. It is not evidence that the adaptation hypothesis holds or fails.",runs=(id,))
    end
    return render_experiment(protocol,joinpath(root,"report"))
end

if abspath(PROGRAM_FILE)==@__FILE__
    length(ARGS)==1 || error("usage: julia --project=. examples/programme_lifecycle.jl NEW-DIRECTORY")
    println(programme_lifecycle(only(ARGS)))
end
