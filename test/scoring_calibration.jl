using BrainlessLab
using Test

function _test_calibrated_floor(measured)
    @test measured.kind == NULL_MEASURED
    @test isfinite(measured.value)
end

# Each call pins ticks/window to the scored interval its shipped anchor was
# measured over, which is also the interval the v2 core protocol runs:
# wall 1000-800 = 200, pong 7200-1200 = 6000. Rate matching measures the
# reference firing rate over the scoring window, so calibrating at a different
# window measures a different anchor -- leaving these to `default_ticks` is how
# the harness silently stopped reproducing its own recorded floors.
@testset "Scoring calibration" begin
    wall = BrainlessLab.calibrate_task(:wall; seeds=0:7, ticks=1000, window=200)
    _test_calibrated_floor(wall.floor)
    @test wall.ceiling.value ≈ BrainlessLab.WALL_TASK.ceiling.value atol=1e-12
    @test wall.ceiling.kind == ANALYTIC
    @test wall.ceiling.value > wall.floor.value
    @test occursin("task=wall", wall.floor.provenance)
    @test occursin("rate_reference=falandays", wall.floor.provenance)
    @test occursin("null_target_rate=", wall.floor.provenance)
    @test occursin("rng=MersenneTwister", wall.floor.provenance)
    @test occursin("julia=$(VERSION)", wall.floor.provenance)

    tracking = BrainlessLab.calibrate_task(:tracking; seeds=0:7)
    _test_calibrated_floor(tracking.floor)
    # Tracking's shipped floor is analytic 0.0 (E[cos] = 0 by symmetry), so the
    # measured rate-matched null must be consistent with zero, not sit in some
    # positive band. Five disjoint 8-seed blocks at the default 2000 scored ticks
    # give mean 0.00215, sd 0.0167, range [-0.0224, 0.0225]; 0.1 is ~6 sd, loose
    # enough not to flake and tight enough to catch a null that stops being one.
    # The former 0.05 < x < 0.35 band encoded the noise of the old 200-tick
    # window, where the same measurement was 0.0599 +/- 0.0691.
    @test abs(tracking.floor.value) < 0.1
    @test tracking.ceiling.value == BrainlessLab.TRACKING_TASK.ceiling.value

    pong = BrainlessLab.calibrate_task(:pong; seeds=0:7, ticks=7200, window=6000)
    _test_calibrated_floor(pong.floor)
    @test pong.ceiling.value ≈ BrainlessLab.PONG_TASK.ceiling.value atol=1e-12
    @test BrainlessLab.PONG_TASK.ceiling.kind == ANALYTIC

    pong_hitrate = BrainlessLab.calibrate_task(:pong_hitrate; seeds=0:7)
    _test_calibrated_floor(pong_hitrate.floor)
    @test pong_hitrate.ceiling.value ≈ BrainlessLab.PONG_HITRATE_TASK.ceiling.value atol=1e-12
    @test BrainlessLab.PONG_HITRATE_TASK.ceiling.kind == ANALYTIC

    cartpole_swingup = BrainlessLab.calibrate_task(:cartpole_swingup; seeds=0:7)
    _test_calibrated_floor(cartpole_swingup.floor)
    @test cartpole_swingup.ceiling.value ≈ BrainlessLab.CARTPOLE_SWINGUP_TASK.ceiling.value atol=1e-12
    @test cartpole_swingup.ceiling.kind == ANALYTIC

    forage = BrainlessLab.calibrate_task(:forage; seeds=0:7)
    _test_calibrated_floor(forage.floor)
    @test forage.ceiling.kind == ANALYTIC

    a = simulate(:wall; node=:null_random, seed=3, ticks=16, window=16, record=:effectors)
    b = simulate(:wall; node=:null_random, seed=3, ticks=16, window=16, record=:effectors)
    @test getchannel(a.recorder, :effectors) == getchannel(b.recorder, :effectors)

    # A descriptor-only task declares no scalar objective, so it has no outcome.
    # This is the public contract; the former `_sim_score` wrapper that turned it
    # into a NaN CSV row was removed with the legacy sweep layer.
    torus = simulate(:torus; node=:null_random, seed=2, ticks=20, window=20, n_agents=4, record=Symbol[])
    @test task_outcome(torus) === nothing
end

@testset "Rate-matched null reservoir" begin
    reference_rate = 0.035
    reservoir = BrainlessLab.NullRandomReservoir(200, 2, 2; target_rate=reference_rate, seed=91)
    spikes = Float64[]
    outputs = Float64[]
    for _ in 1:200
        step_spikes = step!(reservoir, zeros(2))
        append!(spikes, step_spikes)
        append!(outputs, effectors(reservoir, step_spikes))
    end
    @test any(==(1.0), spikes)
    @test abs(sum(spikes) / length(spikes) - reference_rate) <= 0.005
    @test abs(sum(outputs) / length(outputs) - reference_rate) <= 0.005

    blind_a = BrainlessLab.NullRandomReservoir(40, 2, 2; seed=17)
    blind_b = BrainlessLab.NullRandomReservoir(40, 2, 2; seed=17)
    @test blind_a.target_rate == reference_rate
    for _ in 1:20
        spikes_a = step!(blind_a, zeros(2))
        spikes_b = step!(blind_b, fill(100.0, 2))
        @test spikes_a == spikes_b
        @test effectors(blind_a, spikes_a) == effectors(blind_b, spikes_b)
    end

    replay_source = BrainlessLab.NullRandomReservoir(40, 2, 2; target_rate=0.08, seed=29)
    for _ in 1:12
        step!(replay_source, zeros(2))
    end
    state = snapshot_state(replay_source)
    replay_target = BrainlessLab.NullRandomReservoir(40, 2, 2; target_rate=0.5, seed=999)
    load_state!(replay_target, state)
    @test replay_target.target_rate == 0.08
    for _ in 1:20
        source_spikes = step!(replay_source, zeros(2))
        target_spikes = step!(replay_target, ones(2))
        @test source_spikes == target_spikes
        @test effectors(replay_source, source_spikes) ==
              effectors(replay_target, target_spikes)
    end

    @test_throws ArgumentError BrainlessLab.NullRandomReservoir(20, 2, 2; target_rate=-0.01)
    @test_throws ArgumentError BrainlessLab.NullRandomReservoir(20, 2, 2; target_rate=1.01)
end

@testset "Calibration injects the task-window rate" begin
    seed = 19
    ticks = 24
    window = 7
    n_nodes = 20
    canonical = simulate(
        :tracking;
        node=:falandays,
        seed=seed,
        ticks=ticks,
        window=window,
        N=n_nodes,
        record=(:rate,),
    )
    rate_samples = getchannel(canonical.recorder, :rate)
    matched_rate = sum(
        Float64(rate)
        for frame in rate_samples[(end - window + 1):end]
        for rate in frame
    ) / window

    calibrated = BrainlessLab.calibrate_task(
        :tracking;
        seeds=seed:seed,
        ticks=ticks,
        window=window,
        N=n_nodes,
    )
    explicit_null = simulate(
        :tracking;
        node=:null_random,
        seed=seed,
        ticks=ticks,
        window=window,
        N=n_nodes,
        record=Symbol[],
        node_kwargs=(target_rate=matched_rate,),
    )

    @test calibrated.floor.value == explicit_null.metrics.track_score
    @test occursin("null_target_rate=$(matched_rate)", calibrated.floor.provenance)
end

@testset "Calibration diagnostics stay visible" begin
    diagnostic_task = TaskSpec(
        :diagnostic_reference,
        BrainlessLab.WallEnv;
        floor=null_anchor(0.5, "fresh null"),
        ceiling=reference_anchor(0.8, "stored reference"),
    )
    error = try
        BrainlessLab._reference_ceiling_with_fallback(
            diagnostic_task,
            reference_anchor(0.4, "fresh reference"),
            diagnostic_task.floor,
        )
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test occursin("does not exceed the measured null floor", sprint(showerror, error))
    @test occursin("stored ceiling 0.8 was not retained", sprint(showerror, error))

    report = IOBuffer()
    BrainlessLab.write_calibration_report(
        report;
        seeds=0:0,
        ticks=1,
        window=1,
        N=8,
        n_agents=2,
    )
    @test occursin("\ntracking\n", "\n" * String(take!(report)))
end
