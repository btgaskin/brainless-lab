using BrainlessLab
using Test

@testset "typed composition catalog" begin
    registry = RegistrySet()
    @test isempty(nodes(registry))
    register!(registry, BrainlessLab.falandays_node_spec())
    @test nodes(registry) == [:falandays]
    @test_throws ArgumentError register!(registry, BrainlessLab.falandays_node_spec())

    falandays = node_spec(DEFAULT_REGISTRY, :falandays)
    @test falandays.stability === :reference
    @test falandays.genome_type === FalandaysParams
    @test BrainlessLab.node_parameter_set(falandays, :sweep) == (:leak, :lrate_wmat)
    @test_throws KeyError BrainlessLab.node_parameter_set(falandays, :evolve)
    @test BrainlessLab.node_parameter(falandays, :link_p).owner === :reservoir
    @test_throws KeyError BrainlessLab.node_parameter(falandays, :n_nodes)

    @test BrainlessLab.task_spec(DEFAULT_REGISTRY, :wall).status === :reference
    @test BrainlessLab.task_spec(DEFAULT_REGISTRY, :tracking).status === :reference
    @test BrainlessLab.task_spec(DEFAULT_REGISTRY, :pong).status === :reference
    @test BrainlessLab.task_spec(DEFAULT_REGISTRY, :wall).minimum_scored_ticks == 200
    @test BrainlessLab.task_spec(DEFAULT_REGISTRY, :tracking).minimum_scored_ticks == 2_000
    @test BrainlessLab.task_spec(DEFAULT_REGISTRY, :pong).minimum_scored_ticks == 6_000
    @test BrainlessLab.PONG_HITRATE_TASK.minimum_scored_ticks == 6_000
    for task_name in (
        :cartpole,
        :cartpole_hard,
        :cartpole_swingup,
        :cartpole_long,
        :cartpole_plank_easy,
        :cartpole_plank_medium,
        :cartpole_plank_hard,
        :cartpole_plank_hardest,
        :torus,
        :forage,
        :shoal_forage,
    )
        task = BrainlessLab.task_spec(DEFAULT_REGISTRY, task_name)
        @test task.minimum_scored_ticks == task.default_window
    end
    @test Set(tasks(DEFAULT_REGISTRY; tag=:benchmark)) == Set((:tracking, :pong, :wall))
    @test tasks(DEFAULT_REGISTRY; tag=:frontier) == [:cartpole_plank_easy]
    @test :branching_ratio_mr in analyses(DEFAULT_REGISTRY; task=:tracking)
    @test :freeze_plasticity in ablations(DEFAULT_REGISTRY)
    @test :pong_hitrate ∉ tasks(DEFAULT_REGISTRY)
    @test all(task -> task in tasks(DEFAULT_REGISTRY), (
        :cartpole_plank_easy,
        :cartpole_plank_medium,
        :cartpole_plank_hard,
        :cartpole_plank_hardest,
    ))

    tracking = BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    pong = BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :pong)
    wall = BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :wall)
    @test tracking.n_nodes == 200
    @test tracking.parameters[:input_weight] == 0.75
    @test tracking.parameters[:lrate_targ] == 0.01
    @test tracking.parameters[:weight_init_mode] === :excitatory
    @test pong.n_nodes == 500
    @test pong.parameters[:input_weight] == 2.75
    @test pong.parameters[:lrate_targ] == 0.1
    @test pong.parameters[:weight_init_mode] === :pong_mixed
    @test wall.n_nodes == 200
    @test_throws KeyError BrainlessLab.default_composition(
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
    @test_throws ArgumentError BrainlessLab.resolve_composition(bad, DEFAULT_REGISTRY)

    resolved = BrainlessLab.resolve_composition(tracking, DEFAULT_REGISTRY)
    @test resolved.parameters[:leak] == FalandaysParams().leak
    @test resolved.parameters[:lrate_wmat] == 1.0
    @test resolved.task_options[:movement_amp] == 10.0
    @test resolved.task_options[:randomize_start] === true
    @test resolved.task_options[:theta0] === nothing
    @test isempty(resolved.body_options)
    @test resolved.interaction_cycle === nothing

    bad_task_option = CompositionSpec(
        :bad_task_option,
        :falandays,
        :tracking;
        n_nodes=12,
        task_options=Dict(:sensory_gaim => 1.0),
    )
    task_option_error = try
        resolve_composition(bad_task_option, DEFAULT_REGISTRY)
        nothing
    catch error
        error
    end
    @test task_option_error isa ArgumentError
    @test occursin(
        "task :tracking received unknown options [:sensory_gaim]",
        sprint(showerror, task_option_error),
    )

    body_registry = RegistrySet()
    register!(body_registry, node_spec(DEFAULT_REGISTRY, :falandays))
    register!(body_registry, BrainlessLab.task_spec(DEFAULT_REGISTRY, :tracking))
    register!(
        body_registry,
        :bodies,
        BrainlessLab.ImplementationSpec(
            :configured_body,
            () -> nothing;
            options=(radius=0.5, gain=1.0),
        ),
    )
    configured = CompositionSpec(
        :configured_body,
        :falandays,
        :tracking;
        body=:configured_body,
        n_nodes=12,
        body_options=Dict(:gain => 2.0),
    )
    resolved_body = resolve_composition(configured, body_registry)
    @test resolved_body.body_options == Dict(:radius => 0.5, :gain => 2.0)
    bad_body = CompositionSpec(
        :bad_body_option,
        :falandays,
        :tracking;
        body=:configured_body,
        n_nodes=12,
        body_options=Dict(:raduis => 0.5),
    )
    @test_throws ArgumentError resolve_composition(bad_body, body_registry)

    atomic = RegistrySet()
    register!(atomic, BrainlessLab.falandays_node_spec())
    register!(atomic, BrainlessLab.task_spec(DEFAULT_REGISTRY, :tracking))
    first_default = CompositionSpec(:first_default, :falandays, :tracking; n_nodes=8)
    second_default = CompositionSpec(:second_default, :falandays, :tracking; n_nodes=8)
    BrainlessLab.register_default!(atomic, first_default)
    @test_throws ArgumentError BrainlessLab.register_default!(atomic, second_default)
    @test :second_default ∉ BrainlessLab.compositions(atomic)
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
    first_run = simulate(composition; ticks=8, window=8, seed=19, record=())
    second_run = simulate(composition; ticks=8, window=8, seed=19, record=())
    @test first_run.metrics == second_run.metrics
    @test first_run.config.composition === :tracking_smoke
    @test first_run.config.n_nodes == 12
    @test first_run.config.seed_ledger == second_run.config.seed_ledger
    @test propertynames(first_run.config.seed_ledger[1]) == (
        :topology,
        :world,
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
    registry = RegistrySet()
    register!(registry, node_spec(DEFAULT_REGISTRY, :falandays))
    register!(
        registry,
        BrainlessLabTestUtils.task_with_minimum(:tracking, 1),
    )
    custom_batch = BrainlessLab.evaluate(custom_target; registry)
    @test propertynames(only(only(custom_batch.trials).seeds)) ==
        (:topology, :world, :node_custom)

    missing_required = EvaluationTarget(
        :missing_topology,
        composition,
        EvaluationSpec(horizon=2, streams=(:world,)),
    )
    @test_throws ArgumentError BrainlessLab.evaluate(missing_required; registry)
end

@testset "long convenience runs use the full scored interval" begin
    symbol_run = simulate(
        :tracking;
        node=:null_random,
        n_nodes=2,
        ticks=2_000,
        seed=7,
        record=(),
    )
    composition = CompositionSpec(
        :tracking_window_regression,
        :null_random,
        :tracking;
        n_nodes=2,
    )
    composition_run = simulate(composition; ticks=2_000, seed=7, record=())

    @test symbol_run.config.window == 2_000
    @test composition_run.config.window == 2_000
    @test task_outcome(symbol_run).window == 2_000
    @test task_outcome(composition_run).window == 2_000
end
