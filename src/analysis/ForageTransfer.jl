# EXPERIMENTAL forage information-transfer measures.
#
# For an informed-subset foraging swarm, a subset of "lookout" agents can see
# the source (source_gain > 0) and the rest are blind "followers"
# (source_gain = 0, same 128-receptor shape). The question is whether the source
# direction the lookouts hold is transmitted to the followers via vision.
#
#   forage_alignment    — Vanni "C": mean cos(heading - bearing-to-source) over a
#                         chosen agent subset. This is a PER-AGENT time average,
#                         so it is (near-)invariant under per-agent circular
#                         shifts -- its correct control is a DIFFERENCE OF
#                         CONDITIONS (vision-on minus vision-off), NOT
#                         `crossshift_null`.
#   lookout_follower_te — directed transfer entropy from lookout turning to
#                         follower turning. This IS a cross-agent measure, so the
#                         circular-shift null (`crossshift_null`) is the right
#                         gate: pass `s -> lookout_follower_te(s; ...).te`.
#
# Both are experimental. See notes/criticality-and-information (Vanni/Grigolini,
# lookout->flock transmission) and designing-analyses.md (null discipline).

function _forage_source_and_torus(sim::SimResult, name::Symbol)
    hasproperty(sim.config, :environment) ||
        throw(ArgumentError("$(name) needs sim.config.environment (a :forage run)"))
    env = getproperty(sim.config, :environment)
    (hasproperty(env, :source_position) && getproperty(env, :source_position) !== nothing) ||
        throw(ArgumentError("$(name) needs a forage source_position; run a :forage simulation"))
    src = getproperty(env, :source_position)
    source = (Float64(src[1]), Float64(src[2]))
    torus_size = hasproperty(env, :size) ? getproperty(env, :size) : nothing
    torus = torus_size === nothing ? nothing : Torus(Float64(torus_size))
    return source, torus
end

# Recover the lookout/follower split from the run config when the caller does
# not pass it explicitly. `n_lookouts === nothing` means every agent is a
# lookout (symmetric forage) -- there are no followers to read.
function _forage_infer_lookouts(sim::SimResult, n_agents::Integer)
    n = Int(n_agents)
    env = getproperty(sim.config, :environment)
    if hasproperty(env, :n_lookouts)
        nl = getproperty(env, :n_lookouts)
        nl === nothing && return (collect(1:n), Int[])
        k = clamp(Int(nl), 0, n)
        return (collect(1:k), collect((k + 1):n))
    end
    return (collect(1:n), Int[])
end

function _forage_tail_rows(n_ticks::Integer, window)
    window === nothing && return 1:Int(n_ticks)
    w = Int(window)
    w <= 0 && return 1:Int(n_ticks)
    return max(1, Int(n_ticks) - w + 1):Int(n_ticks)
end

"""
    forage_alignment(sim; subset=nothing, window=nothing)

EXPERIMENTAL Vanni "C" order parameter: the mean over `subset` agents of the
time-averaged alignment `cos(heading_i - bearing_to_source_i)` (in `[-1, 1]`,
`1` = pointed straight at the source). `subset=nothing` uses all agents; pass
the follower indices to read whether the blind subset is nonetheless steered
toward the source. `window` restricts to the trailing `window` ticks (drop the
dispersal transient).

This is a per-agent time average, so it is (near-)invariant under per-agent
circular shifts -- read it as a DIFFERENCE OF CONDITIONS (vision-on minus
vision-off), not against `crossshift_null`.
"""
function forage_alignment(sim::SimResult; subset=nothing, window=nothing)
    xs, ys, headings = _te_pose_matrices(getchannel(sim.recorder, :poses), :forage_alignment)
    n_ticks, n_agents = size(headings)
    source, torus = _forage_source_and_torus(sim, :forage_alignment)
    idxs = subset === nothing ? collect(1:n_agents) : collect(Int.(subset))
    rows = _forage_tail_rows(n_ticks, window)

    c_per = Vector{Float64}(undef, length(idxs))
    @inbounds for (k, i) in enumerate(idxs)
        1 <= i <= n_agents ||
            throw(ArgumentError("forage_alignment subset index $(i) outside 1:$(n_agents)"))
        acc = 0.0
        cnt = 0
        for t in rows
            b = torus === nothing ?
                atan(source[2] - ys[t, i], source[1] - xs[t, i]) :
                bearing(torus, (xs[t, i], ys[t, i]), source)
            acc += cos(headings[t, i] - b)
            cnt += 1
        end
        c_per[k] = cnt == 0 ? NaN : acc / cnt
    end

    return (;
        c=_analysis_finite_mean(c_per),
        c_per_agent=c_per,
        n_agents=length(idxs),
        window=window === nothing ? n_ticks : Int(window),
    )
end

"""
    lookout_follower_te(sim; lookouts=nothing, followers=nothing, bins=2, lag=1)

EXPERIMENTAL directed transfer entropy from lookout agents to follower agents,
using the sign of each agent's per-tick heading change (as in
`agent_transfer_entropy`). Returns the mean over lookout->follower pairs of
`TE(lookout_turn -> follower_turn)` in bits -- the predictive information the
lookouts' turning carries about a follower's next turn beyond the follower's own
past. `lookouts`/`followers = nothing` infers the split from
`sim.config.environment.n_lookouts` (first `k` agents are lookouts).

This IS a cross-agent measure, so validate it with `crossshift_null`
(`s -> lookout_follower_te(s; lookouts=…, followers=…).te`): the null should
collapse it toward 0 if the apparent flow is shared drive rather than coupling.
"""
function lookout_follower_te(sim::SimResult; lookouts=nothing, followers=nothing, bins=2, lag=1)
    _, _, headings = _te_pose_matrices(getchannel(sim.recorder, :poses), :lookout_follower_te)
    n_agents = size(headings, 2)
    inferred_l, inferred_f = _forage_infer_lookouts(sim, n_agents)
    L = lookouts === nothing ? inferred_l : collect(Int.(lookouts))
    F = followers === nothing ? inferred_f : collect(Int.(followers))

    signal = _te_heading_change_signal(headings)   # (n_ticks-1) x n_agents, binary
    te_total = 0.0
    valid = 0
    @inbounds for l in L, f in F
        (1 <= l <= n_agents && 1 <= f <= n_agents) ||
            throw(ArgumentError("lookout_follower_te index outside 1:$(n_agents)"))
        l == f && continue
        te = transfer_entropy(@view(signal[:, l]), @view(signal[:, f]); bins=bins, lag=lag)
        if isfinite(te)
            te_total += te
            valid += 1
        end
    end

    return (;
        te=valid == 0 ? NaN : te_total / valid,
        n_lookouts=length(L),
        n_followers=length(F),
        pairs_evaluated=valid,
        bins=Int(bins),
        lag=Int(lag),
    )
end
