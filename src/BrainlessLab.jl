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
include("core/Registry.jl")
include("core/Recorder.jl")
include("viz/Style.jl")
include("viz/Views.jl")
include("nodes/Drives.jl")
include("nodes/Axes.jl")
include("world/Torus.jl")
include("world/Body.jl")
include("world/Morphology.jl")
include("nodes/SpikeHistory.jl")
include("nodes/Falandays.jl")
include("nodes/SORN.jl")
include("nodes/Spatial.jl")
include("nodes/Delays.jl")
include("nodes/NoisyInput.jl")
include("nodes/Compartmental.jl")
include("nodes/Wiring.jl")
include("nodes/CompartmentalReservoir.jl")
include("nodes/Interventions.jl")
include("envs/WallBox.jl")
include("envs/Envs.jl")
include("envs/CartPoleVariants.jl")
include("tasks/Tasks.jl")
include("world/Environments.jl")
include("world/Ensemble.jl")
include("world/Metrics.jl")
include("api/Highlevel.jl")
include("analysis/ActivityLevels.jl")
include("analysis/Branching.jl")
include("analysis/Avalanches.jl")
include("analysis/TargetError.jl")
include("analysis/Spectral.jl")
include("analysis/SecondOrder.jl")
include("analysis/SwarmAnalysis.jl")
include("analysis/TaskSignals.jl")
include("analysis/TransferEntropy.jl")
include("drivers/Driver.jl")
include("drivers/Parallel.jl")
include("drivers/Evolve.jl")
include("drivers/Fixed.jl")
include("drivers/Plastic.jl")
include("run/Config.jl")
include("run/Profiles.jl")
include("run/Manifest.jl")
include("run/Replay.jl")
include("run/Artifacts.jl")
include("run/Sweep.jl")

export NodeModel,
    Reservoir,
    Body,
    Environment,
    AbstractTask,
    Morphology,
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
    portspec,
    ports,
    pack_params,
    unpack_params,
    paramdim,
    genome_type,
    snapshot_state,
    load_state!,
    observe,
    bounds,
    pose,
    actuate!,
    receptors,
    encode_receptors,
    sense,
    decode_effectors,
    integrate_motion!,
    metrics,
    default_ticks,
    default_window,
    apply_drive!,
    apply!,
    ask,
    tell!,
    result,
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
    plasticity

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
    next_noise!,
    reset_noise!,
    noise_index,
    falandays_oosawa

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

export TaskWorld,
    RecordedDraws,
    recorded_draw!,
    draws_remaining,
    WallBox,
    WallEnv,
    TrackingEnv,
    PongEnv,
    CartPoleEnv,
    CartPoleVariantEnv,
    CartPoleHardEnv,
    CartPoleLongEnv,
    CartPoleSwingupEnv,
    cartpole_balancer,
    cartpole_swingup_controller,
    distance_last,
    collisions_last

export TaskSpec,
    WALL_TASK,
    TRACKING_TASK,
    PONG_TASK,
    PONG_HITRATE_TASK,
    CARTPOLE_TASK,
    CARTPOLE_HARD_TASK,
    CARTPOLE_SWINGUP_TASK,
    CARTPOLE_LONG_TASK,
    make_env,
    normalized_score

export Agent,
    Ensemble,
    PassthroughBody,
    PassthroughMorphology,
    TaskEnvironment,
    Torus,
    wrap,
    tdelta,
    tdistance,
    bearing,
    VENParams,
    VENBody,
    VENMorphology,
    Port,
    PortSpec,
    default_morphology,
    SwarmConfig,
    TorusEnvironment,
    ForageEnvironment,
    assemble_inputs,
    assemble_forage_inputs,
    sense_agents,
    sense_source,
    liveness,
    polarization,
    milling,
    mean_pairwise_distance,
    mean_nearest_neighbor_distance,
    input_stability,
    swarm_metrics,
    forage_metrics

export register_node!,
    resolve_node,
    register_task!,
    resolve_task,
    register_drive!,
    resolve_drive,
    register_body!,
    resolve_body,
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

export Recorder,
    record!,
    tick!,
    getchannel

export SimResult,
    simulate,
    variants,
    tasks,
    branching_ratio,
    branching_ratio_mr,
    avalanches,
    transfer_entropy,
    node_transfer_entropy,
    agent_transfer_entropy,
    node_target_error,
    spectral_radius,
    susceptibility,
    fano_factor,
    participation_ratio,
    swarm_regime,
    correlation_length,
    wall_distance,
    heading_error,
    ball_paddle_distance

export SepCMA,
    EvolveRunner,
    FixedRunner,
    PlasticRunner,
    rollout,
    evolve,
    find_alive_centroid

export RunConfig,
    read_config,
    write_config,
    resolve,
    save_recorder,
    run_experiment,
    run_from_config,
    run_sweep,
    ablate,
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

register_node!(:falandays, _falandays_native; genome_type=FalandaysParams)        # alias of :falandays_base
register_node!(:falandays_base, _falandays_native; genome_type=FalandaysParams)
register_node!(:falandays_noisy, _falandays_noisy_native; genome_type=FalandaysParams)
register_node!(:falandays_ablated, _falandays_ablated_native; genome_type=FalandaysParams)
register_node!(:falandays_hemispheric, _falandays_hemispheric_native; genome_type=FalandaysParams)
register_node!(:falandays_oosawa, _falandays_oosawa_native; genome_type=FalandaysParams)
register_node!(:falandays_spatial, _falandays_spatial_native; genome_type=FalandaysParams)
register_node!(:falandays_delayed, _falandays_delayed_native; genome_type=FalandaysParams)
register_node!(:sorn, _sorn_native; genome_type=SORNParams)
register_node!(:compartmental_dense, _compartmental_dense_native; genome_type=DenseCompartmental)
register_node!(:compartmental_structured, _compartmental_structured_native; genome_type=StructuredCompartmental)

register_task!(:wall, WALL_TASK)
register_task!(:tracking, TRACKING_TASK)
register_task!(:pong, PONG_TASK)
register_task!(:pong_hitrate, PONG_HITRATE_TASK)
register_task!(:cartpole, CARTPOLE_TASK)
register_task!(:cartpole_hard, CARTPOLE_HARD_TASK)
register_task!(:cartpole_swingup, CARTPOLE_SWINGUP_TASK)
register_task!(:cartpole_long, CARTPOLE_LONG_TASK)
register_task!(:torus, :torus)
register_task!(:forage, :forage)

register_body!(:passthrough, PassthroughBody)
register_body!(:ven, VENBody)

register_metric!(:polarization, polarization)
register_metric!(:milling, milling)
register_metric!(:mean_pairwise_distance, mean_pairwise_distance)
register_metric!(:mean_nearest_neighbor_distance, mean_nearest_neighbor_distance)
register_metric!(:input_stability, input_stability)
register_metric!(:swarm_metrics, swarm_metrics)
register_metric!(:forage_metrics, forage_metrics)

register_analysis!(:branching_ratio, branching_ratio)
register_analysis!(:branching_ratio_mr, branching_ratio_mr; label="branching ratio m (MR estimator, subsampling-robust)")
register_analysis!(:avalanches, avalanches; label="neuronal avalanche size/duration exponents")
register_analysis!(:node_transfer_entropy, node_transfer_entropy; label="node-level transfer entropy (experimental)")
register_analysis!(:agent_transfer_entropy, agent_transfer_entropy; label="agent-level transfer entropy (experimental)")
register_analysis!(:node_target_error, node_target_error; label="per-node distance to target |act−T|")
register_analysis!(:spectral_radius, spectral_radius; label="spectral radius ρ(W)")
register_analysis!(:susceptibility, susceptibility; label="susceptibility χ (experimental)")
register_analysis!(:fano_factor, fano_factor; label="Fano factor (experimental)")
register_analysis!(:participation_ratio, participation_ratio; label="participation ratio (experimental)")
register_analysis!(:swarm_regime, swarm_regime; label="swarm regime classifier (experimental)")
register_analysis!(:correlation_length, correlation_length; label="swarm velocity correlation length (experimental)")
register_analysis!(:wall_distance, wall_distance; task=:wall, label="distance to nearest wall")
register_analysis!(:heading_error, heading_error; task=:tracking, label="heading error (rad)")
register_analysis!(:ball_paddle_distance, ball_paddle_distance; task=:pong, label="ball–paddle distance")

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

end
