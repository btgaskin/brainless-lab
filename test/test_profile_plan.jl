using BrainlessLab
using Test

Base.include(
    BrainlessLab,
    joinpath(@__DIR__, "..", "src", "operations", "Profile.jl"),
)

function _profile_tracking_target(; blocks=1, trials=2, horizon=8)
    composition = CompositionSpec(
        :profile_tracking_smoke,
        :falandays,
        :tracking;
        n_nodes=8,
        parameters=Dict(
            :input_weight => 0.75,
            :lrate_wmat => 1.0,
            :lrate_targ => 0.01,
            :weight_init_mode => :excitatory,
            :rectify => false,
            :repair_masks => false,
        ),
    )
    evaluation = EvaluationSpec(
        blocks=blocks,
        trials_per_block=trials,
        horizon=horizon,
        root_seed=611,
    )
    return EvaluationTarget(:tracking, composition, evaluation)
end

@testset "profile resolves registry contracts once" begin
    registry = RegistrySet()
    register_builtins!(registry)
    target = _profile_tracking_target()

    defaults = ProfilePlan(:tracking_defaults, target)
    validated = validate(defaults, registry)
    resolved = resolve(defaults, registry)
    @test validated === defaults
    @test Tuple(spec.key for spec in resolved.analyses) ==
          node_spec(registry, :falandays).default_analyses
    @test resolved.record_channels == (
        :acts,
        :rate,
        :spectral_radius,
        :spikes,
        :targets,
    )

    wrong_task = ProfilePlan(
        :wrong_task_analysis,
        target;
        analyses=(:ball_paddle_distance,),
    )
    @test_throws ArgumentError validate(wrong_task, registry)
    @test_throws KeyError validate(
        ProfilePlan(:unknown_analysis, target; analyses=(:not_registered,)),
        registry,
    )
end

@testset "profile executes every trial and emits two tables" begin
    registry = RegistrySet()
    register_builtins!(registry)
    target = _profile_tracking_target(blocks=2, trials=2)
    plan = ProfilePlan(
        :tracking_heading_profile,
        target;
        analyses=(:heading_error,),
        record_every=2,
    )

    resolved = resolve(plan, registry)
    @test resolved.record_channels == (:scene,)
    result = execute(resolved)
    output = tables(result)
    report = BrainlessLab.summary(result)

    @test result isa BrainlessLab.ProfileResult
    @test length(result.batch.trials) == 4
    @test length(output.task) == 4
    @test all(row -> row.score_key === :track_score, output.task)
    @test !isempty(output.analyses)
    @test all(row -> row.analysis === :heading_error, output.analyses)
    @test Set(row.statistic for row in output.analyses) ==
          Set((:n, :finite_n, :mean, :std, :minimum, :maximum))
    @test report.plan === :tracking_heading_profile
    @test report.blocks == 2
    @test report.trials == 4
    @test report.analyses == (:heading_error,)
    @test report.record_channels == (:scene,)
    @test isfinite(report.raw_score_mean)
    @test all(item -> item.n_trials == 4, report.analysis_statistics)
end

@testset "profile analysis failures retain trial context" begin
    registry = RegistrySet()
    register_builtins!(registry)
    register!(
        registry,
        :analyses,
        ImplementationSpec(
            :profile_failure_fixture,
            _ -> error("deliberate analysis failure");
            metadata=(task=:tracking, required_channels=()),
        ),
    )
    plan = ProfilePlan(
        :failing_profile,
        _profile_tracking_target(trials=1);
        analyses=(:profile_failure_fixture,),
    )

    failure = try
        execute(resolve(plan, registry))
        nothing
    catch error
        error
    end
    @test failure isa BrainlessLab.ProfileAnalysisError
    @test failure.analysis === :profile_failure_fixture
    @test failure.block == 1
    @test failure.trial == 1
    @test occursin("deliberate analysis failure", sprint(showerror, failure))
end
