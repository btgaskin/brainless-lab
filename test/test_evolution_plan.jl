using BrainlessLab
using Test

function _tiny_ctrnn_target(id; root_seed, aggregate=:mean)
    return EvaluationTarget(
        id,
        CompositionSpec(
            Symbol(id, :_composition),
            :compartmental_structured,
            :tracking;
            n_nodes=2,
        ),
        EvaluationSpec(
            blocks=1,
            trials_per_block=1,
            horizon=1,
            root_seed=root_seed,
            aggregate=aggregate,
        ),
    )
end

function _tiny_run(;
    strategy=:sepcma,
    iterations=1,
    options=(population=2, reducer=:mean,),
)
    return BrainlessLab.Evolution.RunConfig(
        strategy,
        iterations,
        101,
        :normalized_score,
        :maximise,
        BrainlessLab.Evolution.NormalInitialisation(centre=:zero, scale=0.1),
        options,
    )
end

@testset "typed node-design evolution plan" begin
    training = _tiny_ctrnn_target(:tracking_train; root_seed=101)
    heldout = _tiny_ctrnn_target(:tracking_heldout; root_seed=202)
    plan = EvolutionPlan(
        :tiny_ctrnn,
        (training,);
        run=_tiny_run(),
        heldout_targets=(heldout,),
    )

    @test validate(plan, DEFAULT_REGISTRY) === plan
    resolved = resolve(plan, DEFAULT_REGISTRY)
    @test resolved isa BrainlessLab.ResolvedEvolutionPlan
    @test resolved.node.id === :compartmental_structured
    @test resolved.design.dimension == 220
    @test resolved.strategy.key === :sepcma

    result = execute(resolved)
    @test result isa BrainlessLab.EvolutionResult
    @test length(result.candidates) == 2
    @test length(result.convergence) == 1
    @test all(candidate -> length(candidate.evaluations) == 1, result.candidates)
    @test only(result.models).model_id == "selected"
    @test only(result.models).model isa BrainlessLab.StructuredCompartmental
    @test only(result.heldout).target === :tracking_heldout
    @test !ismissing(only(result.heldout).aggregate)

    output = BrainlessLab.tables(result)
    @test length(output.convergence) == 1
    @test length(output.candidates) == 2
    @test length(output.candidate_scores) == 2
    @test length(output.candidate_trials) == 2
    @test length(output.models) == 1
    @test length(output.heldout_trials) == 1

    report = BrainlessLab.summary(result)
    @test report.plan === :tiny_ctrnn
    @test report.strategy === :sepcma
    @test report.models == ("selected",)
    @test only(report.heldout).target === :tracking_heldout
end

@testset "evolution validation keeps the experimental boundary explicit" begin
    training = _tiny_ctrnn_target(:tracking_train; root_seed=303)
    no_scalar = _tiny_ctrnn_target(
        :tracking_no_aggregate;
        root_seed=303,
        aggregate=:none,
    )
    @test_throws ArgumentError validate(
        EvolutionPlan(:no_scalar, (no_scalar,); run=_tiny_run()),
        DEFAULT_REGISTRY,
    )

    falandays = EvaluationTarget(
        :legacy_parameter_search,
        BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :tracking),
        EvaluationSpec(horizon=1, aggregate=:mean),
    )
    @test_throws ArgumentError validate(
        EvolutionPlan(:unsupported_node, (falandays,); run=_tiny_run()),
        DEFAULT_REGISTRY,
    )

    nsga = _tiny_run(
        strategy=:nsga2,
        options=(population=4,),
    )
    @test_throws ArgumentError validate(
        EvolutionPlan(:one_objective, (training,); run=nsga),
        DEFAULT_REGISTRY,
    )
    second = _tiny_ctrnn_target(:tracking_second; root_seed=404)
    @test_throws ArgumentError validate(
        EvolutionPlan(
            :pareto_with_heldout,
            (training, second);
            run=nsga,
            heldout_targets=(
                _tiny_ctrnn_target(:heldout; root_seed=505),
            ),
        ),
        DEFAULT_REGISTRY,
    )
end
