using Aqua

@testset "Package quality" begin
    Aqua.test_all(BrainlessLab)
    @test all(
        name -> isdefined(BrainlessLab, name),
        names(BrainlessLab; all=false, imported=false),
    )
end
