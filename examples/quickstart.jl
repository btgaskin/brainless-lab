using BrainlessLab

let
    output_dir = get(ENV, "BRAINLESSLAB_EXAMPLE_OUTPUT_DIR", joinpath(@__DIR__, "output"))
    mkpath(output_dir)

    sim = simulate(:wall; node=:falandays_base, ticks=300)

    println("quickstart score=$(round(sim.metrics.score; digits=3))")
    if isdefined(Main, :CairoMakie)
        fig = visualize(sim)
        raster = rasterplot(sim)

        Main.CairoMakie.save(joinpath(output_dir, "quickstart_visualize.png"), fig)
        Main.CairoMakie.save(joinpath(output_dir, "quickstart_raster.png"), raster)
        println("saved figures to $(output_dir)")
    else
        println("CairoMakie is not loaded; skipped figure export")
    end
end
