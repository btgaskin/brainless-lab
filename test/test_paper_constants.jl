using BrainlessLab
using Test

@testset "Falandays paper config table" begin
    @test paramdim(FalandaysParams) == 7
    @test length(pack_params(FalandaysParams())) == 7

    wall = falandays_paper_config(:wall)
    @test wall.nnodes == 200
    @test wall.input_amp == 4.0
    @test wall.lrate_wmat == 1.0
    @test wall.lrate_targ == 0.01
    @test wall.weight_init_mode === :excitatory
    @test wall.sensory_noise == 0.0
    @test !wall.sensory_noise_assumption
    @test wall.clip_sensory_noise

    tracking = falandays_paper_config(:tracking)
    @test tracking.nnodes == 200
    @test tracking.input_amp == 0.75
    @test tracking.lrate_wmat == 1.0
    @test tracking.lrate_targ == 0.01
    @test tracking.weight_init_mode === :excitatory
    @test tracking.sensory_noise == 0.0

    pong = falandays_paper_config(:pong)
    @test pong.nnodes == 500
    @test pong.input_amp == 2.75
    @test pong.lrate_wmat == 1.0
    @test pong.lrate_targ == 0.1
    @test pong.weight_init_mode === :pong_mixed
    @test PONG_TASK.score_key === :hit_rate

    collective = falandays_paper_config(:collective)
    @test collective.nnodes == 250
    @test collective.input_amp == 12.5
    @test collective.lrate_wmat == 0.10
    @test collective.lrate_targ == 0.01
    @test collective.weight_init_mode === :collective_dale_smallworld
end

@testset "Falandays base constructor defaults" begin
    faithful = FalandaysReservoir(5, 2, 2; seed=1, link_p=0.0, input_amp=4.0)
    @test faithful.rectify == false
    @test all(.!faithful.recurrent_mask)
    @test all(faithful.input_wmat .== 0.0)
    @test all(faithful.output_mask .== 0.0)

    excitatory = FalandaysReservoir(80, 4, 2; seed=2, link_p=0.4, input_amp=4.0)
    active_weights = excitatory.wmat0[excitatory.recurrent_mask]
    @test !isempty(active_weights)
    @test minimum(active_weights) > 3.0
    @test maximum(excitatory.input_wmat) == 4.0

    pong = FalandaysReservoir(
        120,
        8,
        2;
        seed=3,
        link_p=0.3,
        input_amp=2.75,
        weight_init_mode=:pong_mixed,
    )
    pong_active = pong.wmat0[pong.recurrent_mask]
    @test any(<(-0.5), pong_active)
    @test any(x -> -0.5 < x < 0.5, pong_active)
end

@testset "simulate injects task-specific Falandays base defaults" begin
    for task in (:wall, :tracking, :pong)
        cfg = falandays_paper_config(task)
        setup = BrainlessLab._build_ensemble(task, :falandays; ticks=1, seed=10, record=Symbol[])
        reservoir = setup.ensemble.agents[1].reservoir
        @test setup.n_nodes == cfg.nnodes
        @test reservoir.rectify == false
        @test reservoir.params.lrate_wmat == cfg.lrate_wmat
        @test reservoir.params.lrate_targ == cfg.lrate_targ
        @test maximum(reservoir.input_wmat) == cfg.input_amp
    end

    wall_setup = BrainlessLab._build_ensemble(:wall, :falandays; ticks=1, seed=10, record=Symbol[])
    wall_env = wall_setup.ensemble.environment.world
    @test wall_env isa WallEnv
    @test wall_env.sensory_noise == 0.0
    @test wall_env.clip_sensory_noise == true

    noisy_wall = BrainlessLab._build_ensemble(
        :wall,
        :falandays;
        ticks=1,
        seed=10,
        record=Symbol[],
        sensory_noise=0.1,
        clip_sensory_noise=false,
    ).ensemble.environment.world
    @test noisy_wall.sensory_noise == 0.1
    @test noisy_wall.clip_sensory_noise == false

    override = BrainlessLab._build_ensemble(
        :wall,
        :falandays;
        ticks=1,
        seed=10,
        record=Symbol[],
        n_nodes=12,
        input_amp=1.5,
        lrate_wmat=0.25,
    )
    override_reservoir = override.ensemble.agents[1].reservoir
    @test override.n_nodes == 12
    @test override_reservoir.params.lrate_wmat == 0.25
    @test maximum(override_reservoir.input_wmat) == 1.5
end

@testset "swarm Falandays path keeps legacy defaults explicit" begin
    setup = BrainlessLab._build_ensemble(
        :torus,
        :falandays;
        ticks=1,
        seed=4,
        record=Symbol[],
        n_agents=2,
        n_nodes=24,
    )
    reservoir = setup.ensemble.agents[1].reservoir
    @test setup.n_nodes == 24
    @test reservoir.rectify == true
    @test reservoir.params.lrate_wmat == FalandaysParams().lrate_wmat
    @test reservoir.params.lrate_targ == FalandaysParams().lrate_targ
end
