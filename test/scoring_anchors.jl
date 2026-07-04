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
