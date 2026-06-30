using Random

const _FALANDAYS_MODEL_SYMS = Set((:falandays, :falandays_base, :falandays_noisy,
                                   :falandays_ablated, :falandays_hemispheric, :falandays_oosawa))
const _DENSE_COMPARTMENTAL_MODEL_SYMS = Set((:dense, :compartmental_dense))
const _STRUCTURED_COMPARTMENTAL_MODEL_SYMS = Set((:compartmental, :structured, :compartmental_structured))

function _canonical_model_sym(model_sym::Union{Symbol,AbstractString})
    sym = Symbol(model_sym)
    sym in _FALANDAYS_MODEL_SYMS && return sym
    sym in _DENSE_COMPARTMENTAL_MODEL_SYMS && return :compartmental_dense
    sym in _STRUCTURED_COMPARTMENTAL_MODEL_SYMS && return :compartmental_structured
    return sym
end

function _model_param_type(model_sym::Symbol)
    sym = _canonical_model_sym(model_sym)
    sym in _FALANDAYS_MODEL_SYMS && return FalandaysParams
    sym == :compartmental_dense && return DenseCompartmental
    sym == :compartmental_structured && return StructuredCompartmental
    throw(ArgumentError("no evolvable parameter type is known for model :$(model_sym)"))
end

_model_mode(::Type{DenseCompartmental}) = :dense
_model_mode(::Type{StructuredCompartmental}) = :structured

function _with_learn_on(p::FalandaysParams, learn_on)
    learn_on === nothing && return p
    return FalandaysParams(
        leak=p.leak,
        lrate_wmat=p.lrate_wmat,
        lrate_targ=p.lrate_targ,
        threshold_mult=p.threshold_mult,
        targ_min=p.targ_min,
        input_weight=p.input_weight,
        weight_init_std=p.weight_init_std,
        learn_on=Bool(learn_on),
    )
end

function _node_kwargs_for_model(model_sym::Symbol, model; learn_on=nothing)
    node_sym = _canonical_model_sym(model_sym)
    options = Dict{Symbol,Any}()

    if node_sym in _FALANDAYS_MODEL_SYMS
        params =
            model isa FalandaysParams ? model :
            model isa AbstractVector{<:Real} ? unpack_params(FalandaysParams, model) :
            throw(ArgumentError("Falandays rollout model must be FalandaysParams or a raw parameter vector"))
        options[:params] = _with_learn_on(params, learn_on)
        return options
    end

    genome_type = _model_param_type(node_sym)
    if model isa AbstractCompartmental
        options[:genome] = model
    elseif model isa AbstractVector{<:Real}
        options[:raw] = Vector{Float64}(Float64.(model))
    else
        throw(ArgumentError("compartmental rollout model must be an AbstractCompartmental genome or raw parameter vector"))
    end
    options[:mode] = _model_mode(genome_type)
    return options
end

function _metric_value(metrics_nt, key::Symbol)
    key in propertynames(metrics_nt) ||
        throw(KeyError("metric :$(key) is absent from rollout metrics"))
    return Float64(getproperty(metrics_nt, key))
end

function _metric_default(metrics_nt, key::Symbol, default)
    return key in propertynames(metrics_nt) ? getproperty(metrics_nt, key) : default
end

"""
    rollout(task, model, seed; ticks, N, model_sym=:falandays, kwargs...)

Build a deterministic single-agent task collective, stamp `model` into the
reservoir, run it, and return task score, normalized score, and liveness
diagnostics.
"""
function rollout(
    task,
    model,
    seed;
    ticks=nothing,
    N=nothing,
    model_sym=:falandays,
    link_p::Real=0.1,
    rho::Real=0.2,
    window=nothing,
    lam::Real=1.0,
    record=Symbol[],
    every::Integer=1,
    learn_on=nothing,
    node_kwargs=NamedTuple(),
    env_kwargs=NamedTuple(),
    kwargs...,
)
    task_spec = resolve_task(task)
    task_spec isa TaskSpec ||
        throw(ArgumentError("rollout supports TaskSpec tasks, got $(typeof(task_spec))"))

    node_sym = _canonical_model_sym(model_sym)
    node_ctor = resolve_node(node_sym)

    n_nodes = N === nothing ? _default_node_count(node_sym) : Int(N)
    tick_count = ticks === nothing ? task_spec.default_ticks : Int(ticks)
    win = window === nothing ? min(tick_count, task_spec.default_window) : Int(window)

    node_options = _merge_kwdicts(node_kwargs, kwargs)
    stamped = _node_kwargs_for_model(node_sym, model; learn_on=learn_on)
    for (key, value) in stamped
        node_options[key] = value
    end
    node_options[:link_p] = Float64(link_p)
    if node_sym == :compartmental_dense || node_sym == :compartmental_structured
        node_options[:rho] = Float64(rho)
    end

    env_options = _merge_kwdicts(env_kwargs)
    if task_spec.name == :wall
        env_options[:lam] = Float64(lam)
    end

    collective, _ = _make_task_collective(
        task_spec,
        node_sym,
        node_ctor;
        seed=Int(seed),
        record=record,
        every=every,
        n_nodes=n_nodes,
        node_kwargs=node_options,
        env_kwargs=env_options,
    )

    metrics_nt = rollout!(collective, tick_count; window=win)
    raw_score = _metric_value(metrics_nt, task_spec.score_key)
    norm = normalized_score(task_spec, raw_score)

    return (
        task=task_spec.name,
        model_sym=node_sym,
        seed=Int(seed),
        ticks=tick_count,
        N=n_nodes,
        score=Float64(raw_score),
        norm_score=Float64(norm),
        alive=Bool(_metric_default(metrics_nt, :alive, false)),
        rate_mean=Float64(_metric_default(metrics_nt, :rate_mean, NaN)),
        rate_var=Float64(_metric_default(metrics_nt, :rate_var, NaN)),
        total_spikes_window=Float64(_metric_default(metrics_nt, :total_spikes_window, NaN)),
        metrics=metrics_nt,
    )
end
