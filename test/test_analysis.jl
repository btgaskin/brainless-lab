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
    @test resolve_analysis(:branching_ratio_mr_windowed) === branching_ratio_mr_windowed
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

@testset "Windowed ensemble branching observables" begin
    @test BrainlessLab._quantile_positive([0.0, 1.0, 2.0, 4.0, 8.0], 0.5) ≈ 3.0
    @test BrainlessLab._quantile_positive([0.0, 1.0, 2.0, 4.0, 8.0], 0.75) ≈ 5.0

    function _synthetic_rate_sim(rates)
        rec = Recorder(enabled=(:rate,))
        for rate in rates
            record!(rec, :rate, rate)
            tick!(rec)
        end
        return SimResult(rec, (;), :synthetic, :synthetic, (; ticks=length(rates), window=length(rates), every=1))
    end

    rng = MersenneTwister(701)
    n = 1800
    ramp = zeros(Float64, n)
    ramp[1] = 0.25
    @inbounds for t in 1:(n - 1)
        coeff = 0.8 + 0.2 * (t - 1) / (n - 2)
        ramp[t + 1] = coeff * ramp[t] + 0.035 * randn(rng)
    end
    ramp_sim = _synthetic_rate_sim(10.0 .+ ramp)
    _, m_ramp, r2_ramp, _ = BrainlessLab.branching_ratio_mr_windowed(ramp_sim; window=240, stride=80, kmax=8)
    usable_ramp = findall(i -> isfinite(m_ramp[i]) && isfinite(r2_ramp[i]) && r2_ramp[i] > 0.5, eachindex(m_ramp))
    @test length(usable_ramp) >= 4
    split = max(1, fld(length(usable_ramp), 3))
    early_ramp = m_ramp[usable_ramp[1:split]]
    late_ramp = m_ramp[usable_ramp[(end - split + 1):end]]
    @test sum(late_ramp) / length(late_ramp) > sum(early_ramp) / length(early_ramp)

    rng = MersenneTwister(702)
    true_m = 0.88
    stationary = zeros(Float64, n)
    stationary[1] = 0.25
    @inbounds for t in 1:(n - 1)
        stationary[t + 1] = true_m * stationary[t] + 0.035 * randn(rng)
    end
    stationary_sim = _synthetic_rate_sim(10.0 .+ stationary)
    mr = branching_ratio_mr(stationary_sim; kmax=8, transient=100)
    _, m_stationary, _, _ = BrainlessLab.branching_ratio_mr_windowed(stationary_sim; window=240, stride=120, kmax=8)
    finite_stationary = filter(isfinite, m_stationary)
    @test !isempty(finite_stationary)
    @test abs(sum(finite_stationary) / length(finite_stationary) - mr.m_mr) < 0.08

    forage = simulate(
        :forage;
        node=:falandays_base,
        ticks=140,
        seed=31,
        n_agents=5,
        n_nodes=12,
        vision_range=15.0,
        sensory_noise=0.0,
        record=(:spikes, :rate, :poses),
    )
    median_events = BrainlessLab._analysis_agent_activity_matrix(forage, :test; observable=(; kind=:turn, threshold=:median))
    q85_events = BrainlessLab._analysis_agent_activity_matrix(forage, :test; observable=(; kind=:turn, threshold=(:quantile, 0.85)))
    @test sum(q85_events) < sum(median_events)

    for spec in (
        (; kind=:turn, threshold=(:quantile, 0.85)),
        (; kind=:speed, threshold=(:quantile, 0.85)),
        (; kind=:align, threshold=(:quantile, 0.85), neighbor_radius=15.0),
        (; kind=:graded),
    )
        centers, m_series, r2_series, n_used = BrainlessLab.branching_ratio_mr_windowed(
            forage;
            level=:agent,
            window=36,
            stride=18,
            kmax=4,
            observable=spec,
        )
        @test length(centers) == length(m_series) == length(r2_series) == length(n_used)
        @test any(isfinite, m_series)
    end
    _, align_from_config, _, _ = BrainlessLab.branching_ratio_mr_windowed(
        forage;
        level=:agent,
        window=36,
        stride=18,
        kmax=4,
        observable=(; kind=:align, threshold=(:quantile, 0.85), neighbor_radius=nothing),
    )
    @test any(isfinite, align_from_config)
    no_radius_cfg = (;
        ticks=forage.config.ticks,
        window=forage.config.window,
        every=forage.config.every,
        n_agents=forage.config.n_agents,
        n_nodes=forage.config.n_nodes,
        environment=(; size=forage.config.environment.size),
    )
    no_radius_sim = SimResult(forage.recorder, forage.metrics, forage.task, forage.node, no_radius_cfg)
    @test_throws ArgumentError BrainlessLab.branching_ratio_mr_windowed(
        no_radius_sim;
        level=:agent,
        window=36,
        stride=18,
        kmax=4,
        observable=(; kind=:align, threshold=(:quantile, 0.85), neighbor_radius=nothing),
    )
    distances = BrainlessLab.distance_to_source(forage)
    @test length(distances) == length(getchannel(forage.recorder, :poses))
    @test all(isfinite, distances)
end

@testset "Circular-shift null tests" begin
    function _markov_events(rng, n; p_on=0.25, stay=0.85)
        events = falses(n)
        events[1] = rand(rng) < p_on
        @inbounds for t in 2:n
            if rand(rng) < stay
                events[t] = events[t - 1]
            else
                events[t] = rand(rng) < p_on
            end
        end
        return events
    end

    function _synthetic_swarm_from_events(events)
        n_steps, n_agents = size(events)
        headings = zeros(Float64, n_steps + 1, n_agents)
        @inbounds for i in 1:n_agents, t in 1:n_steps
            headings[t + 1, i] = headings[t, i] + (events[t, i] ? 1.0 : 0.02)
        end
        rec = Recorder(enabled=(:poses,))
        @inbounds for t in 1:(n_steps + 1)
            poses = [(Float64(i), 0.0, headings[t, i]) for i in 1:n_agents]
            record!(rec, :poses, poses)
            tick!(rec)
        end
        config = (; ticks=n_steps + 1, window=n_steps + 1, every=1, n_agents=n_agents, n_nodes=1, environment=(; size=100.0, vision_range=100.0))
        return SimResult(rec, (;), :synthetic, :synthetic, config)
    end

    n_steps = 220
    n_agents = 6
    rng = MersenneTwister(880)
    shared = _markov_events(rng, n_steps)
    coupled_events = falses(n_steps, n_agents)
    @inbounds for i in 1:n_agents
        coupled_events[:, i] .= shared
    end
    uncoupled_events = falses(n_steps, n_agents)
    @inbounds for i in 1:n_agents
        uncoupled_events[:, i] .= _markov_events(rng, n_steps)
    end
    coupled = _synthetic_swarm_from_events(coupled_events)
    uncoupled = _synthetic_swarm_from_events(uncoupled_events)

    sus_fn = s -> susceptibility(s; level=:agent).susceptibility
    coupled_sus = crossshift_null(coupled, sus_fn; n_shifts=20, rng=MersenneTwister(881))
    uncoupled_sus = crossshift_null(uncoupled, sus_fn; n_shifts=20, rng=MersenneTwister(882))
    @test isfinite(coupled_sus.real)
    @test isfinite(coupled_sus.null_mean)
    @test coupled_sus.real < 0.25 * coupled_sus.null_mean
    @test abs(uncoupled_sus.real - uncoupled_sus.null_mean) <= max(0.05, 3.0 * uncoupled_sus.null_std)

    branch_spec = (; kind=:turn, threshold=:median)
    branch_fn = s -> branching_ratio_mr(s; level=:agent, kmax=3, observable=branch_spec).m_mr
    coupled_branch = crossshift_null(coupled, branch_fn; n_shifts=20, rng=MersenneTwister(883))
    uncoupled_branch = crossshift_null(uncoupled, branch_fn; n_shifts=20, rng=MersenneTwister(884))
    @test isfinite(coupled_branch.real)
    @test isfinite(coupled_branch.null_mean)
    @test isfinite(uncoupled_branch.real)
    @test isfinite(uncoupled_branch.null_mean)
    @test abs(coupled_branch.real - coupled_branch.null_mean) <= max(0.25, 3.0 * coupled_branch.null_std)
    @test abs(uncoupled_branch.real - uncoupled_branch.null_mean) <= max(0.25, 3.0 * uncoupled_branch.null_std)
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
    node_sus_w = BrainlessLab.susceptibility_windowed(sim; level=:node, window=24, stride=12)
    agent_sus_w = BrainlessLab.susceptibility_windowed(sim; level=:agent, window=24, stride=12)
    @test node_sus_w.level == :node
    @test agent_sus_w.level == :agent
    @test length(node_sus_w.t_centers) == length(node_sus_w.susceptibility)
    @test length(agent_sus_w.t_centers) == length(agent_sus_w.susceptibility)
    @test all(isfinite, node_sus_w.susceptibility)
    @test all(isfinite, agent_sus_w.susceptibility)

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
    @test resolve_analysis(:susceptibility_windowed) === susceptibility_windowed
    @test resolve_analysis(:fano_factor) === fano_factor
    @test resolve_analysis(:participation_ratio) === participation_ratio
    @test analysis_meta(:susceptibility).label == "susceptibility χ (experimental)"
    @test analysis_meta(:fano_factor).label == "Fano factor (experimental)"
    @test analysis_meta(:participation_ratio).label == "participation ratio (experimental)"
end

@testset "Swarm regime and correlation length" begin
    valid_labels = (:polarized, :milling, :swarming, :static)

    torus_sim = simulate(:torus; node=:falandays_base, ticks=70, seed=10, n_agents=5, n_nodes=12, vision_range=15.0, record=(:poses, :polarization, :milling, :rate))
    torus_regime = swarm_regime(torus_sim)
    @test torus_regime.label in valid_labels
    @test isfinite(torus_regime.polarization)
    @test isfinite(torus_regime.milling)
    @test isfinite(torus_regime.speed)
    @test isfinite(correlation_length(torus_sim))
    corr_w = BrainlessLab.correlation_length_windowed(torus_sim; window=20, stride=10)
    @test length(corr_w.t_centers) == length(corr_w.correlation_length)
    @test all(isfinite, corr_w.correlation_length)
    clusters = BrainlessLab.contact_graph_clusters(torus_sim)
    @test length(clusters.n_components) == length(getchannel(torus_sim.recorder, :poses))
    @test all(isfinite, clusters.n_components)
    @test all(x -> 0.0 <= x <= 1.0, clusters.largest_component_frac)
    clusters_w = BrainlessLab.contact_graph_clusters_windowed(torus_sim; window=20, stride=10)
    @test length(clusters_w.t_centers) == length(clusters_w.n_components)
    @test all(isfinite, clusters_w.mean_component_size)

    forage_sim = simulate(:forage; node=:falandays_base, ticks=70, seed=11, n_agents=5, n_nodes=12, vision_range=15.0, record=(:poses, :polarization, :milling, :rate))
    forage_regime = swarm_regime(forage_sim)
    @test forage_regime.label in valid_labels
    @test isfinite(forage_regime.polarization)
    @test isfinite(forage_regime.milling)
    @test isfinite(forage_regime.speed)
    @test isfinite(correlation_length(forage_sim))
    @test isfinite(BrainlessLab.contact_graph_clusters(forage_sim).largest_component_frac_mean)

    @test resolve_analysis(:swarm_regime) === swarm_regime
    @test resolve_analysis(:correlation_length) === correlation_length
    @test resolve_analysis(:correlation_length_windowed) === correlation_length_windowed
    @test resolve_analysis(:contact_graph_clusters) === contact_graph_clusters
    @test resolve_analysis(:contact_graph_clusters_windowed) === contact_graph_clusters_windowed
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
    @test :distance_to_source in task_analyses(:forage)
    @test isempty(task_analyses(:cartpole))
    @test :branching_ratio in analyses()
    @test !in(:wall_distance, analyses())
    @test :wall_distance in analyses(task=:wall)
    @test resolve_analysis(:branching_ratio) === branching_ratio
    @test resolve_analysis(:crossshift_null) === crossshift_null
    @test analysis_meta(:heading_error).label == "heading error (rad)"
end
