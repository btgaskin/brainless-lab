using BrainlessLab
using Test

@testset "typed composition catalog" begin
    registry = RegistrySet()
    @test isempty(nodes(registry))
    register!(registry, falandays_node_spec())
    @test nodes(registry) == [:falandays]
    @test_throws ArgumentError register!(registry, falandays_node_spec())

    falandays = node_spec(DEFAULT_REGISTRY, :falandays)
    @test falandays.stability === :reference
    @test falandays.genome_type === FalandaysParams
    @test node_parameter_set(falandays, :sweep) == (:leak, :lrate_wmat)
    @test node_parameter_set(falandays, :evolve) == (
        :leak,
        :lrate_wmat,
        :lrate_targ,
        :threshold_mult,
        :targ_min,
        :input_weight,
        :weight_init_std,
    )
    @test node_parameter(falandays, :link_p).owner === :reservoir
    @test_throws KeyError node_parameter(falandays, :n_nodes)

    @test task_spec(DEFAULT_REGISTRY, :wall).status === :experimental
    @test task_spec(DEFAULT_REGISTRY, :tracking).status === :reference
    @test task_spec(DEFAULT_REGISTRY, :pong).status === :reference
    @test Set(tasks(DEFAULT_REGISTRY; tag=:benchmark)) == Set((:tracking, :pong))
    @test :branching_ratio_mr in analyses(DEFAULT_REGISTRY; task=:tracking)
    @test :freeze_plasticity in ablations(DEFAULT_REGISTRY)
    @test :pong_hitrate ∉ tasks(DEFAULT_REGISTRY)
    @test all(task -> task in tasks(DEFAULT_REGISTRY), (
        :cartpole_plank_easy,
        :cartpole_plank_medium,
        :cartpole_plank_hard,
        :cartpole_plank_hardest,
    ))

    tracking = default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    pong = default_composition(DEFAULT_REGISTRY, :falandays, :pong)
    wall = default_composition(DEFAULT_REGISTRY, :falandays, :wall)
    @test tracking.n_nodes == 200
    @test tracking.parameters[:input_weight] == 0.75
    @test tracking.parameters[:lrate_targ] == 0.01
    @test tracking.parameters[:weight_init_mode] === :excitatory
    @test pong.n_nodes == 500
    @test pong.parameters[:input_weight] == 2.75
    @test pong.parameters[:lrate_targ] == 0.1
    @test pong.parameters[:weight_init_mode] === :pong_mixed
    @test wall.n_nodes == 200
    @test_throws KeyError default_composition(
        DEFAULT_REGISTRY,
        :falandays,
        :cartpole_plank_easy,
    )

    bad = CompositionSpec(
        :bad,
        :falandays,
        :tracking;
        n_nodes=12,
        parameters=Dict(:unknown => 1.0),
    )
    @test_throws ArgumentError resolve_composition(bad, DEFAULT_REGISTRY)

    resolved = resolve_composition(tracking, DEFAULT_REGISTRY)
    @test resolved.parameters[:leak] == FalandaysParams().leak
    @test resolved.parameters[:lrate_wmat] == 1.0
    @test resolved.interaction_cycle === nothing

    atomic = RegistrySet()
    register!(atomic, falandays_node_spec())
    register!(atomic, task_spec(DEFAULT_REGISTRY, :tracking))
    first_default = CompositionSpec(:first_default, :falandays, :tracking; n_nodes=8)
    second_default = CompositionSpec(:second_default, :falandays, :tracking; n_nodes=8)
    register_default!(atomic, first_default)
    @test_throws ArgumentError register_default!(atomic, second_default)
    @test :second_default ∉ compositions(atomic)
end

@testset "CompositionSpec executes through named seed streams" begin
    composition = CompositionSpec(
        :tracking_smoke,
        :falandays,
        :tracking;
        n_nodes=12,
        parameters=Dict(
            :input_weight => 0.75,
            :lrate_wmat => 1.0,
            :lrate_targ => 0.01,
            :weight_init_mode => :excitatory,
            :rectify => false,
            :repair_masks => false,
        ),
    )
    first_run = simulate(composition; ticks=8, seed=19, record=())
    second_run = simulate(composition; ticks=8, seed=19, record=())
    @test first_run.metrics == second_run.metrics
    @test first_run.config.composition === :tracking_smoke
    @test first_run.config.n_nodes == 12
    @test first_run.config.seed_ledger == second_run.config.seed_ledger
    @test propertynames(first_run.config.seed_ledger[1]) == (
        :topology,
        :node_state,
        :world,
        :body,
        :task,
        :mechanism,
    )
    @test task_outcome(first_run).key === :track_score

    custom_target = EvaluationTarget(
        :custom_stream,
        composition,
        EvaluationSpec(
            horizon=2,
            root_seed=19,
            streams=(:topology, :world, :node_custom),
        ),
    )
    custom_batch = evaluate(custom_target)
    @test propertynames(only(only(custom_batch.trials).seeds)) ==
        (:topology, :world, :node_custom)

    missing_required = EvaluationTarget(
        :missing_topology,
        composition,
        EvaluationSpec(horizon=2, streams=(:world,)),
    )
    @test_throws ArgumentError evaluate(missing_required)
end
