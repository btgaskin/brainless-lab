using BrainlessLab, CairoMakie

let
    output_dir = get(ENV, "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR", joinpath(@__DIR__, "output"))
    mkpath(output_dir)

    sim = simulate(
        :torus;
        node=:falandays,
        n_agents=2,
        ticks=400,
        seed=7,
        record=[:spikes, :rate, :poses, :polarization, :milling],
    )

    swarm = swarmplot(sim)
    overview = visualize(sim; panels=[:swarm, :rate], size=(900, 520))

    save(joinpath(output_dir, "dyad_swarm.png"), swarm)
    save(joinpath(output_dir, "dyad_overview.png"), overview)

    println("dyad polarization=$(round(sim.metrics.polarization; digits=3)) milling=$(round(sim.metrics.milling; digits=3))")
    println("saved figures to $(output_dir)")
end
