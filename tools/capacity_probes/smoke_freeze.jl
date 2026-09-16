using BrainlessLab
include(joinpath(@__DIR__, "freeze_curves.jl"))

function smoke_freeze(root)
    ispath(root) && error("use a new conformance directory")
    experiment = capacity_freeze_programme(blocks=2, trials_per_block=2,
        fractions=(0.0,1.0), root_seed=2026092001)
    write_experiment(joinpath(root,"protocol"),experiment)
    for branch in experiment.children
        result = run_experiment(branch; root=joinpath(root,"runs"),id=String(branch.id))
        println(result.directory); flush(stdout)
    end
    println("Software conformance only: two blocks per condition; not the ten-block study.")
end

length(ARGS)==1 || error("usage: smoke_freeze.jl NEW-DIRECTORY")
smoke_freeze(only(ARGS))
