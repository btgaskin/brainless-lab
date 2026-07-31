using BrainlessLab
using Test

@testset "Falandays extended variant builds and runs" begin
    result = BrainlessLabTestUtils.diagnostic_simulate(:wall; node=:falandays_extended, ticks=20, seed=0)
    @test isfinite(result.metrics.score)
end
