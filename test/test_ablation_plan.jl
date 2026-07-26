using BrainlessLab
using Test
using .BrainlessLabTestUtils: operation_registry, operation_target

function _ablation_registry()
    return operation_registry()
end

function _ablation_target()
    return operation_target(
        :tracking,
        :tracking;
        trials=2,
        horizon=3,
        root_seed=812,
        aggregate=:mean,
    )
end

function _with_ablation_parameter(
    source::CompositionSpec,
    id::Symbol,
    parameter::Symbol,
    value,
)
    parameters = copy(source.parameters)
    parameters[parameter] = value
    return CompositionSpec(
        Symbol(source.id, "__", id),
        source.node,
        source.task;
        body=source.body,
        n_agents=source.n_agents,
        n_nodes=source.n_nodes,
        parameters,
        task_options=source.task_options,
        body_options=source.body_options,
        interaction_cycle=source.interaction_cycle,
    )
end

function _register_test_ablations!(registry)
    freeze = BrainlessLab.AblationSpec(
        :freeze_plasticity,
        source -> _with_ablation_parameter(
            source,
            :freeze_plasticity,
            :gain,
            0.5,
        );
        stage=:composition,
        required_capabilities=(:online_plasticity,),
    )
    clamp = BrainlessLab.AblationSpec(
        :clamp_target,
        source -> _with_ablation_parameter(
            source,
            :clamp_target,
            :bias,
            -0.25,
        );
        stage=:composition,
        required_capabilities=(:homeostatic_target,),
    )
    register!(
        registry,
        :ablations,
        BrainlessLab.ImplementationSpec(:freeze_plasticity, freeze),
    )
    register!(
        registry,
        :ablations,
        BrainlessLab.ImplementationSpec(:clamp_target, clamp),
    )
    return registry
end

@testset "ablation plan resolution is explicit" begin
    registry = _register_test_ablations!(_ablation_registry())
    target = _ablation_target()
    plan = AblationPlan(
        :test_ablations,
        target;
        ablations=(:freeze_plasticity, :clamp_target),
    )
    resolved = BrainlessLab.resolve(plan, registry)

    @test Tuple(case.id for case in resolved.cases) ==
          (:baseline, :freeze_plasticity, :clamp_target)
    @test resolved.cases[1].ablation === nothing
    @test resolved.cases[2].target.composition.parameters[:gain] == 0.5
    @test resolved.cases[3].target.composition.parameters[:bias] == -0.25

    missing_capability = BrainlessLab.AblationSpec(
        :requires_dendrites,
        source -> _with_ablation_parameter(source, :dendrites, :gain, 0.25);
        required_capabilities=(:dendrites,),
    )
    register!(
        registry,
        :ablations,
        BrainlessLab.ImplementationSpec(:requires_dendrites, missing_capability),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:bad_capability, target; ablations=(:requires_dendrites,)),
        registry,
    )

    reservoir_stage = BrainlessLab.AblationSpec(
        :reservoir_stage,
        identity;
        stage=:reservoir,
    )
    register!(
        registry,
        :ablations,
        BrainlessLab.ImplementationSpec(:reservoir_stage, reservoir_stage),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:bad_stage, target; ablations=(:reservoir_stage,)),
        registry,
    )

    register!(
        registry,
        :ablations,
        BrainlessLab.ImplementationSpec(:raw_intervention, BrainlessLab.FreezePlasticity),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:raw, target; ablations=(:raw_intervention,)),
        registry,
    )

    register!(
        registry,
        :ablations,
        BrainlessLab.ImplementationSpec(
            :baseline,
            BrainlessLab.AblationSpec(:baseline, source -> deepcopy(source)),
        ),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:reserved, target; ablations=(:baseline,)),
        registry,
    )
end

@testset "ablation execution includes paired baseline" begin
    registry = _register_test_ablations!(_ablation_registry())
    plan = AblationPlan(
        :paired_ablations,
        _ablation_target();
        ablations=(:freeze_plasticity, :clamp_target),
    )
    result = BrainlessLab.execute(BrainlessLab.resolve(plan, registry))
    output = BrainlessLab.tables(result)
    compact = BrainlessLab.summary(result)

    @test length(output.trials) == 6
    @test length(output.cases) == 3
    @test compact.n_cases == 3
    @test compact.n_rollouts == 6
    @test first(output.cases).ablation === :none
    @test all(row -> isfinite(row.raw_score), output.trials)
    @test all(row -> row.normalized_n == 2, output.cases)
    @test all(
        row -> row.normalized_censored_count ==
               row.normalized_floor_count + row.normalized_ceiling_count,
        output.cases,
    )

    for trial in 1:2
        paired = filter(row -> row.block == 1 && row.trial == trial, output.trials)
        @test length(paired) == 3
        @test length(unique(row.topology_seed for row in paired)) == 1
        @test length(unique(row.world_seed for row in paired)) == 1
        @test length(unique(row.task_seed for row in paired)) == 1
    end
end
