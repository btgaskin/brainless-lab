using BrainlessLab
using Test

module SweepOperation
using BrainlessLab
import BrainlessLab: execute, resolve, summary, tables, validate
include(joinpath(@__DIR__, "..", "src", "operations", "Sweep.jl"))
end

function _small_sweep_target(; blocks=1, trials=2, horizon=3)
    reference = default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    composition = CompositionSpec(
        :tracking_sweep_smoke,
        reference.node,
        reference.task;
        n_nodes=8,
        parameters=reference.parameters,
    )
    evaluation = EvaluationSpec(
        blocks=blocks,
        trials_per_block=trials,
        horizon=horizon,
        root_seed=811,
        aggregate=:mean,
    )
    return EvaluationTarget(:tracking, composition, evaluation)
end

@testset "sweep plan resolution" begin
    target = _small_sweep_target()
    default_plan = SweepPlan(
        :default_axes,
        target;
        axes=(),
        mode=:factorial,
        max_rollouts=100,
    )
    resolved_default = BrainlessLab.resolve(default_plan, DEFAULT_REGISTRY)
    @test Tuple(axis.parameter for axis in resolved_default.axes) ==
          (:leak, :lrate_wmat)
    @test length(resolved_default.cells) == 16
    @test resolved_default.rollouts == 32

    axes = (
        SweepAxis(:leak, (0.1, 0.5)),
        SweepAxis(:lrate_wmat, (0.1, 1.0)),
    )
    factorial = BrainlessLab.resolve(
        SweepPlan(:factorial, target; axes, max_rollouts=8),
        DEFAULT_REGISTRY,
    )
    @test length(factorial.cells) == 4
    @test factorial.rollouts == 8
    @test factorial.cells[4].parameters ==
          Dict{Symbol,Any}(:leak => 0.5, :lrate_wmat => 1.0)

    one_at_a_time = BrainlessLab.resolve(
        SweepPlan(:oaat, target; axes, mode=:one_at_a_time, max_rollouts=8),
        DEFAULT_REGISTRY,
    )
    @test length(one_at_a_time.cells) == 4
    @test all(cell -> length(cell.parameters) == 1, one_at_a_time.cells)

    @test_throws ArgumentError BrainlessLab.resolve(
        SweepPlan(:too_large, target; axes, max_rollouts=7),
        DEFAULT_REGISTRY,
    )
    @test_throws KeyError BrainlessLab.resolve(
        SweepPlan(
            :missing_parameter,
            target;
            axes=(SweepAxis(:missing, (1.0,)),),
        ),
        DEFAULT_REGISTRY,
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        SweepPlan(
            :invalid_value,
            target;
            axes=(SweepAxis(:leak, (2.0,)),),
        ),
        DEFAULT_REGISTRY,
    )
end

@testset "sweep execution preserves paired seeds" begin
    target = _small_sweep_target()
    plan = SweepPlan(
        :paired_sweep,
        target;
        axes=(
            SweepAxis(:leak, (0.1, 0.5)),
            SweepAxis(:lrate_wmat, (0.1, 1.0)),
        ),
        mode=:one_at_a_time,
        max_rollouts=8,
    )
    result = BrainlessLab.execute(BrainlessLab.resolve(plan, DEFAULT_REGISTRY))
    output = BrainlessLab.tables(result)
    compact = BrainlessLab.summary(result)

    @test length(output.trials) == 8
    @test length(output.cells) == 4
    @test compact.n_cells == 4
    @test compact.n_rollouts == 8
    @test all(row -> isfinite(row.raw_score), output.trials)

    for trial in 1:2
        paired = filter(row -> row.block == 1 && row.trial == trial, output.trials)
        @test length(paired) == 4
        @test length(unique(row.topology_seed for row in paired)) == 1
        @test length(unique(row.world_seed for row in paired)) == 1
        @test length(unique(row.task_seed for row in paired)) == 1
    end
end
