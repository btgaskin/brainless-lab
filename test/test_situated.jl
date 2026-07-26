using BrainlessLab
using Random
using Test

@testset "Arena geometry and situated input validation" begin
    torus = BrainlessLab.Torus(10.0)
    walled = BrainlessLab.WalledArena(10.0)
    @test BrainlessLab.arena_distance(torus, (0.2, 5.0), (9.8, 5.0)) ≈ 0.4
    @test BrainlessLab.arena_distance(walled, (0.2, 5.0), (9.8, 5.0)) ≈ 9.6
    @test BrainlessLab.arena_bounds(walled) == (0.0, 10.0, 0.0, 10.0)

    food = BrainlessLab.ObjectType(:food)
    @test_throws ArgumentError BrainlessLab.ObjectPopulation(food, [(NaN, 1.0)])
    @test_throws ArgumentError BrainlessLab.TorusEnvironment(
        torus,
        NTuple{2,Float64}[(Inf, 1.0)];
        config=BrainlessLab.SwarmConfig(n_agents=1, space_size=10.0),
        rng=MersenneTwister(1),
    )
end
