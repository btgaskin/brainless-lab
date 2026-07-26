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
        r":falandays_base\b",
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
        :fano_factor,
        :spectral_radius,
        :participation_ratio,
        :node_target_error,
        :distance_to_source,
        :wall_distance,
        :heading_error,
        :object_in_view,
        :ball_paddle_distance,
        :EvaluationTarget,
        :ProfilePlan,
        :SweepPlan,
        :AblationPlan,
        :EvolutionPlan,
        :BenchmarkPlan,
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
    @test length(public_only) == 523
    @test all(name -> name in public_only, (
        :explore,
        :Evolution,
        :SORNReservoir,
        :CompartmentalReservoir,
        :DendriticReservoir,
        :SpatialConnectome,
        :DelayedConnectome,
        :Embodiment,
        :SpectralCamera,
        :RegulatedPhysiology,
        :branching_ratio_mr,
        :transfer_entropy,
        :susceptibility,
    ))
    @test !Base.isexported(BrainlessLab, :Unsigned)
    @test !Base.ispublic(BrainlessLab, :Unsigned)
    @test !isdefined(BrainlessLab, :HomeostaticFlowParams)
    @test !isdefined(BrainlessLab, :HomeostaticFlowReservoir)
end
