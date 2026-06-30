using BrainlessLab
using Test

@testset "Run-directory replay" begin
    dir = mktempdir()
    sim = simulate(
        :wall;
        node=:falandays,
        ticks=24,
        seed=11,
        n_nodes=12,
        record=[:spikes, :rate, :poses, :scene],
    )

    path = save_recorder(dir, sim)
    @test path == joinpath(dir, "recorder.jld2")
    @test isfile(path)

    restored = replay(dir)
    @test restored isa SimResult
    @test restored.task == sim.task
    @test restored.node == sim.node
    @test restored.metrics == sim.metrics
    @test restored.config == sim.config
    @test restored.recorder.enabled == sim.recorder.enabled
    @test restored.recorder.every == sim.recorder.every
    @test restored.recorder.tick == sim.recorder.tick
    @test sort(collect(keys(restored.recorder.channels))) == sort(collect(keys(sim.recorder.channels)))

    for channel in keys(sim.recorder.channels)
        @test getchannel(restored.recorder, channel) == getchannel(sim.recorder, channel)
    end

    restored_from_file = replay(path)
    @test restored_from_file.metrics == sim.metrics
    @test getchannel(restored_from_file.recorder, :spikes) == getchannel(sim.recorder, :spikes)
end
