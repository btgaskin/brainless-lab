Base.@kwdef struct FixedRunner <: Runner
    model_sym::Symbol = :falandays
    model::Any = pack_params(FalandaysParams())
    tasks::Tuple = (:wall,)
    seeds::Tuple = (0,)
    N::Union{Nothing,Int} = nothing
    ticks::Any = nothing
    link_p::Float64 = 0.1
    rho::Float64 = 0.2
    window::Any = nothing
    lam::Float64 = 1.0
end

function _summarize_rollouts(outs)
    scores = [out.score for out in outs]
    norms = [out.norm_score for out in outs]
    alive = [out.alive ? 1.0 : 0.0 for out in outs]
    return (
        score=_mean_float(scores),
        norm_score=_mean_float(norms),
        fraction_alive=_mean_float(alive),
        n=length(outs),
    )
end

function evaluate(runner::FixedRunner)
    results = Dict{Symbol,Vector{Any}}()
    summary = Dict{Symbol,Any}()
    for task in runner.tasks
        task_spec = resolve_task(task)
        outs = Any[]
        for seed in runner.seeds
            push!(
                outs,
                rollout(
                    task_spec,
                    runner.model,
                    seed;
                    model_sym=runner.model_sym,
                    N=runner.N,
                    ticks=runner.ticks,
                    link_p=runner.link_p,
                    rho=runner.rho,
                    window=runner.window,
                    lam=runner.lam,
                ),
            )
        end
        results[task_spec.name] = outs
        summary[task_spec.name] = _summarize_rollouts(outs)
    end
    return (results=results, summary=summary)
end
