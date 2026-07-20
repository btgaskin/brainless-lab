using BrainlessLab
using Test

@testset "Scoring anchors" begin
    floor = null_anchor(2.0, "test null")
    ceiling = reference_anchor(6.0, "test reference")
    @test floor.value == 2.0
    @test floor.kind == NULL_MEASURED
    @test ceiling.kind == REFERENCE_MEASURED
    @test analytic(1.0; note="unit").provenance == "unit"

    task = TaskSpec(:anchor_test, WallEnv; floor=floor, ceiling=ceiling)
    @test score_floor(task) == 2.0
    @test score_ceiling(task) == 6.0
    @test task.score_floor == 2.0
    @test task.score_ceiling == 6.0
    @test normalized_score(task, 4.0) == 0.5
    @test normalized_score(task, -10.0) == 0.0
    @test normalized_score(task, 10.0) == 1.0

    bad = TaskSpec(:bad_anchor_test, WallEnv; floor=analytic(1.0), ceiling=analytic(1.0))
    @test_throws ArgumentError normalized_score(bad, 1.0)

    legacy = @test_logs (:warn, r"bare literal") TaskSpec(
        :legacy_anchor_test,
        WallEnv;
        score_floor=1.0,
        score_ceiling=3.0,
    )
    @test legacy.floor.kind == ANALYTIC
    @test legacy.ceiling.kind == ANALYTIC
    @test legacy.floor.provenance == "legacy literal (uncalibrated)"
    @test normalized_score(legacy, 2.0) == 0.5

    @test WALL_TASK.score_key == :nav_score
    @test :collisions_window in WALL_TASK.descriptor_keys
    @test :distance_window in WALL_TASK.descriptor_keys
end

@testset "Task outcomes follow declared objectives" begin
    for (task, key) in ((:wall, :nav_score), (:tracking, :track_score), (:pong, :hit_rate))
        sim = simulate(task; node=:null_random, ticks=12, seed=9, record=Symbol[])
        outcome = task_outcome(sim)
        @test outcome.key === key
        @test outcome.raw === Float64(getproperty(sim.metrics, key))
        @test outcome.normalized === normalized_score(resolve_task(task), outcome.raw)
    end

    wall = simulate(:wall; node=:null_random, ticks=12, seed=10, record=Symbol[])
    @test task_outcome(wall).raw === Float64(wall.metrics.nav_score)

    torus = simulate(
        :torus;
        node=:null_random,
        n_agents=3,
        n_nodes=8,
        ticks=8,
        seed=3,
        record=Symbol[],
    )
    @test task_outcome(torus) === nothing

    direct_scored = TaskSpec(
        :direct_scored,
        WALL_TASK.setup;
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
        TORUS_TASK.setup;
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
