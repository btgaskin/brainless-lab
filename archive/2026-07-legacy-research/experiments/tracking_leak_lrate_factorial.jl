# leak × lrate_wmat factorial for the Falandays tracking model
# ============================================================
# Registered for `experiments/run.jl`; run with:
#   julia -t auto --project=. experiments/run.jl tracking_leak_lrate_factorial
#   julia -t 4 --project=. experiments/run.jl tracking_leak_lrate_factorial leaks=0.25,0.5 lrate_wmats=0.1,1.0 seeds=0:2 ticks=600

using .ExpHarness, .ExpRegistry
using BrainlessLab

const TRACKING_FACTORIAL_DEFAULT_LEAKS = [0.1, 0.25, 0.4, 0.5, 0.75]
const TRACKING_FACTORIAL_DEFAULT_LRATE_WMATS = [0.05, 0.1, 0.2, 0.35, 0.5, 1.0]

function _tracking_factorial_float(x, name::Symbol)
    x isa Number && return Float64(x)
    x isa Symbol && return parse(Float64, String(x))
    x isa AbstractString && return parse(Float64, x)
    throw(ArgumentError("$(name) values must be numeric; got $(repr(x))"))
end

function _tracking_factorial_float_vector(values, name::Symbol)
    raw = values isa Number || values isa Symbol || values isa AbstractString ? [values] : collect(values)
    isempty(raw) && throw(ArgumentError("$(name) must not be empty"))
    return [_tracking_factorial_float(x, name) for x in raw]
end

function _simulate_tracking_factorial(leak::Real, lrate_wmat::Real, seed::Integer;
                                      ticks::Integer, nnodes::Integer)
    return simulate(
        :tracking;
        node=:falandays,
        N=Int(nnodes),
        ticks=Int(ticks),
        seed=Int(seed),
        record=(:rate, :scene, :spectral_radius, :acts, :targets),
        spectral_every=50,
        env_kwargs=(randomize_start=true,),
        leak=Float64(leak),
        lrate_wmat=Float64(lrate_wmat),
    )
end

function _run_tracking_factorial(leaks::Vector{Float64}, lrate_wmats::Vector{Float64},
                                 seeds::Vector{Int}; ticks::Integer, warmup::Integer,
                                 nnodes::Integer)
    nleaks = length(leaks)
    nrates = length(lrate_wmats)
    nseeds = length(seeds)
    measures = NamedTuple{TRACKING_RUN_MEASURE_KEYS}(
        map(_ -> Array{Float64}(undef, nleaks, nrates, nseeds), TRACKING_RUN_MEASURE_KEYS),
    )

    for (li, leak) in enumerate(leaks)
        for (ri, lrate_wmat) in enumerate(lrate_wmats)
            println("[leak=$(leak), lrate_wmat=$(lrate_wmat)] cell $(li),$(ri) of $(nleaks),$(nrates)")
            Threads.@threads for si in 1:nseeds
                seed = seeds[si]
                sim = _simulate_tracking_factorial(leak, lrate_wmat, seed;
                                                   ticks=ticks, nnodes=nnodes)
                run_measure = measure_tracking_run(sim; warmup=warmup)
                for key in TRACKING_RUN_MEASURE_KEYS
                    getproperty(measures, key)[li, ri, si] = getproperty(run_measure, key)
                end
            end
        end
    end

    metric_aggs = NamedTuple{TRACKING_RUN_MEASURE_KEYS}(
        map(key -> _tracking_factorial_agg(getproperty(measures, key)), TRACKING_RUN_MEASURE_KEYS),
    )
    frac_within = measures.frac_within_30deg
    frac_viable = [
        _finite_fraction_gt(view(frac_within, li, ri, :), 0.25)
        for li in axes(frac_within, 1), ri in axes(frac_within, 2)
    ]
    return (; metrics=metric_aggs, frac_viable=frac_viable)
end

function _tracking_factorial_agg(cube)
    mean_grid = [
        _finite_mean(view(cube, li, ri, :))
        for li in axes(cube, 1), ri in axes(cube, 2)
    ]
    sd_grid = [
        _finite_std(view(cube, li, ri, :))
        for li in axes(cube, 1), ri in axes(cube, 2)
    ]
    per_seed = [
        [cube[li, ri, si] for si in axes(cube, 3)]
        for li in axes(cube, 1), ri in axes(cube, 2)
    ]
    return (; mean=_tracking_factorial_rows(mean_grid),
            sd=_tracking_factorial_rows(sd_grid),
            per_seed=_tracking_factorial_rows(per_seed))
end

_tracking_factorial_rows(mat) = [vec(mat[i, :]) for i in axes(mat, 1)]
_tracking_factorial_jcube(rows) = "[" * join((_jmatrix(row) for row in rows), ",") * "]"

function _tracking_factorial_metric_json(metric)
    return "{\"mean\":$(_jmatrix(metric.mean)),\"sd\":$(_jmatrix(metric.sd))}"
end

function _tracking_factorial_metrics_json(metrics)
    blocks = [
        _jstr(key) * ":" * _tracking_factorial_metric_json(getproperty(metrics, key))
        for key in TRACKING_RUN_MEASURE_KEYS
    ]
    return "{" * join(blocks, ",") * "}"
end

function _tracking_factorial_per_seed_json(metrics)
    blocks = [
        _jstr(key) * ":" * _tracking_factorial_jcube(getproperty(metrics, key).per_seed)
        for key in TRACKING_RUN_MEASURE_KEYS
    ]
    return "{" * join(blocks, ",") * "}"
end

function _tracking_factorial_results_json(result, seeds::Vector{Int}, leaks::Vector{Float64},
                                          lrate_wmats::Vector{Float64}; ticks::Integer,
                                          warmup::Integer, nnodes::Integer)
    return "{\n" *
           "\"experiment\":\"tracking_leak_lrate_factorial\"," *
           "\"node\":\"falandays\"," *
           "\"nnodes\":$(Int(nnodes))," *
           "\"ticks\":$(Int(ticks))," *
           "\"warmup\":$(Int(warmup))," *
           "\"nseeds\":$(length(seeds))," *
           "\"seeds\":$(_jarr(seeds))," *
           "\"leaks\":$(_jarr(leaks))," *
           "\"lrate_wmats\":$(_jarr(lrate_wmats))," *
           "\"metrics\":$(_tracking_factorial_metrics_json(result.metrics))," *
           "\"frac_viable\":$(_jmatrix(_tracking_factorial_rows(result.frac_viable)))," *
           "\"per_seed\":$(_tracking_factorial_per_seed_json(result.metrics))" *
           "\n}\n"
end

function _tracking_factorial_manifest(seeds::Vector{Int}, leaks::Vector{Float64},
                                      lrate_wmats::Vector{Float64}; ticks::Integer,
                                      warmup::Integer, nnodes::Integer)
    lines = [
        "experiment = tracking_leak_lrate_factorial",
        "node = falandays",
        "task = tracking",
        "nnodes = $(Int(nnodes))",
        "ticks = $(Int(ticks))",
        "warmup = $(Int(warmup))",
        "seeds = $(seeds)",
        "leaks = $(leaks)",
        "lrate_wmats = $(lrate_wmats)",
        "grid = $(length(leaks)) x $(length(lrate_wmats))",
        "total_runs = $(length(leaks) * length(lrate_wmats) * length(seeds))",
        "env_kwargs = (randomize_start=true,)",
        "node_kwargs = leak, lrate_wmat",
        "git = $(git_sha())",
        "stamp = $(stamp())",
    ]
    return join(lines, "\n") * "\n"
end

function _tracking_factorial_print_cost_preview(leaks::Vector{Float64}, lrate_wmats::Vector{Float64},
                                                seeds::Vector{Int}; ticks::Integer,
                                                nnodes::Integer)
    total_runs = length(leaks) * length(lrate_wmats) * length(seeds)
    total_ticks = total_runs * Int(ticks)
    println("=== tracking_leak_lrate_factorial cost calibration ===")
    println("timing one calibration run...")
    calib_elapsed = @elapsed _simulate_tracking_factorial(first(leaks), first(lrate_wmats), first(seeds);
                                                          ticks=ticks, nnodes=nnodes)
    ticks_per_second = Int(ticks) / max(calib_elapsed, eps(Float64))
    est_seconds = total_ticks / ticks_per_second
    println("=== tracking_leak_lrate_factorial cost preview ===")
    println("total_runs = ", total_runs)
    println("total_ticks = ", total_ticks)
    println("Threads.nthreads() = ", Threads.nthreads())
    println("estimated wall time = ~", round(est_seconds / 60; digits=1), " min single-threaded")
    println("estimated threaded wall time = ~", round((est_seconds / Threads.nthreads()) / 60; digits=1),
            " min on ", Threads.nthreads(), " threads")
    return (; total_runs, total_ticks, calib_elapsed, est_seconds)
end

function run_tracking_leak_lrate_factorial(; leaks=TRACKING_FACTORIAL_DEFAULT_LEAKS,
                                           lrate_wmats=TRACKING_FACTORIAL_DEFAULT_LRATE_WMATS,
                                           seeds=0:99, ticks=7200, warmup=100,
                                           nnodes=200, dry_run=false)
    leak_values = _tracking_factorial_float_vector(leaks, :leaks)
    lrate_values = _tracking_factorial_float_vector(lrate_wmats, :lrate_wmats)
    seed_values = _seed_vector(seeds)
    isempty(seed_values) && throw(ArgumentError("seeds must not be empty"))
    ticks_i = Int(ticks)
    warmup_i = Int(warmup)
    nnodes_i = Int(nnodes)
    ticks_i > 0 || throw(ArgumentError("ticks must be positive"))
    0 <= warmup_i < ticks_i || throw(ArgumentError("warmup must satisfy 0 <= warmup < ticks"))
    nnodes_i > 0 || throw(ArgumentError("nnodes must be positive"))

    _tracking_factorial_print_cost_preview(leak_values, lrate_values, seed_values;
                                           ticks=ticks_i, nnodes=nnodes_i)
    if _dry_run(dry_run)
        println("dry_run=true; skipping factorial and run directory creation")
        return ""
    end

    println("=== tracking_leak_lrate_factorial ===")
    result = _run_tracking_factorial(leak_values, lrate_values, seed_values;
                                     ticks=ticks_i, warmup=warmup_i, nnodes=nnodes_i)

    dir = run_dir("tracking_leak_lrate_factorial")
    write_text(dir, "results.json",
               _tracking_factorial_results_json(result, seed_values, leak_values, lrate_values;
                                                ticks=ticks_i, warmup=warmup_i, nnodes=nnodes_i))
    write_text(dir, "manifest.txt",
               _tracking_factorial_manifest(seed_values, leak_values, lrate_values;
                                            ticks=ticks_i, warmup=warmup_i, nnodes=nnodes_i))
    return dir
end

ExpRegistry.register_experiment!(:tracking_leak_lrate_factorial, run_tracking_leak_lrate_factorial;
    description="leak × lrate_wmat factorial on the paper tracking model — the joint viability landscape over the two interacting homeostatic-gain axes.")
