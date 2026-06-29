function _train_seed_tuple(generation::Integer, k_trials::Integer, wiring_seed_base::Integer)
    k_trials = Int(k_trials)
    k_trials >= 1 || throw(ArgumentError("k_trials must be at least 1"))
    return Tuple(Int(wiring_seed_base) + Int(generation) * 10007 + i for i in 0:(k_trials - 1))
end

_seed_tuple(seeds::Integer) = Tuple(0:(Int(seeds) - 1))
_seed_tuple(seeds) = Tuple(Int.(collect(seeds)))

function evaluate_fitness_matrix(
    solutions,
    task,
    seeds;
    model_sym=:falandays,
    threaded::Bool=true,
    kwargs...,
)
    seed_tuple = _seed_tuple(seeds)
    isempty(seed_tuple) && throw(ArgumentError("seeds must contain at least one seed"))

    n_candidates = length(solutions)
    n_trials = length(seed_tuple)
    out = Matrix{Float64}(undef, n_candidates, n_trials)

    function eval_cell!(linear_index)
        i = fld(linear_index - 1, n_trials) + 1
        j = mod(linear_index - 1, n_trials) + 1
        out[i, j] = rollout(task, solutions[i], seed_tuple[j]; model_sym=model_sym, kwargs...).norm_score
        return nothing
    end

    total = n_candidates * n_trials
    if threaded && total > 1
        Base.Threads.@threads for idx in 1:total
            eval_cell!(idx)
        end
    else
        for idx in 1:total
            eval_cell!(idx)
        end
    end

    return out
end
