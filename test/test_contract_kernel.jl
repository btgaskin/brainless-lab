using Test
using BrainlessLab:
    AblationPlan,
    CompositionSpec,
    EquationSpec,
    EvaluationSpec,
    EvaluationTarget,
    ImplementationSpec,
    ParameterSpec,
    Registry,
    DEFAULT_REGISTRY,
    SeedStreamSpec,
    derive_seed,
    node_spec,
    register!,
    resolve,
    seed_stream_names,
    sweepable,
    validate_parameter

@testset "typed registry" begin
    registry = Registry{Symbol,Int}(:nodes)
    @test isempty(registry)
    @test register!(registry, :a, 1) == 1
    @test registry[:a] == 1
    @test length(registry) == 1
    @test collect(keys(registry)) == [:a]
    @test_throws ArgumentError register!(registry, :a, 2)
    @test_throws KeyError resolve(registry, :missing)
    @test_throws MethodError register!(registry, "b", 2)
    @test_throws MethodError register!(registry, :b, 2.0)
end

@testset "built-in node capabilities describe their mechanisms" begin
    expected = Dict(
        :falandays_noisy => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :sensory_noise,
            :receptor_profile,
        ),
        :falandays_extended => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :sensory_noise,
            :small_world_topology,
            :signed_weights,
            :receptor_profile,
        ),
        :falandays_hemispheric => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :hemispheric_topology,
        ),
        :falandays_oosawa => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :endogenous_drive,
            :receptor_profile,
        ),
        :falandays_dendritic => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :dendritic_eligibility,
        ),
        :falandays_spatial => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :spatial_topology,
        ),
        :falandays_delayed => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :spatial_topology,
            :conduction_delays,
        ),
        :sorn => (
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :intrinsic_plasticity,
        ),
        :compartmental_dense => (
            :spiking,
            :recurrent_weights,
            :compartmental_dynamics,
            :model_design,
        ),
        :compartmental_structured => (
            :spiking,
            :recurrent_weights,
            :compartmental_dynamics,
            :model_design,
        ),
        :null_random => (:spiking, :input_independent_control),
        :homeostatic_flow_v2 => (
            :continuous_state,
            :online_plasticity,
            :recurrent_weights,
            :intrinsic_homeostasis,
            :flow_control,
        ),
    )

    for (id, capabilities) in expected
        @test node_spec(DEFAULT_REGISTRY, id).capabilities == capabilities
    end
end

@testset "canonical ablations resolve for declared node capabilities" begin
    evaluation = EvaluationSpec(horizon=2)
    cases = (
        (
            node=:sorn,
            ablation=:freeze_plasticity,
            parameter=:learn_on,
            expected=false,
        ),
        (
            node=:homeostatic_flow_v2,
            ablation=:freeze_plasticity,
            parameter=:learn_on,
            expected=false,
        ),
        (
            node=:falandays_spatial,
            ablation=:clamp_target,
            parameter=:lrate_targ,
            expected=0.0,
        ),
    )
    for case in cases
        composition = CompositionSpec(
            Symbol(:capability_, case.node),
            case.node,
            :tracking;
            n_nodes=20,
        )
        target = EvaluationTarget(case.node, composition, evaluation)
        plan = AblationPlan(
            Symbol(:ablate_, case.node),
            target;
            ablations=(case.ablation,),
        )
        resolved = resolve(plan, DEFAULT_REGISTRY)
        @test resolved.cases[2].target.composition.parameters[case.parameter] ==
              case.expected
    end
end

@testset "implementation and equation metadata" begin
    implementation = ImplementationSpec(
        :falandays,
        identity;
        label="Falandays reference",
        origin="Falandays et al.",
        stability=:reference,
        tags=(:benchmark, :qualification),
        capabilities=(:plasticity, :spiking),
        metadata=(family=:homeostatic,),
    )
    @test implementation.key === :falandays
    @test implementation.tags == (:benchmark, :qualification)
    @test implementation.metadata.family === :homeostatic
    @test_throws ArgumentError ImplementationSpec(
        :invalid,
        identity;
        stability=:unknown,
    )
    @test_throws ArgumentError ImplementationSpec(
        :invalid,
        identity;
        tags=(:duplicate, :duplicate),
    )

    equation = EquationSpec(
        :activation,
        raw"a_n(t) = \lambda a_n(t-1) + I_n(t)";
        title="Leaky activation",
        variables=(
            :a => "node activation",
            :lambda => "leak coefficient",
        ),
        references=("Falandays2024",),
    )
    @test equation.name === :activation
    @test equation.variables[2] == (:lambda => "leak coefficient")
    @test_throws ArgumentError EquationSpec(:empty, "")
    @test_throws ArgumentError EquationSpec(
        :duplicate,
        "x";
        variables=(:x => "first", :x => "second"),
    )
    @test EquationSpec(
        :single_variable,
        "x";
        variables=:x => "value",
    ).variables == (:x => "value",)
end

@testset "parameter metadata" begin
    leak = ParameterSpec(
        :leak,
        0.25;
        owner=:node,
        validator=value -> 0.0 <= value <= 1.0,
        sweep=(0.1, 0.25, 0.5),
        description="activation retained between ticks",
    )
    @test leak.default == 0.25
    @test leak.datatype === Float64
    @test leak.sweep == (0.1, 0.25, 0.5)
    @test sweepable(leak)
    @test validate_parameter(leak, 0.75) == 0.75
    @test_throws ArgumentError validate_parameter(leak, 1.1)
    @test_throws ArgumentError validate_parameter(leak, 1)

    connectivity = ParameterSpec(
        :recurrent_connectivity,
        :sparse;
        owner=:reservoir,
        validator=value -> value in (:sparse, :dense),
    )
    @test connectivity.owner === :reservoir

    @test_throws ArgumentError ParameterSpec(
        :bad_default,
        2.0;
        validator=value -> 0 <= value <= 1,
    )
    @test_throws ArgumentError ParameterSpec(
        :bad_sweep,
        0.5;
        sweep=(0.2, 0.2),
    )
    @test_throws ArgumentError ParameterSpec(
        :bad_validator,
        0.5;
        validator=value -> value,
    )
end

@testset "evaluation and stable named streams" begin
    evaluation = EvaluationSpec(
        blocks=3,
        trials_per_block=4,
        horizon=7_200,
        warmup=100,
        construction_scope=:block,
        reset=:body_environment,
        root_seed=42,
        streams=(
            SeedStreamSpec(:environment),
            SeedStreamSpec(:node_construction),
            SeedStreamSpec(:bootstrap),
        ),
        aggregate=:median,
    )
    @test evaluation.blocks == 3
    @test evaluation.root_seed == UInt64(42)
    @test seed_stream_names(evaluation) ==
          (:environment, :node_construction, :bootstrap)

    environment_seed = derive_seed(evaluation, :environment, 1, 1)
    @test environment_seed == derive_seed(evaluation, "environment", 1, 1)
    @test environment_seed != derive_seed(evaluation, :environment, 1, 2)
    @test environment_seed != derive_seed(evaluation, :node_construction, 1, 1)
    @test environment_seed == UInt64(0x330373f0e97c4790)

    reordered = EvaluationSpec(
        horizon=7_200,
        root_seed=42,
        streams=(:bootstrap, :environment, :node_construction),
    )
    @test derive_seed(reordered, :environment, 1, 1) == environment_seed

    @test_throws ArgumentError EvaluationSpec(horizon=0)
    @test_throws ArgumentError EvaluationSpec(horizon=10, warmup=10)
    @test_throws ArgumentError EvaluationSpec(horizon=10, construction_scope=:episode)
    @test_throws ArgumentError EvaluationSpec(horizon=10, reset=:partial)
    @test_throws ArgumentError EvaluationSpec(horizon=10, aggregate=:standard_error)
    @test_throws ArgumentError EvaluationSpec(horizon=10, streams=(:trial, :trial))
    @test_throws KeyError derive_seed(evaluation, :optimizer, 1)
    @test_throws ArgumentError derive_seed(evaluation, :environment, -1)
end
