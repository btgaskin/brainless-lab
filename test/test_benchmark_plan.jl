using BrainlessLab
using Test
using .BrainlessLabTestUtils: operation_registry, operation_target

function _benchmark_target(id, task; gain=1.0, root_seed=55)
    return operation_target(
        id,
        task;
        parameters=Dict{Symbol,Any}(:gain => Float64(gain)),
        trials=2,
        horizon=3,
        root_seed=root_seed,
        aggregate=:none,
    )
end

@testset "benchmark keeps tasks separate and comparisons paired" begin
    registry = operation_registry()
    tracking_base = _benchmark_target(:tracking_base, :tracking)
    tracking_low_gain = _benchmark_target(:tracking_low_gain, :tracking; gain=0.5)
    pong_base = _benchmark_target(:pong_base, :pong)
    plan = BenchmarkPlan(
        :core_smoke,
        (
            BenchmarkCasePlan(
                :tracking,
                (tracking_base, tracking_low_gain);
                baseline=:tracking_base,
            ),
            BenchmarkCasePlan(:pong, (pong_base,)),
        ),
    )
    result = execute(plan; registry)
    result_tables = tables(result)
    @test result isa BenchmarkResult
    @test length(result_tables.trials) == 6
    @test Set(row.case for row in result_tables.statistics) == Set((:tracking, :pong))
    @test length(result_tables.contrasts) == 1
    @test result.plan.cases[2].baseline === nothing
    @test result_tables.contrasts[1].condition === :tracking_low_gain
    @test result_tables.contrasts[1].n == 2
    @test hasproperty(result_tables.contrasts[1], :raw_ci_lower)
    @test result_tables.contrasts[1].interval_method === :paired_student_t_95
    @test all(row -> row.interval_method === :student_t_95, result_tables.statistics)
    @test summary(result).cases == (:tracking, :pong)
    @test !hasproperty(summary(result), :aggregate)
    @test_throws ArgumentError BenchmarkCasePlan(
        :missing_baseline,
        (tracking_base, tracking_low_gain),
    )

    unpaired = _benchmark_target(:unpaired, :tracking; root_seed=56)
    bad = BenchmarkPlan(
        :bad,
        (BenchmarkCasePlan(
            :tracking,
            (tracking_base, unpaired);
            baseline=:tracking_base,
        ),),
    )
    @test_throws ArgumentError resolve(bad, registry)

    cross_task = BenchmarkPlan(
        :cross_task,
        (BenchmarkCasePlan(
            :invalid,
            (tracking_base, pong_base);
            baseline=:tracking_base,
        ),),
    )
    @test_throws ArgumentError resolve(cross_task, registry)

    mismatched_protocol = EvaluationTarget(
        :mismatched_protocol,
        tracking_low_gain.composition,
        EvaluationSpec(
            blocks=1,
            trials_per_block=2,
            horizon=4,
            root_seed=55,
            aggregate=:none,
        ),
    )
    bad_protocol = BenchmarkPlan(
        :bad_protocol,
        (BenchmarkCasePlan(
            :tracking,
            (tracking_base, mismatched_protocol);
            baseline=:tracking_base,
        ),),
    )
    @test_throws ArgumentError resolve(bad_protocol, registry)
end
