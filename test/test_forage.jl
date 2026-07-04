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
    params = VENParams(agent_radius=0.5)
    bodies = [
        VENBody((4.0, 5.0), 0.0; params=params),
        VENBody((4.2, 5.0), 0.0; params=params),
    ]
    config = SwarmConfig(
        n_agents=2,
        space_size=10.0,
        sensory_noise=0.0,
        physical_coupling=true,
        conspecific_vision=false,
        source_position=(5.0, 5.0),
        source_gain=2.0,
        capture_radius=0.5,
        ven=params,
    )
    environment = ForageEnvironment(torus, bodies; config=config, rng=MersenneTwister(7))

    percepts = observe(environment, bodies)
    receptors_ = receptors(bodies[1], percepts[1])
    @test length(receptors_) == 128
    @test all(iszero, @view(receptors_[1:64]))
    @test maximum(@view(receptors_[65:128])) ≈ 2.0

    before = [body.pos for body in bodies]
    actuate!(environment, bodies, [zeros(3), zeros(3)])
    after = [body.pos for body in bodies]
    @test after != before
    @test tdistance(torus, after[1], after[2]) >= 2.0 * params.agent_radius - 1e-9
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
