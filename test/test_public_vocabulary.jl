using Test

@testset "public documentation uses current vocabulary and canonical paths" begin
    root = normpath(joinpath(@__DIR__, ".."))
    surfaces = (
        joinpath(root, "README.md"),
        joinpath(root, "docs"),
        joinpath(root, "site", "src", "content"),
        joinpath(root, "examples"),
        joinpath(root, "experiments", "README.md"),
        joinpath(root, "research"),
        joinpath(root, "skills", "brainless-lab"),
    )
    forbidden = (
        r"VEN[A-Za-z_]*|:ven(?:_|\b)|\"ven(?:_|\")|SensorimotorBody|HomeostaticBody|PassthroughBody|NeedSpec|NeedDelta|Morphology\.jl|encode_receptors|decode_effectors|update_body!",
        r"""docs_path\s*=\s*"docs/""",
        r"authors-faithful|authors faithful",
        r"\brun_sweep\b|whole compute surface",
    )
    offenders = String[]
    for surface in surfaces
        files = if isfile(surface)
            (surface,)
        else
            Tuple(
                joinpath(directory, file)
                for (directory, _, names) in walkdir(surface)
                for file in names
                if any(extension -> endswith(file, extension), (".md", ".mdx", ".jl", ".toml", ".mjs"))
            )
        end
        for file in files
            text = read(file, String)
            any(pattern -> occursin(pattern, text), forbidden) &&
                push!(offenders, relpath(file, root))
        end
    end
    @test isempty(offenders)
end

@testset "package names have explicit core and supported-public tiers" begin
    expected_exports = Set((
        :simulate,
        :visualize,
        :animate,
        :replay,
        :task_outcome,
        :SimResult,
        :Recorder,
        :getchannel,
        :NodeSpec,
        :TaskSpec,
        :CompositionSpec,
        :EvaluationSpec,
        :ExperimentSpec,
        :ParameterSpec,
        :RegistrySet,
        :NodeBuildContext,
        :DEFAULT_REGISTRY,
        :register!,
        :register_node!,
        :register_task!,
        :register_drive!,
        :register_body!,
        :register_motor!,
        :register_sensor!,
        :register_metric!,
        :register_analysis!,
        :register_ablation!,
        :resolve_node,
        :resolve_task,
        :resolve_drive,
        :resolve_body,
        :resolve_motor,
        :resolve_sensor,
        :resolve_metric,
        :resolve_analysis,
        :resolve_view,
        :resolve_ablation,
        :variants,
        :tasks,
        :analyses,
        :ablations,
        :nodes,
        :node_spec,
        :genome_type,
        :composition_spec,
        :resolve_composition,
        :NodeModel,
        :Reservoir,
        :AbstractBody,
        :TaskWorld,
        :TaskSetup,
        :FalandaysParams,
        :FalandaysReservoir,
        :step!,
        :effectors,
        :reset!,
        :n_receptors,
        :n_effectors,
        :n_nodes,
        :sense,
        :metrics,
        :default_ticks,
        :default_window,
        :portspec,
        :pack_params,
        :unpack_params,
        :paramdim,
        :snapshot_state,
        :load_state!,
        :PlasticityTrait,
        :NoPlasticity,
        :OnlinePlasticity,
        :SpatialTrait,
        :Aspatial,
        :Embedded,
        :DelayTrait,
        :UnitDelay,
        :HeteroDelay,
        :WindowTrait,
        :IntrinsicWindow,
        :SteppedWindow,
        :spatiality,
        :delaykind,
        :plasticity,
        :windowing,
        :temporal_window,
        :AnchorKind,
        :ScoreAnchor,
        :ANALYTIC,
        :NULL_MEASURED,
        :REFERENCE_MEASURED,
        :analytic,
        :null_anchor,
        :reference_anchor,
        :normalized_score,
        :calibrate_task,
        :write_calibration_report,
        :fano_factor,
        :spectral_radius,
        :node_target_error,
        :distance_to_source,
        :wall_distance,
        :heading_error,
        :object_in_view,
        :tracking_plasticity_diagnostics,
        :ball_paddle_distance,
        :EvaluationTarget,
        :ScheduledIntervention,
        :AnalysisSeries,
        :AnalysisResult,
        :BenchmarkCasePlan,
        :ProfilePlan,
        :SweepPlan,
        :AblationPlan,
        :EvolutionPlan,
        :BenchmarkPlan,
        :evaluate,
        :resolve,
        :validate,
        :execute,
        :read_plan,
        :write_plan,
        :read_experiment,
        :write_experiment,
        :write_record,
        :run_operation,
        :run_experiment,
        :components,
        :component_info,
        :read_embodiment_config,
        :materialize_blueprint,
        :materialize_embodiment,
    ))
    actual_exports = Set(
        name for name in names(BrainlessLab; all=true, imported=false)
        if name !== :BrainlessLab && Base.isexported(BrainlessLab, name)
    )
    public_only = Set(
        name for name in names(BrainlessLab; all=true, imported=false)
        if Base.ispublic(BrainlessLab, name) && !Base.isexported(BrainlessLab, name)
    )

    @test actual_exports == expected_exports
    @test length(public_only) == 490
    @test all(name -> name in public_only, (
        :explore,
        :Evolution,
        :SORNReservoir,
        :CompartmentalReservoir,
        :Embodiment,
        :SpectralCamera,
        :RegulatedPhysiology,
        :branching_ratio_mr,
        :transfer_entropy,
        :susceptibility,
        :participation_ratio,
    ))
    @test !Base.isexported(BrainlessLab, :Unsigned)
    @test !Base.ispublic(BrainlessLab, :Unsigned)
    @test !Base.isexported(BrainlessLab, :node_receptor_profile_keyword)
    @test !Base.ispublic(BrainlessLab, :node_receptor_profile_keyword)
    @test !isdefined(BrainlessLab, :HomeostaticFlowParams)
    @test !isdefined(BrainlessLab, :HomeostaticFlowReservoir)
end

@testset "core workflows are complete after using BrainlessLab" begin
    workflows = (
        add_task=(
            :TaskWorld, :TaskSetup, :TaskSpec, :analytic, :null_anchor,
            :reference_anchor, :calibrate_task, :write_calibration_report,
            :register!, :DEFAULT_REGISTRY,
        ),
        add_node=(
            :NodeModel, :Reservoir, :NodeBuildContext, :NodeSpec, :ParameterSpec,
            :genome_type, :step!, :effectors, :reset!, :n_nodes, :n_receptors,
            :n_effectors, :pack_params, :unpack_params, :paramdim,
            :snapshot_state, :load_state!, :register!, :DEFAULT_REGISTRY,
        ),
        design_body=(
            :components, :component_info, :read_embodiment_config,
            :materialize_blueprint, :materialize_embodiment, :portspec,
        ),
        create_benchmark=(
            :CompositionSpec, :composition_spec, :resolve_composition,
            :EvaluationSpec, :EvaluationTarget, :evaluate, :BenchmarkCasePlan,
            :BenchmarkPlan, :validate, :resolve, :execute, :write_plan,
            :run_operation,
        ),
    )

    for names in values(workflows), name in names
        @test Base.isexported(BrainlessLab, name)
    end
end
