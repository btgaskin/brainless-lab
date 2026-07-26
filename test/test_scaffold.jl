@testset "BrainlessLab scaffold" begin
    @test BrainlessLab isa Module

    @test NodeModel isa Type
    @test Reservoir isa Type
    @test AbstractBody isa Type
    @test BrainlessLab.Environment isa Type
    @test TaskWorld isa Type
    @test BrainlessLab.Runner isa Type
    @test BrainlessLab.Drive isa Type
    @test BrainlessLab.Intervention isa Type
    @test BrainlessLab.Evolution isa Module
    @test BrainlessLab.Evolution.RunConfig isa Type
    @test BrainlessLab.Evolution.search_strategies() == [:cmame, :nsga2, :sepcma]

    struct _DummyNode <: NodeModel end
    register_node!(:dummy, _DummyNode)
    @test resolve_node(:dummy) === _DummyNode
    duplicate_error = try
        register_node!(:dummy, _ -> nothing)
        nothing
    catch error
        error
    end
    @test duplicate_error isa ArgumentError
    @test occursin("node registry key :dummy is already registered", sprint(showerror, duplicate_error))
    @test resolve_node(:dummy) === _DummyNode
    @test_throws KeyError resolve_node(:missing_node)

    rec = Recorder(enabled=[:state], every=2)
    BrainlessLab.record!(rec, :state, 1)
    BrainlessLab.tick!(rec)
    BrainlessLab.record!(rec, :state, 2)
    BrainlessLab.tick!(rec)
    BrainlessLab.record!(rec, :state, 3)
    BrainlessLab.tick!(rec)
    BrainlessLab.record!(rec, :state, 4)
    BrainlessLab.tick!(rec)
    BrainlessLab.record!(rec, :disabled, 5)

    @test getchannel(rec, :state) == Any[1, 3]
    @test isempty(getchannel(rec, :disabled))
    @test haskey(rec, :state)

    reset!(rec)
    @test isempty(getchannel(rec, :state))

    @test isfinite(BrainlessLab.softplus(1000.0))
    @test isfinite(BrainlessLab.softplus(-1000.0))
    @test BrainlessLab.softplus(0.0) ≈ log(2.0)
    @test 0.0 <= BrainlessLab.sigmoid(-1000.0) <= 1.0
    @test 0.0 <= BrainlessLab.sigmoid(1000.0) <= 1.0
    @test 0.0 < BrainlessLab.sigmoid(0.0) < 1.0
    @test BrainlessLab.sigmoid(0.0) ≈ 0.5
    @test BrainlessLab.mapped_tau(-1000.0) >= BrainlessLab.TAU_MIN
    @test isfinite(BrainlessLab.mapped_tau(1000.0))

    # The oracle suite owns the corresponding build-and-run check.
    @test :falandays_extended in variants()
end
