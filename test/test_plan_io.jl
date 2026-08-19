using BrainlessLab
using Test
using TOML

function _io_target(id, task)
    return EvaluationTarget(
        id,
        BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, task),
        EvaluationSpec(
            blocks=2,
            trials_per_block=3,
            horizon=12,
            warmup=1,
            construction_scope=:block,
            root_seed=44,
            aggregate=:none,
        ),
    )
end

function _io_evolution_plan()
    target = EvaluationTarget(
        :ctrnn_tracking,
        CompositionSpec(
            :ctrnn_tracking,
            :compartmental_structured,
            :tracking;
            n_nodes=2,
        ),
        EvaluationSpec(horizon=1, aggregate=:mean),
    )
    run = BrainlessLab.Evolution.RunConfig(
        strategy=:sepcma,
        iterations=2,
        search_seed=44,
        initialisation=BrainlessLab.Evolution.NormalInitialisation(
            centre=:zero,
            scale=0.1,
        ),
        options=(population=4, reducer=:mean,),
    )
    return EvolutionPlan(:evolve, (target,); run)
end

function _read_plan_error(document)
    path = tempname() * ".toml"
    open(path, "w") do io
        TOML.print(io, document; sorted=true)
    end
    return try
        read_plan(path)
        nothing
    catch caught
        caught
    end
end

@testset "version-three TOML plan round trips" begin
    target = _io_target(:tracking, :tracking)
    evolution_target = EvaluationTarget(
        :ctrnn_tracking,
        CompositionSpec(
            :ctrnn_tracking,
            :compartmental_structured,
            :tracking;
            n_nodes=2,
        ),
        EvaluationSpec(horizon=1, aggregate=:mean),
    )
    evolution_run = BrainlessLab.Evolution.RunConfig(
        strategy=:sepcma,
        iterations=2,
        search_seed=44,
        initialisation=BrainlessLab.Evolution.NormalInitialisation(
            centre=:zero,
            scale=0.1,
        ),
        options=(population=4, reducer=:mean,),
    )
    plans = (
        ProfilePlan(:profile, target; analyses=(:branching_ratio_mr,), record_every=2),
        SweepPlan(
            :sweep,
            target;
            axes=(BrainlessLab.SweepAxis(:leak, (0.1, 0.5)),),
            mode=:one_at_a_time,
            max_rollouts=100,
        ),
        AblationPlan(:ablate, target; ablations=(:freeze_plasticity,)),
        EvolutionPlan(
            :evolve,
            (evolution_target,);
            run=evolution_run,
        ),
        BenchmarkPlan(
            :benchmark,
            (
                BrainlessLab.BenchmarkCasePlan(:tracking, (target,)),
                BrainlessLab.BenchmarkCasePlan(
                    :pong,
                    (_io_target(:pong, :pong),);
                    baseline=:pong,
                ),
            ),
        ),
    )
    for plan in plans
        path = tempname() * ".toml"
        write_plan(path, plan)
        parsed = read_plan(path)
        @test typeof(parsed).name.wrapper === typeof(plan).name.wrapper
        @test parsed.id === plan.id
        @test BrainlessLab.plan_document(parsed)["format_version"] == 3
    end
end

@testset "plan format version gates preserve version-two evolution" begin
    evolution = BrainlessLab.plan_document(_io_evolution_plan())
    evolution["format_version"] = 2
    path = tempname() * ".toml"
    open(path, "w") do io
        TOML.print(io, evolution; sorted=true)
    end
    @test read_plan(path) isa EvolutionPlan

    scheduled = BrainlessLab.plan_document(ProfilePlan(
        :scheduled,
        EvaluationTarget(
            :tracking,
            _io_target(:tracking, :tracking).composition,
            _io_target(:tracking, :tracking).evaluation;
            interventions=(ScheduledIntervention(3, :freeze_plasticity),),
        );
        analyses=(:branching_ratio_mr,),
    ))
    scheduled["format_version"] = 2
    @test _read_plan_error(scheduled) isa ArgumentError

    configured = BrainlessLab.plan_document(ProfilePlan(
        :configured,
        _io_target(:tracking, :tracking);
        analyses=(:branching_ratio_mr,),
        analysis_options=Dict(:branching_ratio_mr => Dict(:kmax => 5)),
    ))
    configured["format_version"] = 2
    @test _read_plan_error(configured) isa ArgumentError
end

@testset "plan IO preserves scheduled interventions and profile settings" begin
    base = _io_target(:tracking, :tracking)
    target = EvaluationTarget(
        base.id,
        base.composition,
        base.evaluation;
        interventions=(
            ScheduledIntervention(7, :freeze_plasticity),
            ScheduledIntervention(3, :clamp_target),
        ),
        topology_key=:falandays_tracking,
    )
    plan = ProfilePlan(
        :scheduled_profile,
        target;
        analyses=(:branching_ratio_mr_windowed,),
        record_every=1,
        analysis_options=Dict(
            :branching_ratio_mr_windowed => Dict(:window => 5),
        ),
        compute_every=Dict(:rate => 2),
    )
    path = tempname() * ".toml"
    write_plan(path, plan)
    parsed = read_plan(path)
    @test [(item.tick, item.verb) for item in parsed.target.interventions] == [
        (3, :clamp_target),
        (7, :freeze_plasticity),
    ]
    @test parsed.target.topology_key === :falandays_tracking
    @test parsed.analysis_options[:branching_ratio_mr_windowed][:window] == 5
    @test parsed.compute_every == Dict(:rate => 2)
end

@testset "plan IO preserves interface axes and topology keys" begin
    base = CompositionSpec(
        :gain_tracking,
        :falandays,
        :tracking;
        n_nodes=200,
        interface=InterfaceSpec(input_gain=8.0),
    )
    target = EvaluationTarget(
        :gain_tracking,
        base,
        EvaluationSpec(horizon=2_000);
        topology_key=:falandays_direct_v1,
    )
    plan = SweepPlan(
        :gain_tracking,
        target;
        axes=(BrainlessLab.SweepAxis(
            :input_gain,
            (1.0, 8.0);
            scope=:interface,
        ),),
    )
    path = tempname() * ".toml"
    write_plan(path, plan)
    parsed = read_plan(path)
    @test parsed.target.composition.interface.input_gain == 8.0
    @test parsed.target.topology_key === :falandays_direct_v1
    @test only(parsed.axes).scope === :interface
end

@testset "anchor-only benchmark TOML omits a baseline" begin
    target = _io_target(:tracking, :tracking)
    plan = BenchmarkPlan(
        :anchor_only,
        (BrainlessLab.BenchmarkCasePlan(:tracking, (target,)),),
    )
    document = BrainlessLab.plan_document(plan)
    @test !haskey(only(document["benchmark"]["cases"]), "baseline")

    path = tempname() * ".toml"
    write_plan(path, plan)
    parsed = read_plan(path)
    @test only(parsed.cases).baseline === nothing
end

@testset "plan IO preserves the interaction cycle" begin
    base = BrainlessLab.default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    composition = CompositionSpec(
        :timed_tracking,
        base.node,
        base.task;
        n_nodes=base.n_nodes,
        parameters=base.parameters,
        interaction_cycle=BrainlessLab.FixedRateCycle(7),
    )
    plan = ProfilePlan(
        :timed_profile,
        EvaluationTarget(:tracking, composition, EvaluationSpec(horizon=12)),
    )
    path = tempname() * ".toml"
    write_plan(path, plan)
    parsed = read_plan(path)
    @test parsed.target.composition.interaction_cycle == BrainlessLab.FixedRateCycle(7)
end

@testset "plan IO resolves task defaults and rejects unknown options" begin
    composition = CompositionSpec(
        :configured_tracking,
        :falandays,
        :tracking;
        n_nodes=12,
        task_options=Dict(
            :sensory_gain => 1.5,
            :theta0 => nothing,
        ),
    )
    plan = ProfilePlan(
        :configured_tracking,
        EvaluationTarget(
            :tracking,
            composition,
            EvaluationSpec(horizon=2),
        );
        analyses=(),
    )
    path = tempname() * ".toml"
    write_plan(path, plan)
    parsed = read_plan(path)
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    resolved = resolve(parsed, registry)
    @test resolved.composition.task_options[:sensory_gain] == 1.5
    @test resolved.composition.task_options[:movement_amp] == 10.0
    @test resolved.composition.task_options[:theta0] === nothing

    bad_composition = CompositionSpec(
        :misspelled_tracking,
        :falandays,
        :tracking;
        n_nodes=12,
        task_options=Dict(:sensory_gaim => 1.5),
    )
    bad_plan = ProfilePlan(
        :misspelled_tracking,
        EvaluationTarget(
            :tracking,
            bad_composition,
            EvaluationSpec(horizon=2),
        );
        analyses=(),
    )
    bad_path = tempname() * ".toml"
    write_plan(bad_path, bad_plan)
    parsed_bad = read_plan(bad_path)
    @test_throws ArgumentError validate(parsed_bad, DEFAULT_REGISTRY)
    @test_throws ArgumentError resolve(parsed_bad, DEFAULT_REGISTRY)
end

@testset "plan parser rejects unknown schema" begin
    path = tempname() * ".toml"
    open(path, "w") do io
        write(io, """
format = "brainlesslab-plan"
format_version = 1
operation = "profile"
id = "bad"
unknown = true
targets = []

[profile]
target = "missing"
""")
    end
    @test_throws ArgumentError read_plan(path)
end

@testset "plan parser rejects unknown nested keys" begin
    run_document = BrainlessLab.plan_document(_io_evolution_plan())
    run_document["evolve"]["run"]["bogus_run_key"] = 7
    run_error = _read_plan_error(run_document)
    @test run_error isa ArgumentError
    @test sprint(showerror, run_error) ==
          "ArgumentError: unknown evolution run keys: bogus_run_key"

    initialisation_document = BrainlessLab.plan_document(_io_evolution_plan())
    initialisation_document["evolve"]["run"]["initialisation"][
        "bogus_initialisation_key"
    ] = 7
    initialisation_error = _read_plan_error(initialisation_document)
    @test initialisation_error isa ArgumentError
    @test sprint(showerror, initialisation_error) ==
          "ArgumentError: unknown evolution run initialisation keys: " *
          "bogus_initialisation_key"

    sweep = SweepPlan(
        :sweep,
        _io_target(:tracking, :tracking);
        axes=(BrainlessLab.SweepAxis(:leak, (0.1, 0.5)),),
    )
    sweep_document = BrainlessLab.plan_document(sweep)
    only(sweep_document["sweep"]["axes"])["bogus_axis_key"] = 7
    sweep_error = _read_plan_error(sweep_document)
    @test sweep_error isa ArgumentError
    @test sprint(showerror, sweep_error) ==
          "ArgumentError: unknown sweep axis keys: bogus_axis_key"

    reference = BrainlessLab.Evolution.ModelReference(
        "records/example",
        "selected",
        :compartmental_structured,
        repeat("a", 64),
        repeat("b", 64),
    )
    model_target = EvaluationTarget(
        :saved_model,
        CompositionSpec(
            :saved_model,
            :compartmental_structured,
            :tracking;
            n_nodes=2,
        ),
        EvaluationSpec(horizon=1),
        model=reference,
    )
    model_document = BrainlessLab.plan_document(ProfilePlan(:saved_model, model_target))
    only(model_document["targets"])["model"]["bogus_model_key"] = 7
    model_error = _read_plan_error(model_document)
    @test model_error isa ArgumentError
    @test sprint(showerror, model_error) ==
          "ArgumentError: unknown model reference keys: bogus_model_key"
end

@testset "other plan tables retain strict key validation" begin
    target = _io_target(:tracking, :tracking)
    plans = (
        ("profile", ProfilePlan(:profile, target)),
        (
            "sweep",
            SweepPlan(
                :sweep,
                target;
                axes=(BrainlessLab.SweepAxis(:leak, (0.1, 0.5)),),
            ),
        ),
        (
            "ablate",
            AblationPlan(:ablate, target; ablations=(:freeze_plasticity,)),
        ),
        (
            "benchmark",
            BenchmarkPlan(
                :benchmark,
                (BrainlessLab.BenchmarkCasePlan(:tracking, (target,)),),
            ),
        ),
        ("evolve", _io_evolution_plan()),
    )
    for (section, plan) in plans
        document = BrainlessLab.plan_document(plan)
        document[section]["bogus_operation_key"] = 7
        error = _read_plan_error(document)
        @test error isa ArgumentError
        @test sprint(showerror, error) ==
              "ArgumentError: unknown $(section) keys: bogus_operation_key"
    end

    options_document = BrainlessLab.plan_document(_io_evolution_plan())
    options_document["evolve"]["run"]["options"]["bogus_option_key"] = 7
    options_error = _read_plan_error(options_document)
    @test options_error isa ArgumentError
    @test sprint(showerror, options_error) ==
          "ArgumentError: unknown :sepcma options: :bogus_option_key"

    for (table, context) in (
        ("composition", "composition"),
        ("evaluation", "evaluation"),
    )
        document = BrainlessLab.plan_document(ProfilePlan(:profile, target))
        document["targets"][1][table]["bogus_target_key"] = 7
        error = _read_plan_error(document)
        @test error isa ArgumentError
        @test sprint(showerror, error) ==
              "ArgumentError: unknown $(context) keys: bogus_target_key"
    end
end
