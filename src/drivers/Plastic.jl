Base.@kwdef struct PlasticRunner <: Runner
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
    _model_param_type(node_sym) === FalandaysParams ||
        throw(ArgumentError("PlasticRunner currently records Falandays online-plastic diagnostics only"))

    out = rollout(
        task,
        model,
        seed;
        model_sym=node_sym,
        N=N,
        ticks=ticks,
        link_p=link_p,
        window=window,
        lam=lam,
        learn_on=true,
        record=Symbol[],
        return_ensemble=true,
    )

    reservoir = out.ensemble.agents[1].reservoir

    return (
        task=out.task,
        model_sym=out.model_sym,
        seed=out.seed,
        ticks=out.ticks,
        N=out.N,
        score=out.score,
        norm_score=out.norm_score,
        alive=out.alive,
        rate_mean=out.rate_mean,
        rate_var=out.rate_var,
        total_spikes_window=out.total_spikes_window,
        target_mean=_mean_float(reservoir.targets),
        target_var=_variance_float(reservoir.targets),
        weight_delta_norm=sqrt(sum(abs2, reservoir.wmat .- reservoir.wmat0)),
        weight_delta_mean_abs=_mean_float(abs.(vec(reservoir.wmat .- reservoir.wmat0))),
        metrics=out.metrics,
    )
end

function evaluate(runner::PlasticRunner)
    results = Dict{Symbol,Vector{Any}}()
    summary = Dict{Symbol,Any}()
    for task in runner.tasks
        task_spec = resolve_task(task)
        outs = Any[]
        for seed in runner.seeds
            push!(
                outs,
                _plastic_rollout(
                    task_spec,
                    runner.model,
                    seed;
                    model_sym=runner.model_sym,
                    N=runner.N,
                    ticks=runner.ticks,
                    link_p=runner.link_p,
                    window=runner.window,
                    lam=runner.lam,
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
