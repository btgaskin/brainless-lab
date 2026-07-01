using BrainlessLab
using Random
using StaticArrays
using Test

@testset "Spatial Falandays connectome" begin
    @test connection_prob(ExpKernel(0.5, 0.3), 0.0) >
          connection_prob(ExpKernel(0.5, 0.3), 1.0)

    r = resolve_node(:falandays_spatial)(24, 3, 2; seed=7)
    @test spatiality(r.connectome) == Embedded{2}()
    @test typeof(r) <: FalandaysReservoir
    @test all(!r.recurrent_mask[i, i] for i in axes(r.recurrent_mask, 1))
    @test count(r.recurrent_mask) > 0

    sim = simulate(:wall; node=:falandays_spatial, ticks=50, seed=1)
    @test isfinite(Float64(sim.metrics.score))

    space = MetricSpace(SVector(0.0, 0.0), SVector(1.0, 1.0))
    rule = SpatialRule(space, ExpKernel(0.5, 0.3), 0.1, 1.0)
    c1 = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11))
    c2 = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11))
    @test c1.recurrent_mask == c2.recurrent_mask
end
