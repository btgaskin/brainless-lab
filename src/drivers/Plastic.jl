Base.@kwdef struct PlasticDriver <: Driver
    model_sym::Symbol = :falandays
    model::Any = pack_params(FalandaysParams())
    tasks::Tuple = (:wall,)
    seeds::Tuple = (0,)
    N::Union{Nothing,Int} = nothing
    ticks::Any = nothing
    link_p::Float64 = 0.1
    window::Any = nothing
    lam::Float64 = 1.0
end

function _variance_float(values)
    isempty(values) && return 0.0
    m = _mean_float(values)
    total = 0.0
    for value in values
        total += (Float64(value) - m)^2
    end
    return total / length(values)
end

function _plastic_rollout(
    task,
    model,
    seed;
    model_sym=:falandays,
    N=nothing,
    ticks=nothing,
    link_p::Real=0.1,
    window=nothing,
    lam::Real=1.0,
)
    node_sym = _canonical_model_sym(model_sym)
    node_sym in _FALANDAYS_MODEL_SYMS ||
        throw(ArgumentError("PlasticDriver currently records Falandays online-plastic diagnostics only"))

    task_spec = resolve_task(task)
    n_nodes = N === nothing ? _default_node_count(node_sym) : Int(N)
    tick_count = ticks === nothing ? task_spec.default_ticks : Int(ticks)
    win = window === nothing ? min(tick_count, task_spec.default_window) : Int(window)

    node_options = _node_kwargs_for_model(node_sym, model; learn_on=true)
    node_options[:link_p] = Float64(link_p)

    env_options = Dict{Symbol,Any}()
    task_spec.name == :wall && (env_options[:lam] = Float64(lam))

    collective, _ = _make_task_collective(
        task_spec,
        node_sym,
        resolve_node(node_sym);
        seed=Int(seed),
        record=Symbol[],
        every=1,
        n_nodes=n_nodes,
        node_kwargs=node_options,
        env_kwargs=env_options,
    )

    metrics_nt = rollout!(collective, tick_count; window=win)
    reservoir = collective.agents[1].reservoir
    raw_score = _metric_value(metrics_nt, task_spec.score_key)

    return (
        task=task_spec.name,
        model_sym=node_sym,
        seed=Int(seed),
        ticks=tick_count,
        N=n_nodes,
        score=Float64(raw_score),
        norm_score=Float64(normalized_score(task_spec, raw_score)),
        alive=Bool(_metric_default(metrics_nt, :alive, false)),
        rate_mean=Float64(_metric_default(metrics_nt, :rate_mean, NaN)),
        rate_var=Float64(_metric_default(metrics_nt, :rate_var, NaN)),
        total_spikes_window=Float64(_metric_default(metrics_nt, :total_spikes_window, NaN)),
        target_mean=_mean_float(reservoir.targets),
        target_var=_variance_float(reservoir.targets),
        weight_delta_norm=sqrt(sum(abs2, reservoir.wmat .- reservoir.wmat0)),
        weight_delta_mean_abs=_mean_float(abs.(vec(reservoir.wmat .- reservoir.wmat0))),
        metrics=metrics_nt,
    )
end

function evaluate(driver::PlasticDriver)
    results = Dict{Symbol,Vector{Any}}()
    summary = Dict{Symbol,Any}()
    for task in driver.tasks
        task_spec = resolve_task(task)
        outs = Any[]
        for seed in driver.seeds
            push!(
                outs,
                _plastic_rollout(
                    task_spec,
                    driver.model,
                    seed;
                    model_sym=driver.model_sym,
                    N=driver.N,
                    ticks=driver.ticks,
                    link_p=driver.link_p,
                    window=driver.window,
                    lam=driver.lam,
                ),
            )
        end
        results[task_spec.name] = outs
        summary[task_spec.name] = (
            _summarize_rollouts(outs)...,
            target_mean=_mean_float([out.target_mean for out in outs]),
            target_var=_mean_float([out.target_var for out in outs]),
            weight_delta_norm=_mean_float([out.weight_delta_norm for out in outs]),
            weight_delta_mean_abs=_mean_float([out.weight_delta_mean_abs for out in outs]),
        )
    end
    return (results=results, summary=summary)
end
