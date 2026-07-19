using Random

"""
    SimResult

High-level simulation output. `recorder` stores sampled channels for plotting,
`metrics` stores task or swarm diagnostics, and `task`/`node` retain the
registered symbols that produced the run.
"""
struct SimResult{R,M,C}
    recorder::R
    metrics::M
    task::Symbol
    node::Symbol
    config::C
end

function view(sim::SimResult, sym::Union{Symbol,AbstractString}; kwargs...)
    return resolve_view(Symbol(sym))(sim; kwargs...)
end

function view(rec::Recorder, sym::Union{Symbol,AbstractString}; kwargs...)
    return resolve_view(Symbol(sym))(rec; kwargs...)
end

const _DEFAULT_RECORD_CHANNELS = (:spikes, :rate, :poses, :polarization, :milling)

const _NODE_DEFAULT_N = Dict{Symbol,Int}(
    :falandays => 100,
    :falandays_oosawa => 100,
    :falandays_dendritic => 100,
    :falandays_spatial => 100,
    :falandays_delayed => 100,
    :compartmental_dense => 60,
    :compartmental_structured => 60,
)

"""
    variants()

Return the registered high-level node variant symbols.
"""
variants() = sort!(collect(keys(NODES)))

"""
    tasks()

Return the registered high-level task symbols.
"""
tasks() = sort!(collect(keys(TASKS)))

function _record_symbols(record)
    record === nothing && return Symbol[]
    record isa Symbol && return [record]
    return Symbol.(collect(record))
end

function _kwdict(kwargs)
    out = Dict{Symbol,Any}()
    for (key, value) in pairs(kwargs)
        out[Symbol(key)] = value
    end
    return out
end

function _merge_kwdicts(args...)
    out = Dict{Symbol,Any}()
    for arg in args
        arg === nothing && continue
        for (key, value) in pairs(arg)
            out[Symbol(key)] = value
        end
    end
    return out
end

function _kwargs_tuple(dict::Dict{Symbol,Any})
    isempty(dict) && return NamedTuple()
    keys_ = Tuple(keys(dict))
    values_ = Tuple(dict[key] for key in keys_)
    return NamedTuple{keys_}(values_)
end

_sim_seed(seed, offset::Integer=0) = seed === nothing ? nothing : Int(seed) + Int(offset)
_sim_rng(seed) = seed === nothing ? MersenneTwister() : MersenneTwister(Int(seed))

_default_node_count(node::Symbol) = get(_NODE_DEFAULT_N, node, 100)

const _FALANDAYS_BASE_ALIASES = Set{Symbol}((:falandays, :falandays_base))
const _FALANDAYS_NATIVE_COMPAT_NODES = Set{Symbol}((
    :falandays,
    :falandays_base,
    :falandays_noisy,
    :falandays_extended,
    :falandays_ablated,
    :falandays_oosawa,
))

_falandays_config_key(task::Symbol) = task === :pong_hitrate ? :pong : task
_has_falandays_paper_config(task::Symbol) = haskey(FALANDAYS_PAPER_CONFIG, _falandays_config_key(task))

function _default_node_count(node::Symbol, task::Symbol, is_swarm::Bool)
    if !is_swarm && node in _FALANDAYS_BASE_ALIASES && _has_falandays_paper_config(task)
        return falandays_paper_config(_falandays_config_key(task)).nnodes
    end
    return _default_node_count(node)
end

function _setdefault!(options::Dict{Symbol,Any}, key::Symbol, value)
    haskey(options, key) || (options[key] = value)
    return options
end

const _FALANDAYS_PARAM_KEYS = Set(fieldnames(FalandaysParams))
const _DRIVE_PARAM_KEYS = Set{Symbol}((:membrane_noise, :noise_gain))

function _is_falandays_node(node::Symbol)
    try
        return genome_type(node) === FalandaysParams
    catch
        return false
    end
end

function _is_compartmental_node(node::Symbol)
    try
        T = genome_type(node)
        return T isa Type && T <: AbstractCompartmental
    catch
        return false
    end
end

function _take_falandays_params!(options::Dict{Symbol,Any})
    has_updates = false
    params = haskey(options, :params) ? _as_falandays_params(pop!(options, :params)) : FalandaysParams()
    updates = Dict{Symbol,Any}()
    for key in fieldnames(FalandaysParams)
        if haskey(options, key)
            updates[key] = pop!(options, key)
            has_updates = true
        end
    end
    return has_updates ? _falandays_params_with(params; updates...) : params
end

function _normalize_drive_options!(options::Dict{Symbol,Any})
    has_drive_params = any(key -> haskey(options, key), _DRIVE_PARAM_KEYS)
    has_drive = haskey(options, :drive)
    (has_drive || has_drive_params) || return options

    membrane_noise = haskey(options, :membrane_noise) ? Float64(pop!(options, :membrane_noise)) : 0.0
    noise_gain = haskey(options, :noise_gain) ? Float64(pop!(options, :noise_gain)) : 0.0
    drive = has_drive ? pop!(options, :drive) : :oosawa
    options[:drive] = _resolve_drive_instance(drive; membrane_noise=membrane_noise, noise_gain=noise_gain)
    return options
end

function _normalize_node_options!(node::Symbol, options::Dict{Symbol,Any})
    if _is_falandays_node(node)
        options[:params] = _take_falandays_params!(options)
        _normalize_drive_options!(options)
    elseif node == :sorn
        # SORN accepts learn_on directly; leave it in place for freeze_plasticity.
        _normalize_drive_options!(options)
    end
    return options
end

_ablation_symbol(::Nothing) = :none
_ablation_symbol(name::Symbol) = name
_ablation_symbol(name::AbstractString) = Symbol(name)
_ablation_symbol(::Type{T}) where {T<:Intervention} = Symbol(nameof(T))
_ablation_symbol(i::Intervention) = Symbol(nameof(typeof(i)))

function _ablation_notes(sym::Symbol, node::Symbol, task::Symbol, is_swarm::Bool)
    sym === :none && return String[]
    notes = String[]
    if sym === :freeze_plasticity
        if _is_falandays_node(node) || node === :sorn
            push!(notes, "freeze_plasticity applied: learn_on=false")
        elseif _is_compartmental_node(node)
            push!(notes, "freeze_plasticity no-op: compartmental nodes have no online plasticity")
        else
            push!(notes, "freeze_plasticity no-op for node :$(node)")
        end
    elseif sym === :zero_recurrent
        if _is_falandays_node(node) || _is_compartmental_node(node)
            push!(notes, "zero_recurrent applied: recurrent weights removed at build")
        else
            push!(notes, "zero_recurrent no-op for node :$(node)")
        end
    elseif sym === :clamp_target
        if _is_falandays_node(node)
            push!(notes, "clamp_target applied: lrate_targ=0")
        else
            push!(notes, "clamp_target no-op: target homeostasis is Falandays-specific")
        end
    elseif sym === :disable_vision
        if is_swarm
            push!(notes, "disable_vision applied: conspecific_vision=false")
        else
            push!(notes, "disable_vision no-op: task :$(task) is not a swarm task")
        end
    elseif sym in (:reset_dendrites, :no_soma_back, :no_hillock_back)
        if _is_compartmental_node(node)
            push!(notes, "$(sym) applied: compartmental intervention")
        else
            push!(notes, "$(sym) no-op: compartmental-specific ablation")
        end
    else
        push!(notes, "ablation :$(sym) passed through registered intervention hooks")
    end
    return notes
end

function _prepare_ablation_options!(node::Symbol, task::Symbol, is_swarm::Bool, node_options::Dict{Symbol,Any}, swarm_options::Dict{Symbol,Any}, ablation)
    sym = _ablation_symbol(ablation)
    sym === :none && return sym
    resolve_ablation(sym)

    if sym === :freeze_plasticity
        if _is_falandays_node(node)
            node_options[:learn_on] = false
        elseif node === :sorn
            node_options[:learn_on] = false
        end
    elseif sym === :clamp_target
        _is_falandays_node(node) && (node_options[:lrate_targ] = 0.0)
    elseif sym === :disable_vision
        is_swarm && (swarm_options[:conspecific_vision] = false)
    elseif sym in (:zero_recurrent, :reset_dendrites, :no_soma_back, :no_hillock_back)
        if _is_compartmental_node(node)
            node_options[:ablation] = sym
        end
    end

    return sym
end

function _apply_postbuild_ablation!(reservoir::Reservoir, sym::Symbol)
    sym === :none && return reservoir
    intervention =
        sym === :zero_recurrent ? ZeroRecurrent() :
        sym === :freeze_plasticity ? FreezePlasticity() :
        sym === :clamp_target ? ClampTarget() :
        nothing
    intervention === nothing && return reservoir
    supports_intervention(intervention, reservoir) && apply!(intervention, reservoir)
    return reservoir
end

# Verbs that `_apply_postbuild_ablation!` can apply to a live reservoir, and hence
# that a mid-rollout intervention schedule may reference. (Compartmental tick verbs
# such as :reset_dendrites go through a different, node-specific hook.)
const _MIDROLLOUT_VERBS = (:freeze_plasticity, :clamp_target, :zero_recurrent)

_intervention_tick_verb(item::Pair) = (item.first, item.second)
_intervention_tick_verb(item::Tuple) = (item[1], item[2])
function _intervention_tick_verb(item::NamedTuple)
    hasproperty(item, :tick) ||
        throw(ArgumentError("intervention entry $(item) needs a :tick field"))
    verb = hasproperty(item, :verb) ? item.verb :
           hasproperty(item, :ablation) ? item.ablation :
           throw(ArgumentError("intervention entry $(item) needs a :verb field"))
    return (item.tick, verb)
end

# Resolve the user-facing `interventions=[(tick=1800, verb=:freeze_plasticity)]`
# kwarg into a validated, tick-sorted `Vector{Tuple{Int,Symbol}}` (or `nothing`).
function _resolve_intervention_schedule(arg)
    arg === nothing && return nothing
    entries = Tuple{Int,Symbol}[]
    for item in arg
        tick, verb = _intervention_tick_verb(item)
        verb_sym = Symbol(verb)
        verb_sym in _MIDROLLOUT_VERBS ||
            throw(ArgumentError("unknown mid-rollout intervention verb :$(verb_sym); supported: $(_MIDROLLOUT_VERBS)"))
        Int(tick) >= 1 ||
            throw(ArgumentError("intervention tick must be >= 1, got $(tick)"))
        push!(entries, (Int(tick), verb_sym))
    end
    isempty(entries) && return nothing
    sort!(entries; by=first)
    return entries
end

function _resolve_n_nodes!(
    node::Symbol,
    task::Symbol,
    explicit_n_nodes,
    node_kwargs::Dict{Symbol,Any},
    is_swarm::Bool,
)
    node_kw_n = haskey(node_kwargs, :n_nodes) ? pop!(node_kwargs, :n_nodes) : nothing
    explicit_n_nodes !== nothing && return Int(explicit_n_nodes)
    node_kw_n !== nothing && return Int(node_kw_n)
    return _default_node_count(node, task, is_swarm)
end

function _apply_falandays_task_defaults!(
    task::Symbol,
    node::Symbol,
    is_swarm::Bool,
    node_kwargs::Dict{Symbol,Any},
    env_kwargs::Dict{Symbol,Any},
)
    (!is_swarm && node in _FALANDAYS_BASE_ALIASES && _has_falandays_paper_config(task)) || return nothing

    cfg = falandays_paper_config(_falandays_config_key(task))
    if !haskey(node_kwargs, :params)
        _setdefault!(node_kwargs, :lrate_wmat, cfg.lrate_wmat)
        _setdefault!(node_kwargs, :lrate_targ, cfg.lrate_targ)
        _setdefault!(node_kwargs, :input_amp, cfg.input_amp)
    end
    _setdefault!(node_kwargs, :weight_init_mode, cfg.weight_init_mode)
    _setdefault!(node_kwargs, :rectify, false)
    _setdefault!(node_kwargs, :topology, :bernoulli)
    _setdefault!(node_kwargs, :repair_masks, false)

    if cfg.task === :wall
        if haskey(node_kwargs, :sensory_noise)
            env_kwargs[:sensory_noise] = pop!(node_kwargs, :sensory_noise)
        end
        if haskey(node_kwargs, :clip_sensory_noise)
            env_kwargs[:clip_sensory_noise] = pop!(node_kwargs, :clip_sensory_noise)
        end
        _setdefault!(env_kwargs, :sensory_noise, cfg.sensory_noise)
        _setdefault!(env_kwargs, :clip_sensory_noise, cfg.clip_sensory_noise)
    end
    return nothing
end

function _preserve_swarm_falandays_defaults!(
    node::Symbol,
    is_swarm::Bool,
    node_kwargs::Dict{Symbol,Any},
)
    (is_swarm && node in _FALANDAYS_NATIVE_COMPAT_NODES) || return nothing
    _setdefault!(node_kwargs, :weight_init_mode, :legacy_normal)
    _setdefault!(node_kwargs, :repair_masks, true)
    _setdefault!(node_kwargs, :rectify, true)
    return nothing
end

function _falandays_native(n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer; seed=nothing, kwargs...)
    return FalandaysReservoir(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); seed=seed, kwargs...)
end

function _sorn_native(n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer; seed=nothing, kwargs...)
    options = _kwdict(kwargs)
    if haskey(options, :params)
        params = _as_sorn_params(pop!(options, :params))
        for name in fieldnames(SORNParams)
            haskey(options, name) || (options[name] = getfield(params, name))
        end
    end
    return SORNReservoir(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); seed=seed, _kwargs_tuple(options)...)
end

function _falandays_oosawa_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    membrane_noise::Real=0.0,
    noise_gain::Real=0.8,
    kwargs...,
)
    options = _kwdict(kwargs)
    drive = pop!(
        options,
        :drive,
        :oosawa,
    )
    drive = _resolve_drive_instance(
        drive;
        membrane_noise=Float64(membrane_noise),
        noise_gain=Float64(noise_gain),
    )
    return FalandaysReservoir(
        Int(n_nodes),
        Int(n_receptors_),
        Int(n_effectors_);
        seed=seed,
        drive=drive,
        _kwargs_tuple(options)...,
    )
end

# `:falandays_dendritic` — the homeostatic Falandays neuron with per-dendrite
# eligibility-tag plasticity and a logistic endogenous drive (port of v0.2's
# `DendriticReservoir`). Distinct from the biophysical `compartmental_*` nodes.
# `dend_drive` defaults active so dendritic spikes occur and widen the plastic
# gate; `eligibility_only=true` keeps the soma behaving like the base node.
function _falandays_dendritic_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    n_dendrites::Integer=4,
    soma_drive::Real=0.0,
    dend_drive::Real=0.6,
    drive_floor::Real=0.0,
    drive_d0::Real=1.0,
    drive_w::Real=0.4,
    dend_threshold::Real=1.0,
    eligibility_only::Bool=true,
    kwargs...,
)
    options = _kwdict(kwargs)
    return DendriticReservoir(
        Int(n_nodes),
        Int(n_receptors_),
        Int(n_effectors_);
        seed=seed,
        n_dendrites=Int(n_dendrites),
        soma_drive=Float64(soma_drive),
        dend_drive=Float64(dend_drive),
        drive_floor=Float64(drive_floor),
        drive_d0=Float64(drive_d0),
        drive_w=Float64(drive_w),
        dend_threshold=Float64(dend_threshold),
        eligibility_only=Bool(eligibility_only),
        _kwargs_tuple(options)...,
    )
end

# `:falandays_noisy` — the base reservoir wrapped with sensory input noise
# (Uniform(±sensory_noise), clip >= 0). Distinct from `:falandays_oosawa`, which
# is membrane noise. `sensory_noise` defaults to the v0.2 body value of 0.1.
function _falandays_noisy_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    sensory_noise::Real=0.1,
    kwargs...,
)
    inner = _falandays_native(n_nodes, n_receptors_, n_effectors_; seed=seed, kwargs...)
    return NoisyInput(inner; sensory_noise=Float64(sensory_noise), seed=(seed === nothing ? 0 : Int(seed)))
end

# `:falandays_extended` — the paper's extended model: the base homeostatic reservoir
# with sensory input noise, Watts–Strogatz small-world recurrent wiring, and Dale's
# law (excitatory/inhibitory sign). Same neuron update as base; a richer substrate.
function _falandays_extended_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    sensory_noise::Real=0.1,
    topology=:watts_strogatz,
    sign=:dale,
    kwargs...,
)
    inner = _falandays_native(n_nodes, n_receptors_, n_effectors_;
                              seed=seed, topology=topology, sign=sign, kwargs...)
    return NoisyInput(inner; sensory_noise=Float64(sensory_noise), seed=(seed === nothing ? 0 : Int(seed)))
end

function _falandays_hemispheric_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    callosum_density::Real=0.0,
    contralateral=true,
    kernel::Union{Symbol,AbstractString}=:exp,
    p0::Real=0.5,
    lambda::Real=0.3,
    d0::Real=0.3,
    alpha::Real=2.0,
    link_p::Real=0.1,
    extent::Real=1.0,
    effector_wiring::Union{Symbol,AbstractString}=:bernoulli,
    params=FalandaysParams(),
    drive=NoDrive(),
    sign=Unsigned(),
    rectify=true,
    noise_source=nothing,
    kwargs...,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_receptors_ >= 2 || throw(ArgumentError("hemispheric node needs >= 2 receptors to split left/right"))
    n_effectors_ >= 2 || throw(ArgumentError("hemispheric node needs >= 2 effectors to split left/right"))
    n_nodes >= 2 || throw(ArgumentError("hemispheric node needs >= 2 nodes"))

    params = _as_falandays_params(params)
    input_weight, inhibitory_frac = _spatial_native_options(params, kwargs)

    rng = _rng_from_seed(seed)
    axis = _native_axis(sign, n_nodes, rng, inhibitory_frac)
    connectome = build_hemispheric_connectome(
        n_nodes,
        n_receptors_,
        n_effectors_;
        rng=rng,
        kernel=kernel,
        p0=p0,
        lambda=lambda,
        d0=d0,
        alpha=alpha,
        link_p=link_p,
        extent=extent,
        callosum_density=callosum_density,
        contralateral=Bool(contralateral),
        effector_wiring=effector_wiring,
        weight_init_std=params.weight_init_std,
        input_weight=input_weight,
    )

    source = noise_source === nothing ? _noise_source_from_seed(seed) : noise_source
    wmat = copy(connectome.wmat0)
    acts = zeros(Float64, n_nodes)
    targets = ones(Float64, n_nodes)
    spikes = zeros(Float64, n_nodes)
    errors = zeros(Float64, n_nodes)
    prev_spikes = zeros(Float64, n_nodes)

    return ReservoirInstance(
        FalandaysModel(params, _resolve_drive_instance(drive), axis, Bool(rectify)),
        connectome,
        FalandaysConnState(wmat),
        FalandaysNodeState(acts, targets, spikes, errors, prev_spikes, source),
        PortSpec(n_receptors_, n_effectors_),
    )
end

# `:falandays_ablated` is the packaged node preset for the canonical
# `clamp_target` intervention: lrate_targ=0 pins every node's target at its
# init (1.0), so the firing threshold stays fixed at 2.0; recurrent weights
# still learn.
function _falandays_ablated_native(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    kwargs...,
)
    options = _kwdict(kwargs)
    reservoir = _falandays_native(n_nodes, n_receptors_, n_effectors_;
                                  seed=seed, _kwargs_tuple(options)...)
    return apply!(ClampTarget(), reservoir)
end

function _native_compartmental_wiring(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    mode::Symbol,
    link_p::Real=0.1,
    rho::Real=0.2,
    k_rec=nothing,
    k_in=nothing,
    output_fanout=nothing,
)
    n_nodes = Int(n_nodes)
    n_receptors_ = Int(n_receptors_)
    n_effectors_ = Int(n_effectors_)
    n_nodes >= 1 || throw(ArgumentError("n_nodes must be at least 1"))
    n_receptors_ >= 1 || throw(ArgumentError("n_receptors must be at least 1"))
    n_effectors_ >= 1 || throw(ArgumentError("n_effectors must be at least 1"))

    link_p_ = k_rec === nothing ? Float64(link_p) : Float64(Int(k_rec)) / Float64(max(n_nodes - 1, 1))
    K_rec_ = min(n_nodes - 1, max(1, round(Int, link_p_ * (n_nodes - 1))))
    rho_ = k_in === nothing ? Float64(rho) : Float64(Int(k_in)) / Float64(max(K_rec_, 1))

    return build_wiring(
        n_nodes,
        seed;
        link_p=link_p_,
        n_receptors=n_receptors_,
        n_effectors=n_effectors_,
        rho=rho_,
        mode=mode,
    )
end

function _randomize_compartmental_state!(r::CompartmentalReservoir, rng::AbstractRNG, scale::Real)
    scale = Float64(scale)
    scale <= 0.0 && return r

    r.dend_y .= scale .* randn(rng, size(r.dend_y)...)
    r.soma_y .= scale .* randn(rng, size(r.soma_y)...)
    r.V .= 0.5 .* rand(rng, length(r.V))
    r.spike_buffer .= Float64.(rand(rng, length(r.spike_buffer)) .< 0.03)
    copyto!(r.prev_spike, r.spike_buffer)
    copyto!(r.prev_soma_y, r.soma_y)
    return r
end

function _resolve_compartmental_intervention(ablation, intervention)
    intervention !== nothing && return _compartmental_intervention(intervention)
    ablation === nothing && return nothing
    return _compartmental_intervention(ablation)
end

function _compartmental_native(
    genome_type::Type{<:AbstractCompartmental},
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=nothing,
    raw=nothing,
    raw_scale::Real=0.25,
    genome=nothing,
    wiring=nothing,
    link_p::Real=0.1,
    rho::Real=0.2,
    k_rec=nothing,
    k_in=nothing,
    output_fanout=nothing,
    init_random::Bool=true,
    state_scale::Real=0.05,
    dt::Real=1.0,
    hill_tau::Real=HILL_TAU,
    hill_reset::Real=HILL_RESET,
    ablation=nothing,
    intervention=nothing,
    kwargs...,
)
    rng = _sim_rng(seed)
    mode = _compartmental_mode(genome_type)

    genome_ =
        genome === nothing ?
        unpack_params(genome_type, raw === nothing ? Float64(raw_scale) .* randn(rng, paramdim(genome_type)) : raw) :
        genome

    wiring_ =
        wiring === nothing ?
        _native_compartmental_wiring(
            n_nodes,
            n_receptors_,
            n_effectors_;
            seed=seed,
            mode=mode,
            link_p=link_p,
            rho=rho,
            k_rec=k_rec,
            k_in=k_in,
            output_fanout=output_fanout,
        ) :
        wiring

    reservoir = CompartmentalReservoir(
        genome_,
        wiring_;
        dt=dt,
        hill_tau=hill_tau,
        hill_reset=hill_reset,
        intervention=_resolve_compartmental_intervention(ablation, intervention),
    )
    init_random && _randomize_compartmental_state!(reservoir, rng, state_scale)
    return reservoir
end

function _compartmental_dense_native(args...; kwargs...)
    return _compartmental_native(DenseCompartmental, args...; kwargs...)
end

function _compartmental_structured_native(args...; kwargs...)
    return _compartmental_native(StructuredCompartmental, args...; kwargs...)
end

function _build_reservoir(
    node::Symbol,
    node_ctor,
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    node_kwargs=NamedTuple(),
    ablation=:none,
)
    options = _merge_kwdicts(node_kwargs)
    _normalize_node_options!(node, options)
    options[:seed] = _sim_seed(seed)
    kwargs = _kwargs_tuple(options)

    try
        reservoir = node_ctor(Int(n_nodes), Int(n_receptors_), Int(n_effectors_); kwargs...)
        return _apply_postbuild_ablation!(reservoir, Symbol(ablation))
    catch err
        msg = "Registered node :$(node) must accept (n_nodes, n_receptors, n_effectors; seed, kwargs...). Original error: $(sprint(showerror, err))"
        throw(ArgumentError(msg))
    end
end

function _validate_agent_ports(reservoir::Reservoir, body::AbstractBody)
    spec = portspec(body)
    reservoir_receptors = n_receptors(reservoir)
    reservoir_effectors = n_effectors(reservoir)
    body_receptors = n_receptors(spec)
    body_effectors = n_effectors(spec)

    if reservoir_receptors != body_receptors || reservoir_effectors != body_effectors
        msg =
            "Agent port mismatch for $(typeof(body)): " *
            "reservoir has ($(reservoir_receptors), $(reservoir_effectors)) " *
            "but body expects ($(body_receptors), $(body_effectors))"
        throw(DimensionMismatch(msg))
    end

    return nothing
end

function _make_agent(reservoir::Reservoir, body::AbstractBody)
    _validate_agent_ports(reservoir, body)
    return Agent(reservoir, body)
end

function _setup_for_node_count(
    task_spec::TaskSpec{S},
    n_nodes::Integer;
    kwargs...,
) where {S<:TaskWorldSetup}
    return setup_task(task_spec; kwargs...)
end

function _setup_for_node_count(task_spec::TaskSpec, n_nodes::Integer; kwargs...)
    return setup_task(task_spec; n_nodes=Int(n_nodes), kwargs...)
end

function _make_ensemble(
    task_spec::TaskSpec,
    node::Symbol,
    node_ctor;
    seed=0,
    record=Symbol[],
    every::Integer=1,
    spectral_every::Integer=1,
    n_nodes::Integer=100,
    node_kwargs=NamedTuple(),
    task_kwargs=NamedTuple(),
    body=nothing,
    ablation=:none,
)
    setup_options = _kwargs_tuple(_merge_kwdicts(task_kwargs))
    task_setup = _setup_for_node_count(
        task_spec,
        n_nodes;
        seed=seed,
        body=body,
        setup_options...,
    )

    bodies = task_setup.bodies
    agents = Vector{Agent}(undef, length(bodies))
    @inbounds for i in eachindex(bodies)
        spec = portspec(bodies[i])
        body_node_options = _merge_kwdicts(node_kwargs)
        if haskey(body_node_options, :noise_source)
            body_node_options[:noise_source] = agent_noise_source(
                body_node_options[:noise_source],
                i,
            )
        end
        default_link_p = Float64(get(body_node_options, :link_p, 0.1))
        input_profile = receptor_link_profile(bodies[i], default_link_p)
        if input_profile !== nothing
            profile_keyword = node_receptor_profile_keyword(node)
            profile_keyword === nothing && throw(ArgumentError(
                "body requires a per-receptor link profile, but registered node :$(node) " *
                "does not declare receptor_profile_keyword; register the constructor " *
                "with that capability or use a uniform body profile",
            ))
            if haskey(body_node_options, profile_keyword)
                explicit_profile = body_node_options[profile_keyword]
                explicit_values = try
                    Float64.(collect(explicit_profile))
                catch
                    nothing
                end
                explicit_values == input_profile || throw(ArgumentError(
                    "node :$(node) received conflicting :$(profile_keyword): the explicit " *
                    "profile does not match the body-derived receptor profile",
                ))
            else
                body_node_options[profile_keyword] = input_profile
            end
        end
        reservoir = _build_reservoir(
            node,
            node_ctor,
            n_nodes,
            n_receptors(spec),
            n_effectors(spec);
            seed=_sim_seed(seed, i - 1),
            node_kwargs=body_node_options,
            ablation=ablation,
        )
        agents[i] = _make_agent(reservoir, bodies[i])
    end

    recorder = Recorder(enabled=record, every=every, compute_every=_spectral_compute_every(spectral_every))
    ensemble = Ensemble(agents, task_setup.environment; recorder=recorder)
    return ensemble, recorder
end

_spectral_compute_every(spectral_every::Integer) =
    spectral_every > 1 ? Dict{Symbol,Int}(:spectral_radius => Int(spectral_every)) : Dict{Symbol,Int}()

_environment_size(::TaskWorld) = nothing
_environment_size(env::WallEnv) = Float64(env.box.size)

_config_type(value) = string(typeof(value))

function _custom_callable_config(value)
    names = fieldnames(typeof(value))
    parameters = NamedTuple{names}(Tuple(getfield(value, name) for name in names))
    return (kind=:custom, type=_config_type(value), parameters=parameters)
end

_deficit_config(::BelowSetpoint) = (kind=:below_setpoint,)
_deficit_config(::AboveSetpoint) = (kind=:above_setpoint,)
_deficit_config(::SetpointDistance) = (kind=:setpoint_distance,)
_deficit_config(value) = _custom_callable_config(value)

_curve_config(::LinearFeedback) = (kind=:linear,)
_curve_config(curve::ConstantResponse) = (kind=:constant, value=curve.value)
_curve_config(curve::PowerFeedback) = (kind=:power, exponent=curve.exponent)
_curve_config(curve::LogisticFeedback) = (
    kind=:logistic,
    slope=curve.slope,
    midpoint=curve.midpoint,
)
_curve_config(curve::ThresholdFeedback) = (kind=:threshold, threshold=curve.threshold)
_curve_config(value) = _custom_callable_config(value)

_feedback_mode_config(::OffFeedback) = (kind=:off,)
_feedback_mode_config(::TonicFeedback) = (kind=:tonic,)
_feedback_mode_config(::BernoulliFeedback) = (kind=:bernoulli,)
_feedback_mode_config(mode::ReplayFeedback) = (
    kind=:replay,
    values=Tuple(mode.values),
    cycle=mode.cycle,
)
_feedback_mode_config(value) = _custom_callable_config(value)

_failure_config(::NoFailure) = (kind=:none,)
_failure_config(policy::BelowFailure) = (kind=:below, threshold=policy.threshold)
_failure_config(policy::AboveFailure) = (kind=:above, threshold=policy.threshold)
_failure_config(value) = _custom_callable_config(value)

function _variable_config(need::RegulatedVariable)
    return (
        name=need.name,
        minimum=need.minimum,
        maximum=need.maximum,
        initial=need.initial,
        setpoint=need.setpoint,
        drift=need.drift,
        deficit=_deficit_config(need.deficit),
        curve=_curve_config(need.curve),
        mode=_feedback_mode_config(need.mode),
        gain=need.gain,
        emission_p=need.emission_p,
        link_p=need.link_p,
        failure=_failure_config(need.failure),
    )
end

function _ports_config(body::AbstractBody)
    spec = portspec(body)
    return (
        n_receptors=n_receptors(spec),
        n_effectors=n_effectors(spec),
        receptor_ids=Tuple(port.id for port in spec.receptor_ports),
        effector_ids=Tuple(port.id for port in spec.effector_ports),
    )
end

function _sensory_bank_config(bank::SensorBank)
    return (
        name=bank.name,
        source=_sensory_source_config(bank.source),
        modality=_sensory_modality_config(bank.modality),
        norm_mode=bank.norm_mode,
        norm_sigma=bank.norm_sigma,
        gain=bank.gain,
        link_p=bank.link_p,
    )
end

_sensory_source_config(source::ObjectSource) = (
    kind=:objects,
    name=source_name(source),
)

_sensory_source_config(source::SpatialFieldSource) = (
    kind=:spatial_field,
    name=source_name(source),
)

_sensory_modality_config(modality::BearingModality) = (
    kind=:bearing,
    range=modality.range,
    curve=_curve_config(modality.curve),
    sensor=_sensor_config(modality.sensor),
)

_sensory_modality_config(modality::FieldModality) = (
    kind=:field,
    range=modality.range,
    curve=_curve_config(modality.curve),
    probe_count=modality.probe_count,
    probe_radius=modality.probe_radius,
    aggregation=modality.aggregation,
)

_sensory_modality_config(modality::OffModality) = (
    kind=:off,
    underlying=_sensory_modality_config(modality.modality),
)

function _sensor_component_config(sensor::SituatedSensorLayout)
    return (
        kind=:situated,
        sensory_scaling=sensor.sensory_scaling,
        source_bank=sensor.source_bank,
        source_gain=sensor.source_gain,
        signalling=sensor.signalling,
        norm_mode=sensor.norm_mode,
        norm_sigma=sensor.norm_sigma,
        conspecific_gain=sensor.conspecific_gain,
        n_colours=sensor.n_colours,
        colour_sensing=sensor.colour_sensing,
        sensor=_sensor_config(sensor.sensor),
        sensory_banks=Tuple(_sensory_bank_config(bank) for bank in sensor.sensory_banks),
    )
end

_sensor_component_config(sensor::DirectRelaySensor) = (
    kind=:direct,
    port_ids=sensor.port_ids,
)
_mount_config(mount::Mount2D) = (
    position=Tuple(mount.position),
    yaw=mount.yaw,
)
function _sensor_component_config(sensor::SpectralCamera)
    sensitivity = Tuple(
        Tuple(sensor.sensitivity[row, column] for column in axes(sensor.sensitivity, 2))
        for row in axes(sensor.sensitivity, 1)
    )
    return (
        kind=:spectral_camera,
        wavelengths_nm=Tuple(sensor.grid.wavelengths_nm),
        channels=Tuple(sensor.channels),
        sensitivity=sensitivity,
        ray_angles=Tuple(sensor.ray_angles),
        mount=_mount_config(sensor.mount),
        max_range=sensor.max_range,
        exposure=sensor.exposure,
        saturation=sensor.saturation,
        layout=:channel_major,
    )
end
_sensor_response_config(response::SensorResponse) = (
    tau=response.tau,
    dt=response.dt,
    shared_sigma=response.shared_sigma,
    independent_sigma=response.independent_sigma,
    minimum=response.minimum,
    maximum=response.maximum,
)
_sensor_component_config(sensor::AbstractSensor) = (
    kind=:custom,
    type=_config_type(sensor),
)

_encoder_component_config(encoder::IdentityEncoder) = (
    kind=:identity,
    port_ids=encoder.port_ids,
    sources=encoder.source_ids,
)
_encoder_component_config(encoder::SituatedEncoder) = (kind=:situated,)
_encoder_component_config(encoder::AbstractEncoder) = (
    kind=:custom,
    type=_config_type(encoder),
)

_actuator_component_config(actuator::DirectRelayActuator) = (
    kind=:direct,
    port_ids=actuator.port_ids,
    minimum=actuator.minimum,
    maximum=actuator.maximum,
)
_actuator_component_config(actuator::SituatedActuator) = (
    kind=:situated,
    signalling=actuator.signalling,
    policy=_motor_config(actuator.policy),
)
_actuator_component_config(actuator::ForwardTurnActuator) = (
    kind=:forward_turn,
    max_forward_speed=actuator.max_forward_speed,
    max_turn_rate=actuator.max_turn_rate,
    allow_reverse=actuator.allow_reverse,
)
_actuator_component_config(actuator::DifferentialDriveActuator) = (
    kind=:differential_drive,
    max_wheel_speed=actuator.max_wheel_speed,
    allow_reverse=actuator.allow_reverse,
)
_actuator_component_config(actuator::PlanarForceYawActuator) = (
    kind=:planar_force_yaw,
    max_force=actuator.max_force,
    max_yaw_torque=actuator.max_yaw_torque,
)
_actuator_component_config(actuator::AbstractActuator) = (
    kind=:custom,
    type=_config_type(actuator),
)

_geometry_config(::NoGeometry) = (kind=:none,)
_geometry_config(geometry::DiscGeometry) = (kind=:disc, radius=geometry.radius)
_geometry_config(geometry::AbstractGeometry) = (kind=:custom, type=_config_type(geometry))

_dynamics_config(::NoDynamics) = (kind=:none,)
_dynamics_config(dynamics::UnicycleDynamics) = (
    kind=:unicycle,
    dt=dynamics.dt,
    linear_tau=dynamics.linear_tau,
    angular_tau=dynamics.angular_tau,
)
_dynamics_config(dynamics::DifferentialDriveDynamics) = (
    kind=:differential_drive,
    dt=dynamics.dt,
    wheel_base=dynamics.wheel_base,
)
_dynamics_config(dynamics::PlanarRigidBodyDynamics) = (
    kind=:planar_rigid_body,
    dt=dynamics.dt,
    mass=dynamics.mass,
    moment_of_inertia=dynamics.moment_of_inertia,
    linear_drag=dynamics.linear_drag,
    angular_drag=dynamics.angular_drag,
    max_linear_speed=dynamics.max_linear_speed,
    max_angular_speed=dynamics.max_angular_speed,
)
_dynamics_config(dynamics::AbstractDynamics) = (kind=:custom, type=_config_type(dynamics))

_unknown_effect_config(::RejectUnknownEffects) = :reject
_unknown_effect_config(::IgnoreUnknownEffects) = :ignore
_unknown_effect_config(policy::UnknownEffectPolicy) = (
    kind=:custom,
    type=_config_type(policy),
)
_physiology_config(physiology::NoPhysiology) = (
    kind=:none,
    unknown_effects=_unknown_effect_config(physiology.unknown_effects),
)
_physiology_config(physiology::RegulatedPhysiology) = (
    kind=:regulated,
    variables=Tuple(_variable_config(variable) for variable in physiology.variables),
    feedback_seed=physiology.seed,
    unknown_effects=_unknown_effect_config(physiology.unknown_effects),
)
_physiology_config(physiology) = (kind=:custom, type=_config_type(physiology))

function _body_config(body::Embodiment)
    return (
        kind=:embodiment,
        geometry=_geometry_config(body.geometry),
        sensors=Tuple(_sensor_component_config(sensor) for sensor in body.sensors),
        encoders=Tuple(_encoder_component_config(encoder) for encoder in body.encoders),
        actuators=Tuple(_actuator_component_config(actuator) for actuator in body.actuators),
        dynamics=_dynamics_config(body.dynamics),
        physiology=_physiology_config(body.physiology),
        component_ids=body.state.ids,
        traits=body.traits,
        state=component_state(body).body,
        ports=_ports_config(body),
    )
end

_body_config(body::AbstractBody) = (
    kind=:custom,
    type=_config_type(body),
    ports=_ports_config(body),
)

function _motor_config(m::KinematicMotor)
    return (
        kind=:kinematic,
        scheme=m.scheme,
        readout=m.readout,
        turn_gain=Float64(m.turn_gain),
        allow_reverse=Bool(m.allow_reverse),
        brake=Bool(m.brake),
        top_speed=Float64(m.top_speed),
        accel_time=Float64(m.accel_time),
        top_heading_rate=Float64(m.top_heading_rate),
        h_accel_time=Float64(m.h_accel_time),
        dt=Float64(m.dt),
    )
end

function _sensor_config(s::BearingSensor)
    return (
        kind=:bearing,
        n_sensors=Int(n_sensors(s)),
        angles_deg=angles_deg(s),
        encoding=encoding(s),
        tuning_deg=Float64(s.tuning_deg),
        angle_range_deg=s.angle_range_deg,
        tuning_range_deg=s.tuning_range_deg,
        enabled=collect(s.enabled),
    )
end

function _sensor_config(s::AbstractSensor)
    return (
        kind=Symbol(lowercase(string(nameof(typeof(s))))),
        n_sensors=Int(n_sensors(s)),
        angles_deg=angles_deg(s),
        encoding=encoding(s),
    )
end

_respawn_config(::NoRespawn) = (kind=:none,)
_respawn_config(policy::SamePositionRespawn) = (kind=:same_position, delay=policy.delay)
_respawn_config(policy::UniformRespawn) = (kind=:uniform, delay=policy.delay)
_respawn_config(value) = (kind=:custom, type=_config_type(value))

_effect_config(delta::Exposure) = (
    kind=:exposure,
    name=delta.name,
    amount=delta.amount,
)
_effect_config(value) = (kind=:custom, type=_config_type(value))

_appearance_config(::NoAppearance) = (kind=:none,)
_appearance_config(appearance::SpectralAppearance) = (
    kind=:spectral,
    wavelengths_nm=Tuple(appearance.reflectance.grid.wavelengths_nm),
    reflectance=Tuple(appearance.reflectance.values),
)
_appearance_config(appearance::AbstractObjectAppearance) = (
    kind=:custom,
    type=_config_type(appearance),
)

_spatial_field_config(field::ConstantSpatialField) = (
    kind=:constant,
    value=field.value,
)

_spatial_field_config(field::LinearSpatialField) = (
    kind=:linear,
    origin=field.origin,
    direction=field.direction,
    offset=field.offset,
    scale=field.scale,
)

_spatial_field_config(field::AbstractSpatialField) = (
    kind=:custom,
    type=_config_type(field),
)

function _object_type_config(kind::ObjectType)
    return (
        name=kind.name,
        bank=kind.bank,
        radius=kind.radius,
        effects=Tuple(_effect_config(effect) for effect in kind.effects),
        capacity=kind.capacity,
        respawn=_respawn_config(kind.respawn),
        appearance=_appearance_config(kind.appearance),
    )
end

function _environment_config(m::TaskEnvironment)
    world = m.world
    return (
        kind=:task,
        world=Symbol(lowercase(string(nameof(typeof(world))))),
        bounds=bounds(world),
        size=_environment_size(world),
    )
end

function _environment_config(world::TaskWorld)
    return (
        kind=:task,
        world=Symbol(lowercase(string(nameof(typeof(world))))),
        bounds=bounds(world),
        size=_environment_size(world),
    )
end

function _environment_config(m::TorusEnvironment)
    size = Float64(m.torus.size)
    return (
        kind=:torus,
        bounds=(0.0, size, 0.0, size),
        size=size,
        n_agents=length(m.positions),
        vision_range=m.config.vision_range,
        motor=_motor_config(m.config.motor),
        agent_radius=Float64(m.config.agent_radius),
        norm_mode=m.config.norm_mode,
        norm_sigma=Float64(m.config.norm_sigma),
        conspecific_gain=Float64(m.config.conspecific_gain),
        sensor=_sensor_config(m.config.sensor),
        n_colours=Int(m.config.n_colours),
        colour_sensing=Bool(m.config.colour_sensing),
        colours=copy(m.colours),
    )
end

function _environment_config(m::ForageEnvironment)
    size = Float64(m.torus.size)
    return (
        kind=:forage,
        bounds=(0.0, size, 0.0, size),
        size=size,
        n_agents=length(m.positions),
        vision_range=m.config.vision_range,
        source_vision_range=m.config.source_vision_range,
        source_position=m.source_position,
        source_gain=Float64(m.config.source_gain),
        n_lookouts=m.config.n_lookouts,
        motor=_motor_config(m.config.motor),
        agent_radius=Float64(m.config.agent_radius),
        norm_mode=m.config.norm_mode,
        norm_sigma=Float64(m.config.norm_sigma),
        conspecific_gain=Float64(m.config.conspecific_gain),
        sensor=_sensor_config(m.config.sensor),
        signalling=Bool(m.config.signalling),
        signal_range=Float64(m.config.signal_range),
        signal_gain=Float64(m.config.signal_gain),
        capture_radius=Float64(m.config.capture_radius),
        conspecific_vision=Bool(m.config.conspecific_vision),
        n_colours=Int(m.config.n_colours),
        colour_sensing=Bool(m.config.colour_sensing),
        colours=copy(m.colours),
    )
end

_environment_config(m::SituatedEnvironment{CollectiveMode}) =
    _environment_config(TorusEnvironment(m))

_environment_config(m::SituatedEnvironment{ForageMode}) =
    _environment_config(ForageEnvironment(m))

_environment_config(m::Environment) = (kind=Symbol(lowercase(string(nameof(typeof(m))))), bounds=nothing, size=nothing)

function network_snapshot(r::FalandaysReservoir)
    return (
        kind=:falandays,
        adjacency=Float64.(r.recurrent_mask),
        state=copy(r.acts),
        spikes=copy(r.spikes),
    )
end

function network_snapshot(r::CompartmentalReservoir)
    n = r.wiring.N
    adjacency = zeros(Float64, n, n)
    @inbounds for dst in 1:n, src0 in r.wiring.node_sources[dst, :]
        if 0 <= src0 < n
            adjacency[src0 + 1, dst] = 1.0
        end
    end
    return (
        kind=:compartmental,
        adjacency=adjacency,
        state=copy(r.V),
        spikes=copy(r.spike_buffer),
    )
end

const _SWARM_ENVIRONMENT_KWARGS = Set{Symbol}((
    :space_size,
    :sens_agent_dist,
    :vision_range,
    :source_vision_range,
    :sensory_noise,
    :sensory_scaling,
    :visual_coupling,
    :physical_coupling,
    :conspecific_vision,
    :source_position,
    :source_gain,
    :n_lookouts,
    :norm_mode,
    :norm_sigma,
    :conspecific_gain,
    :signalling,
    :signal_range,
    :signal_gain,
    :capture_radius,
    :n_colours,
    :colour_sensing,
    :colours,
    :motor,
    :sensor,
    :agent_radius,
    :record_inputs,
))

function _extract_swarm_environment_kwargs!(options::Dict{Symbol,Any}, swarm_kwargs)
    out = _merge_kwdicts(swarm_kwargs)
    for key in _SWARM_ENVIRONMENT_KWARGS
        if haskey(options, key)
            out[key] = pop!(options, key)
        end
    end
    return out
end

function _simulation_config(
    c::Ensemble;
    ticks::Integer,
    seed,
    record,
    every::Integer,
    window::Integer,
    n_nodes::Integer,
    ablation::Symbol=:none,
    ablation_notes=(),
    interventions=nothing,
)
    ids = entity_ids(c)
    agent_configs = Tuple(
        (
            id=ids[slot],
            slot=slot,
            body=_body_config(body_at_slot(c, slot)),
            network=network_snapshot(agent_at_slot(c, slot).reservoir),
        )
        for slot in 1:nagents(c)
    )
    return (
        ticks=Int(ticks),
        seed=seed,
        record=Tuple(record),
        every=Int(every),
        window=Int(window),
        n_agents=nagents(c),
        n_nodes=Int(n_nodes),
        environment=_environment_config(c.environment),
        agents=agent_configs,
        entity_ids=Tuple(ids),
        bodies=Tuple(agent.body for agent in agent_configs),
        networks=Tuple(agent.network for agent in agent_configs),
        ablation=ablation,
        ablation_notes=Tuple(ablation_notes),
        interventions=interventions === nothing ? () : Tuple(interventions),
    )
end

function _task_spec(task::TaskSpec)
    return task
end

function _task_spec(task::Union{Symbol,AbstractString})
    spec = resolve_task(Symbol(task))
    spec isa TaskSpec || throw(ArgumentError(
        "registered task :$(Symbol(task)) resolved to $(typeof(spec)); expected TaskSpec",
    ))
    return spec
end

function _build_ensemble(task_spec::TaskSpec, node::Symbol; ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, kwargs...)
    options = _kwdict(kwargs)
    record_channels = _record_symbols(record)

    n_agents = haskey(options, :n_agents) ? pop!(options, :n_agents) : nothing
    explicit_n_nodes =
        haskey(options, :n_nodes) ? pop!(options, :n_nodes) :
        haskey(options, :N) ? pop!(options, :N) :
        nothing
    window_arg = haskey(options, :window) ? pop!(options, :window) : nothing
    spectral_every = haskey(options, :spectral_every) ? Int(pop!(options, :spectral_every)) : 1
    explicit_task_kwargs = haskey(options, :task_kwargs) ? pop!(options, :task_kwargs) : NamedTuple()
    env_kwargs = haskey(options, :env_kwargs) ? pop!(options, :env_kwargs) : NamedTuple()
    environment_kwargs = haskey(options, :environment_kwargs) ? pop!(options, :environment_kwargs) : NamedTuple()
    swarm_kwargs = haskey(options, :swarm_kwargs) ? pop!(options, :swarm_kwargs) : NamedTuple()
    node_kwargs = haskey(options, :node_kwargs) ? pop!(options, :node_kwargs) : NamedTuple()
    body = haskey(options, :body) ? pop!(options, :body) : nothing
    ablation_arg = haskey(options, :ablation) ? pop!(options, :ablation) : nothing
    interventions_arg = haskey(options, :interventions) ? pop!(options, :interventions) : nothing
    intervention_schedule = _resolve_intervention_schedule(interventions_arg)

    is_swarm = is_multiagent(task_spec.setup)
    if n_agents !== nothing && !is_swarm
        throw(ArgumentError(
            "n_agents is only valid for a multi-agent task setup; task :$(task_spec.name) is single-agent",
        ))
    end

    task_options = _merge_kwdicts(env_kwargs, environment_kwargs, swarm_kwargs, explicit_task_kwargs)
    if is_swarm
        task_options = _extract_swarm_environment_kwargs!(options, task_options)
        n_agents !== nothing && (task_options[:n_agents] = Int(n_agents))
    elseif !isempty(_merge_kwdicts(swarm_kwargs))
        throw(ArgumentError("swarm_kwargs is only valid for a multi-agent task setup"))
    end

    node_kwargs = _merge_kwdicts(node_kwargs, options)
    _apply_falandays_task_defaults!(task_spec.name, node, is_swarm, node_kwargs, task_options)
    _preserve_swarm_falandays_defaults!(node, is_swarm, node_kwargs)
    ablation_sym = _prepare_ablation_options!(node, task_spec.name, is_swarm, node_kwargs, task_options, ablation_arg)
    ablation_notes = _ablation_notes(ablation_sym, node, task_spec.name, is_swarm)
    n_nodes = _resolve_n_nodes!(node, task_spec.name, explicit_n_nodes, node_kwargs, is_swarm)

    node_ctor = resolve_node(node)
    ensemble, recorder = _make_ensemble(
        task_spec,
        node,
        node_ctor;
        seed=seed,
        record=record_channels,
        every=every,
        spectral_every=spectral_every,
        n_nodes=n_nodes,
        node_kwargs=node_kwargs,
        task_kwargs=task_options,
        body=body,
        ablation=ablation_sym,
    )
    tick_count = ticks === nothing ? task_spec.default_ticks : Int(ticks)
    window = window_arg === nothing ? min(tick_count, task_spec.default_window) : Int(window_arg)

    return (
        ensemble=ensemble,
        recorder=recorder,
        task=task_spec.name,
        node=node,
        ticks=tick_count,
        window=window,
        record=record_channels,
        every=Int(every),
        seed=seed,
        n_nodes=n_nodes,
        ablation=ablation_sym,
        ablation_notes=Tuple(ablation_notes),
        interventions=intervention_schedule,
    )
end

function _build_ensemble(task::Union{Symbol,AbstractString}, node::Symbol; kwargs...)
    return _build_ensemble(_task_spec(task), node; kwargs...)
end

"""
    simulate(task; node=:falandays, ticks=nothing, seed=0, record=..., every=1, kwargs...)

Run a single-agent task such as `:wall`, `:tracking`, `:pong`, or `:cartpole`,
or run a swarm with `simulate(:torus; node=:falandays, n_agents=5)`.

Pass `interventions=[(tick=1800, verb=:freeze_plasticity)]` to apply a live-reservoir
verb (`:freeze_plasticity`, `:clamp_target`, or `:zero_recurrent`) at a chosen tick
(inclusive) — e.g. to freeze plasticity after the network self-organizes and test
whether the learned structure persists without ongoing adaptation.
"""
function simulate(task::TaskSpec; node=:falandays, ticks=nothing, seed=0, record=_DEFAULT_RECORD_CHANNELS, every::Integer=1, metrics=nothing, kwargs...)
    node_sym = Symbol(node)
    setup = _build_ensemble(task, node_sym; ticks=ticks, seed=seed, record=record, every=every, kwargs...)
    result_metrics = rollout!(setup.ensemble, setup.ticks; window=setup.window, metrics=metrics, interventions=setup.interventions)
    config = _simulation_config(
        setup.ensemble;
        ticks=setup.ticks,
        seed=setup.seed,
        record=setup.record,
        every=setup.every,
        window=setup.window,
        n_nodes=setup.n_nodes,
        ablation=setup.ablation,
        ablation_notes=setup.ablation_notes,
        interventions=setup.interventions,
    )
    return SimResult(setup.recorder, result_metrics, setup.task, setup.node, config)
end

simulate(task::Union{Symbol,AbstractString}; kwargs...) = simulate(_task_spec(task); kwargs...)
