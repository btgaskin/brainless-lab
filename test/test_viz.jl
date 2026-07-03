using BrainlessLab
using Test

@testset "Recording and Makie visualization extension" begin
    @test Base.get_extension(BrainlessLab, :BrainlessLabMakieExt) === nothing

    sim = simulate(:wall; node=:falandays, ticks=60)
    @test sim isa SimResult
    @test sim.task == :wall
    @test sim.node == :falandays
    @test !isempty(getchannel(sim.recorder, :spikes))
    @test !isempty(getchannel(sim.recorder, :rate))
    @test Base.get_extension(BrainlessLab, :BrainlessLabMakieExt) === nothing

    using CairoMakie
    import Makie

    @test Base.get_extension(BrainlessLab, :BrainlessLabMakieExt) !== nothing

    fig = visualize(sim; panels=[:raster, :rate, :trajectory])
    @test fig isa Makie.Figure
    @test rasterplot(sim) isa Makie.Figure
    @test driftplot(sim) isa Makie.Figure

    path = tempname() * ".png"
    Makie.save(path, fig)
    @test isfile(path)
    rm(path; force=true)

    for short_sim in (
        simulate(:wall; node=:falandays, n_nodes=30, ticks=8, seed=7, record=(:spikes, :rate, :poses)),
        simulate(:forage; node=:falandays_base, n_agents=3, n_nodes=30, ticks=8, seed=7,
                 record=(:spikes, :rate, :poses, :polarization, :milling)),
    )
        @test visualize(short_sim; panels=[:raster, :rate, short_sim.task == :forage ? :swarm : :trajectory]) isa Makie.Figure
        gif = tempname() * ".gif"
        @test animate(short_sim; path=gif, maxframes=2, framerate=2) == gif
        @test isfile(gif)
        rm(gif; force=true)
    end
end
