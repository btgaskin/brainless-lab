"""
    BrainlessLab

An extensible Julia tinkering lab for brainless reservoirs, bodies, tasks, and
ensembles. The high-level workflow is intentionally two lines:

    sim = simulate(:wall; node=:falandays)
    visualize(sim)

Load CairoMakie or another Makie backend before plotting; the compute core stays
Makie-free.
"""
module BrainlessLab

import Base: view

include("core/Interfaces.jl")
include("core/Traits.jl")
include("core/Params.jl")
include("core/Specifications.jl")
include("core/Registry.jl")
include("core/Components.jl")
include("core/Recorder.jl")
include("core/Parallel.jl")
include("viz/Style.jl")
include("viz/Views.jl")
include("nodes/Drives.jl")
include("nodes/Axes.jl")
include("world/Torus.jl")
include("world/Arena.jl")
include("world/Ports.jl")
include("world/Sensor.jl")
include("world/Response.jl")
include("world/SpatialFields.jl")
include("world/SpectralVision.jl")
include("world/BilateralSensing.jl")
include("world/Body.jl")
include("world/Motor.jl")
include("world/PhysicalComponents.jl")
include("world/Interaction.jl")
include("world/Embodiment.jl")
include("world/SectorVision.jl")
include("world/Homeostasis.jl")
include("nodes/SpikeHistory.jl")
include("nodes/Falandays.jl")
include("nodes/Dendritic.jl")
include("nodes/SORN.jl")
include("nodes/Spatial.jl")
include("nodes/Delays.jl")
include("nodes/NoisyInput.jl")
include("nodes/Compartmental.jl")
include("nodes/Wiring.jl")
include("nodes/CompartmentalReservoir.jl")
include("nodes/Interventions.jl")
include("nodes/NullRandom.jl")
include("nodes/HomeostaticFlow.jl")
include("nodes/HomeostaticFlowV2.jl")
include("envs/WallBox.jl")
include("envs/Envs.jl")
include("envs/CartPoleVariants.jl")
include("envs/PlankCartPole.jl")
include("tasks/Scoring.jl")
include("tasks/Tasks.jl")
include("core/Composition.jl")
include("world/Environments.jl")
include("world/Ensemble.jl")
include("world/Metrics.jl")
include("api/paper_config.jl")
include("api/Highlevel.jl")
include("core/Catalog.jl")
include("api/Composition.jl")
include("analysis/ActivityLevels.jl")
include("analysis/Branching.jl")
include("analysis/Avalanches.jl")
include("analysis/TargetError.jl")
include("analysis/Spectral.jl")
include("analysis/SecondOrder.jl")
include("analysis/SwarmAnalysis.jl")
include("analysis/NullTest.jl")
include("analysis/TaskSignals.jl")
include("analysis/TransferEntropy.jl")
include("analysis/ForageTransfer.jl")
include("analysis/OwnColour.jl")
include("drivers/Driver.jl")
include("tasks/Calibration.jl")
include("drivers/Parallel.jl")
include("drivers/Composite.jl")
include("drivers/Evolve.jl")
include("drivers/MultiObjective.jl")
include("drivers/QualityDiversity.jl")
include("drivers/Fixed.jl")
include("drivers/Plastic.jl")
include("run/EmbodimentConfig.jl")
include("run/ComponentCatalog.jl")
include("run/Evaluation.jl")
include("world/ObjectWorld.jl")
include("tasks/ShoalForage.jl")
include("analysis/ShoalForage.jl")
include("run/Development.jl")
include("run/Config.jl")
include("run/Profiles.jl")
include("run/Manifest.jl")
include("run/Replay.jl")
include("run/Artifacts.jl")
include("run/Sweep.jl")

export NodeModel,
    Reservoir,
    AbstractBody,
    Environment,
    AbstractTask,
    Runner,
    Drive,
    Intervention,
    AbstractEvolutionStrategy

export step!,
    rollout!,
    effectors,
    reset!,
    n_receptors,
    n_effectors,
    n_nodes,
    portspec,
    ports,
    pack_params,
    unpack_params,
    paramdim,
    genome_type,
    snapshot_state,
    load_state!,
    network_snapshot,
    prepare_step!,
    sync_activity!,
    rawspec,
    sample!,
    encode!,
    begin_encoding!,
    encode_frame!,
    encoder_sources,
    sense!,
    decode!,
    apply_commands!,
    integrate!,
    expose!,
    update!,
    inactive_command,
    component_state,
    remember_receptors!,
    conspecific_contacts,
    bounds,
    pose,
    sense,
    metrics,
    default_ticks,
    default_window,
    apply_drive!,
    apply!,
    supports_intervention,
    ask,
    tell!,
    result,
    develop,
    mutate,
    recombine,
    record_state!

export PlasticityTrait,
    NoPlasticity,
    OnlinePlasticity,
    SpatialTrait,
    Aspatial,
    Embedded,
    DelayTrait,
    UnitDelay,
    HeteroDelay,
    spatiality,
    delaykind,
    plasticity,
    WindowTrait,
    IntrinsicWindow,
    SteppedWindow,
    windowing,
    temporal_window

export sigmoid,
    softplus,
    TAU_MIN,
    mapped_tau

export NoDrive,
    OosawaDrive

export Unsigned,
    Dale,
    recurrent_input,
    learn!,
    bernoulli_mask,
    directed_watts_strogatz,
    dale_signs

export FalandaysParams,
    ReservoirInstance,
    Connectome,
    FalandaysConnectome,
    ConnState,
    FalandaysModel,
    DenseConnectome,
    MetricSpace,
    Embedding,
    ExpKernel,
    PowerLawKernel,
    connection_prob,
    SpatialRule,
    SpatialConnectome,
    SpikeHistory,
    DelayedConnectome,
    build_spatial_connectome,
    build_hemispheric_connectome,
    build_delayed_connectome,
    delays_from_embedding,
    distance,
    FalandaysConnState,
    FalandaysNodeState,
    FalandaysReservoir,
    SORNParams,
    SORNReservoir,
    activations,
    weights,
    RngNoise,
    RecordedNoise,
    AgentNoiseFactory,
    agent_noise_source,
    next_noise!,
    reset_noise!,
    noise_index,
    falandays_oosawa,
    DendriticModel,
    DendriticConnectome,
    DendriticConnState,
    DendriticNodeState,
    DendriticReservoir

export AbstractCompartmental,
    DenseCompartmental,
    StructuredCompartmental,
    CompartmentalModel,
    CompartmentalConnectome,
    CompartmentalConnState,
    CompartmentalNodeState,
    CompartmentalReservoir,
    Wiring,
    build_wiring,
    inject_wiring,
    ResetDendrites,
    NoSomaBack,
    NoHillockBack,
    FreezePlasticity,
    ZeroRecurrent,
    ClampTarget,
    DisableVision,
    COMPARTMENTAL_D,
    COMPARTMENTAL_S,
    IN_UNIT,
    OUT_UNIT,
    FB_UNIT,
    DRIVE_UNIT,
    THR_UNIT,
    HB_UNIT,
    HILL_TAU,
    HILL_RESET

export NullRandomReservoir

export HomeostaticFlowParams, HomeostaticFlowReservoir
export HomeostaticFlowV2Params, HomeostaticFlowV2Reservoir

export TaskWorld,
    RecordedDraws,
    recorded_draw!,
    draws_remaining,
    WallBox,
    WallEnv,
    TrackingEnv,
    PongEnv,
    tracking_reference_policy,
    pong_reference_policy,
    CartPoleEnv,
    CartPoleVariantEnv,
    CartPoleHardEnv,
    CartPoleLongEnv,
    CartPoleSwingupEnv,
    PlankCartPoleLevel,
    PLANK_CARTPOLE_LEVELS,
    PLANK_CARTPOLE_MISSION_STEPS,
    PLANK_CARTPOLE_NEURAL_FRAMES,
    PLANK_CARTPOLE_EVAL_EPISODES,
    plank_cartpole_level,
    SpikeFF2Encoder,
    Argyle4Encoder,
    PlankCartPoleEnv,
    PlankCartPoleSetup,
    plank_cartpole_fitness,
    set_plank_cartpole_state!,
    cartpole_balancer,
    cartpole_swingup_controller,
    distance_last,
    collisions_last

export TaskSpec,
    TaskSetup,
    task_outcome,
    setup_task,
    is_multiagent,
    resolved_task_ports,
    has_objective,
    AnchorKind,
    ScoreAnchor,
    ANALYTIC,
    NULL_MEASURED,
    REFERENCE_MEASURED,
    analytic,
    null_anchor,
    reference_anchor,
    WALL_TASK,
    TRACKING_TASK,
    PONG_TASK,
    PONG_HITRATE_TASK,
    CARTPOLE_TASK,
    CARTPOLE_HARD_TASK,
    CARTPOLE_SWINGUP_TASK,
    CARTPOLE_LONG_TASK,
    PLANK_CARTPOLE_PROTOCOL,
    CARTPOLE_PLANK_EASY_TASK,
    CARTPOLE_PLANK_MEDIUM_TASK,
    CARTPOLE_PLANK_HARD_TASK,
    CARTPOLE_PLANK_HARDEST_TASK,
    TORUS_TASK,
    FORAGE_TASK,
    FORAGE_FLOOR_ANCHOR,
    FORAGE_CEILING_ANCHOR,
    make_env,
    score_floor,
    score_ceiling,
    normalized_score,
    normalized_forage_score,
    calibrate_task,
    write_calibration_report,
    FalandaysPaperTaskConfig,
    FALANDAYS_PAPER_CONFIG,
    falandays_paper_config

export Agent,
    Ensemble,
    EntityID,
    EntityFrame,
    entity_index,
    entity_value,
    align_entities,
    nagents,
    entity_ids,
    agent_at_slot,
    body_at_slot,
    group_agents,
    group_slots,
    group_ids,
    foreach_group,
    Embodiment,
    EmbodimentState,
    ComponentSlot,
    component_id,
    component_value,
    component_slots,
    AbstractPhysiology,
    RegulatedPhysiology,
    RegulatedVariable,
    Exposure,
    BelowSetpoint,
    AboveSetpoint,
    SetpointDistance,
    ResponseCurve,
    ConstantResponse,
    LinearResponse,
    PowerResponse,
    LogisticResponse,
    ThresholdResponse,
    response_value,
    LinearFeedback,
    PowerFeedback,
    LogisticFeedback,
    ThresholdFeedback,
    FeedbackMode,
    OffFeedback,
    TonicFeedback,
    BernoulliFeedback,
    ReplayFeedback,
    NoFailure,
    BelowFailure,
    AboveFailure,
    regulated_values,
    regulation_feedback,
    regulation_urgency,
    emit_feedback,
    alive,
    receptor_link_profile,
    TaskEnvironment,
    bind_entity_ids!,
    Torus,
    WalledArena,
    arena_size,
    arena_bounds,
    arena_distance,
    arena_bearing,
    sample_position,
    wrap,
    tdelta,
    tdistance,
    bearing,
    Motor,
    KinematicMotor,
    readout,
    readout_policy,
    readout_components,
    primary_readout,
    begin_readout!,
    observe_frame!,
    finish_readout!,
    InteractionCycle,
    FixedRateCycle,
    neural_frames,
    default_interaction_cycle,
    AbstractReadout,
    MeanReadout,
    InstantReadout,
    VotingReadout,
    AbstractSensor,
    AbstractEncoder,
    IdentityEncoder,
    SensorBank,
    SensorySource,
    ObjectSource,
    SpatialFieldSource,
    SensoryModality,
    BearingModality,
    FieldModality,
    OffModality,
    BearingSensor,
    bearing_eyes,
    n_sensors,
    paramspace,
    DirectRelaySensor,
    SituatedSensorLayout,
    SituatedEncoder,
    SituatedActuator,
    NoPhysiology,
    UnknownEffectPolicy,
    RejectUnknownEffects,
    IgnoreUnknownEffects,
    physiology_ports,
    physiology_alive,
    physiology_feedback!,
    physiology_state,
    physiology_update!,
    physiology_expose!,
    physiology_reset!,
    physiology_link_profile,
    direct_embodiment,
    situated_embodiment,
    sensor_components,
    encoder_components,
    actuator_components,
    situated_sensor,
    primary_actuator,
    Port,
    PortSpec,
    SituatedConfig,
    SwarmConfig,
    SituatedEnvironment,
    EmbodiedEnvironment,
    ObjectWorld,
    ObjectWorldSensorContext,
    ObjectID,
    ObjectInteractionEvent,
    interaction_events,
    object_snapshot,
    sample_world_sensor!,
    apply_world_relation!,
    ObjectType,
    ObjectPopulation,
    AbstractObjectAppearance,
    NoAppearance,
    NoRespawn,
    SamePositionRespawn,
    UniformRespawn,
    AbstractSpatialField,
    ConstantSpatialField,
    LinearSpatialField,
    sample_field,
    TorusEnvironment,
    ForageEnvironment,
    assemble_inputs,
    assemble_forage_inputs,
    sense_agents,
    sense_agents_coloured,
    sense_source,
    liveness,
    polarization,
    milling,
    mean_pairwise_distance,
    mean_nearest_neighbor_distance,
    segregation,
    input_stability,
    swarm_metrics,
    forage_metrics

export SpectralGrid,
    Spectrum,
    SpectralReflectance,
    SpectralIlluminant,
    SpectralAppearance,
    spectral_reflectance,
    rgb_appearance,
    Mount2D,
    mounted_pose,
    CircleTarget,
    RayHit,
    nearest_circle_hit,
    SpectralCircleTarget,
    SpectralCamera,
    n_camera_channels,
    n_camera_rays,
    relative_radiometric_response,
    sample_spectral_camera,
    display_rgb,
    SensorResponse,
    SensorResponseState,
    response_alpha,
    respond!,
    BilateralFieldProbe,
    sample_bilateral_fields!,
    sample_bilateral_fields,
    bilateral_noise_groups,
    respond_bilateral_fields!,
    AbstractBilateralEncoder,
    RawBilateralEncoder,
    CommonModeEncoder,
    UnitContrastEncoder,
    encode_bilateral

export AbstractGeometry,
    NoGeometry,
    DiscGeometry,
    geometry_radius,
    geometry_area,
    MotionState2D,
    linear_speed,
    AbstractCommand,
    DirectCommand,
    ForwardTurnCommand,
    DifferentialDriveCommand,
    PlanarForceYawCommand,
    command_values,
    AbstractActuator,
    DirectRelayActuator,
    ForwardTurnActuator,
    AntagonisticTurnActuator,
    DifferentialDriveActuator,
    PlanarForceYawActuator,
    command_buffer,
    AbstractDynamics,
    NoDynamics,
    UnicycleDynamics,
    DifferentialDriveDynamics,
    PlanarRigidBodyDynamics

export ConspecificSource,
    SectorVision,
    AbstractWorldRelation,
    ProximityExposure

export ShoalForageSetup,
    SHOAL_FORAGE_TASK,
    SHOAL_FORAGE_ARENA_SIZE,
    SHOAL_FORAGE_BODY_RADIUS,
    SHOAL_FORAGE_SOURCE_RADIUS,
    SHOAL_FORAGE_SOURCE_RANGE,
    SHOAL_FORAGE_SECTORS,
    SHOAL_FORAGE_FIELD_OF_VIEW

export shoal_need_satisfaction,
    shoal_contact_summary,
    shoal_movement_summary,
    shoal_group_movement_summary,
    shoal_perceptual_graph,
    shoal_experiment_summary

export register_node!,
    resolve_node,
    node_receptor_profile_keyword,
    register_task!,
    resolve_task,
    register_drive!,
    resolve_drive,
    register_body!,
    resolve_body,
    register_motor!,
    resolve_motor,
    register_sensor!,
    resolve_sensor,
    register_metric!,
    resolve_metric,
    register_analysis!,
    resolve_analysis,
    analysis_meta,
    analyses,
    task_analyses,
    register_view!,
    resolve_view,
    register_optimizer!,
    resolve_optimizer,
    register_ablation!,
    resolve_ablation,
    ablations

export ComponentConformance,
    ComponentDescriptor,
    COMPONENT_READINESS_LEVELS,
    validate_component_descriptor,
    register_component!,
    resolve_component,
    components,
    component_info,
    readiness,
    readiness_markdown

export Recorder,
    record!,
    tick!,
    getchannel

export parallel_map,
    init_parallelism!

export Registry,
    register!,
    ImplementationSpec,
    EquationSpec,
    ParameterSpec,
    validate_parameter,
    sweepable,
    evolvable,
    SeedStreamSpec,
    EvaluationSpec,
    seed_stream_names,
    derive_seed

export NodeBuildContext,
    NodeSpec,
    node_parameter,
    node_parameter_set,
    resolve_parameters,
    CompositionSpec,
    ResolvedComposition,
    RegistrySet,
    DEFAULT_REGISTRY,
    register_default!,
    register_builtins!,
    node_spec,
    task_spec,
    composition_spec,
    nodes,
    compositions,
    default_composition,
    resolve_composition,
    falandays_node_spec

export SimResult,
    simulate,
    variants,
    tasks,
    task_info,
    branching_ratio,
    branching_ratio_mr,
    branching_ratio_mr_windowed,
    branching_ratio_mr_conditioned,
    avalanches,
    transfer_entropy,
    node_transfer_entropy,
    agent_transfer_entropy,
    own_colour_decodability,
    forage_alignment,
    lookout_follower_te,
    node_target_error,
    spectral_radius,
    susceptibility,
    susceptibility_windowed,
    fano_factor,
    participation_ratio,
    swarm_regime,
    correlation_length,
    correlation_length_windowed,
    contact_graph_clusters,
    contact_graph_clusters_windowed,
    crossshift_null,
    temporal_null,
    distance_to_source,
    wall_distance,
    heading_error,
    object_in_view,
    ball_paddle_distance

export SepCMA,
    EvolveRunner,
    GenomeBlock,
    CompositeGenome,
    FixedRunner,
    PlasticRunner,
    rollout,
    evolve,
    node_block,
    motor_block,
    sensor_block,
    compose_genome,
    swarm_rollout,
    swarm_evaluate,
    find_alive_centroid,
    nsga2,
    cma_me,
    MEArchive

export RunConfig,
    ComponentConfig,
    EmbodimentConfig,
    ComponentBlueprint,
    EmbodimentBlueprint,
    EMBODIMENT_SCHEMA_VERSION,
    read_embodiment_config,
    embodiment_config_namedtuple,
    canonical_embodiment_toml,
    write_embodiment_config,
    materialize_embodiment,
    materialize_blueprint,
    EvaluationProtocol,
    EvaluationResult,
    PLANK_CARTPOLE_EVALUATION,
    plank_cartpole_initial_conditions,
    evaluate_plank_cartpole,
    MountedFieldProbe,
    sample_field_probe!,
    BilateralContrastEncoder,
    DEFAULT_CAMERA_WAVELENGTHS_NM,
    BUILTIN_COMPONENT_DESCRIPTORS,
    DevelopmentBlock,
    DevelopmentSpec,
    DevelopmentGenotype,
    DevelopmentContext,
    DevelopedEmbodimentBlueprint,
    development_seed,
    validate_development_structure,
    composite_genome,
    read_config,
    write_config,
    resolve,
    save_recorder,
    run_experiment,
    run_from_config,
    run_sweep,
    ablate,
    SweepAxisInfo,
    sweep_env_axes,
    sweepable_axes,
    capture_manifest

export rasterplot,
    rateplot,
    trajectoryplot,
    swarmplot,
    networkplot,
    driftplot,
    fitnessplot,
    view,
    visualize,
    explore,
    replay,
    animate

export BL_PAPER,
    BL_INK,
    BL_INKSOFT,
    BL_GRID,
    BL_TEAL,
    BL_TEALSOFT,
    BL_AMBER,
    BL_AMBERSOFT,
    BL_INKMUTED,
    BL_STYLE_SEMANTICS,
    BL_CATEGORICAL,
    BL_SEQUENTIAL

register_drive!(:none, NoDrive)
register_drive!(:oosawa, OosawaDrive)

register_node!(
    :falandays,
    _falandays_native;
    genome_type=FalandaysParams,
    receptor_profile_keyword=:input_link_p,
)
register_node!(
    :falandays_base,
    _falandays_native;
    genome_type=FalandaysParams,
    receptor_profile_keyword=:input_link_p,
) # compatibility alias of :falandays
register_node!(
    :falandays_noisy,
    _falandays_noisy_native;
    genome_type=FalandaysParams,
    receptor_profile_keyword=:input_link_p,
)
register_node!(
    :falandays_extended,
    _falandays_extended_native;
    genome_type=FalandaysParams,
    receptor_profile_keyword=:input_link_p,
)
register_node!(
    :falandays_ablated,
    _falandays_ablated_native;
    genome_type=FalandaysParams,
    receptor_profile_keyword=:input_link_p,
)
register_node!(:falandays_hemispheric, _falandays_hemispheric_native; genome_type=FalandaysParams)
register_node!(
    :falandays_oosawa,
    _falandays_oosawa_native;
    genome_type=FalandaysParams,
    receptor_profile_keyword=:input_link_p,
)
register_node!(:falandays_dendritic, _falandays_dendritic_native; genome_type=FalandaysParams)
register_node!(:falandays_spatial, _falandays_spatial_native; genome_type=FalandaysParams)
register_node!(:falandays_delayed, _falandays_delayed_native; genome_type=FalandaysParams)
register_node!(:sorn, _sorn_native; genome_type=SORNParams)
register_node!(:compartmental_dense, _compartmental_dense_native; genome_type=DenseCompartmental)
register_node!(:compartmental_structured, _compartmental_structured_native; genome_type=StructuredCompartmental)
# Bench roster aliases for compartmental_structured genomes found by the NSGA-II /
# CMA-ME multi-task drivers (identical dynamics/genome_type; only the trained
# genome bench loads differs) -- see bench/train_moo.jl / bench/train_qd.jl.
register_node!(:compartmental_structured_nsga, _compartmental_structured_native; genome_type=StructuredCompartmental)
register_node!(:compartmental_structured_cmame, _compartmental_structured_native; genome_type=StructuredCompartmental)
register_node!(:null_random, NullRandomReservoir)
register_node!(:homeostatic_flow, HomeostaticFlowReservoir; genome_type=HomeostaticFlowParams)
register_node!(:homeostatic_flow_v2, HomeostaticFlowV2Reservoir; genome_type=HomeostaticFlowV2Params)

register_task!(:wall, WALL_TASK)
register_task!(:tracking, TRACKING_TASK)
register_task!(:pong, PONG_TASK)
register_task!(:pong_hitrate, PONG_HITRATE_TASK)
register_task!(:cartpole, CARTPOLE_TASK)
register_task!(:cartpole_hard, CARTPOLE_HARD_TASK)
register_task!(:cartpole_swingup, CARTPOLE_SWINGUP_TASK)
register_task!(:cartpole_long, CARTPOLE_LONG_TASK)
register_task!(:cartpole_plank_easy, CARTPOLE_PLANK_EASY_TASK)
register_task!(:cartpole_plank_medium, CARTPOLE_PLANK_MEDIUM_TASK)
register_task!(:cartpole_plank_hard, CARTPOLE_PLANK_HARD_TASK)
register_task!(:cartpole_plank_hardest, CARTPOLE_PLANK_HARDEST_TASK)
register_task!(:torus, TORUS_TASK)
register_task!(:forage, FORAGE_TASK)
register_task!(:shoal_forage, SHOAL_FORAGE_TASK)

register_body!(:direct, Embodiment)

register_motor!(:situated_kinematics, KinematicMotor)

register_sensor!(:bearing_cone, BearingSensor)

register_metric!(:polarization, polarization)
register_metric!(:milling, milling)
register_metric!(:mean_pairwise_distance, mean_pairwise_distance)
register_metric!(:mean_nearest_neighbor_distance, mean_nearest_neighbor_distance)
register_metric!(:segregation, segregation)
register_metric!(:input_stability, input_stability)
register_metric!(:swarm_metrics, swarm_metrics)
register_metric!(:forage_metrics, forage_metrics)

register_analysis!(:branching_ratio, branching_ratio)
register_analysis!(:branching_ratio_mr, branching_ratio_mr; label="branching ratio m (MR estimator, subsampling-robust)")
register_analysis!(:branching_ratio_mr_windowed, branching_ratio_mr_windowed; label="windowed branching ratio m (MR estimator)")
register_analysis!(:branching_ratio_mr_conditioned, branching_ratio_mr_conditioned; label="branching ratio m split by object-in-view vs drift (experimental)")
register_analysis!(:avalanches, avalanches; label="neuronal avalanche size/duration exponents")
register_analysis!(:node_transfer_entropy, node_transfer_entropy; label="node-level transfer entropy (experimental)")
register_analysis!(:agent_transfer_entropy, agent_transfer_entropy; label="agent-level transfer entropy (experimental)")
register_analysis!(:node_target_error, node_target_error; label="per-node distance to target |act−T|")
register_analysis!(:spectral_radius, spectral_radius; label="spectral radius ρ(W)")
register_analysis!(:susceptibility, susceptibility; label="susceptibility χ (experimental)")
register_analysis!(:susceptibility_windowed, susceptibility_windowed; label="windowed susceptibility χ (experimental)")
register_analysis!(:fano_factor, fano_factor; label="Fano factor (experimental)")
register_analysis!(:participation_ratio, participation_ratio; label="participation ratio (experimental)")
register_analysis!(:swarm_regime, swarm_regime; label="swarm regime classifier (experimental)")
register_analysis!(:correlation_length, correlation_length; label="swarm velocity correlation length (experimental)")
register_analysis!(:correlation_length_windowed, correlation_length_windowed; label="windowed swarm velocity correlation length (experimental)")
register_analysis!(:contact_graph_clusters, contact_graph_clusters; label="contact-graph connected-component clusters (experimental)")
register_analysis!(:contact_graph_clusters_windowed, contact_graph_clusters_windowed; label="windowed contact-graph connected-component clusters (experimental)")
register_analysis!(:crossshift_null, crossshift_null; label="per-agent circular-shift null test")
register_analysis!(:temporal_null, temporal_null; label="within-network condition-shuffle null test")
register_analysis!(:distance_to_source, distance_to_source; task=:forage, label="mean distance to forage source")
register_analysis!(:forage_alignment, forage_alignment; task=:forage, label="follower source-alignment (Vanni C, experimental)")
register_analysis!(:lookout_follower_te, lookout_follower_te; task=:forage, label="lookout→follower transfer entropy (experimental)")
register_analysis!(:own_colour_decodability, own_colour_decodability; task=:torus, label="own-colour decodability from reservoir state (experimental)")
register_analysis!(:wall_distance, wall_distance; task=:wall, label="distance to nearest wall")
register_analysis!(:heading_error, heading_error; task=:tracking, label="heading error (rad)")
register_analysis!(:object_in_view, object_in_view; task=:tracking, label="stimulus-in-view indicator (experimental)")
register_analysis!(:ball_paddle_distance, ball_paddle_distance; task=:pong, label="ball–paddle distance")
register_analysis!(:shoal_need_satisfaction, shoal_need_satisfaction; task=:shoal_forage, label="material and association need satisfaction (exploratory)")
register_analysis!(:shoal_contact_summary, shoal_contact_summary; task=:shoal_forage, label="resource contact and alternation summary (exploratory)")
register_analysis!(:shoal_movement_summary, shoal_movement_summary; task=:shoal_forage, label="recorded movement diagnostics (exploratory)")
register_analysis!(:shoal_group_movement_summary, shoal_group_movement_summary; task=:shoal_forage, label="proximity cohesion and movement coherence (exploratory)")
register_analysis!(:shoal_perceptual_graph, shoal_perceptual_graph; task=:shoal_forage, label="dynamic conspecific perceptual graph (exploratory)")

register_view!(:raster, rasterplot)
register_view!(:rate, rateplot)
register_view!(:trajectory, trajectoryplot)
register_view!(:swarm, swarmplot)
register_view!(:network, networkplot)
register_view!(:drift, driftplot)
register_view!(:fitness, fitnessplot)
register_view!(:visualize, visualize)
register_view!(:explore, explore)
register_view!(:replay, replay)
register_view!(:animate, animate)

register_ablation!(:reset_dendrites, ResetDendrites)
register_ablation!(:no_soma_back, NoSomaBack)
register_ablation!(:no_hillock_back, NoHillockBack)
register_ablation!(:freeze_plasticity, FreezePlasticity)
register_ablation!(:zero_recurrent, ZeroRecurrent)
register_ablation!(:clamp_target, ClampTarget)
register_ablation!(:disable_vision, DisableVision)

register_optimizer!(:sepcma, SepCMA)

register_builtins!(DEFAULT_REGISTRY)

end
