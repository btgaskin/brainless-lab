using BrainlessLab
using Test

@testset "Scoring calibration" begin
    wall = calibrate_task(
        :wall;
        reference=FalandaysParams(),
        reference_model=:falandays_base,
        seeds=0:7,
    )
    @test wall.floor.value ≈ WALL_TASK.floor.value atol=1e-12
    @test wall.ceiling.value ≈ WALL_TASK.ceiling.value atol=1e-12
    @test wall.floor.kind == NULL_MEASURED
    @test wall.ceiling.kind == REFERENCE_MEASURED
    @test wall.ceiling.value > wall.floor.value

    pong = calibrate_task(:pong; reference=FalandaysParams(), reference_model=:falandays_base, seeds=0:7)
    @test pong.floor.value ≈ PONG_TASK.floor.value atol=1e-12
    @test pong.ceiling.value ≈ PONG_TASK.ceiling.value atol=1e-12
    @test abs(pong.floor.value - 0.33) <= 0.15
    @test PONG_TASK.ceiling.kind == REFERENCE_MEASURED

    pong_hitrate = calibrate_task(:pong_hitrate; reference=FalandaysParams(), reference_model=:falandays_base, seeds=0:7)
    @test pong_hitrate.floor.value ≈ PONG_HITRATE_TASK.floor.value atol=1e-12
    @test pong_hitrate.ceiling.value ≈ PONG_HITRATE_TASK.ceiling.value atol=1e-12
    @test abs(pong_hitrate.floor.value - 0.30) <= 0.10

    forage = calibrate_task(:forage; seeds=0:7)
    @test forage.floor.value ≈ FORAGE_FLOOR_ANCHOR.value atol=1e-12
    @test abs(forage.floor.value - 0.5) <= 0.10
    @test forage.ceiling.kind == ANALYTIC

    a = simulate(:wall; node=:null_random, seed=3, ticks=16, window=16, record=:effectors)
    b = simulate(:wall; node=:null_random, seed=3, ticks=16, window=16, record=:effectors)
    @test getchannel(a.recorder, :effectors) == getchannel(b.recorder, :effectors)
    @test a.metrics.alive == false

    torus = simulate(:torus; node=:null_random, seed=2, ticks=20, n_agents=4, record=Symbol[])
    score, raw, key = @test_logs (:warn, r"descriptors") BrainlessLab._sim_score(torus)
    @test isnan(score)
    @test isnan(raw)
    @test key == "none"
end
