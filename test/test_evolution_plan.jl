using BrainlessLab
using Test

isdefined(BrainlessLab, :EvolutionResult) || Base.include(
    BrainlessLab,
    joinpath(pkgdir(BrainlessLab), "src", "operations", "Evolution.jl"),
)

function _tiny_evolution_target(id, task; root_seed, blocks=1)
    base = default_composition(DEFAULT_REGISTRY, :falandays, task)
    composition = CompositionSpec(
        Symbol(id, :_composition),
        base.node,
        base.task;
        body=base.body,
        n_agents=base.n_agents,
        n_nodes=8,
        parameters=base.parameters,
        task_options=base.task_options,
        body_options=base.body_options,
        interaction_cycle=base.interaction_cycle,
    )
    evaluation = EvaluationSpec(
        blocks=blocks,
        trials_per_block=1,
        horizon=4,
        root_seed=root_seed,
        aggregate=:mean,
    )
    return EvaluationTarget(id, composition, evaluation)
end

@testset "typed evolution plan" begin
    training = _tiny_evolution_target(:tracking_train, :tracking; root_seed=101, blocks=2)
    heldout = _tiny_evolution_target(:pong_heldout, :pong; root_seed=202)
    plan = EvolutionPlan(
        :tiny_cross_task,
        training;
        heldout_targets=(heldout,),
        parameter_set=:evolve,
        generations=1,
        popsize=2,
        sigma0=0.1,
    )

    @test validate(plan, DEFAULT_REGISTRY) === plan
    resolved = resolve(plan, DEFAULT_REGISTRY)
    @test resolved isa BrainlessLab.ResolvedEvolutionPlan
    @test getfield.(resolved.parameters, :name) == (
        :leak,
        :lrate_wmat,
        :lrate_targ,
        :threshold_mult,
        :targ_min,
        :input_weight,
        :weight_init_std,
    )
    @test resolved.optimizer_seed != training.evaluation.root_seed

    result = execute(resolved)
    @test result isa BrainlessLab.EvolutionResult
    @test length(result.candidates) == 2
    @test length(result.candidate_batches) == 2
    @test length(result.convergence) == 1
    @test all(candidate -> length(candidate.objective_values) == 2, result.candidates)
    @test result.training.target === :tracking_train
    @test length(result.training.objective_values) == 2
    @test length(result.heldout) == 1
    @test result.heldout[1].target === :pong_heldout
    @test isfinite(result.training.aggregate)
    @test isfinite(result.heldout[1].aggregate)

    output_tables = tables(result)
    @test length(output_tables.convergence) == 1
    @test length(output_tables.candidates) == 2
    @test length(output_tables.candidate_trials) == 4
    @test length(output_tables.champion_parameters) == 7
    @test output_tables.champion_parameters[1].parameter === :leak
    @test length(output_tables.training_trials) == 2
    @test length(output_tables.heldout_trials) == 1
    @test output_tables.optimizer[1].optimizer_seed == result.optimizer_seed
    @test !hasproperty(output_tables.training_trials[1], :optimizer_seed)

    report = BrainlessLab.summary(result)
    @test report.plan === :tiny_cross_task
    @test report.training_target === :tracking_train
    @test report.heldout[1].target === :pong_heldout
    @test propertynames(report.champion_parameters) == (
        :input_weight,
        :leak,
        :lrate_targ,
        :lrate_wmat,
        :targ_min,
        :threshold_mult,
        :weight_init_std,
    )
end

@testset "evolution validation follows node metadata" begin
    training = _tiny_evolution_target(:tracking_train, :tracking; root_seed=303)
    missing_set = EvolutionPlan(
        :missing_set,
        training;
        parameter_set=:not_registered,
        generations=1,
        popsize=2,
    )
    @test_throws KeyError validate(missing_set, DEFAULT_REGISTRY)

    no_scalar = EvaluationTarget(
        :tracking_no_aggregate,
        training.composition,
        EvaluationSpec(horizon=4, root_seed=303, aggregate=:none),
    )
    invalid = EvolutionPlan(
        :no_scalar,
        no_scalar;
        parameter_set=:evolve,
        generations=1,
        popsize=2,
    )
    @test_throws ArgumentError validate(invalid, DEFAULT_REGISTRY)
end
