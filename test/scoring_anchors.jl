using BrainlessLab
using Test

@testset "Scoring anchors" begin
    floor = null_anchor(2.0, "test null")
    ceiling = reference_anchor(6.0, "test reference")
    @test floor.value == 2.0
    @test floor.kind == NULL_MEASURED
    @test floor.scored_ticks === nothing
    @test ceiling.kind == REFERENCE_MEASURED
    @test analytic(1.0; note="unit").provenance == "unit"

    task = TaskSpec(:anchor_test, BrainlessLab.WallEnv; floor=floor, ceiling=ceiling)
    @test BrainlessLab.score_floor(task) == 2.0
    @test BrainlessLab.score_ceiling(task) == 6.0
    @test task.score_floor == 2.0
    @test task.score_ceiling == 6.0
    @test normalized_score(task, 4.0) == 0.5
    @test normalized_score(task, -10.0) == 0.0
    @test normalized_score(task, 10.0) == 1.0
    @test BrainlessLab._normalized_anchor_result(-10.0, 2.0, 6.0, "test").bound === :floor
    @test BrainlessLab._normalized_anchor_result(4.0, 2.0, 6.0, "test").bound === :none
    @test BrainlessLab._normalized_anchor_result(10.0, 2.0, 6.0, "test").bound === :ceiling

    scoped_floor = null_anchor(2.0, "scoped null"; scored_ticks=200)
    scoped = TaskSpec(
        :scoped_anchor_test,
        BrainlessLab.WallEnv;
        floor=scoped_floor,
        ceiling=analytic(6.0),
    )
    @test scoped.floor.scored_ticks == 200
    @test normalized_score(scoped, 4.0; window=200) == 0.5
    @test_throws ArgumentError normalized_score(scoped, 4.0)
    @test_throws ArgumentError normalized_score(scoped, 4.0; window=1000)

    bad = TaskSpec(:bad_anchor_test, BrainlessLab.WallEnv; floor=analytic(1.0), ceiling=analytic(1.0))
    @test_throws ArgumentError normalized_score(bad, 1.0)

    legacy = @test_logs (:warn, r"bare literal") TaskSpec(
        :legacy_anchor_test,
        BrainlessLab.WallEnv;
        score_floor=1.0,
        score_ceiling=3.0,
    )
    @test legacy.floor.kind == ANALYTIC
    @test legacy.ceiling.kind == ANALYTIC
    @test legacy.floor.provenance == "legacy literal (uncalibrated)"
    @test normalized_score(legacy, 2.0) == 0.5
    second_legacy = @test_logs (:warn, r"bare literal") TaskSpec(
        :second_legacy_anchor_test,
        BrainlessLab.WallEnv;
        score_floor=2.0,
        score_ceiling=4.0,
    )
    @test normalized_score(second_legacy, 3.0) == 0.5

    @test BrainlessLab.WALL_TASK.score_key == :nav_score
    @test :collisions_window in BrainlessLab.WALL_TASK.descriptor_keys
    @test :distance_window in BrainlessLab.WALL_TASK.descriptor_keys
end

@testset "Task outcomes follow declared objectives" begin
    for (task, key) in ((:wall, :nav_score), (:tracking, :track_score), (:pong, :hit_rate))
        sim = simulate(task; node=:null_random, ticks=12, window=12, seed=9, record=Symbol[])
        outcome = task_outcome(sim)
        @test outcome.key === key
        @test outcome.raw === Float64(getproperty(sim.metrics, key))
        if task === :tracking
            @test outcome.normalized === normalized_score(resolve_task(task), outcome.raw)
            @test outcome.normalized_bound in (:floor, :none, :ceiling)
            @test outcome.normalization_status === :available
            @test outcome.anchor_scored_ticks === nothing
        else
            @test ismissing(outcome.normalized)
            @test ismissing(outcome.normalized_bound)
            @test outcome.normalization_status === :anchor_window_mismatch
            @test outcome.anchor_scored_ticks == (task === :wall ? 200 : 6000)
        end
    end

    wall = simulate(:wall; node=:null_random, ticks=12, window=12, seed=10, record=Symbol[])
    @test task_outcome(wall).raw === Float64(wall.metrics.nav_score)

    torus = simulate(
        :torus;
        node=:null_random,
        n_agents=3,
        n_nodes=8,
        ticks=8,
        window=8,
        seed=3,
        record=Symbol[],
    )
    @test task_outcome(torus) === nothing

    direct_scored = TaskSpec(
        :direct_scored,
        BrainlessLab.WALL_TASK.setup;
        default_ticks=4,
        default_window=4,
        floor=analytic(0.0),
        ceiling=analytic(1.0),
        score_key=:nav_score,
    )
    direct_scored_sim = simulate(
        direct_scored;
        node=:null_random,
        ticks=4,
        seed=2,
        record=Symbol[],
    )
    @test task_outcome(direct_scored_sim).key === :nav_score

    direct_unscored = TaskSpec(
        :direct_unscored,
        BrainlessLab.TORUS_TASK.setup;
        default_ticks=4,
        default_window=4,
        score_key=nothing,
    )
    direct_unscored_sim = simulate(
        direct_unscored;
        node=:null_random,
        n_agents=3,
        n_nodes=8,
        ticks=4,
        seed=2,
        record=Symbol[],
    )
    @test task_outcome(direct_unscored_sim) === nothing
end

@testset "Measured anchors apply only to their scored interval" begin
    @test BrainlessLab.WALL_TASK.floor.value == 0.8106249999999999
    @test BrainlessLab.WALL_TASK.floor.scored_ticks == 200
    @test BrainlessLab.PONG_TASK.floor.value == 0.23673837560386476
    @test BrainlessLab.PONG_TASK.floor.scored_ticks == 6000
    @test normalized_score(:pong, 0.5; window=6000) isa Float64
    @test_throws ArgumentError normalized_score(:pong, 0.5; window=7200)

    default_wall = simulate(
        :wall;
        node=:null_random,
        n_nodes=2,
        seed=81,
        record=(),
    )
    default_outcome = task_outcome(default_wall)
    @test default_outcome.window == 1000
    @test default_outcome.raw == default_wall.metrics.nav_score
    @test ismissing(default_outcome.normalized)
    @test default_outcome.normalization_status === :anchor_window_mismatch
    @test default_outcome.anchor_scored_ticks == 200

    matched_wall = simulate(
        :wall;
        node=:null_random,
        n_nodes=2,
        ticks=1000,
        window=200,
        seed=81,
        record=(),
    )
    matched_outcome = task_outcome(matched_wall)
    @test matched_outcome.window == 200
    @test matched_outcome.normalized isa Float64
    @test matched_outcome.normalization_status === :available

    composition = CompositionSpec(
        :typed_anchor_window_wall,
        :null_random,
        :wall;
        n_nodes=2,
    )
    mismatched_target = EvaluationTarget(
        :typed_mismatch,
        composition,
        EvaluationSpec(horizon=1000, root_seed=82),
    )
    mismatched_row = only(BrainlessLab.trial_table(evaluate(mismatched_target)))
    @test mismatched_row.window == 1000
    @test ismissing(mismatched_row.normalized_score)
    @test mismatched_row.normalization_status === :anchor_window_mismatch
    @test mismatched_row.anchor_scored_ticks == 200

    matched_target = EvaluationTarget(
        :typed_match,
        composition,
        EvaluationSpec(horizon=1000, warmup=800, root_seed=82),
    )
    matched_row = only(BrainlessLab.trial_table(evaluate(matched_target)))
    @test matched_row.window == 200
    @test matched_row.normalized_score isa Float64
    @test matched_row.normalization_status === :available
    @test matched_row.anchor_scored_ticks == 200
end
