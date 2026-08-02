using BrainlessLab
using Test

function _plan_target(id, task; blocks=1, trials=2, horizon=20)
    composition = BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, task)
    evaluation = EvaluationSpec(
        blocks=blocks,
        trials_per_block=trials,
        horizon=horizon,
        root_seed=17,
    )
    return EvaluationTarget(id, composition, evaluation)
end

@testset "evaluation blocks retain raw trials and named seeds" begin
    composition = CompositionSpec(
        :tracking_evaluation_smoke,
        :null_random,
        :tracking;
        n_nodes=8,
    )
    evaluation = EvaluationSpec(
        blocks=2,
        trials_per_block=2,
        horizon=4,
        construction_scope=:block,
        root_seed=91,
        aggregate=:none,
    )
    registry = RegistrySet()
    register!(registry, node_spec(DEFAULT_REGISTRY, :null_random))
    register!(
        registry,
        BrainlessLabTestUtils.task_with_minimum(:tracking, 1),
    )
    batch = BrainlessLab.evaluate(
        EvaluationTarget(:tracking, composition, evaluation);
        registry,
    )
    rows = BrainlessLab.trial_table(batch)
    @test length(batch.trials) == 4
    @test length(rows) == 4
    @test rows[1].topology_seed == rows[2].topology_seed
    @test rows[1].topology_seed != rows[3].topology_seed
    @test rows[1].world_seed != rows[2].world_seed
    @test all(row -> row.score_key === :track_score, rows)
    @test all(row -> isfinite(row.raw_score), rows)

    unsupported = EvaluationTarget(
        :unsupported_reset,
        composition,
        EvaluationSpec(horizon=4, reset=:body_environment),
    )
    @test_throws ArgumentError BrainlessLab.evaluate(unsupported; registry)
end

@testset "typed evaluations reject starved scoring intervals" begin
    composition = CompositionSpec(
        :starved_pong,
        :null_random,
        :pong;
        n_nodes=2,
    )
    target = EvaluationTarget(
        :starved_pong,
        composition,
        EvaluationSpec(horizon=300, root_seed=12),
    )
    error = try
        BrainlessLab.evaluate(target)
        nothing
    catch caught
        caught
    end
    message = error === nothing ? "" : sprint(showerror, error)
    @test error isa ArgumentError
    @test occursin("task :pong", message)
    @test occursin("300", message)
    @test occursin("6000", message)
end

@testset "operation plans reject starved scored targets during validation" begin
    tracking = EvaluationTarget(
        :starved_tracking,
        BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :tracking),
        EvaluationSpec(horizon=120, warmup=20, root_seed=12),
    )
    plans = (
        ProfilePlan(:starved_profile, tracking; analyses=(:heading_error,)),
        SweepPlan(
            :starved_sweep,
            tracking;
            axes=(BrainlessLab.SweepAxis(:leak, (0.25, 0.5)),),
        ),
        AblationPlan(
            :starved_ablation,
            tracking;
            ablations=(:freeze_plasticity,),
        ),
        BenchmarkPlan(
            :starved_benchmark,
            (BrainlessLab.BenchmarkCasePlan(:tracking, (tracking,)),),
        ),
    )

    for plan in plans, operation in (validate, resolve)
        error = try
            operation(plan, DEFAULT_REGISTRY)
            nothing
        catch caught
            caught
        end
        message = error === nothing ? "" : sprint(showerror, error)
        @test error isa ArgumentError
        @test occursin("task :tracking", message)
        @test occursin("100", message)
        @test occursin("2000", message)
    end
end

@testset "evolution plans reject starved scored targets during validation" begin
    # validate(::EvolutionPlan) lives in src/operations/Evolution.jl rather than
    # alongside the other operation validators, so it was the one path where a
    # starved plan still validated and failed minutes into a run.
    starved = EvaluationTarget(
        :starved_evolution,
        BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :tracking),
        EvaluationSpec(horizon=120, warmup=20, root_seed=12),
    )
    plan = EvolutionPlan(
        :starved_evolution_plan,
        (starved,);
        run=BrainlessLab.Evolution.RunConfig(
            :sepcma,
            1,
            101,
            :normalized_score,
            :maximise,
            BrainlessLab.Evolution.NormalInitialisation(centre=:zero, scale=0.1),
            (population=2, reducer=:mean),
        ),
    )

    for operation in (validate, resolve)
        error = try
            operation(plan, DEFAULT_REGISTRY)
            nothing
        catch caught
            caught
        end
        message = error === nothing ? "" : sprint(showerror, error)
        @test error isa ArgumentError
        @test occursin("task :tracking", message)
        @test occursin("100", message)
        @test occursin("2000", message)
    end
end

@testset "unscored tasks do not use an objective scoring minimum" begin
    task = BrainlessLab.task_spec(DEFAULT_REGISTRY, :torus)
    @test task.score_key === nothing
    @test task.minimum_scored_ticks > 2

    target = EvaluationTarget(
        :short_torus_profile,
        CompositionSpec(
            :short_torus_profile,
            :null_random,
            :torus;
            n_nodes=4,
        ),
        EvaluationSpec(horizon=2, root_seed=19),
    )
    plan = ProfilePlan(:short_torus_profile, target; analyses=())
    @test validate(plan, DEFAULT_REGISTRY) === plan
    resolved = resolve(plan, DEFAULT_REGISTRY)
    @test resolved isa BrainlessLab.ResolvedProfilePlan
    result = execute(resolved)
    @test result.batch.resolved.task.score_key === nothing
    @test all(ismissing(row.raw_score) for row in result.task_rows)
end

@testset "Plank evaluation records explicit starts under one fixed design" begin
    composition = CompositionSpec(
        :plank_easy_smoke,
        :null_random,
        :cartpole_plank_easy;
        n_nodes=8,
    )
    evaluation = EvaluationSpec(
        blocks=1,
        trials_per_block=2,
        horizon=2,
        construction_scope=:evaluation,
        root_seed=101,
        aggregate=:mean,
    )
    registry = RegistrySet()
    register!(registry, node_spec(DEFAULT_REGISTRY, :null_random))
    register!(
        registry,
        BrainlessLabTestUtils.task_with_minimum(:cartpole_plank_easy, 1),
    )
    rows = BrainlessLab.trial_table(BrainlessLab.evaluate(
        EvaluationTarget(:plank_easy, composition, evaluation);
        registry,
    ))
    @test length(rows) == 2
    @test rows[1].topology_seed == rows[2].topology_seed
    @test rows[1].initial_state isa NTuple{4,Float64}
    @test rows[1].initial_state != rows[2].initial_state
    @test rows[1].score_key === :fitness
end

@testset "one operation-plan schema" begin
    tracking = _plan_target(:tracking, :tracking)
    pong = _plan_target(:pong, :pong)

    profile = ProfilePlan(:profile_tracking, tracking; record_every=2)
    @test profile isa BrainlessLab.AbstractOperationPlan
    @test isempty(profile.analyses)
    @test profile.record_every == 2
    @test_throws ArgumentError ProfilePlan(:bad, tracking; record_every=0)

    axis = BrainlessLab.SweepAxis(:leak, (0.1, 0.25, 0.5))
    sweep = SweepPlan(:sweep_tracking, tracking; axes=(axis,), max_rollouts=100)
    @test sweep.mode === :factorial
    @test sweep.axes[1].values == (0.1, 0.25, 0.5)
    @test_throws ArgumentError BrainlessLab.SweepAxis(:leak, ())
    @test_throws ArgumentError SweepPlan(:bad, tracking; mode=:random)

    ablation = AblationPlan(
        :ablate_tracking,
        tracking;
        ablations=(:freeze_plasticity, :clamp_target),
    )
    @test ablation.ablations == (:freeze_plasticity, :clamp_target)

    ctrnn_composition = CompositionSpec(
        :structured_ctrnn_tracking,
        :compartmental_structured,
        :tracking;
        n_nodes=2,
    )
    ctrnn_training = EvaluationTarget(
        :ctrnn_tracking,
        ctrnn_composition,
        EvaluationSpec(horizon=1, aggregate=:mean),
    )
    ctrnn_heldout = EvaluationTarget(
        :ctrnn_tracking_heldout,
        ctrnn_composition,
        EvaluationSpec(horizon=1, root_seed=18, aggregate=:mean),
    )
    run = BrainlessLab.Evolution.RunConfig(
        strategy=:sepcma,
        iterations=5,
        search_seed=17,
        initialisation=BrainlessLab.Evolution.NormalInitialisation(
            centre=:zero,
            scale=0.1,
        ),
        options=(population=4, reducer=:mean,),
    )
    evolution = EvolutionPlan(
        :evolve_tracking,
        (ctrnn_training,);
        run,
        heldout_targets=(ctrnn_heldout,),
    )
    @test evolution.run.strategy === :sepcma
    @test evolution.heldout_targets == (ctrnn_heldout,)
    @test_throws ArgumentError EvolutionPlan(
        :bad,
        ();
        run,
    )

    tracking_case = BrainlessLab.BenchmarkCasePlan(
        :tracking,
        (tracking,);
        baseline=:tracking,
    )
    pong_case = BrainlessLab.BenchmarkCasePlan(:pong, (pong,); baseline=:pong)
    benchmark = BenchmarkPlan(:core, (tracking_case, pong_case))
    @test Tuple(case.id for case in benchmark.cases) == (:tracking, :pong)
    @test !hasproperty(benchmark, :aggregate)
    @test_throws ArgumentError BrainlessLab.BenchmarkCasePlan(
        :bad,
        (tracking,);
        baseline=:missing,
    )

    experiment = ExperimentSpec(
        :falandays_cross_task,
        v"1.0.0";
        title="Evolve one task, evaluate the other",
        question="How does task-specific parameter evolution move performance across the core benchmark?",
        conditions=(ctrnn_training, ctrnn_heldout, tracking, pong),
        operations=(evolution, benchmark),
        evidence_state=:exploratory,
        limitations=("Parameter evolution only; node structure is fixed.",),
    )
    @test experiment.version == v"1.0.0"
    @test experiment.evidence_state === :exploratory
    registry = BrainlessLab.ExperimentRegistry(:test_experiments)
    validation_registry = BrainlessLabTestUtils.diagnostic_registry((:tracking, :pong))
    @test BrainlessLab.register_experiment!(
        registry,
        experiment;
        registry=validation_registry,
    ) === experiment
    @test BrainlessLab.experiment_spec(
        :falandays_cross_task,
        v"1.0.0";
        experiments=registry,
    ) === experiment
    @test BrainlessLab.experiments(registry) == [(:falandays_cross_task, v"1.0.0")]
    @test_throws ArgumentError BrainlessLab.register_experiment!(registry, experiment)

    copied_tracking = EvaluationTarget(
        tracking.id,
        CompositionSpec(
            :changed_tracking,
            tracking.composition.node,
            tracking.composition.task;
            n_nodes=tracking.composition.n_nodes + 1,
            parameters=tracking.composition.parameters,
        ),
        tracking.evaluation,
    )
    inconsistent = ExperimentSpec(
        :inconsistent,
        v"1.0.0";
        title="Inconsistent condition references",
        question="Does validation reject copied condition objects?",
        conditions=(tracking, pong),
        operations=(ProfilePlan(:copied, copied_tracking),),
    )
    @test_throws ArgumentError validate(inconsistent, DEFAULT_REGISTRY)
    @test_throws ArgumentError ExperimentSpec(
        :bad,
        v"1.0.0";
        title="Bad",
        question="Bad?",
        conditions=(tracking,),
        operations=(evolution,),
        evidence_state=:certain,
    )
end
