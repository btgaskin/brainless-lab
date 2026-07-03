function _node_state_channel_vector(entry, channel::Symbol, t::Integer)
    if entry isa AbstractVector
        if all(x -> x isa Real, entry)
            return Float64.(entry)
        elseif all(x -> x isa AbstractVector, entry)
            out = Float64[]
            for agent_entry in entry
                append!(out, Float64.(vec(agent_entry)))
            end
            return out
        end
    end
    throw(ArgumentError("node_target_error needs :$(channel) entries shaped as node vectors or vectors of agent node vectors; bad entry at tick $(t)"))
end

"""
    node_target_error(sim)

Compute each recorded Falandays node's absolute distance from its homeostatic
target. Requires both `:acts` and `:targets` recorded: run
`simulate(...; record=(:acts, :targets, ...))`.

Returns `(per_node_error, mean_over_nodes, final_distribution)`, where
`per_node_error` is a nodes-by-time matrix of `|acts - targets|`.
"""
function node_target_error(sim::SimResult)
    acts_raw = getchannel(sim.recorder, :acts)
    targets_raw = getchannel(sim.recorder, :targets)
    isempty(acts_raw) && throw(ArgumentError("node_target_error needs the :acts channel recorded; run simulate(...; record=(:acts, :targets, ...))"))
    isempty(targets_raw) && throw(ArgumentError("node_target_error needs the :targets channel recorded; run simulate(...; record=(:acts, :targets, ...))"))
    length(acts_raw) == length(targets_raw) ||
        throw(DimensionMismatch("node_target_error expected :acts and :targets to have the same number of samples"))

    n_ticks = length(acts_raw)
    columns = Vector{Vector{Float64}}(undef, n_ticks)
    @inbounds for t in 1:n_ticks
        acts = _node_state_channel_vector(acts_raw[t], :acts, t)
        targets = _node_state_channel_vector(targets_raw[t], :targets, t)
        length(acts) == length(targets) ||
            throw(DimensionMismatch("node_target_error sample $(t) has $(length(acts)) acts but $(length(targets)) targets"))
        columns[t] = abs.(acts .- targets)
    end

    n_nodes = length(columns[1])
    per_node_error = Matrix{Float64}(undef, n_nodes, n_ticks)
    @inbounds for t in 1:n_ticks
        length(columns[t]) == n_nodes ||
            throw(DimensionMismatch("node_target_error sample $(t) has $(length(columns[t])) nodes; expected $(n_nodes)"))
        per_node_error[:, t] .= columns[t]
    end

    mean_over_nodes = Vector{Float64}(undef, n_ticks)
    @inbounds for t in 1:n_ticks
        mean_over_nodes[t] = n_nodes == 0 ? NaN : sum(@view per_node_error[:, t]) / n_nodes
    end

    # Weight-update magnitude scales with |error|, so |error| is the primary
    # "how hard is this node working" signal. A separate per-node update-count
    # channel would need a hook in learn! and is deferred.
    final_distribution = copy(@view per_node_error[:, end])
    return (;
        per_node_error=per_node_error,
        mean_over_nodes=mean_over_nodes,
        final_distribution=final_distribution,
    )
end
