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
end
