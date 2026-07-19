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

    rec = Recorder(enabled=(:poses, :objects, :body_alive))
    for t in 1:4
        record!(rec, :poses, [(4.0 + 0.2t, 5.0, 0.0)])
        record!(rec, :objects, [(
            object=1,
            type_index=1,
            kind=:beacon,
            bank=:beacon,
            position=(7.0, 5.0),
            radius=0.5,
            active=true,
            remaining=typemax(Int),
            capacity=nothing,
        )])
        record!(rec, :body_alive, [t < 4])
        tick!(rec)
    end
    physical_sim = SimResult(
        rec,
        (;),
        :synthetic,
        :falandays_base,
        (environment=(bounds=(0.0, 10.0, 0.0, 10.0),),),
    )
    @test swarmplot(physical_sim) isa Makie.Figure
    @test visualize(physical_sim; panels=[:swarm]) isa Makie.Figure
    gif = tempname() * ".gif"
    @test animate(physical_sim; path=gif, maxframes=2, framerate=2) == gif
    @test isfile(gif)
    rm(gif; force=true)
end
