using BrainlessLab, CairoMakie

let
    output_dir = get(ENV, "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR", joinpath(@__DIR__, "output"))
    mkpath(output_dir)

    sim = simulate(:wall; node=:falandays, ticks=300, seed=23, record=[:spikes, :rate, :poses])
    fig = driftplot(sim; bin=6)

    save(joinpath(output_dir, "drift.png"), fig)

    println("drift example score=$(round(sim.metrics.score; digits=3))")
    println("saved figures to $(output_dir)")
end
