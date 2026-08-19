using BrainlessLab
using Test
using .BrainlessLabTestUtils: operation_registry, operation_target

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

function _profile_series_fixture(sim; scale=1.0)
    block = Float64(sim.config.block)
    return AnalysisResult(
        statistics=(scale=Float64(scale),),
        series=AnalysisSeries(
            :fixture,
            :tick,
            [2.0, 4.0],
            (value=Float64(scale) .* [block, block + 1.0],),
        ),
    )
end

@testset "profile resolves registry contracts once" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    target = _profile_tracking_target()

    defaults = ProfilePlan(:tracking_defaults, target)
    validated = validate(defaults, registry)
    resolved = resolve(defaults, registry)
    @test validated === defaults
    @test Tuple(spec.key for spec in resolved.analyses) ==
          node_spec(registry, :falandays).default_analyses
    @test resolved.record_channels == (
        :acts,
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


@testset "profile resolves options and aggregates aligned series" begin
    registry = operation_registry()
    register!(
        registry,
        :analyses,
        BrainlessLab.ImplementationSpec(
            :profile_series_fixture,
            _profile_series_fixture;
            options=Dict(:scale => 1.0),
            metadata=(task=:tracking, required_channels=(:rate,)),
        ),
    )
    plan = ProfilePlan(
        :series_profile,
        operation_target(
            :tracking,
            :tracking;
            blocks=2,
            trials=2,
            horizon=8,
            root_seed=611,
        );
        analyses=(:profile_series_fixture,),
        analysis_options=Dict(
            :profile_series_fixture => Dict(:scale => 2.0),
        ),
        compute_every=Dict(:rate => 2),
    )
    resolved = resolve(plan, registry)
    @test resolved.analysis_options[:profile_series_fixture][:scale] == 2.0
    @test resolved.compute_every == Dict(:rate => 2)

    result = execute(resolved)
    series = BrainlessLab.tables(result).analysis_series
    @test length(series) == 2
    @test all(row -> row.n_trials == 4, series)
    @test series[1].mean == 3.0
    @test series[2].mean == 5.0
    @test series[1].median == 3.0
    @test length(result.analysis_series_rows) == 8

    record = write_record(
        plan,
        result;
        registry,
        root=mktempdir(),
        id="profile-series-record",
    )
    @test isfile(joinpath(record, "data", "analysis_series.csv"))
    @test occursin(
        "data/analysis_series.csv",
        read(joinpath(record, "record.toml"), String),
    )

    @test_throws ArgumentError resolve(
        ProfilePlan(
            :bad_options,
            operation_target(:tracking, :tracking; horizon=8);
            analyses=(:profile_series_fixture,),
            analysis_options=Dict(
                :profile_series_fixture => Dict(:unknown => 2.0),
            ),
        ),
        registry,
    )
end

@testset "profile executes every trial and emits standard tables" begin
    registry = operation_registry()
    target = operation_target(
        :tracking,
        :tracking;
        blocks=2,
        trials=2,
        horizon=8,
        root_seed=611,
    )
    plan = ProfilePlan(
        :tracking_heading_profile,
        target;
        analyses=(:heading_error,),
        record_every=2,
    )

    resolved = resolve(plan, registry)
    @test resolved.record_channels == (:scene,)
    result = execute(resolved)
    output = BrainlessLab.tables(result)
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
    @test report.normalized_n == 4
    @test report.normalized_censored_count ==
          report.normalized_floor_count + report.normalized_ceiling_count
    @test all(item -> item.n_trials == 4, report.analysis_statistics)
end

@testset "profile analysis failures retain trial context" begin
    registry = operation_registry()
    register!(
        registry,
        :analyses,
        BrainlessLab.ImplementationSpec(
            :profile_failure_fixture,
            _ -> error("deliberate analysis failure");
            metadata=(task=:tracking, required_channels=()),
        ),
    )
    plan = ProfilePlan(
        :failing_profile,
        operation_target(
            :tracking,
            :tracking;
            horizon=8,
            root_seed=611,
        );
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
