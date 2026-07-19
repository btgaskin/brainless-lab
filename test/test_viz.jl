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
    @test networkplot(sim) isa Makie.Figure
    @test visualize(sim; panels=[:network]) isa Makie.Figure

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

    ext = Base.get_extension(BrainlessLab, :BrainlessLabMakieExt)
    sparse_ids = EntityID.([10, 42])
    identity_rec = Recorder(enabled=(:poses, :body_alive, :spikes, :objects))
    record!(identity_rec, :poses, EntityFrame(
        sparse_ids,
        [(1.0, 0.0, 0.0), (101.0, 0.0, 0.0)],
    ))
    record!(identity_rec, :body_alive, EntityFrame(sparse_ids, [true, false]))
    record!(identity_rec, :spikes, EntityFrame(sparse_ids, [[1.0, 0.0], [0.0, 1.0]]))
    record!(identity_rec, :objects, [
        (kind=:food, position=(1.0, 1.0), active=true),
        (kind=:food, position=(2.0, 1.0), active=true),
    ])
    tick!(identity_rec)
    reversed_ids = reverse(sparse_ids)
    record!(identity_rec, :poses, EntityFrame(
        reversed_ids,
        [(102.0, 0.0, 0.0), (2.0, 0.0, 0.0)],
    ))
    record!(identity_rec, :body_alive, EntityFrame(reversed_ids, [false, true]))
    record!(identity_rec, :spikes, EntityFrame(reversed_ids, [[0.5, 1.0], [1.0, 0.5]]))
    record!(identity_rec, :objects, [
        (kind=:food, position=(2.0, 1.0), active=true),
        (kind=:food, position=(1.0, 1.0), active=true),
    ])
    tick!(identity_rec)
    networks = (
        (kind=:synthetic, adjacency=[0.0 1.0; 0.0 0.0], state=[0.0, 0.0]),
        (kind=:synthetic, adjacency=[0.0 0.0; 1.0 0.0], state=[0.0, 0.0]),
    )
    identity_sim = SimResult(
        identity_rec,
        (;),
        :synthetic,
        :synthetic,
        (
            n_agents=2,
            agents=(
                (id=sparse_ids[1], network=networks[1]),
                (id=sparse_ids[2], network=networks[2]),
            ),
            entity_ids=Tuple(sparse_ids),
            networks=networks,
            environment=(
                bounds=(0.0, 120.0, 0.0, 10.0),
                n_colours=2,
                colours=[0, 1],
            ),
        ),
    )

    track_data = ext._pose_track_data(identity_sim)
    @test track_data.ids == sparse_ids
    @test first.(track_data.tracks[1]) == [1.0, 2.0]
    @test first.(track_data.tracks[2]) == [101.0, 102.0]
    @test ext._alive_sample(identity_sim, 2, sparse_ids) == [true, false]
    @test ext._network_info(identity_sim, 42).id == EntityID(42)
    @test ext._network_state(identity_sim, 2, ext._network_info(identity_sim, 42)) == [0.5, 1.0]
    @test_throws ArgumentError networkplot(identity_sim)
    @test networkplot(identity_sim; entity=42) isa Makie.Figure
    @test visualize(identity_sim; panels=[:network], entity=EntityID(10)) isa Makie.Figure
    @test swarmplot(identity_sim) isa Makie.Figure
    @test ext._object_style_key((kind=:food,), 1) ==
          ext._object_style_key((kind=:food,), 2)
    @test ext._object_style_key((type_index=3, kind=:food), 1) ==
          (:type_index, 3)
    colors = ext._agent_group_colors(identity_sim, reverse(sparse_ids))
    @test colors == reverse(ext._agent_group_colors(identity_sim))

    legacy_network_sim = SimResult(
        Recorder(),
        (;),
        :legacy,
        :synthetic,
        (network=networks[1], environment=(bounds=nothing,)),
    )
    @test ext._network_info(legacy_network_sim).id == EntityID(1)

    one_available_network_sim = SimResult(
        identity_rec,
        (;),
        :synthetic,
        :synthetic,
        (
            agents=(
                (id=sparse_ids[1], network=nothing),
                (id=sparse_ids[2], network=networks[2]),
            ),
            environment=(bounds=nothing,),
        ),
    )
    @test ext._network_info(one_available_network_sim).id == sparse_ids[2]
    @test_throws ArgumentError networkplot(one_available_network_sim; entity=sparse_ids[1])
end
