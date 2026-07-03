using BrainlessLab
using Random
using Test

@testset "Branching ratio analysis" begin
    steady = BrainlessLab._branching_from_rates([1.0, 1.0, 1.0, 1.0])
    @test steady.per_tick == [1.0, 1.0, 1.0]
    @test steady.sigma ≈ 1.0
    @test isnan(steady.sigma_ols)

    doubling = BrainlessLab._branching_from_rates([1.0, 2.0, 4.0])
    @test doubling.per_tick == [2.0, 2.0]
    @test doubling.sigma ≈ 2.0
    @test doubling.sigma_ols ≈ 2.0

    with_zero = BrainlessLab._branching_from_rates([0.0, 2.0, 4.0])
    @test isnan(with_zero.per_tick[1])
    @test with_zero.per_tick[2] == 2.0
    @test with_zero.sigma ≈ 2.0

    sim = simulate(:wall; node=:falandays_base, ticks=60, seed=1)
    raw = getchannel(sim.recorder, :rate)
    br = branching_ratio(sim)
    @test length(br.per_tick) == length(raw) - 1
    @test isfinite(br.sigma)
    @test isfinite(br.sigma_ols)

    @test resolve_analysis(:branching_ratio) === branching_ratio
    @test :branching_ratio in analyses()
    @test resolve_analysis(:branching_ratio_mr) === branching_ratio_mr
    @test analysis_meta(:branching_ratio_mr).label == "branching ratio m (MR estimator, subsampling-robust)"
end

@testset "MR branching estimator" begin
    true_m = 0.9
    n = 3000
    rng = MersenneTwister(7)
    centered = zeros(Float64, n)
    centered[1] = 0.5
    @inbounds for t in 1:(n - 1)
        centered[t + 1] = true_m * centered[t] + 0.05 * randn(rng)
    end
    rates = 10.0 .+ centered

    rec = Recorder(enabled=(:rate,))
    for rate in rates
        record!(rec, :rate, rate)
        tick!(rec)
    end
    sim = SimResult(rec, (;), :synthetic, :synthetic, (;))

    legacy = branching_ratio(sim)
    mr = branching_ratio_mr(sim; kmax=12, transient=100)
    @test mr.kmax == 12
    @test length(mr.r_k) == 12
    @test isfinite(mr.m_mr)
    @test abs(mr.m_mr - true_m) < 0.05
    @test abs(mr.m_mr - true_m) < abs(legacy.sigma - true_m)
end

@testset "Avalanche statistics analysis" begin
    sim = simulate(:wall; node=:falandays_base, ticks=80, seed=2, n_nodes=24, record=(:spikes,))
    av = avalanches(sim)
    @test isfinite(Float64(av.n_avalanches))
    @test length(av.sizes) == av.n_avalanches
    @test length(av.durations) == av.n_avalanches
    @test all(x -> x > 0.0, av.sizes)
    @test all(x -> x > 0, av.durations)
    @test isfinite(av.threshold)

    rec = Recorder(enabled=(:spikes,))
    for sample in ([0, 0, 0, 0], [1, 1, 1, 0], [1, 1, 1, 1], [0, 0, 0, 0])
        record!(rec, :spikes, sample)
        tick!(rec)
    end
    synthetic = SimResult(rec, (;), :synthetic, :synthetic, (;))
    got = avalanches(synthetic; threshold=0.5)
    @test got.sizes == [7.0]
    @test got.durations == [2]
    @test got.n_avalanches == 1
    @test isnan(got.tau)
    @test resolve_analysis(:avalanches) === avalanches
    @test analysis_meta(:avalanches).label == "neuronal avalanche size/duration exponents"
end

@testset "Transfer entropy analysis" begin
    rng = MersenneTwister(11)
    n = 500
    driver = rand(rng, 0:1, n)
    response = zeros(Int, n)
    response[1] = rand(rng, 0:1)
    @inbounds for t in 1:(n - 1)
        response[t + 1] = rand(rng) < 0.9 ? driver[t] : rand(rng, 0:1)
    end

    driver_to_response = transfer_entropy(driver, response; bins=2, lag=1)
    response_to_driver = transfer_entropy(response, driver; bins=2, lag=1)
    @test isfinite(driver_to_response)
    @test isfinite(response_to_driver)
    @test driver_to_response > response_to_driver

    sim = simulate(
        :torus;
        node=:falandays_base,
        ticks=50,
        seed=3,
        n_agents=3,
        n_nodes=10,
        sensory_noise=0.0,
        record=(:spikes, :poses),
    )
    node_te = node_transfer_entropy(sim; max_pairs=24, seed=5)
    @test node_te.level == :node
    @test node_te.signal == :spikes
    @test node_te.sampled
    @test node_te.pairs_evaluated == 24
    @test node_te.valid_pairs == node_te.pairs_evaluated
    @test isfinite(node_te.mean_pairwise_te)
    @test isfinite(node_te.net_directional_asymmetry)

    agent_te = agent_transfer_entropy(sim)
    @test agent_te.level == :agent
    @test agent_te.signal == :heading_change
    @test agent_te.pairs_evaluated == 3
    @test agent_te.valid_pairs == agent_te.pairs_evaluated
    @test isfinite(agent_te.mean_pairwise_te)
    @test isfinite(agent_te.net_directional_asymmetry)

    @test resolve_analysis(:node_transfer_entropy) === node_transfer_entropy
    @test resolve_analysis(:agent_transfer_entropy) === agent_transfer_entropy
    @test analysis_meta(:node_transfer_entropy).label == "node-level transfer entropy (experimental)"
    @test analysis_meta(:agent_transfer_entropy).label == "agent-level transfer entropy (experimental)"
end

@testset "Node target error analysis" begin
    sim = simulate(:wall; node=:falandays_base, ticks=12, seed=1, n_nodes=16, record=(:acts, :targets))
    target_error = node_target_error(sim)
    raw = getchannel(sim.recorder, :acts)

    @test size(target_error.per_node_error) == (16, length(raw))
    @test length(target_error.mean_over_nodes) == length(raw)
    @test length(target_error.final_distribution) == 16
    @test all(x -> x >= 0.0, target_error.per_node_error)
    @test all(x -> x >= 0.0, target_error.mean_over_nodes)

    missing_targets = simulate(:wall; node=:falandays_base, ticks=4, seed=1, n_nodes=8, record=(:acts,))
    @test_throws ArgumentError node_target_error(missing_targets)

    @test resolve_analysis(:node_target_error) === node_target_error
    @test analysis_meta(:node_target_error).label == "per-node distance to target |act−T|"
end

@testset "Spectral radius analysis" begin
    @test BrainlessLab._spectral_radius([0.0 0.0; 0.0 0.0]) == 0.0
    @test BrainlessLab._spectral_radius([2.0 0.0; 0.0 -3.0]) ≈ 3.0

    sim = simulate(:wall; node=:falandays_base, ticks=120, seed=1, record=(:spectral_radius,), every=10)
    sr = spectral_radius(sim)
    @test !isempty(sr.series)
    @test all(isfinite, sr.series)
    @test all(x -> x >= 0.0, sr.series)
    @test length(unique(round.(sr.series, digits=6))) > 1

    sim2 = simulate(:wall; node=:falandays_base, ticks=20)
    @test haskey(sim2.recorder, :spectral_radius) == false
    @test_throws ArgumentError spectral_radius(sim2)

    @test :spectral_radius in analyses()
    @test analysis_meta(:spectral_radius).label == "spectral radius ρ(W)"
end

@testset "Task performance analyses" begin
    wall_sim = simulate(:wall; node=:falandays_base, ticks=40, seed=1, record=(:rate, :poses))
    wd = wall_distance(wall_sim)
    @test length(wd) == length(getchannel(wall_sim.recorder, :poses))
    @test all(isfinite, wd)
    @test all(x -> x >= 0.0, wd)

    tracking_sim = simulate(:tracking; node=:falandays_base, ticks=40, seed=1, record=(:rate, :scene))
    he = heading_error(tracking_sim)
    @test length(he) == length(getchannel(tracking_sim.recorder, :scene))
    @test all(isfinite, he)
    @test all(x -> x >= 0.0, he)

    pong_sim = simulate(:pong; node=:falandays_base, ticks=40, seed=1, record=(:rate, :scene))
    bpd = ball_paddle_distance(pong_sim)
    @test length(bpd) == length(getchannel(pong_sim.recorder, :scene))
    @test all(isfinite, bpd)
    @test all(x -> x >= 0.0, bpd)

    @test task_analyses(:wall) == [:wall_distance]
    @test isempty(task_analyses(:cartpole))
    @test :branching_ratio in analyses()
    @test !in(:wall_distance, analyses())
    @test :wall_distance in analyses(task=:wall)
    @test resolve_analysis(:branching_ratio) === branching_ratio
    @test analysis_meta(:heading_error).label == "heading error (rad)"
end
