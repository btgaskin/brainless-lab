using BrainlessLab
using Test

function _test_calibrated_floor(measured, stored; runtime_tolerance)
    if VERSION == v"1.10.11"
        @test measured.value ≈ stored.value atol=1e-12
    else
        @test abs(measured.value - stored.value) <= runtime_tolerance
    end
    @test measured.kind == NULL_MEASURED
    @test isfinite(measured.value)
end

@testset "Scoring calibration" begin
    wall = calibrate_task(:wall; seeds=0:7)
    _test_calibrated_floor(wall.floor, WALL_TASK.floor; runtime_tolerance=0.10)
    @test wall.ceiling.value ≈ WALL_TASK.ceiling.value atol=1e-12
    @test wall.ceiling.kind == ANALYTIC
    @test wall.ceiling.value > wall.floor.value
    @test occursin("task=wall", wall.floor.provenance)
    @test occursin("rng=MersenneTwister", wall.floor.provenance)
    @test occursin("julia=$(VERSION)", wall.floor.provenance)

    pong = calibrate_task(:pong; seeds=0:7)
    _test_calibrated_floor(pong.floor, PONG_TASK.floor; runtime_tolerance=0.10)
    @test pong.ceiling.value ≈ PONG_TASK.ceiling.value atol=1e-12
    @test abs(pong.floor.value - 0.33) <= 0.15
    @test PONG_TASK.ceiling.kind == ANALYTIC

    pong_hitrate = calibrate_task(:pong_hitrate; seeds=0:7)
    _test_calibrated_floor(pong_hitrate.floor, PONG_HITRATE_TASK.floor; runtime_tolerance=0.10)
    @test pong_hitrate.ceiling.value ≈ PONG_HITRATE_TASK.ceiling.value atol=1e-12
    @test abs(pong_hitrate.floor.value - 0.30) <= 0.10
    @test PONG_HITRATE_TASK.ceiling.kind == ANALYTIC

    cartpole_swingup = calibrate_task(:cartpole_swingup; seeds=0:7)
    _test_calibrated_floor(
        cartpole_swingup.floor,
        CARTPOLE_SWINGUP_TASK.floor;
        runtime_tolerance=0.15,
    )
    @test cartpole_swingup.ceiling.value ≈ CARTPOLE_SWINGUP_TASK.ceiling.value atol=1e-12
    @test cartpole_swingup.ceiling.kind == ANALYTIC

    forage = calibrate_task(:forage; seeds=0:7)
    _test_calibrated_floor(forage.floor, FORAGE_FLOOR_ANCHOR; runtime_tolerance=0.10)
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
