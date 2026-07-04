using BrainlessLab, Random, Test

function _signalling_forage_environment(bodies; signal_range=2.0, signal_gain=1.0)
    config = SwarmConfig(
        n_agents=length(bodies),
        space_size=20.0,
        sensory_noise=0.0,
        conspecific_vision=false,
        source_position=(10.0, 10.0),
        source_gain=1.0,
        signalling=true,
        signal_range=signal_range,
        signal_gain=signal_gain,
    )
    return ForageEnvironment(Torus(20.0), bodies; config=config, rng=MersenneTwister(13))
end

@testset "Signalling morphology ports" begin
    silent = default_morphology(VENBody((0.0, 0.0), 0.0; source_bank=true, signalling=false))
    @test n_effectors(silent) == 3
    @test n_receptors(silent) == 128

    signalling = default_morphology(VENBody((0.0, 0.0), 0.0; source_bank=true, signalling=true))
    signalling_ports = ports(signalling)
    @test n_effectors(signalling) == 4
    @test n_receptors(signalling) == 128
    @test signalling_ports.effectors[end].id == :signal
    @test signalling_ports.receptors[VEN_ACOUSTIC_RECEPTOR_INDEX].id == :acoustic

    plain = VENMorphology()
    @test n_effectors(plain) == 3
end

@testset "Signalling reservoir sizing via simulate" begin
    setup = BrainlessLab._build_ensemble(
        :forage,
        :falandays_base;
        ticks=3,
        seed=5,
        n_agents=3,
        n_nodes=24,
        sensory_noise=0.0,
        signalling=true,
        record=[:effectors],
    )
    @test all(n_effectors(agent.reservoir) == 4 for agent in setup.ensemble.agents)

    sim = simulate(
        :forage;
        node=:falandays_base,
        ticks=4,
        seed=5,
        n_agents=3,
        n_nodes=24,
        sensory_noise=0.0,
        signalling=true,
        record=[:effectors],
    )
    signal_effectors = getchannel(sim.recorder, :effectors)
    @test sim.config.environment.signalling == true
    @test !isempty(signal_effectors)
    @test all(length(eff) == 4 for sample in signal_effectors for eff in sample)

    base_kwargs = (
        node=:falandays_base,
        ticks=4,
        seed=6,
        n_agents=3,
        n_nodes=24,
        sensory_noise=0.0,
        record=[:effectors],
    )
    default_sim = simulate(:forage; base_kwargs...)
    explicit_false = simulate(:forage; base_kwargs..., signalling=false)
    default_effectors = getchannel(default_sim.recorder, :effectors)
    false_effectors = getchannel(explicit_false.recorder, :effectors)
    @test default_sim.config.environment.signalling == false
    @test all(length(eff) == 3 for sample in default_effectors for eff in sample)
    @test default_effectors == false_effectors
end

@testset "Signalling hearing math" begin
    bodies = [
        VENBody((2.0, 2.0), 0.0),
        VENBody((3.0, 2.0), 0.0),
        VENBody((8.0, 2.0), 0.0),
        VENBody((2.0, 8.0), 0.0),
    ]
    env = _signalling_forage_environment(bodies; signal_range=2.0, signal_gain=1.25)

    env.last_signal .= [1.0, 0.0, 0.0, 0.0]
    self_inputs = observe(env, bodies)
    @test self_inputs[1][VEN_ACOUSTIC_RECEPTOR_INDEX] ≈ 0.0

    env.last_signal .= [0.0, 1.0, 0.0, 0.0]
    near_inputs = observe(env, bodies)
    near_expected = 1.25 * exp(-tdistance(env.torus, bodies[1].pos, bodies[2].pos) / 2.0)
    @test near_inputs[1][VEN_ACOUSTIC_RECEPTOR_INDEX] ≈ near_expected

    env.last_signal .= [0.0, 0.0, 1.0, 0.0]
    far_inputs = observe(env, bodies)
    far_expected = 1.25 * exp(-tdistance(env.torus, bodies[1].pos, bodies[3].pos) / 2.0)
    @test far_inputs[1][VEN_ACOUSTIC_RECEPTOR_INDEX] ≈ far_expected
    @test near_inputs[1][VEN_ACOUSTIC_RECEPTOR_INDEX] > far_inputs[1][VEN_ACOUSTIC_RECEPTOR_INDEX]

    close_bodies = [
        VENBody((5.0, 5.0), 0.0),
        VENBody((5.0, 5.0), 0.0),
        VENBody((5.0, 5.0), 0.0),
        VENBody((5.0, 5.0), 0.0),
    ]
    saturated = _signalling_forage_environment(close_bodies; signal_range=3.0, signal_gain=1.25)
    saturated.last_signal .= [0.0, 1.0, 1.0, 1.0]
    saturated_inputs = observe(saturated, close_bodies)
    @test saturated_inputs[1][VEN_ACOUSTIC_RECEPTOR_INDEX] ≈ 1.25
end

@testset "Signalling one tick delay" begin
    bodies = [
        VENBody((2.0, 2.0), 0.0),
        VENBody((3.0, 2.0), 0.0),
    ]
    env = _signalling_forage_environment(bodies)
    inputs = observe(env, bodies)
    @test all(input[VEN_ACOUSTIC_RECEPTOR_INDEX] == 0.0 for input in inputs)
end

@testset "Signalling leaves non-forage torus untouched" begin
    config = SwarmConfig(
        n_agents=3,
        space_size=10.0,
        sensory_noise=0.0,
        signalling=true,
    )
    env = TorusEnvironment(config; rng=MersenneTwister(17))
    @test all(!body.signalling for body in env.bodies)
    @test all(n_effectors(default_morphology(body)) == 3 for body in env.bodies)
end
