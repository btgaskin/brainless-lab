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

