using BrainlessLab
using Random
using Test

@testset "Own-colour decodability analysis" begin
    sim = simulate(
        :torus;
        node=:falandays,
        n_agents=8,
        n_nodes=24,
        ticks=24,
        seed=7,
        space_size=24.0,
        vision_range=16.0,
        n_colours=2,
        colour_sensing=true,
        record=(:spikes, :acts, :poses),
    )

    res = @test_logs (:warn, r"underpowered") own_colour_decodability(
        sim;
        n_perm=32,
        rng=MersenneTwister(12),
    )

    @test res isa NamedTuple
    @test res.n_agents == 8
    @test res.n_colours == 2
    @test res.channel == :acts
    @test res.chance ≈ 0.5
    @test res.shuffle_floor ≈ res.chance atol=0.4
    @test res.underpowered == true
    @test length(res.per_fold) == 8
    @test length(res.per_class_accuracy) == 2
    @test 0.0 <= res.accuracy <= 1.0
    @test 0.0 <= res.shuffle_floor <= 1.0
    @test 0.0 <= res.p_value <= 1.0

    spike_only = simulate(
        :torus;
        node=:falandays,
        n_agents=8,
        n_nodes=16,
        ticks=12,
        seed=8,
        n_colours=2,
        colour_sensing=true,
        record=(:spikes, :poses),
    )
    fallback = @test_logs (:warn, r"underpowered") own_colour_decodability(
        spike_only;
        n_perm=8,
        rng=MersenneTwister(13),
    )
    @test fallback.channel == :spikes

    one_colour = simulate(
        :torus;
        node=:falandays,
        n_agents=4,
        n_nodes=12,
        ticks=8,
        seed=9,
        n_colours=1,
        colour_sensing=false,
        record=(:spikes, :poses),
    )
    @test_throws ArgumentError own_colour_decodability(one_colour; n_perm=2)

    rate_only = simulate(
        :torus;
        node=:falandays,
        n_agents=4,
        n_nodes=12,
        ticks=8,
        seed=10,
        n_colours=2,
        colour_sensing=true,
        record=(:rate,),
    )
    @test_throws ArgumentError own_colour_decodability(rate_only; n_perm=2)
    @test_throws ArgumentError own_colour_decodability(sim; channel=:rate, n_perm=2)

    @test :own_colour_decodability in task_analyses(:torus)
    @test resolve_analysis(:own_colour_decodability) === own_colour_decodability
end
