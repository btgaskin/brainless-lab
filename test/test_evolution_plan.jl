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

    falandays_spec = BrainlessLab.node_spec(DEFAULT_REGISTRY, :falandays)
    @test falandays_spec.design isa BrainlessLab.Evolution.NodeDesignSpec
    @test falandays_spec.design.dimension == 7
    @test getfield.(falandays_spec.design.blocks, :name) == (
        :leak,
        :lrate_wmat,
        :lrate_targ,
        :threshold_mult,
        :targ_min,
        :input_weight,
        :weight_init_std,
    )
    falandays_model = FalandaysParams()
    falandays_coordinates =
        BrainlessLab.Evolution.encode(falandays_spec.design, falandays_model)
    falandays_roundtrip =
        BrainlessLab.Evolution.decode(falandays_spec.design, falandays_coordinates)
    @test pack_params(falandays_roundtrip) ≈ falandays_coordinates
    @test falandays_roundtrip.learn_on

    falandays = EvaluationTarget(
        :falandays_parameter_search,
        BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :tracking),
        EvaluationSpec(horizon=1, aggregate=:mean),
    )
    falandays_plan =
        EvolutionPlan(:falandays_node, (falandays,); run=_tiny_run())
    @test validate(falandays_plan, DEFAULT_REGISTRY) === falandays_plan
    @test resolve(falandays_plan, DEFAULT_REGISTRY).node.id === :falandays
    @test length(BrainlessLab.evaluate(falandays).trials) == 1
    @test length(
        BrainlessLab.evaluate(falandays; model=falandays_roundtrip).trials,
    ) == 1

    no_design = EvaluationTarget(
        :sorn_parameter_search,
        CompositionSpec(
            :sorn_tracking,
            :sorn,
            :tracking;
            n_nodes=8,
        ),
        EvaluationSpec(horizon=1, aggregate=:mean),
    )
    no_design_error = try
        validate(
            EvolutionPlan(:unsupported_node, (no_design,); run=_tiny_run()),
            DEFAULT_REGISTRY,
        )
        nothing
    catch error
        error
    end
    @test no_design_error isa ArgumentError
    @test occursin(
        "node :sorn declares no experimental NodeDesignSpec",
        sprint(showerror, no_design_error),
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
