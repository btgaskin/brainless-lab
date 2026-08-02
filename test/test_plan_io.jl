using BrainlessLab
using Test

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

@testset "version-two TOML plan round trips" begin
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
        @test BrainlessLab.plan_document(parsed)["format_version"] == 2
    end
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
