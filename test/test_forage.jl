using BrainlessLab
using Random
using Test

const FORAGE_KEYS = (
    :polarization,
    :milling,
    :mean_distance_to_source,
    :frac_within_capture,
    :time_to_first_arrival,
    :forage_score,
)

function _test_forage_metrics(metrics; ticks::Integer)
    for key in FORAGE_KEYS
        @test hasproperty(metrics, key)
        @test isfinite(Float64(getproperty(metrics, key)))
    end
    @test 0.0 <= metrics.frac_within_capture <= 1.0
    @test 0.0 <= metrics.forage_score <= 1.0
    @test 1.0 <= metrics.time_to_first_arrival <= Float64(ticks)
end

@testset "Forage high-level API" begin
    @test :forage in tasks()

    for conspecific_vision in (true, false)
        sim = simulate(
            :forage;
            node=:falandays_base,
            n_agents=4,
            n_nodes=40,
            ticks=20,
            seed=0,
            sensory_noise=0.0,
            source_gain=1.5,
            conspecific_vision=conspecific_vision,
            record=Symbol[],
        )

        @test sim isa SimResult
        @test sim.task == :forage
        @test sim.node == :falandays_base
        @test sim.config.environment.kind == :forage
        @test sim.config.environment.conspecific_vision == conspecific_vision
        _test_forage_metrics(sim.metrics; ticks=20)
    end

    oosawa = simulate(
        :forage;
        node=:falandays_oosawa,
        n_agents=3,
        n_nodes=30,
        ticks=8,
        seed=2,
        sensory_noise=0.0,
        source_gain=1.0,
        record=Symbol[],
    )
    @test oosawa.node == :falandays_oosawa
    _test_forage_metrics(oosawa.metrics; ticks=8)
end

@testset "Forage receptor banks and blind condition" begin
    setup = BrainlessLab._build_ensemble(
        :forage,
        :falandays_base;
        ticks=1,
        seed=11,
        n_agents=2,
        n_nodes=30,
        sensory_noise=0.0,
        source_gain=2.0,
        record=Symbol[],
    )
    agent = setup.ensemble.agents[1]
    morphology = default_morphology(agent.body)
    @test n_receptors(agent.reservoir) == 128
    @test n_receptors(morphology) == 128
    @test n_effectors(agent.reservoir) == 3

    torus = Torus(10.0)
    agent_radius = 0.5
    positions = [(4.0, 5.0), (4.2, 5.0)]
    config = SwarmConfig(
        n_agents=2,
        space_size=10.0,
        sensory_noise=0.0,
        physical_coupling=true,
        conspecific_vision=false,
        source_position=(5.0, 5.0),
        source_gain=2.0,
        capture_radius=0.5,
        agent_radius=agent_radius,
    )
    environment = ForageEnvironment(torus, positions; config=config, rng=MersenneTwister(7))

    # observe now returns the fully-encoded reservoir inputs (128-wide); the agent
    # bodies are stateless and only length-checked.
    bodies = [PassthroughBody(), PassthroughBody()]
    inputs = observe(environment, bodies)
    @test length(inputs[1]) == 128
    @test all(iszero, @view(inputs[1][1:64]))           # conspecific-blind
    @test maximum(@view(inputs[1][65:128])) ≈ 2.0       # source bank × source_gain

    before = copy(environment.positions)
    actuate!(environment, bodies, [zeros(3), zeros(3)])
    after = copy(environment.positions)
    @test after != before                                # collision resolution separates them
    @test tdistance(torus, after[1], after[2]) >= 2.0 * agent_radius - 1e-9
end

@testset "Forage source vision range" begin
    kwargs = (
        node=:falandays_base,
        n_agents=4,
        n_nodes=35,
        ticks=16,
        seed=9,
        sensory_noise=0.0,
        source_position=(8.0, 8.0),
        source_gain=1.0,
        record=(:poses,),
    )
    implicit_default = simulate(:forage; kwargs...)
    explicit_default = simulate(:forage; kwargs..., source_vision_range=nothing)
    @test getchannel(implicit_default.recorder, :poses) == getchannel(explicit_default.recorder, :poses)
    @test implicit_default.metrics == explicit_default.metrics
    @test explicit_default.config.environment.source_vision_range === nothing

    torus = Torus(10.0)
    bodies = [PassthroughBody()]
    source_kwargs = (
        n_agents=1,
        space_size=10.0,
        sensory_noise=0.0,
        conspecific_vision=false,
        source_position=(5.0, 5.0),
        source_gain=1.0,
        capture_radius=0.5,
    )
    unlimited = ForageEnvironment(
        torus,
        [(1.0, 5.0)];
        headings=[0.0],
        config=SwarmConfig(; source_kwargs..., source_vision_range=nothing),
        rng=MersenneTwister(3),
    )
    limited = ForageEnvironment(
        torus,
        [(1.0, 5.0)];
        headings=[0.0],
        config=SwarmConfig(; source_kwargs..., source_vision_range=1.5),
        rng=MersenneTwister(3),
    )
    unlimited_inputs = observe(unlimited, bodies)
    limited_inputs = observe(limited, bodies)
    @test maximum(@view(unlimited_inputs[1][65:128])) > 0.0
    @test all(iszero, @view(limited_inputs[1][65:128]))
    @test unlimited_inputs[1][65:128] != limited_inputs[1][65:128]

    conspecific_kwargs = (
        n_agents=2,
        space_size=10.0,
        sensory_noise=0.0,
        source_position=(8.0, 5.0),
        source_gain=1.0,
        capture_radius=0.5,
    )
    conspecific_bodies = [PassthroughBody(), PassthroughBody()]
    conspecific_positions = [(1.0, 5.0), (3.0, 5.0)]
    unlimited_conspecific = ForageEnvironment(
        torus,
        conspecific_positions;
        headings=[0.0, pi],
        config=SwarmConfig(; conspecific_kwargs..., source_vision_range=nothing),
        rng=MersenneTwister(4),
    )
    limited_conspecific = ForageEnvironment(
        torus,
        conspecific_positions;
        headings=[0.0, pi],
        config=SwarmConfig(; conspecific_kwargs..., source_vision_range=1.5),
        rng=MersenneTwister(4),
    )
    unlimited_conspecific_inputs = observe(unlimited_conspecific, conspecific_bodies)
    limited_conspecific_inputs = observe(limited_conspecific, conspecific_bodies)
    @test maximum(@view(unlimited_conspecific_inputs[1][1:64])) > 0.0
    @test limited_conspecific_inputs[1][1:64] == unlimited_conspecific_inputs[1][1:64]
    @test limited_conspecific_inputs[2][1:64] == unlimited_conspecific_inputs[2][1:64]
end

@testset "Forage seeded determinism" begin
    kwargs = (
        node=:falandays_base,
        n_agents=5,
        n_nodes=35,
        ticks=18,
        seed=42,
        sensory_noise=0.0,
        source_gain=1.25,
        conspecific_vision=true,
        record=Symbol[],
    )
    a = simulate(:forage; kwargs...)
    b = simulate(:forage; kwargs...)
    @test a.metrics.mean_distance_to_source == b.metrics.mean_distance_to_source
end
