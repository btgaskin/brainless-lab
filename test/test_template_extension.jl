using BrainlessLab
using Test

module ExternalTemplateNode
include(joinpath(@__DIR__, "..", "examples", "templates", "new_project", "my_node.jl"))
include(joinpath(@__DIR__, "..", "examples", "templates", "new_project", "my_task.jl"))
end

@testset "copy-ready model coordinates use bounded bijections" begin
    params = ExternalTemplateNode.MyNodeParams(learn_on=false)
    raw = ExternalTemplateNode.pack_params(params)
    restored = ExternalTemplateNode.unpack_params(params, raw)

    @test ExternalTemplateNode.pack_params(restored) ≈ raw
    @test !restored.learn_on
    @test !haskey(ExternalTemplateNode.MY_NODE_SPEC.parameter_sets, :evolve)

    model = ExternalTemplateNode.MyNodeParams(leak=0.5, input_gain=2.0)
    context = NodeBuildContext(
        7,
        BrainlessLab.PortSpec(2, 2),
        (topology=UInt64(4),);
        model=model,
    )
    values = BrainlessLab.resolve_parameters(ExternalTemplateNode.MY_NODE_SPEC)
    reservoir = ExternalTemplateNode.build_my_node(context, values)
    @test reservoir.params == model

    sim = BrainlessLabTestUtils.diagnostic_simulate(
        CompositionSpec(
            :template_model_smoke,
            :my_node,
            :my_task;
            n_nodes=7,
        );
        model=model,
        ticks=12,
        seed=4,
        record=Symbol[],
    )
    outcome = task_outcome(sim)
    @test sim.node === :my_node
    @test outcome.key === :score
    @test isfinite(outcome.normalized)
end

@testset "copy-ready reservoir supports inactive stable slots" begin
    reservoir = ExternalTemplateNode.MyNode(7, 1, 1; seed=4)
    body = _DyingBody(true)
    ensemble = BrainlessLab.Ensemble([BrainlessLab.Agent(reservoir, body)], _MetriclessEnvironment())

    first = step!(ensemble)
    @test length(only(first)) == 7
    @test !BrainlessLab.alive(body)

    second = step!(ensemble)
    @test only(second) == zeros(7)
    @test ExternalTemplateNode.n_nodes(reservoir) == 7
end
