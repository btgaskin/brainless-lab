using BrainlessLab
using Test

function _ablation_registry()
    registry = RegistrySet()
    register!(registry, falandays_node_spec())
    register!(registry, task_spec(DEFAULT_REGISTRY, :tracking))
    return registry
end

function _ablation_target()
    reference = default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    composition = CompositionSpec(
        :tracking_ablation_smoke,
        reference.node,
        reference.task;
        n_nodes=8,
        parameters=reference.parameters,
    )
    evaluation = EvaluationSpec(
        blocks=1,
        trials_per_block=2,
        horizon=3,
        root_seed=812,
        aggregate=:mean,
    )
    return EvaluationTarget(:tracking, composition, evaluation)
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

function _register_falandays_ablations!(registry)
    freeze = AblationSpec(
        :freeze_plasticity,
        source -> _with_ablation_parameter(
            source,
            :freeze_plasticity,
            :learn_on,
            false,
        );
        stage=:composition,
        required_capabilities=(:online_plasticity,),
    )
    clamp = AblationSpec(
        :clamp_target,
        source -> _with_ablation_parameter(
            source,
            :clamp_target,
            :lrate_targ,
            0.0,
        );
        stage=:composition,
        required_capabilities=(:homeostatic_target,),
    )
    register!(
        registry,
        :ablations,
        ImplementationSpec(:freeze_plasticity, freeze),
    )
    register!(
        registry,
        :ablations,
        ImplementationSpec(:clamp_target, clamp),
    )
    return registry
end

@testset "ablation plan resolution is explicit" begin
    registry = _register_falandays_ablations!(_ablation_registry())
    target = _ablation_target()
    plan = AblationPlan(
        :falandays_ablations,
        target;
        ablations=(:freeze_plasticity, :clamp_target),
    )
    resolved = BrainlessLab.resolve(plan, registry)

    @test Tuple(case.id for case in resolved.cases) ==
          (:baseline, :freeze_plasticity, :clamp_target)
    @test resolved.cases[1].ablation === nothing
    @test resolved.cases[2].target.composition.parameters[:learn_on] == false
    @test resolved.cases[3].target.composition.parameters[:lrate_targ] == 0.0

    missing_capability = AblationSpec(
        :requires_dendrites,
        source -> _with_ablation_parameter(source, :dendrites, :learn_on, false);
        required_capabilities=(:dendrites,),
    )
    register!(
        registry,
        :ablations,
        ImplementationSpec(:requires_dendrites, missing_capability),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:bad_capability, target; ablations=(:requires_dendrites,)),
        registry,
    )

    reservoir_stage = AblationSpec(
        :reservoir_stage,
        identity;
        stage=:reservoir,
    )
    register!(
        registry,
        :ablations,
        ImplementationSpec(:reservoir_stage, reservoir_stage),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:bad_stage, target; ablations=(:reservoir_stage,)),
        registry,
    )

    register!(
        registry,
        :ablations,
        ImplementationSpec(:raw_intervention, FreezePlasticity),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:raw, target; ablations=(:raw_intervention,)),
        registry,
    )

    register!(
        registry,
        :ablations,
        ImplementationSpec(
            :baseline,
            AblationSpec(:baseline, source -> deepcopy(source)),
        ),
    )
    @test_throws ArgumentError BrainlessLab.resolve(
        AblationPlan(:reserved, target; ablations=(:baseline,)),
        registry,
    )
end

@testset "ablation execution includes paired baseline" begin
    registry = _register_falandays_ablations!(_ablation_registry())
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

    for trial in 1:2
        paired = filter(row -> row.block == 1 && row.trial == trial, output.trials)
        @test length(paired) == 3
        @test length(unique(row.topology_seed for row in paired)) == 1
        @test length(unique(row.world_seed for row in paired)) == 1
        @test length(unique(row.task_seed for row in paired)) == 1
    end
end
