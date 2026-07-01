"""
    BrainlessLab

An extensible Julia tinkering lab for brainless reservoirs, bodies, tasks, and
collectives. The high-level workflow is intentionally two lines:

    sim = simulate(:wall; node=:falandays)
    visualize(sim)

Load CairoMakie or another Makie backend before plotting; the compute core stays
Makie-free.
"""
module BrainlessLab

include("core/Interfaces.jl")
include("core/Traits.jl")
include("core/Params.jl")
include("core/Registry.jl")
include("core/Recorder.jl")
include("viz/Views.jl")
include("nodes/Drives.jl")
include("nodes/Axes.jl")
include("world/Torus.jl")
include("world/Body.jl")
include("world/Morphology.jl")
include("nodes/Falandays.jl")
include("nodes/Spatial.jl")
include("nodes/NoisyInput.jl")
include("nodes/Compartmental.jl")
include("nodes/Wiring.jl")
include("nodes/CompartmentalReservoir.jl")
include("nodes/Interventions.jl")
include("envs/WallBox.jl")
include("envs/Envs.jl")
include("envs/CartPoleVariants.jl")
include("tasks/Tasks.jl")
include("world/Mediums.jl")
include("world/Collective.jl")
include("world/Metrics.jl")
include("api/Highlevel.jl")
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
    Medium,
    AbstractTask,
    Morphology,
    Driver,
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
    snapshot_state,
    load_state!,
    observe,
    actuate!,
    receptors,
    encode_receptors,
    sense,
    motor,
    decode_effectors,
    score,
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
    build_spatial_connectome,
    build_hemispheric_connectome,
    distance,
    FalandaysConnState,
    FalandaysNeuronState,
    FalandaysReservoir,
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
    CompartmentalNeuronState,
    CompartmentalReservoir,
    Wiring,
    build_wiring,
    inject_wiring,
    ResetDendrites,
    NoSomaBack,
    NoHillockBack,
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

export Environment,
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
    Collective,
    PassthroughBody,
    PassthroughMorphology,
    TaskMedium,
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
    TorusMedium,
    assemble_inputs,
    sense_agents,
    liveness,
    polarization,
    milling,
    mean_pairwise_distance,
    mean_nearest_neighbor_distance,
    input_stability,
    swarm_metrics

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
    register_view!,
    resolve_view,
    register_optimizer!,
    resolve_optimizer,
    register_ablation!,
    resolve_ablation

export Recorder,
    record!,
    tick!,
    getchannel

export SimResult,
    simulate,
    variants,
    tasks

export SepCMA,
    EvolveDriver,
    FixedDriver,
    PlasticDriver,
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
    capture_manifest

export rasterplot,
    rateplot,
    trajectoryplot,
    swarmplot,
    networkplot,
    driftplot,
    fitnessplot,
    visualize,
    explore,
    replay,
    animate

register_drive!(:none, NoDrive)
register_drive!(:oosawa, OosawaDrive)

register_node!(:falandays, _falandays_native)        # alias of :falandays_base
register_node!(:falandays_base, _falandays_native)
register_node!(:falandays_noisy, _falandays_noisy_native)
register_node!(:falandays_ablated, _falandays_ablated_native)
register_node!(:falandays_hemispheric, _falandays_hemispheric_native)
register_node!(:falandays_oosawa, _falandays_oosawa_native)
register_node!(:falandays_spatial, _falandays_spatial_native)
register_node!(:compartmental_dense, _compartmental_dense_native)
register_node!(:compartmental_structured, _compartmental_structured_native)

register_task!(:wall, WALL_TASK)
register_task!(:tracking, TRACKING_TASK)
register_task!(:pong, PONG_TASK)
register_task!(:pong_hitrate, PONG_HITRATE_TASK)
register_task!(:cartpole, CARTPOLE_TASK)
register_task!(:cartpole_hard, CARTPOLE_HARD_TASK)
register_task!(:cartpole_swingup, CARTPOLE_SWINGUP_TASK)
register_task!(:cartpole_long, CARTPOLE_LONG_TASK)
register_task!(:torus, :torus)

register_body!(:passthrough, PassthroughBody)
register_body!(:ven, VENBody)

register_metric!(:polarization, polarization)
register_metric!(:milling, milling)
register_metric!(:mean_pairwise_distance, mean_pairwise_distance)
register_metric!(:mean_nearest_neighbor_distance, mean_nearest_neighbor_distance)
register_metric!(:input_stability, input_stability)
register_metric!(:swarm_metrics, swarm_metrics)

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

register_optimizer!(:sepcma, SepCMA)

end
