using BrainlessLab
using Test
using .BrainlessLabTestUtils: operation_registry, operation_target

function _small_sweep_target(; blocks=1, trials=2, horizon=3)
    return operation_target(
        :tracking,
        :tracking;
        blocks=blocks,
        trials=trials,
        horizon=horizon,
        root_seed=811,
        aggregate=:mean,
    )
end

@testset "sweep plan resolution" begin
    registry = operation_registry()
    target = _small_sweep_target()
    default_plan = SweepPlan(
        :default_axes,
        target;
        axes=(),
        mode=:factorial,
        max_rollouts=100,
    )
    resolved_default = BrainlessLab.resolve(default_plan, registry)
    @test Tuple(axis.parameter for axis in resolved_default.axes) ==
          (:gain, :bias)
    @test length(resolved_default.cells) == 4
    @test resolved_default.rollouts == 8

    axes = (
        BrainlessLab.SweepAxis(:gain, (0.5, 1.0)),
        BrainlessLab.SweepAxis(:bias, (-0.25, 0.25)),
    )
    factorial = BrainlessLab.resolve(
        SweepPlan(:factorial, target; axes, max_rollouts=8),
        registry,
    )
    @test length(factorial.cells) == 4
    @test factorial.rollouts == 8
    @test factorial.cells[4].parameters ==
          Dict{Symbol,Any}(:gain => 1.0, :bias => 0.25)

    one_at_a_time = BrainlessLab.resolve(
        SweepPlan(:oaat, target; axes, mode=:one_at_a_time, max_rollouts=8),
        registry,
    )
    @test length(one_at_a_time.cells) == 4
    @test all(cell -> length(cell.parameters) == 1, one_at_a_time.cells)

    @test_throws ArgumentError BrainlessLab.resolve(
        SweepPlan(:too_large, target; axes, max_rollouts=7),
        registry,
    )
    @test_throws KeyError BrainlessLab.resolve(
        SweepPlan(
            :missing_parameter,
            target;
            axes=(BrainlessLab.SweepAxis(:missing, (1.0,)),),
        ),
        registry,
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        SweepPlan(
            :invalid_value,
            target;
            axes=(BrainlessLab.SweepAxis(:gain, (3.0,)),),
        ),
        registry,
    )
end

@testset "sweep execution preserves paired seeds" begin
    registry = operation_registry()
    target = _small_sweep_target()
    plan = SweepPlan(
        :paired_sweep,
        target;
        axes=(BrainlessLab.SweepAxis(:gain, (0.5, 1.0)),),
        mode=:one_at_a_time,
        max_rollouts=4,
    )
    result = BrainlessLab.execute(BrainlessLab.resolve(plan, registry))
    output = BrainlessLab.tables(result)
    compact = BrainlessLab.summary(result)

    @test length(output.trials) == 4
    @test length(output.cells) == 2
    @test compact.n_cells == 2
    @test compact.n_rollouts == 4
    @test all(row -> isfinite(row.raw_score), output.trials)
    @test all(row -> row.profile_metric === :mean_abs_error_deg, output.trials)
    @test all(row -> row.profile_direction === :lower, output.cells)
    @test all(row -> isfinite(row.profile_value), output.cells)
    @test all(row -> row.normalized_n == 2, output.cells)
    @test all(
        row -> row.normalized_censored_count ==
               row.normalized_floor_count + row.normalized_ceiling_count,
        output.cells,
    )

    for trial in 1:2
        paired = filter(row -> row.block == 1 && row.trial == trial, output.trials)
        @test length(paired) == 2
        @test length(unique(row.topology_seed for row in paired)) == 1
        @test length(unique(row.world_seed for row in paired)) == 1
    end
end
