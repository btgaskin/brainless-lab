using BrainlessLab
using Test

function _io_target(id, task)
    return EvaluationTarget(
        id,
        default_composition(DEFAULT_REGISTRY, :falandays, task),
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

@testset "version-one TOML plan round trips" begin
    target = _io_target(:tracking, :tracking)
    plans = (
        ProfilePlan(:profile, target; analyses=(:branching_ratio_mr,), record_every=2),
        SweepPlan(
            :sweep,
            target;
            axes=(SweepAxis(:leak, (0.1, 0.5)),),
            mode=:one_at_a_time,
            max_rollouts=100,
        ),
        AblationPlan(:ablate, target; ablations=(:freeze_plasticity,)),
        EvolutionPlan(
            :evolve,
            target;
            heldout_targets=(_io_target(:pong, :pong),),
            generations=2,
            popsize=4,
        ),
        BenchmarkPlan(
            :benchmark,
            (
                BenchmarkCasePlan(:tracking, (target,); baseline=:tracking),
                BenchmarkCasePlan(
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
        @test plan_document(parsed)["format_version"] == 1
    end
end

@testset "plan IO preserves the interaction cycle" begin
    base = default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    composition = CompositionSpec(
        :timed_tracking,
        base.node,
        base.task;
        n_nodes=base.n_nodes,
        parameters=base.parameters,
        interaction_cycle=FixedRateCycle(7),
    )
    plan = ProfilePlan(
        :timed_profile,
        EvaluationTarget(:tracking, composition, EvaluationSpec(horizon=12)),
    )
    path = tempname() * ".toml"
    write_plan(path, plan)
    parsed = read_plan(path)
    @test parsed.target.composition.interaction_cycle == FixedRateCycle(7)
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
