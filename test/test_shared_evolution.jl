using BrainlessLab, Test

@testset "versioned shared-design benchmark targets" begin
    spec = DIRECT_CONTROL_BENCHMARK_V2
    @test spec.version == v"2.0.0"
    @test DIRECT_CONTROL_BENCHMARK.version == v"1.0.0"
    @test length(spec.task_protocols) == 4
    @test length(benchmark_plan(spec).cases) == 4
    @test last(spec.task_protocols).confirmation.blocks == 512
    targets = benchmark_evolution_targets(spec, :compartmental_dense;
        root_seed=910_000, parameters=Dict(:substeps => 3))
    @test all(target -> target.composition.n_nodes == 200, targets)
    @test all(target -> target.composition.parameters == Dict(:substeps => 3), targets)
    @test all(target -> target.model === nothing, targets)
    @test getfield.(getfield.(targets, :composition), :task) == getfield.(spec.task_protocols, :task)
    run = BrainlessLab.Evolution.RunConfig(strategy=:nsga2, iterations=1,
        search_seed=100, measure=:benchmark_profile,
        initialisation=BrainlessLab.Evolution.NormalInitialisation(centre=:zero, scale=0.25),
        options=(population=4,))
    @test validate(EvolutionPlan(:shared_contract, targets; run), DEFAULT_REGISTRY) isa EvolutionPlan
    @test_throws BrainlessLab.EvolutionBudgetExceeded execute(
        resolve(EvolutionPlan(:bounded, targets; run), DEFAULT_REGISTRY); max_seconds=1e-12)
    scalar = BrainlessLab.Evolution.RunConfig(strategy=:sepcma, iterations=1, search_seed=101,
        initialisation=BrainlessLab.Evolution.NormalInitialisation(centre=:zero, scale=0.1),
        options=(population=2, reducer=:mean))
    duplicate = EvaluationTarget(:heldout_overlap, first(targets).composition, first(targets).evaluation)
    @test_throws ArgumentError validate(EvolutionPlan(:overlap, (first(targets),);
        run=scalar, heldout_targets=(duplicate,)), DEFAULT_REGISTRY)

    tiny = EvaluationTarget(:tiny_cue, CompositionSpec(:tiny_cue, :compartmental_dense, :delayed_cue;
        n_nodes=4), EvaluationSpec(horizon=144, root_seed=919_001))
    model = unpack_params(BrainlessLab.DenseCompartmental, zeros(404))
    batch = evaluate(tiny; model)
    trial = only(batch.trials)
    @test BrainlessLab._evolution_trial_value(trial, :benchmark_profile) == task_outcome(trial.simulation).raw
    compact = BrainlessLab._evaluate_evolution_target(tiny, model, :benchmark_profile, DEFAULT_REGISTRY)
    @test compact.batch === nothing
    @test !isempty(compact.trial_rows) && !isempty(compact.seed_rows)
    invalid = EvaluationTarget(:invalid_cue,
        CompositionSpec(:invalid_cue, :compartmental_dense, :delayed_cue;
            n_nodes=4, parameters=Dict(:dt => 1e308)), tiny.evaluation)
    failed = BrainlessLab._evaluate_evolution_target(invalid, model, :benchmark_profile, DEFAULT_REGISTRY)
    @test failed.failure === :nonfinite_dynamics
    @test ismissing(failed.aggregate)
    @test isempty(failed.trial_rows)
end
