using BrainlessLab
using Test

include("test_falandays.jl")
include("test_compartmental.jl")
include("test_ablation.jl")
include("test_envs.jl")
include("test_collective_single.jl")
include("test_collective_dyad.jl")
include("test_api.jl")
include("test_viz.jl")
include("test_examples.jl")

@testset "BrainlessLab scaffold" begin
    @test BrainlessLab isa Module

    @test NodeModel isa Type
    @test Reservoir isa Type
    @test Body isa Type
    @test Medium isa Type
    @test Driver isa Type
    @test Drive isa Type
    @test Intervention isa Type
    @test AbstractEvolutionStrategy isa Type

    struct _DummyNode <: NodeModel end
    register_node!(:dummy, _DummyNode)
    @test resolve_node(:dummy) === _DummyNode
    @test_throws KeyError resolve_node(:missing_node)

    rec = Recorder(enabled=[:state], every=2)
    record!(rec, :state, 1)
    tick!(rec)
    record!(rec, :state, 2)
    tick!(rec)
    record!(rec, :state, 3)
    tick!(rec)
    record!(rec, :state, 4)
    tick!(rec)
    record!(rec, :disabled, 5)

    @test getchannel(rec, :state) == Any[1, 3]
    @test isempty(getchannel(rec, :disabled))
    @test haskey(rec, :state)

    reset!(rec)
    @test isempty(getchannel(rec, :state))

    @test isfinite(softplus(1000.0))
    @test isfinite(softplus(-1000.0))
    @test softplus(0.0) ≈ log(2.0)
    @test 0.0 <= sigmoid(-1000.0) <= 1.0
    @test 0.0 <= sigmoid(1000.0) <= 1.0
    @test 0.0 < sigmoid(0.0) < 1.0
    @test sigmoid(0.0) ≈ 0.5
    @test mapped_tau(-1000.0) >= TAU_MIN
    @test isfinite(mapped_tau(1000.0))
end
