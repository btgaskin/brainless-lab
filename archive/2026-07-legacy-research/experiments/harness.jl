"""
    ExpHarness

Small building blocks for **composed experiments** — reproducible protocols that
live outside the core library (they are not a validated part of the baseline) but
that we want to run in a regular, self-describing way. Everything here composes
the *public* `BrainlessLab` API only (`simulate`, `task_outcome`, …); nothing
reaches into internals, so an experiment written against this harness keeps
working across core refactors.

The pieces:

- `freeze_sweep`  — a protocol: score a task as a function of the tick at which an
  intervention verb is applied, with a matched full-learning control.
- `onset_tick`    — a readout over the resulting score-vs-tick curve (the knee).
- `run_dir` / `write_text` / `git_sha` / `stamp` — a self-describing run directory
  (git SHA + seeds + config) so any result can be traced back to what produced it.

Add a new experiment by writing a `<name>.jl` beside this file that `include`s it,
composes these parts, and writes a run dir under `experiments/runs/<name>/`.
"""
module ExpHarness

using BrainlessLab
using Statistics

export freeze_sweep, onset_tick, run_dir, write_text, git_sha, stamp

"""
    freeze_sweep(task; node=:falandays, freeze_ticks, window=600, seeds=0:5,
                 verb=:freeze_plasticity)

For each tick `T` in `freeze_ticks`: apply `verb` at `T` (via the `interventions`
schedule) and score the run over its final `window` ticks; also run a matched
full-learning control of the same length/window. Returns per-tick, seed-aggregated:

- `fz_mean`/`fz_sd`, `fl_mean` — **`normalized_score`** (chance→0, optimal→1,
  direction-correct), the cross-task-comparable behavioural read;
- `rate_mean`/`rate_sd` — frozen population activity (the crisp signal: a dead
  reservoir either saturates to ~1 or goes silent toward 0, depending on the task);
- `raw_mean` — the raw declared task outcome for reference.

`task_outcome(...).normalized` is used deliberately: raw task outcomes have different scales and
even a different sign of "better" per task, so it is not comparable across tasks —
that is exactly the trap this framework has to avoid.
"""
function freeze_sweep(task::Symbol; node::Symbol=:falandays, freeze_ticks,
                      window::Integer=600, seeds=0:5, verb::Symbol=:freeze_plasticity)
    ticks = freeze_ticks isa Number ? [Int(freeze_ticks)] : collect(freeze_ticks)
    seeds = seeds isa Number ? [Int(seeds)] : collect(seeds)
    nT, nS = length(ticks), length(seeds)
    fz = Matrix{Float64}(undef, nT, nS)   # normalized frozen score
    fl = Matrix{Float64}(undef, nT, nS)   # normalized full-learning score
    rt = Matrix{Float64}(undef, nT, nS)   # frozen population rate
    rw = Matrix{Float64}(undef, nT, nS)   # raw frozen score
    for (si, seed) in enumerate(seeds)
        for (ti, T) in enumerate(ticks)
            sfz = simulate(task; node=node, ticks=T + window, window=window, seed=seed,
                           interventions=[(T, verb)])
            sfl = simulate(task; node=node, ticks=T + window, window=window, seed=seed)
            frozen_outcome = task_outcome(sfz)
            learning_outcome = task_outcome(sfl)
            frozen_outcome === nothing &&
                throw(ArgumentError("freeze_sweep requires a scored task; :$(task) has no objective"))
            learning_outcome === nothing &&
                throw(ArgumentError("freeze_sweep requires a scored task; :$(task) has no objective"))
            fz[ti, si] = frozen_outcome.normalized
            fl[ti, si] = learning_outcome.normalized
            rt[ti, si] = sfz.metrics.rate_mean
            rw[ti, si] = frozen_outcome.raw
        end
    end
    agg(m) = (vec(mean(m; dims=2)), vec(std(m; dims=2)))
    fzm, fzs = agg(fz); flm, _ = agg(fl); rtm, rts = agg(rt); rwm, _ = agg(rw)
    return (; task, node, verb, window, freeze_ticks=ticks,
            fz_mean=fzm, fz_sd=fzs, fl_mean=flm, rate_mean=rtm, rate_sd=rts, raw_mean=rwm)
end

"""
    onset_tick(freeze_ticks, fz_mean; min_drop=0.03)

The onset is the first tick at which the frozen score has risen halfway from the
**dead** level (earliest freeze) to the post-onset **plateau** (median of the last
few ticks). Returns `(; onset, dead, alive, drop, fraction)`; `onset` is `NaN` when
no drop of at least `min_drop` exists (i.e. the task shows no dead→alive transition).

This is a sweep-level readout — a pure function over a curve — deliberately *not* a
`register_analysis!` (those operate on a single `SimResult`).
"""
function onset_tick(freeze_ticks, fz_mean; min_drop::Real=0.03)
    n = length(fz_mean)
    dead = fz_mean[1]
    alive = median(@view fz_mean[max(1, n - 2):n])
    span = alive - dead
    frac = abs(span) < 1e-9 ? zeros(n) : clamp.((fz_mean .- dead) ./ span, -0.2, 1.3)
    onset = NaN
    if span > min_drop
        for k in 1:n
            if frac[k] >= 0.5
                onset = float(freeze_ticks[k]); break
            end
        end
    end
    return (; onset, dead, alive, drop=span, fraction=frac)
end

git_sha() = try readchomp(`git rev-parse --short HEAD`) catch; "nogit" end
stamp() = try readchomp(`date -u +%Y%m%dT%H%M%SZ`) catch; "nostamp" end

"Create and return a self-describing run directory `experiments/runs/<name>/<stamp>_<sha>/`."
function run_dir(name::AbstractString; root::AbstractString=joinpath(@__DIR__, "runs"))
    d = joinpath(root, name, "$(stamp())_$(git_sha())")
    mkpath(d)
    return d
end

write_text(dir, fname, s) = (open(joinpath(dir, fname), "w") do io
    write(io, s)
end; joinpath(dir, fname))

end # module
