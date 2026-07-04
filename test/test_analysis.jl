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

    swarm = simulate(:torus; node=:falandays_base, ticks=70, seed=12, n_agents=4, n_nodes=12, record=(:spikes, :rate, :poses))
    node_br = branching_ratio(swarm; level=:node)
    @test node_br.level == :node
    @test node_br.n_agents == 4
    @test length(node_br.per_agent) == 4
    @test length(node_br.sigma_distribution) == 4
    @test size(node_br.population_rate) == (length(getchannel(swarm.recorder, :rate)), 4)
    @test isfinite(node_br.sigma)

    agent_br = branching_ratio(swarm; level=:agent)
    @test agent_br.level == :agent
    @test agent_br.n_agents == 4
    @test length(agent_br.agent_activity) == size(agent_br.agent_events, 1)
    @test agent_br.turn_threshold == BrainlessLab.DEFAULT_TURN_THRESHOLD

    rec_turns = Recorder(enabled=(:rate, :poses))
    for (rates, poses) in zip(
        ([0.5, 0.5], [0.5, 0.5], [0.5, 0.5], [0.5, 0.5]),
        (
            [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)],
            [(0.0, 0.0, pi / 4), (1.0, 0.0, 0.0)],
            [(0.0, 0.0, pi / 2), (1.0, 0.0, pi / 4)],
            [(0.0, 0.0, pi / 2), (1.0, 0.0, pi / 2)],
        ),
    )
        record!(rec_turns, :rate, rates)
        record!(rec_turns, :poses, poses)
        tick!(rec_turns)
    end
    turn_sim = SimResult(rec_turns, (;), :synthetic, :synthetic, (; n_agents=2, n_nodes=4, every=1, environment=(; size=nothing)))
    pooled_turn = branching_ratio(turn_sim; level=:pooled)
    agent_turn = branching_ratio(turn_sim; level=:agent)
    @test agent_turn.n_agents == 2
    @test agent_turn.agent_activity == [1.0, 2.0, 1.0]
    @test agent_turn.sigma != pooled_turn.sigma

    single_swarm = simulate(:torus; node=:falandays_base, ticks=60, seed=13, n_agents=1, n_nodes=12, record=(:spikes, :rate, :poses))
    pooled_single = branching_ratio(single_swarm)
    node_single = branching_ratio(single_swarm; level=:node)
    agent_single = branching_ratio(single_swarm; level=:agent)
    @test (isnan(node_single.sigma) && isnan(pooled_single.sigma)) || node_single.sigma ≈ pooled_single.sigma
    @test agent_single.n_agents == 1

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

    swarm = simulate(:torus; node=:falandays_base, ticks=90, seed=14, n_agents=3, n_nodes=10, record=(:spikes, :rate, :poses))
    node_mr = branching_ratio_mr(swarm; kmax=4, level=:node)
    @test node_mr.level == :node
    @test node_mr.n_agents == 3
    @test length(node_mr.per_agent) == 3
    @test length(node_mr.m_mr_distribution) == 3
    @test node_mr.kmax == 4

    agent_mr = branching_ratio_mr(swarm; kmax=4, level=:agent)
    @test agent_mr.level == :agent
    @test agent_mr.n_agents == 3
    @test agent_mr.kmax == 4
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

    swarm = simulate(:torus; node=:falandays_base, ticks=80, seed=15, n_agents=4, n_nodes=12, record=(:spikes, :rate, :poses))
    node_av = avalanches(swarm; level=:node)
    @test node_av.level == :node
    @test node_av.n_agents == 4
    @test length(node_av.per_agent) == 4
    @test length(node_av.sizes) == 4
    @test length(node_av.n_avalanches_distribution) == 4

    agent_av = avalanches(swarm; level=:agent)
    @test agent_av.level == :agent
    @test agent_av.n_agents == 4
    @test isfinite(Float64(agent_av.n_avalanches))
    @test agent_av.turn_threshold == BrainlessLab.DEFAULT_TURN_THRESHOLD

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
    @test node_te.n_agents == 3
    @test length(node_te.per_agent) == 3
    @test node_te.n_nodes_distribution == [10, 10, 10]
    @test node_te.pairs_evaluated == 24 * 3
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
    @test sr.rho isa Float64
    @test length(sr.distribution) == 1

    swarm = simulate(:torus; node=:falandays_base, ticks=30, seed=6, n_agents=3, n_nodes=10, record=(:spectral_radius,), every=10)
    sr_swarm = spectral_radius(swarm)
    @test size(sr_swarm.series, 2) == 3
    @test length(sr_swarm.rho) == 3
    @test length(sr_swarm.distribution) == 3
    @test all(isfinite, sr_swarm.series)

    sim2 = simulate(:wall; node=:falandays_base, ticks=20)
    @test haskey(sim2.recorder, :spectral_radius) == false
    @test_throws ArgumentError spectral_radius(sim2)

    @test :spectral_radius in analyses()
    @test analysis_meta(:spectral_radius).label == "spectral radius ρ(W)"
end

@testset "Second-order level-aware signatures" begin
    sim = simulate(:torus; node=:falandays_base, ticks=70, seed=9, n_agents=4, n_nodes=12, record=(:spikes, :rate, :poses, :polarization))

    node_sus = susceptibility(sim; level=:node)
    agent_sus = susceptibility(sim; level=:agent)
    @test node_sus.level == :node
    @test agent_sus.level == :agent
    @test length(node_sus.distribution) == 4
    @test isfinite(node_sus.susceptibility)
    @test isfinite(agent_sus.susceptibility)

    node_fano = fano_factor(sim; level=:node)
    agent_fano = fano_factor(sim; level=:agent)
    @test node_fano.level == :node
    @test agent_fano.level == :agent
    @test length(node_fano.distribution) == 4
    @test isfinite(node_fano.fano_factor)
    @test isfinite(agent_fano.fano_factor)
    @test agent_fano.turn_threshold == BrainlessLab.DEFAULT_TURN_THRESHOLD

    node_pr = participation_ratio(sim; level=:node)
    agent_pr = participation_ratio(sim; level=:agent)
    @test node_pr.level == :node
    @test agent_pr.level == :agent
    @test length(node_pr.distribution) == 4
    @test isfinite(node_pr.participation_ratio)
    @test isfinite(agent_pr.participation_ratio)

    @test resolve_analysis(:susceptibility) === susceptibility
    @test resolve_analysis(:fano_factor) === fano_factor
    @test resolve_analysis(:participation_ratio) === participation_ratio
    @test analysis_meta(:susceptibility).label == "susceptibility χ (experimental)"
    @test analysis_meta(:fano_factor).label == "Fano factor (experimental)"
    @test analysis_meta(:participation_ratio).label == "participation ratio (experimental)"
end

@testset "Swarm regime and correlation length" begin
    valid_labels = (:polarized, :milling, :swarming, :static)

    torus_sim = simulate(:torus; node=:falandays_base, ticks=70, seed=10, n_agents=5, n_nodes=12, record=(:poses, :polarization, :milling, :rate))
    torus_regime = swarm_regime(torus_sim)
    @test torus_regime.label in valid_labels
    @test isfinite(torus_regime.polarization)
    @test isfinite(torus_regime.milling)
    @test isfinite(torus_regime.speed)
    @test isfinite(correlation_length(torus_sim))

    forage_sim = simulate(:forage; node=:falandays_base, ticks=70, seed=11, n_agents=5, n_nodes=12, record=(:poses, :polarization, :milling, :rate))
    forage_regime = swarm_regime(forage_sim)
    @test forage_regime.label in valid_labels
    @test isfinite(forage_regime.polarization)
    @test isfinite(forage_regime.milling)
    @test isfinite(forage_regime.speed)
    @test isfinite(correlation_length(forage_sim))

    @test resolve_analysis(:swarm_regime) === swarm_regime
    @test resolve_analysis(:correlation_length) === correlation_length
    @test analysis_meta(:swarm_regime).label == "swarm regime classifier (experimental)"
    @test analysis_meta(:correlation_length).label == "swarm velocity correlation length (experimental)"
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
