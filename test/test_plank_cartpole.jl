using BrainlessLab
using Random
using Test

@testset "Plank Spike-FF-2 source example" begin
    encoder = SpikeFF2Encoder((2.4, 2.0, 0.209, 2.0))
    cycle = FixedRateCycle(24)
    state = begin_encoding!(encoder, [0.852, -0.007, 0.018, -0.659], cycle)
    totals = zeros(Int, 8)
    for frame in 1:24
        totals .+= Int.(encode_frame!(encoder, state, frame, cycle))
    end
    # Authors' documented example: +x=3, -dx=1, +theta=1, -dtheta=3.
    @test totals == [0, 3, 1, 0, 0, 1, 3, 0]
    @test sum(totals) == 8
end

@testset "Argyle-4 conserves nine spikes per observation" begin
    encoder = Argyle4Encoder((2.4, 0.2095))
    cycle = FixedRateCycle(24)
    state = begin_encoding!(encoder, [0.0, 0.10475], cycle)
    totals = zeros(Int, 8)
    for frame in 1:24
        totals .+= Int.(encode_frame!(encoder, state, frame, cycle))
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
    @test Set(tasks(tag=:qualification)) == Set((:tracking, :pong))
    @test Set(tasks(tag=:benchmark)) == Set((:tracking, :pong))
    @test :pong_hitrate in tasks(tag=:alias)
    @test :wall in tasks(tag=:extended)
    @test :wall ∉ tasks(tag=:qualification)

    for task in expected
        info = task_info(task)
        @test info.status === :experimental
        @test info.tags == (:experimental, :plank_cartpole)
        @test info.interaction_cycle == FixedRateCycle(24)
        @test info.protocol.evaluation_episodes == 1000
        @test info.protocol.cross_task_aggregate === false

        setup = setup_task(resolve_task(task); seed=11)
        @test setup.environment isa PlankCartPoleEnv
        body = only(setup.bodies)
        @test primary_readout(body) isa VotingReadout
        @test n_receptors(body) == resolve_task(task).n_receptors
        @test n_effectors(body) == resolve_task(task).n_effectors
    end
end

@testset "Plank CartPole action and fitness contracts" begin
    dynamics = PlankCartPoleEnv(rng=MersenneTwister(7), level=:easy)
    set_plank_cartpole_state!(dynamics, (0.1, 0.2, 0.05, -0.1))
    previous = copy(dynamics.state)
    step!(dynamics, [1.0, 0.0])
    # Gym's default explicit Euler updates positions from the old velocities.
    @test dynamics.state[1] ≈ previous[1] + dynamics.tau * previous[2]
    @test dynamics.state[3] ≈ previous[3] + dynamics.tau * previous[4]

    medium = PlankCartPoleEnv(rng=MersenneTwister(1), level=:medium)
    initial = copy(medium.state)
    step!(medium, [1.0, 0.0, 0.0])
    @test medium.noop_count == 1
    @test medium.step_count == 1
    @test medium.state != initial
    @test plank_cartpole_fitness(medium) == 1.0

    medium.step_count = 100
    medium.noop_count = 70
    @test plank_cartpole_fitness(medium) ≈ 70 / 0.75
    medium.noop_count = 80
    @test plank_cartpole_fitness(medium) == 100.0

    easy = PlankCartPoleEnv(rng=MersenneTwister(2), level=:easy)
    @test BrainlessLab._plank_cartpole_action(easy, [0.5, 0.5]) === :left
end

@testset "Plank profiles execute through the standard simulation path" begin
    for task in tasks(tag=:plank_cartpole)
        result = simulate(
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

@testset "Plank evaluation freezes design and records the test set" begin
    protocol = EvaluationProtocol(
        trials=3,
        horizon=5,
        reset=:full,
        design_scope=:fixed,
        aggregation=:mean,
    )
    states = plank_cartpole_initial_conditions(71, 3)
    @test states == plank_cartpole_initial_conditions(71, 3)
    @test states != plank_cartpole_initial_conditions(72, 3)

    result = evaluate_plank_cartpole(
        :cartpole_plank_easy;
        node=:null_random,
        protocol=protocol,
        build_seed=4,
        trial_seed=71,
        n_nodes=8,
    )
    @test result isa EvaluationResult
    @test result.initial_conditions == states
    @test length(result.trials) == 3
    @test result.summary.n == 3
    @test result.summary.target_fitness == 14_250.0
    @test all(trial -> trial.steps <= 5, result.trials)
    @test result.protocol.design_scope === :fixed

    @test_throws ArgumentError evaluate_plank_cartpole(
        :tracking;
        node=:null_random,
        protocol=protocol,
        n_nodes=8,
    )
end
