"""
    BrainlessLab

A small, extensible Julia research-tinkering package for node-based collective
systems. Stage 0 defines the core interfaces, registries, parameter/state
contracts, and lightweight recording utilities used by later concrete models.
"""
module BrainlessLab

include("core/Interfaces.jl")
include("core/Traits.jl")
include("core/Params.jl")
include("core/Registry.jl")
include("core/Recorder.jl")
include("nodes/Drives.jl")
include("nodes/Axes.jl")
include("nodes/Falandays.jl")

export NodeModel,
    Reservoir,
    Body,
    Medium,
    AbstractTask,
    Driver,
    Drive,
    Intervention,
    AbstractEvolutionStrategy

export step!,
    effectors,
    reset!,
    n_receptors,
    n_effectors,
    pack_params,
    unpack_params,
    paramdim,
    snapshot_state,
    load_state!,
    observe,
    actuate!,
    receptors,
    motor,
    score,
    metrics,
    apply_drive!,
    apply!,
    ask,
    tell!,
    result

export PlasticityTrait,
    NoPlasticity,
    OnlinePlasticity,
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
    FalandaysReservoir,
    RngNoise,
    RecordedNoise,
    next_noise!,
    reset_noise!,
    noise_index,
    falandays_oosawa,
    falandays_dale

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

register_drive!(:none, NoDrive)
register_drive!(:oosawa, OosawaDrive)

register_node!(:falandays, FalandaysReservoir)
register_node!(:falandays_oosawa, falandays_oosawa)
register_node!(:falandays_dale, falandays_dale)

end
