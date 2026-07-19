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
    layout = situated_sensor(agent.body)
    @test n_receptors(agent.reservoir) == 128
    @test n_sensors(layout) == 128
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

    # The compatibility facade still receives fully composed bodies so its
    # geometry and actuator contracts match the main runtime.
    bodies = [
        situated_embodiment(SituatedSensorLayout(source_bank=true); radius=agent_radius)
        for _ in 1:2
    ]
    inputs = sample!(environment, bodies)
    @test length(inputs[1]) == 128
    @test all(iszero, @view(inputs[1][1:64]))           # conspecific-blind
    @test maximum(@view(inputs[1][65:128])) ≈ 2.0       # source bank × source_gain

    before = copy(environment.positions)
    apply_commands!(environment, bodies, [zeros(3), zeros(3)])
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
    bodies = [situated_embodiment(SituatedSensorLayout(source_bank=true))]
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
    unlimited_inputs = sample!(unlimited, bodies)
    limited_inputs = sample!(limited, bodies)
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
    conspecific_bodies = [
        situated_embodiment(SituatedSensorLayout(source_bank=true))
        for _ in 1:2
    ]
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
    unlimited_conspecific_inputs = sample!(unlimited_conspecific, conspecific_bodies)
    limited_conspecific_inputs = sample!(limited_conspecific, conspecific_bodies)
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

@testset "situated routing precedence and complete provenance" begin
    exclusions = Set((:n_agents, :n_nodes, :link_p, :seed))
    @test BrainlessLab._SWARM_ENVIRONMENT_KWARGS ==
          Set(name for name in fieldnames(SituatedConfig) if !(name in exclusions))

    effects = (Exposure(:social, 0.2),)
    setup = BrainlessLab._build_ensemble(
        :forage,
        :falandays_base;
        ticks=1,
        seed=51,
        n_agents=2,
        n_nodes=10,
        record=Symbol[],
        env_kwargs=(vision_range=1.0,),
        environment_kwargs=(vision_range=2.0,),
        swarm_kwargs=(vision_range=3.0,),
        task_kwargs=(vision_range=4.0,),
        vision_range=5.0,
        conspecific_contact_radius=0.0,
        conspecific_contact_effects=effects,
        source_position=(7.0, 6.0),
        colours=[1, 0],
        n_colours=2,
    )
    environment = setup.ensemble.environment
    @test environment.config.vision_range == 5.0
    @test environment.config.conspecific_contact_radius == 0.0
    @test environment.config.conspecific_contact_effects == effects

    no_bare = BrainlessLab._build_ensemble(
        :torus,
        :falandays_base;
        ticks=1,
        seed=52,
        n_agents=2,
        n_nodes=10,
        record=Symbol[],
        env_kwargs=(vision_range=1.0,),
        environment_kwargs=(vision_range=2.0,),
        swarm_kwargs=(vision_range=3.0,),
        task_kwargs=(vision_range=4.0,),
    )
    @test no_bare.ensemble.environment.config.vision_range == 4.0
end

@testset "situated contact provenance and task-layer errors" begin
    effects = (Exposure(:social, 0.2),)
    sim = simulate(
        :forage;
        node=:falandays_base,
        ticks=1,
        seed=53,
        n_agents=2,
        n_nodes=10,
        record=Symbol[],
        conspecific_contact_radius=0.0,
        conspecific_contact_effects=effects,
        source_position=(7.0, 6.0),
        colours=[1, 0],
        n_colours=2,
    )
    config = sim.config.environment
    @test all(name -> hasproperty(config, name), fieldnames(SituatedConfig))
    @test config.conspecific_contact_radius == 0.0
    @test only(config.conspecific_contact_effects) ==
          (kind=:exposure, name=:social, amount=0.2)
    @test config.source_position == (7.0, 6.0)
    @test config.colours == [1, 0]
    @test length(config.initial_positions) == 2
    @test length(config.initial_headings) == 2
    @test length(config.source_gains) == 2

    err = try
        simulate(
            :wall;
            node=:falandays_base,
            ticks=1,
            n_nodes=10,
            record=Symbol[],
            conspecific_contact_radius=1.0,
        )
        nothing
    catch caught
        caught
    end
    @test err isa ArgumentError
    @test occursin("only valid for multi-agent task setups", sprint(showerror, err))
end
