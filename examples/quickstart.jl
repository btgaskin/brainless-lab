using BrainlessLab, CairoMakie

let
    output_dir = get(ENV, "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR", joinpath(@__DIR__, "output"))
    mkpath(output_dir)

    sim = simulate(:wall; node=:falandays, ticks=300)

    fig = visualize(sim)
    raster = rasterplot(sim)

    save(joinpath(output_dir, "quickstart_visualize.png"), fig)
    save(joinpath(output_dir, "quickstart_raster.png"), raster)

    println("quickstart score=$(round(sim.metrics.score; digits=3))")
    println("saved figures to $(output_dir)")
end
