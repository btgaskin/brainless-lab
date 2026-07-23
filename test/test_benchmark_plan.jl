using BrainlessLab
using Test

function _benchmark_target(id, task; leak=0.25, root_seed=55)
    config = falandays_paper_config(task)
    composition = CompositionSpec(
        Symbol(id, :_composition),
        :falandays,
        task;
        n_nodes=8,
        parameters=Dict(
            :leak => Float64(leak),
            :input_weight => config.input_amp,
            :lrate_wmat => config.lrate_wmat,
            :lrate_targ => config.lrate_targ,
            :weight_init_mode => config.weight_init_mode,
            :rectify => false,
            :repair_masks => false,
        ),
    )
    return EvaluationTarget(
        id,
        composition,
        EvaluationSpec(
            blocks=1,
            trials_per_block=2,
            horizon=3,
            root_seed=root_seed,
            aggregate=:none,
        ),
    )
end

@testset "benchmark keeps tasks separate and comparisons paired" begin
    tracking_base = _benchmark_target(:tracking_base, :tracking)
    tracking_leak = _benchmark_target(:tracking_leak, :tracking; leak=0.5)
    pong_base = _benchmark_target(:pong_base, :pong)
    plan = BenchmarkPlan(
        :core_smoke,
        (
            BenchmarkCasePlan(
                :tracking,
                (tracking_base, tracking_leak);
                baseline=:tracking_base,
            ),
            BenchmarkCasePlan(:pong, (pong_base,); baseline=:pong_base),
        ),
    )
    result = execute(plan)
    result_tables = tables(result)
    @test result isa BenchmarkResult
    @test length(result_tables.trials) == 6
    @test Set(row.case for row in result_tables.statistics) == Set((:tracking, :pong))
    @test length(result_tables.contrasts) == 1
    @test result_tables.contrasts[1].condition === :tracking_leak
    @test result_tables.contrasts[1].n == 2
    @test summary(result).cases == (:tracking, :pong)
    @test !hasproperty(summary(result), :aggregate)

    unpaired = _benchmark_target(:unpaired, :tracking; root_seed=56)
    bad = BenchmarkPlan(
        :bad,
        (BenchmarkCasePlan(
            :tracking,
            (tracking_base, unpaired);
            baseline=:tracking_base,
        ),),
    )
    @test_throws ArgumentError resolve(bad, DEFAULT_REGISTRY)
end

