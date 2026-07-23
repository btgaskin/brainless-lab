using BrainlessLab
using Test

function _plan_target(id, task; blocks=1, trials=2, horizon=20)
    composition = default_composition(DEFAULT_REGISTRY, :falandays, task)
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
        :falandays,
        :tracking;
        n_nodes=8,
        parameters=Dict(
            :input_weight => 0.75,
            :lrate_wmat => 1.0,
            :lrate_targ => 0.01,
            :weight_init_mode => :excitatory,
            :rectify => false,
            :repair_masks => false,
        ),
    )
    evaluation = EvaluationSpec(
        blocks=2,
        trials_per_block=2,
        horizon=4,
        construction_scope=:block,
        root_seed=91,
        aggregate=:none,
    )
    batch = evaluate(EvaluationTarget(:tracking, composition, evaluation))
    rows = trial_table(batch)
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
    @test_throws ArgumentError evaluate(unsupported)
end

@testset "Plank evaluation records explicit starts under one fixed design" begin
    composition = CompositionSpec(
        :plank_easy_smoke,
        :falandays,
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
    rows = trial_table(evaluate(EvaluationTarget(:plank_easy, composition, evaluation)))
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
    @test profile isa AbstractOperationPlan
    @test isempty(profile.analyses)
    @test profile.record_every == 2
    @test_throws ArgumentError ProfilePlan(:bad, tracking; record_every=0)

    axis = SweepAxis(:leak, (0.1, 0.25, 0.5))
    sweep = SweepPlan(:sweep_tracking, tracking; axes=(axis,), max_rollouts=100)
    @test sweep.mode === :factorial
    @test sweep.axes[1].values == (0.1, 0.25, 0.5)
    @test_throws ArgumentError SweepAxis(:leak, ())
    @test_throws ArgumentError SweepPlan(:bad, tracking; mode=:random)

    ablation = AblationPlan(
        :ablate_tracking,
        tracking;
        ablations=(:freeze_plasticity, :clamp_target),
    )
    @test ablation.ablations == (:freeze_plasticity, :clamp_target)

    evolution = EvolutionPlan(
        :evolve_tracking,
        tracking;
        heldout_targets=(pong,),
        generations=5,
        popsize=24,
    )
    @test evolution.parameter_set === :evolve
    @test evolution.heldout_targets == (pong,)
    @test_throws ArgumentError EvolutionPlan(:bad, tracking; popsize=1)

    tracking_case = BenchmarkCasePlan(
        :tracking,
        (tracking,);
        baseline=:tracking,
    )
    pong_case = BenchmarkCasePlan(:pong, (pong,); baseline=:pong)
    benchmark = BenchmarkPlan(:core, (tracking_case, pong_case))
    @test Tuple(case.id for case in benchmark.cases) == (:tracking, :pong)
    @test !hasproperty(benchmark, :aggregate)
    @test_throws ArgumentError BenchmarkCasePlan(
        :bad,
        (tracking,);
        baseline=:missing,
    )

    experiment = ExperimentSpec(
        :falandays_cross_task,
        v"1.0.0";
        title="Evolve one task, evaluate the other",
        question="How does task-specific parameter evolution move performance across the core benchmark?",
        conditions=(tracking, pong),
        operations=(evolution, benchmark),
        evidence_state=:exploratory,
        limitations=("Parameter evolution only; node structure is fixed.",),
    )
    @test experiment.version == v"1.0.0"
    @test experiment.evidence_state === :exploratory
    registry = ExperimentRegistry(:test_experiments)
    @test register_experiment!(registry, experiment) === experiment
    @test experiment_spec(
        :falandays_cross_task,
        v"1.0.0";
        experiments=registry,
    ) === experiment
    @test experiments(registry) == [(:falandays_cross_task, v"1.0.0")]
    @test_throws ArgumentError register_experiment!(registry, experiment)

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
