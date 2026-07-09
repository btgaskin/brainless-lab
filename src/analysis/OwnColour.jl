# EXPERIMENTAL own-colour decoder.
#
# In colour-sensing swarm runs, an agent sees colour-specific banks for its
# neighbours but never receives its own colour tag directly. Decodability of the
# agent's own colour from reservoir state is therefore an offline readout of an
# implicit self-representation, not an online task metric.

function _own_colour_environment_config(sim::SimResult, name::Symbol)
    hasproperty(sim.config, :environment) ||
        throw(ArgumentError("$(name) needs sim.config.environment from a swarm run"))
    env = getproperty(sim.config, :environment)
    hasproperty(env, :n_colours) ||
        throw(ArgumentError("$(name) needs a colour-tagged torus or forage swarm run"))
    return env
end

function _own_colour_agent_colours(sim::SimResult, name::Symbol)
    env = _own_colour_environment_config(sim, name)
    n_colours = Int(getproperty(env, :n_colours))
    n_colours >= 2 ||
        throw(ArgumentError("$(name) needs n_colours >= 2; got $(n_colours)"))
    hasproperty(env, :colours) ||
        throw(ArgumentError("$(name) needs sim.config.environment.colours"))
    colours = Int[Int(c) for c in getproperty(env, :colours)]
    isempty(colours) && throw(ArgumentError("$(name) needs at least one coloured agent"))
    all(c -> 0 <= c < n_colours, colours) ||
        throw(ArgumentError("$(name) colours must be in 0:$(n_colours - 1)"))
    present = sort!(collect(unique(colours)))
    length(present) >= 2 ||
        throw(ArgumentError("$(name) needs at least two colours present"))
    return colours, n_colours, present
end

function _own_colour_resolve_channel(sim::SimResult, channel, name::Symbol)
    channel_sym = Symbol(channel)
    channel_sym in (:rate, :rates) &&
        throw(ArgumentError("$(name) rejects :$(channel_sym); rate channels collapse nodes and cannot support a reservoir-state decoder"))

    if channel_sym === :acts && isempty(getchannel(sim.recorder, :acts))
        if !isempty(getchannel(sim.recorder, :spikes))
            return :spikes
        end
        if !isempty(getchannel(sim.recorder, :rate)) || !isempty(getchannel(sim.recorder, :rates))
            throw(ArgumentError("$(name) needs :acts or :spikes recorded; this run is rate-only"))
        end
        throw(ArgumentError("$(name) needs :acts recorded, or :spikes for the fallback; run simulate(...; record=(:acts, :spikes, ...))"))
    end

    isempty(getchannel(sim.recorder, channel_sym)) &&
        throw(ArgumentError("$(name) needs the :$(channel_sym) channel recorded"))
    return channel_sym
end

function _own_colour_matrix_shape(mats::AbstractVector, name::Symbol)
    isempty(mats) && throw(ArgumentError("$(name) needs at least one recorded agent"))
    n_ticks = size(mats[1], 1)
    n_nodes = size(mats[1], 2)
    n_ticks >= 1 || throw(ArgumentError("$(name) needs at least one recorded tick"))
    n_nodes >= 1 || throw(ArgumentError("$(name) needs non-empty node vectors"))
    @inbounds for i in eachindex(mats)
        size(mats[i], 1) == n_ticks ||
            throw(DimensionMismatch("$(name) agent $(i) has $(size(mats[i], 1)) ticks; expected $(n_ticks)"))
        size(mats[i], 2) == n_nodes ||
            throw(DimensionMismatch("$(name) agent $(i) has $(size(mats[i], 2)) nodes; expected $(n_nodes)"))
    end
    return n_ticks, n_nodes, length(mats)
end

function _own_colour_mean_column(mat::AbstractMatrix{<:Real}, rows, j::Integer)
    total = 0.0
    count = 0
    @inbounds for t in rows
        x = Float64(mat[t, j])
        if isfinite(x)
            total += x
            count += 1
        end
    end
    return count == 0 ? NaN : total / count
end

function _own_colour_effective_window(n_ticks::Integer, window)
    window === nothing && return Int(n_ticks)
    w = Int(window)
    return w <= 0 ? Int(n_ticks) : min(w, Int(n_ticks))
end

function _own_colour_time_mean_features(mats::AbstractVector, window, name::Symbol)
    n_ticks, n_nodes, n_agents = _own_colour_matrix_shape(mats, name)
    rows = _forage_tail_rows(n_ticks, window)
    X = Matrix{Float64}(undef, n_agents, n_nodes)
    @inbounds for agent in 1:n_agents
        mat = mats[agent]
        for node in 1:n_nodes
            X[agent, node] = _own_colour_mean_column(mat, rows, node)
        end
    end
    return X, collect(1:n_agents), _own_colour_effective_window(n_ticks, window)
end

function _own_colour_window_starts(n_ticks::Integer, window)
    w = _own_colour_effective_window(n_ticks, window)
    starts = collect(1:w:(Int(n_ticks) - w + 1))
    isempty(starts) && push!(starts, 1)
    return starts, w
end

function _own_colour_windowed_features(mats::AbstractVector, window, name::Symbol)
    n_ticks, n_nodes, n_agents = _own_colour_matrix_shape(mats, name)
    starts, w = _own_colour_window_starts(n_ticks, window)
    n_samples = n_agents * length(starts)
    X = Matrix{Float64}(undef, n_samples, n_nodes)
    groups = Vector{Int}(undef, n_samples)
    row = 1
    @inbounds for agent in 1:n_agents
        mat = mats[agent]
        for start in starts
            rows = start:(start + w - 1)
            for node in 1:n_nodes
                X[row, node] = _own_colour_mean_column(mat, rows, node)
            end
            groups[row] = agent
            row += 1
        end
    end
    return X, groups, w
end

function _own_colour_features(sim::SimResult, channel, window, reduction::Symbol, name::Symbol)
    channel_sym = _own_colour_resolve_channel(sim, channel, name)
    mats = _analysis_agent_node_matrices(sim, channel_sym, name)
    if reduction === :time_mean
        X, groups, used_window = _own_colour_time_mean_features(mats, window, name)
    elseif reduction === :windowed
        X, groups, used_window = _own_colour_windowed_features(mats, window, name)
    else
        throw(ArgumentError("$(name) reduction must be :time_mean or :windowed"))
    end
    return X, groups, channel_sym, used_window
end

function _own_colour_fit_zscore(X::AbstractMatrix{<:Real}, idxs::AbstractVector{<:Integer})
    p = size(X, 2)
    means = Vector{Float64}(undef, p)
    scales = Vector{Float64}(undef, p)
    @inbounds for j in 1:p
        total = 0.0
        count = 0
        for i in idxs
            x = Float64(X[i, j])
            if isfinite(x)
                total += x
                count += 1
            end
        end
        mean = count == 0 ? 0.0 : total / count
        ss = 0.0
        for i in idxs
            x = Float64(X[i, j])
            if isfinite(x)
                d = x - mean
                ss += d * d
            end
        end
        sd = count <= 1 ? 0.0 : sqrt(ss / count)
        means[j] = mean
        scales[j] = isfinite(sd) && sd > 0.0 ? sd : 1.0
    end
    return means, scales
end

function _own_colour_standardized_matrix(
    X::AbstractMatrix{<:Real},
    idxs::AbstractVector{<:Integer},
    means::AbstractVector{<:Real},
    scales::AbstractVector{<:Real},
)
    out = Matrix{Float64}(undef, length(idxs), size(X, 2))
    @inbounds for (row, i) in enumerate(idxs)
        for j in axes(X, 2)
            x = Float64(X[i, j])
            out[row, j] = isfinite(x) ? (x - Float64(means[j])) / Float64(scales[j]) : 0.0
        end
    end
    return out
end

function _own_colour_shrinkage(shrinkage, n_train::Integer, n_features::Integer)
    if shrinkage === :auto
        denom = max(Int(n_train) + Int(n_features), 1)
        return clamp(Float64(n_features) / denom, 0.05, 0.95)
    elseif shrinkage isa Real
        α = Float64(shrinkage)
        0.0 <= α <= 1.0 ||
            throw(ArgumentError("own_colour_decodability shrinkage must be in [0, 1], or :auto"))
        return α
    end
    throw(ArgumentError("own_colour_decodability shrinkage must be in [0, 1], or :auto"))
end

function _own_colour_class_means(X::AbstractMatrix{<:Real}, y::AbstractVector{<:Integer}, classes)
    p = size(X, 2)
    means = Dict{Int,Vector{Float64}}()
    counts = Dict{Int,Int}()
    for class in classes
        means[Int(class)] = zeros(Float64, p)
        counts[Int(class)] = 0
    end
    @inbounds for i in axes(X, 1)
        c = Int(y[i])
        counts[c] += 1
        μ = means[c]
        for j in 1:p
            μ[j] += Float64(X[i, j])
        end
    end
    for class in classes
        c = Int(class)
        n = counts[c]
        n >= 1 || continue
        μ = means[c]
        @inbounds for j in 1:p
            μ[j] /= n
        end
    end
    return means, counts
end

function _own_colour_regularized_covariance(
    X::AbstractMatrix{<:Real},
    y::AbstractVector{<:Integer},
    means::Dict{Int,Vector{Float64}},
    shrinkage,
)
    n, p = size(X)
    cov = zeros(Float64, p, p)
    @inbounds for i in 1:n
        μ = means[Int(y[i])]
        for a in 1:p
            da = Float64(X[i, a]) - μ[a]
            for b in 1:p
                cov[a, b] += da * (Float64(X[i, b]) - μ[b])
            end
        end
    end

    dof = max(n - length(means), 1)
    @inbounds for a in 1:p, b in 1:p
        cov[a, b] /= dof
    end

    α = _own_colour_shrinkage(shrinkage, n, p)
    reg = Matrix{Float64}(undef, p, p)
    @inbounds for a in 1:p, b in 1:p
        reg[a, b] = (1.0 - α) * cov[a, b]
    end
    @inbounds for j in 1:p
        target = isfinite(cov[j, j]) && cov[j, j] > 0.0 ? cov[j, j] : 1.0
        reg[j, j] += α * target + 1e-8
    end
    return reg
end

function _own_colour_quadratic_distance(inv_source::AbstractMatrix{<:Real}, x, μ)
    p = length(μ)
    diff = Vector{Float64}(undef, p)
    @inbounds for j in 1:p
        diff[j] = Float64(x[j]) - Float64(μ[j])
    end
    sol = inv_source \ diff
    total = 0.0
    @inbounds for j in 1:p
        total += diff[j] * sol[j]
    end
    return isfinite(total) ? total : Inf
end

function _own_colour_predict_lda(
    X_train::AbstractMatrix{<:Real},
    y_train::AbstractVector{<:Integer},
    X_test::AbstractMatrix{<:Real};
    shrinkage,
)
    classes = sort!(collect(unique(Int[y for y in y_train])))
    isempty(classes) && throw(ArgumentError("own_colour_decodability needs at least one training sample"))
    means, _ = _own_colour_class_means(X_train, y_train, classes)
    reg = _own_colour_regularized_covariance(X_train, y_train, means, shrinkage)
    preds = Vector{Int}(undef, size(X_test, 1))
    @inbounds for i in axes(X_test, 1)
        best_class = classes[1]
        best_dist = Inf
        x = @view X_test[i, :]
        for class in classes
            dist = _own_colour_quadratic_distance(reg, x, means[Int(class)])
            if dist < best_dist
                best_dist = dist
                best_class = Int(class)
            end
        end
        preds[i] = best_class
    end
    return preds
end

function _own_colour_agent_labels(groups::AbstractVector{<:Integer}, agent_colours::AbstractVector{<:Integer})
    labels = Vector{Int}(undef, length(groups))
    @inbounds for i in eachindex(groups)
        g = Int(groups[i])
        1 <= g <= length(agent_colours) ||
            throw(ArgumentError("own_colour_decodability group $(g) outside 1:$(length(agent_colours))"))
        labels[i] = Int(agent_colours[g])
    end
    return labels
end

function _own_colour_loao(
    X::AbstractMatrix{<:Real},
    groups::AbstractVector{<:Integer},
    agent_colours::AbstractVector{<:Integer},
    n_colours::Integer;
    classifier::Symbol,
    shrinkage,
)
    classifier === :lda_shrink ||
        throw(ArgumentError("own_colour_decodability classifier must be :lda_shrink"))
    length(groups) == size(X, 1) ||
        throw(DimensionMismatch("own_colour_decodability group count $(length(groups)) does not match $(size(X, 1)) samples"))

    n_agents = length(agent_colours)
    sample_labels = _own_colour_agent_labels(groups, agent_colours)
    sample_preds = Vector{Int}(undef, length(sample_labels))
    per_fold = fill(NaN, n_agents)

    for agent in 1:n_agents
        train_idxs = Int[]
        test_idxs = Int[]
        @inbounds for i in eachindex(groups)
            if Int(groups[i]) == agent
                push!(test_idxs, i)
            else
                push!(train_idxs, i)
            end
        end
        isempty(test_idxs) && continue
        isempty(train_idxs) &&
            throw(ArgumentError("own_colour_decodability needs at least two agents for leave-one-agent-out CV"))

        means, scales = _own_colour_fit_zscore(X, train_idxs)
        X_train = _own_colour_standardized_matrix(X, train_idxs, means, scales)
        X_test = _own_colour_standardized_matrix(X, test_idxs, means, scales)
        y_train = Int[sample_labels[i] for i in train_idxs]
        y_test = Int[sample_labels[i] for i in test_idxs]
        preds = _own_colour_predict_lda(X_train, y_train, X_test; shrinkage=shrinkage)

        correct = 0
        @inbounds for (k, idx) in enumerate(test_idxs)
            sample_preds[idx] = preds[k]
            correct += preds[k] == y_test[k] ? 1 : 0
        end
        per_fold[agent] = correct / length(test_idxs)
    end

    per_class = fill(NaN, Int(n_colours))
    @inbounds for c in 0:(Int(n_colours) - 1)
        vals = Float64[]
        for agent in 1:n_agents
            if Int(agent_colours[agent]) == c && isfinite(per_fold[agent])
                push!(vals, per_fold[agent])
            end
        end
        per_class[c + 1] = _analysis_finite_mean(vals)
    end

    return (;
        accuracy=_analysis_finite_mean(per_class),
        per_fold=per_fold,
        per_class_accuracy=per_class,
        sample_predictions=sample_preds,
    )
end

function _own_colour_underpowered(agent_colours::AbstractVector{<:Integer}, present)
    counts = Int[]
    for class in present
        push!(counts, count(==(Int(class)), agent_colours))
    end
    min_count = minimum(counts)
    return min_count < 15, min_count
end

"""
    own_colour_decodability(sim; channel=:acts, window=nothing,
        reduction=:time_mean, classifier=:lda_shrink, shrinkage=:auto,
        n_perm=500, rng=MersenneTwister(0))

EXPERIMENTAL offline decoder for colour-sensing swarm runs. It asks whether an
agent's recorded reservoir state predicts that agent's own colour, even though
the colour-sensing body only provides colour-specific banks for neighbours and
excludes self.

The statistic is leave-one-agent-out, grouped cross-validated balanced accuracy
from a shrinkage-regularized LDA implemented as a whitened nearest-class-mean
classifier. The sample unit is the agent. With `reduction=:time_mean`, each
agent contributes one vector: the per-node mean over the trailing `window`
samples, or the full run when `window=nothing`. With `reduction=:windowed`,
each agent contributes non-overlapping window means, but all windows from the
held-out agent are excluded together during training.

`channel=:acts` is preferred for Falandays graded activation state. If `:acts`
was not recorded and `channel=:acts`, the analysis falls back to `:spikes`.
`:rate` and `:rates` are rejected because they collapse the node dimension.

The in-function null shuffles the agent-colour vector `n_perm` times and reruns
the full grouped CV pipeline, returning `shuffle_floor` and a one-sided
permutation `p_value`. This controls label structure within the recorded run,
but it does not control the index-derived seed/colour confound by itself. For a
scientific read, run the caller-level colour-blind control separately: repeat a
matched simulation with the same `n_colours` but `colour_sensing=false`, then
call `own_colour_decodability` on that control and require it to sit at chance.
"""
function own_colour_decodability(
    sim::SimResult;
    channel=:acts,
    window=nothing,
    reduction::Symbol=:time_mean,
    classifier::Symbol=:lda_shrink,
    shrinkage=:auto,
    n_perm::Integer=500,
    rng::AbstractRNG=MersenneTwister(0),
)
    name = :own_colour_decodability
    agent_colours, n_colours, present = _own_colour_agent_colours(sim, name)
    X, groups, used_channel, used_window = _own_colour_features(sim, channel, window, reduction, name)
    length(agent_colours) == maximum(groups) ||
        throw(DimensionMismatch("$(name) colour count $(length(agent_colours)) does not match recorded agents $(maximum(groups))"))
    n_perm_ = Int(n_perm)
    n_perm_ >= 1 || throw(ArgumentError("$(name) needs n_perm >= 1"))

    underpowered, min_count = _own_colour_underpowered(agent_colours, present)
    if underpowered
        @warn "own_colour_decodability is underpowered; use at least 15 agents per present colour for scientific reads" n_agents=length(agent_colours) n_colours=n_colours min_agents_per_colour=min_count
    end

    real = _own_colour_loao(
        X,
        groups,
        agent_colours,
        n_colours;
        classifier=classifier,
        shrinkage=shrinkage,
    )

    perms = Vector{Vector{Int}}(undef, n_perm_)
    for i in 1:n_perm_
        perms[i] = randperm(rng, length(agent_colours))
    end
    null_values = Float64[
        Float64(v) for v in parallel_map(perms) do perm
            shuffled = agent_colours[perm]
            _own_colour_loao(
                X,
                groups,
                shuffled,
                n_colours;
                classifier=classifier,
                shrinkage=shrinkage,
            ).accuracy
        end
    ]

    ge = 0
    for value in null_values
        isfinite(value) && value >= real.accuracy && (ge += 1)
    end
    shuffle_floor = _analysis_finite_mean(null_values)
    p_value = (ge + 1) / (n_perm_ + 1)

    return (;
        accuracy=real.accuracy,
        chance=1.0 / n_colours,
        shuffle_floor=shuffle_floor,
        effect=real.accuracy - shuffle_floor,
        p_value=p_value,
        per_fold=real.per_fold,
        per_class_accuracy=real.per_class_accuracy,
        n_agents=length(agent_colours),
        n_colours=n_colours,
        channel=used_channel,
        window=used_window,
        underpowered=underpowered,
    )
end
