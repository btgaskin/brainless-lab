using BrainlessLab
using Test

module ExternalTemplateNode
include(joinpath(@__DIR__, "..", "examples", "templates", "new_project", "my_node.jl"))
end

@testset "copy-ready reservoir supports inactive stable slots" begin
    reservoir = ExternalTemplateNode.MyNode(7, 1, 1; seed=4)
    body = _DyingBody(true)
    ensemble = Ensemble([Agent(reservoir, body)], _MetriclessEnvironment())

    first = step!(ensemble)
    @test length(only(first)) == 7
    @test !alive(body)

    second = step!(ensemble)
    @test only(second) == zeros(7)
    @test ExternalTemplateNode.n_nodes(reservoir) == 7
end
