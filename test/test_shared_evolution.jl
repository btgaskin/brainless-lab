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
    @test occursin("\"decision\"", only(compact.trial_rows).task_diagnostics)
    @test occursin("\"tied\"", only(compact.trial_rows).task_diagnostics)
    invalid = EvaluationTarget(:invalid_cue,
        CompositionSpec(:invalid_cue, :compartmental_dense, :delayed_cue;
            n_nodes=4, parameters=Dict(:dt => 1e308)), tiny.evaluation)
    failed = BrainlessLab._evaluate_evolution_target(invalid, model, :benchmark_profile, DEFAULT_REGISTRY)
    @test failed.failure === :nonfinite_dynamics
    @test ismissing(failed.aggregate)
    @test isempty(failed.trial_rows)
end

@testset "saved models survive benchmark profile generation" begin
    mktempdir() do directory
      cd(directory) do
        node = :compartmental_structured
        design = BrainlessLab.node_spec(DEFAULT_REGISTRY, node).design
        model = unpack_params(BrainlessLab.StructuredCompartmental, zeros(220))
        reference = only(BrainlessLab.Evolution.write_models("saved-record", node, design,
            ((model_id="fixed", role="development", model=model),)))
        profile = ModelProfileSpec(:saved, node; n_nodes=4, parameters=Dict(),
            mechanism="Saved model test", model=reference)
        protocol = BenchmarkTaskProtocol(:delayed_cue;
            development=EvaluationSpec(horizon=144, root_seed=191),
            confirmation=EvaluationSpec(horizon=144, root_seed=192))
        spec = BenchmarkSpec(:saved_model, v"1.0"; title="Saved model contract", n_nodes=4,
            profiles=(profile,), task_protocols=(protocol,),
            entries=(BenchmarkEntrySpec(:saved, :delayed_cue; input_gain=1),),
            gain_grid=(1,), baseline_profile=:saved, state=:frozen)
        @test only(calibration_plans(spec)).target.model === reference
        target = only(only(benchmark_plan(spec).cases).conditions)
        @test target.model === reference
        @test task_outcome(only(evaluate(target).trials).simulation) !== nothing
      end
    end
end

@testset "failed candidate journals retain integrity and can restore" begin
    mktempdir() do directory
        composition = CompositionSpec(:unstable, :compartmental_dense, :delayed_cue;
            n_nodes=4, parameters=Dict(:dt => 1e308))
        targets = Tuple(EvaluationTarget(id, composition, EvaluationSpec(horizon=144, root_seed=919))
            for id in (:first, :second))
        run = BrainlessLab.Evolution.RunConfig(strategy=:nsga2, iterations=2, search_seed=200,
            measure=:benchmark_profile,
            initialisation=BrainlessLab.Evolution.NormalInitialisation(centre=:zero, scale=0.25),
            options=(population=4,))
        plan = EvolutionPlan(:failed_journal, targets; run)
        resolved = resolve(plan, DEFAULT_REGISTRY)
        git = BrainlessLab._record_git()
        callback = BrainlessLab._evolution_checkpoint_callback(directory,
            BrainlessLab._evolution_operation_digests(plan, resolved, git), :nsga2, plan, git)
        @test_throws ErrorException execute(resolved;
            checkpoint=(iteration, state, candidates) -> begin
                callback(iteration, state, candidates)
                error("intentional stop after a complete generation")
            end)
        restored = BrainlessLab._restore_evolution_candidates(directory, plan, 1, 4, 404)
        @test length(restored) == 4
        @test all(candidate -> !candidate.valid, restored)
        @test all(evaluation -> evaluation.failure === :nonfinite_dynamics,
            [evaluation for candidate in restored for evaluation in candidate.evaluations])
        path = joinpath(directory, "generation-data", "00000001", "data", "candidate_scores.csv")
        open(path, "a") do io
            write(io, "corrupted\n")
        end
        @test_throws ArgumentError BrainlessLab._restore_evolution_candidates(directory, plan, 1, 4, 404)
    end
end
