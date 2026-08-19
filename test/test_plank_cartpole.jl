using BrainlessLab
using Random
using Test

@testset "Plank Spike-FF-2 source example" begin
    encoder = BrainlessLab.SpikeFF2Encoder((2.4, 2.0, 0.209, 2.0))
    cycle = BrainlessLab.FixedRateCycle(24)
    state = BrainlessLab.begin_encoding!(encoder, [0.852, -0.007, 0.018, -0.659], cycle)
    totals = zeros(Int, 8)
    for frame in 1:24
        totals .+= Int.(BrainlessLab.encode_frame!(encoder, state, frame, cycle))
    end
    # Authors' documented example: +x=3, -dx=1, +theta=1, -dtheta=3.
    @test totals == [0, 3, 1, 0, 0, 1, 3, 0]
    @test sum(totals) == 8
end

@testset "Argyle-4 conserves nine spikes per observation" begin
    encoder = BrainlessLab.Argyle4Encoder((2.4, 0.2095))
    cycle = BrainlessLab.FixedRateCycle(24)
    state = BrainlessLab.begin_encoding!(encoder, [0.0, 0.10475], cycle)
    totals = zeros(Int, 8)
    for frame in 1:24
        totals .+= Int.(BrainlessLab.encode_frame!(encoder, state, frame, cycle))
    end
    @test sum(@view totals[1:4]) == 9
    @test sum(@view totals[5:8]) == 9
    @test count(>(0), @view totals[1:4]) <= 2
    @test count(>(0), @view totals[5:8]) <= 2
end

@testset "four Plank CartPole levels are experimental task profiles" begin
    expected = Set((
        :cartpole_plank_easy,
        :cartpole_plank_medium,
        :cartpole_plank_hard,
        :cartpole_plank_hardest,
    ))
    @test Set(tasks(tag=:plank_cartpole)) == expected
    @test Set(tasks(tag=:qualification)) == Set((:tracking, :pong, :cartpole_plank_easy))
    @test Set(tasks(tag=:benchmark)) == Set((:tracking, :pong, :cartpole_plank_easy))
    @test isempty(tasks(tag=:frontier))
    @test :pong_hitrate in tasks(tag=:alias)
    @test :wall ∉ tasks(tag=:extended)
    @test :wall ∉ tasks(tag=:qualification)

    for task in expected
        info = BrainlessLab.task_info(task)
        @test info.status === :experimental
        @test info.tags == (
            task === :cartpole_plank_easy ?
            (:benchmark, :qualification, :core, :plank_cartpole) :
            (:experimental, :plank_cartpole)
        )
        @test info.interaction_cycle == BrainlessLab.FixedRateCycle(24)
        @test info.protocol.evaluation.trials_per_block == 1000
        @test info.protocol.evaluation.horizon == 15_000
        @test info.protocol.evaluation.construction_scope === :evaluation
        @test info.protocol.cross_task_aggregate === false
        @test info.protocol.source_commit ==
            "c346e743dc42d5b3339c4252e4ab23c7a8139635"
        @test info.protocol.conformance.voting ===
            :authors_source_cumulative_activity_lower_index_final_tie

        setup = BrainlessLab.setup_task(resolve_task(task); seed=11)
        @test setup.environment isa BrainlessLab.PlankCartPoleEnv
        @test BrainlessLab.scene(setup.environment).level === setup.environment.level.name
        body = only(setup.bodies)
        @test BrainlessLab.primary_readout(body) isa BrainlessLab.VotingReadout
        @test n_receptors(body) == resolve_task(task).n_receptors
        @test n_effectors(body) == resolve_task(task).n_effectors
    end
end

@testset "Plank CartPole Easy task opportunity" begin
    seeds = 91_001:91_016
    oracle_steps = Int[]
    random_steps = Int[]
    always_left_steps = Int[]
    always_right_steps = Int[]

    for seed in seeds
        oracle = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(seed), level=:easy)
        random = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(seed), level=:easy)
        always_left = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(seed), level=:easy)
        always_right = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(seed), level=:easy)
        action_rng = MersenneTwister(seed + 1_000_000)

        while !BrainlessLab.terminated(oracle)
            step!(oracle, BrainlessLab.cartpole_balancer(oracle))
        end
        while !BrainlessLab.terminated(random)
            step!(random, rand(action_rng, Bool) ? [1.0, 0.0] : [0.0, 1.0])
        end
        while !BrainlessLab.terminated(always_left)
            step!(always_left, [1.0, 0.0])
        end
        while !BrainlessLab.terminated(always_right)
            step!(always_right, [0.0, 1.0])
        end

        push!(oracle_steps, oracle.step_count)
        push!(random_steps, random.step_count)
        push!(always_left_steps, always_left.step_count)
        push!(always_right_steps, always_right.step_count)
    end

    @test all(==(BrainlessLab.PLANK_CARTPOLE_MISSION_STEPS), oracle_steps)
    @test sum(oracle_steps) > sum(random_steps)
    @test sum(oracle_steps) > sum(always_left_steps)
    @test sum(oracle_steps) > sum(always_right_steps)
end


@testset "Plank rollout stops at episode termination" begin
    task = BrainlessLabTestUtils.task_with_minimum(:cartpole_plank_easy, 1)
    registry = RegistrySet()
    register!(registry, node_spec(DEFAULT_REGISTRY, :null_random))
    register!(registry, task)
    target = EvaluationTarget(
        :terminal_cartpole,
        CompositionSpec(:terminal_cartpole, :null_random, :cartpole_plank_easy; n_nodes=8),
        EvaluationSpec(horizon=15_000, root_seed=4),
    )
    trial = only(BrainlessLab.evaluate(target; registry).trials)
    row = BrainlessLab.trial_row(trial)
    @test trial.simulation.config.terminated
    @test trial.simulation.config.executed_scored_ticks ==
        trial.simulation.metrics.steps_balanced
    @test trial.simulation.config.executed_scored_ticks < 15_000
    @test row.profile_metric === :steps_balanced
    @test row.profile_value == trial.simulation.metrics.steps_balanced
    @test row.profile_direction === :higher
end

@testset "Plank CartPole action and fitness contracts" begin
    dynamics = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(7), level=:easy)
    BrainlessLab.set_plank_cartpole_state!(dynamics, (0.1, 0.2, 0.05, -0.1))
    previous = copy(dynamics.state)
    step!(dynamics, [1.0, 0.0])
    # Gym's default explicit Euler updates positions from the old velocities.
    @test dynamics.state[1] ≈ previous[1] + dynamics.tau * previous[2]
    @test dynamics.state[3] ≈ previous[3] + dynamics.tau * previous[4]

    medium = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(1), level=:medium)
    initial = copy(medium.state)
    step!(medium, [1.0, 0.0, 0.0])
    @test medium.noop_count == 1
    @test medium.step_count == 1
    @test medium.state != initial
    @test BrainlessLab.plank_cartpole_fitness(medium) == 1.0

    medium.step_count = 100
    medium.noop_count = 70
    @test BrainlessLab.plank_cartpole_fitness(medium) ≈ 70 / 0.75
    medium.noop_count = 80
    @test BrainlessLab.plank_cartpole_fitness(medium) == 100.0

    easy = BrainlessLab.PlankCartPoleEnv(rng=MersenneTwister(2), level=:easy)
    @test BrainlessLab._plank_cartpole_action(easy, [0.5, 0.5]) === :left
end

@testset "Plank profiles execute through the standard simulation path" begin
    for task in tasks(tag=:plank_cartpole)
        result = BrainlessLabTestUtils.diagnostic_simulate(
            task;
            node=:falandays,
            n_nodes=20,
            ticks=3,
            seed=3,
            record=Symbol[],
        )
        @test result isa SimResult
        @test isfinite(result.metrics.fitness)
        @test result.config.agents[1].body.traits.interface_frozen
    end
end

@testset "Plank evaluation uses the general evaluation contract" begin
    protocol = EvaluationSpec(
        blocks=1,
        trials_per_block=3,
        horizon=5,
        reset=:full,
        construction_scope=:evaluation,
        aggregate=:mean,
        root_seed=71,
    )
    composition = CompositionSpec(
        :plank_easy_null,
        :null_random,
        :cartpole_plank_easy;
        n_nodes=8,
    )
    target = EvaluationTarget(:plank_easy, composition, protocol)
    registry = RegistrySet()
    register!(registry, node_spec(DEFAULT_REGISTRY, :null_random))
    register!(
        registry,
        BrainlessLabTestUtils.task_with_minimum(:cartpole_plank_easy, 1),
    )
    result = BrainlessLab.evaluate(target; registry)
    repeated = BrainlessLab.evaluate(target; registry)
    changed = BrainlessLab.evaluate(EvaluationTarget(
        :plank_easy,
        composition,
        EvaluationSpec(
            blocks=1,
            trials_per_block=3,
            horizon=5,
            construction_scope=:evaluation,
            root_seed=72,
        ),
    ); registry)

    @test result isa BrainlessLab.EvaluationBatch
    @test length(result.trials) == 3
    @test getfield.(result.trials, :initial_state) ==
        getfield.(repeated.trials, :initial_state)
    @test getfield.(result.trials, :initial_state) !=
        getfield.(changed.trials, :initial_state)
    @test all(trial -> trial.simulation.metrics.steps_balanced <= 5, result.trials)
    @test result.target.evaluation.construction_scope === :evaluation
    @test length(unique(
        first(trial.seeds).topology for trial in result.trials
    )) == 1
    @test_throws ArgumentError BrainlessLab.evaluate(EvaluationTarget(
        :tracking,
        CompositionSpec(:invalid_plank, :null_random, :tracking; n_nodes=8),
        EvaluationSpec(horizon=5, reset=:none),
    ))
end
