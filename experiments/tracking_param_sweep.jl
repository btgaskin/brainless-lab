# One-at-a-time Falandays tracking parameter sweep
# =================================================
# Registered for `experiments/run.jl`; run with:
#   julia --project=. experiments/run.jl tracking_param_sweep
#   julia --project=. experiments/run.jl tracking_param_sweep seeds=0:1 dry_run=true
#   julia -t auto --project=. experiments/run.jl tracking_param_sweep  # use threads

using .ExpHarness, .ExpRegistry
using BrainlessLab
using Statistics

const TRACKING_PARAM_BASELINE = (
    leak=0.25,
    lrate_targ=0.01,
    lrate_wmat=1.0,
    input_amp=0.75,
    movement_amp=10.0,
    eye_offset_deg=30.0,
    stim_speed_deg_per_tick=1.0,
)

const TRACKING_PARAM_SWEEPS = [
    (name=:leak, kind=:node, values=[0.0, 0.25, 0.5, 0.75, 1.0], baseline=TRACKING_PARAM_BASELINE.leak),
    (name=:lrate_targ, kind=:node, values=[0.01, 0.02, 0.03, 0.04, 0.05], baseline=TRACKING_PARAM_BASELINE.lrate_targ),
    (name=:lrate_wmat, kind=:node, values=[0.01, 0.05, 0.1, 0.2, 0.35, 0.5, 0.75, 1.0, 1.5, 2.0], baseline=TRACKING_PARAM_BASELINE.lrate_wmat),
    (name=:input_amp, kind=:node, values=[0.5, 0.75, 1.0, 1.25, 1.5], baseline=TRACKING_PARAM_BASELINE.input_amp),
    (name=:movement_amp, kind=:env, values=[5.0, 10.0, 15.0], baseline=TRACKING_PARAM_BASELINE.movement_amp),
    (name=:eye_offset_deg, kind=:env, values=[15.0, 30.0, 45.0, 60.0], baseline=TRACKING_PARAM_BASELINE.eye_offset_deg),
]

_dry_run(dry_run) =
    dry_run === true || dry_run === :true ||
    (dry_run isa AbstractString && lowercase(dry_run) == "true")

function _seed_vector(seeds)
    seeds isa Number && return [Int(seeds)]
    return Int.(collect(seeds))
end

function _axis_overrides(axis, value)
    value == axis.baseline && return NamedTuple(), NamedTuple()
    if axis.kind === :node
        return NamedTuple{(axis.name,)}((value,)), NamedTuple()
    elseif axis.kind === :env
        return NamedTuple(), NamedTuple{(axis.name,)}((value,))
    end
    error("unknown sweep kind :$(axis.kind) for $(axis.name)")
end

function _simulate_tracking(axis, value, seed::Integer; ticks::Integer, nnodes::Integer)
    node_override, env_override = _axis_overrides(axis, value)
    return simulate(
        :tracking;
        node=:falandays_base,
        N=Int(nnodes),
        ticks=Int(ticks),
        seed=Int(seed),
        record=(:rate, :scene, :spectral_radius),
        spectral_every=50,
        env_kwargs=merge((randomize_start=true,), env_override),
        node_override...,
    )
end

function _simulate_tracking_baseline(seed::Integer; ticks::Integer, nnodes::Integer)
    return simulate(
        :tracking;
        node=:falandays_base,
        N=Int(nnodes),
        ticks=Int(ticks),
        seed=Int(seed),
        record=(:rate, :scene, :spectral_radius),
        spectral_every=50,
        env_kwargs=(randomize_start=true,),
    )
end

function _rate_mean(sim, warmup::Integer)
    if hasproperty(sim.metrics, :rate_mean)
        return Float64(sim.metrics.rate_mean)
    end
    rates = BrainlessLab._analysis_population_rate_series(sim, :x)
    return mean(@view rates[(Int(warmup) + 1):length(rates)])
end

function _branching_window_params(ticks::Integer)
    ticks_i = Int(ticks)
    window = min(max(fld(ticks_i, 12), 100), ticks_i)
    stride = max(1, fld(window, 2))
    return window, stride
end

function _run_axis(axis, seeds::Vector{Int}; ticks::Integer, warmup::Integer, nnodes::Integer)
    nvalues = length(axis.values)
    nseeds = length(seeds)
    sample_ticks = collect(Int(ticks) >= 20 ? (20:20:Int(ticks)) : (Int(ticks):Int(ticks)))
    branch_window, branch_stride = _branching_window_params(ticks)
    branch_starts = branch_window >= 100 && Int(ticks) >= branch_window ? collect(1:branch_stride:(Int(ticks) - branch_window + 1)) : Int[]
    branch_t = [Float64(start + 0.5 * (branch_window - 1)) for start in branch_starts]
    nwin = length(branch_t)

    mean_err = Matrix{Float64}(undef, nvalues, nseeds)
    m_mr = similar(mean_err)
    rho = similar(mean_err)
    rate = similar(mean_err)
    heading_ts = Array{Float64}(undef, nvalues, nseeds, length(sample_ticks))
    branch_ts = fill(NaN, nvalues, nseeds, nwin)

    for (vi, value) in enumerate(axis.values)
        println("[$(axis.name)] value=$(value) ($(vi)/$(nvalues))")
        Threads.@threads for si in 1:nseeds
            seed = seeds[si]
            sim = _simulate_tracking(axis, value, seed; ticks=ticks, nnodes=nnodes)
            err_ts = heading_error(sim)
            mean_err[vi, si] = mean(@view err_ts[(Int(warmup) + 1):length(err_ts)])
            m_mr[vi, si] = branching_ratio_mr(sim; transient=warmup).m_mr
            rho[vi, si] = spectral_radius(sim).mean
            rate[vi, si] = _rate_mean(sim, warmup)
            @views heading_ts[vi, si, :] .= err_ts[sample_ticks]

            if nwin > 0
                t_centers, m_series, _, _ = branching_ratio_mr_windowed(
                    sim;
                    level=:pooled,
                    window=branch_window,
                    stride=branch_stride,
                )
                nw = min(length(t_centers), length(m_series), nwin)
                @inbounds for wi in 1:nw
                    branch_ts[vi, si, wi] = Float64(m_series[wi])
                end
            end
        end
    end

    agg(mat) = (mean=vec(mean(mat; dims=2)), sd=vec(std(mat; dims=2)), per_seed=[vec(mat[vi, :]) for vi in axes(mat, 1)])
    heading_per_value = Vector{Vector{Float64}}(undef, nvalues)
    for vi in 1:nvalues
        series = zeros(Float64, length(sample_ticks))
        for si in 1:nseeds
            @inbounds for ti in eachindex(sample_ticks)
                series[ti] += heading_ts[vi, si, ti]
            end
        end
        series ./= nseeds
        heading_per_value[vi] = series
    end
    branching_per_value = Vector{Vector{Float64}}(undef, nvalues)
    for vi in 1:nvalues
        series = Vector{Float64}(undef, nwin)
        for wi in 1:nwin
            total = 0.0
            count = 0
            for si in 1:nseeds
                m = branch_ts[vi, si, wi]
                if isfinite(m)
                    total += m
                    count += 1
                end
            end
            series[wi] = count == 0 ? NaN : total / count
        end
        branching_per_value[vi] = series
    end
    return (;
        mean_err=agg(mean_err),
        m_mr=agg(m_mr),
        rho=agg(rho),
        rate=agg(rate),
        heading=(; t=sample_ticks, per_value=heading_per_value),
        branching=(; t=branch_t, per_value=branching_per_value),
    )
end

function _print_cost_preview(seeds::Vector{Int}; ticks::Integer, nnodes::Integer)
    total_runs = sum(length(axis.values) for axis in TRACKING_PARAM_SWEEPS) * length(seeds)
    total_ticks = total_runs * Int(ticks)
    println("=== tracking_param_sweep cost calibration ===")
    println("timing one baseline run...")
    calib_elapsed = @elapsed _simulate_tracking_baseline(first(seeds); ticks=ticks, nnodes=nnodes)
    ticks_per_second = Int(ticks) / max(calib_elapsed, eps(Float64))
    est_seconds = total_ticks / ticks_per_second
    println("=== tracking_param_sweep cost preview ===")
    println("total_runs = ", total_runs)
    println("total_ticks = ", total_ticks)
    println("Threads.nthreads() = ", Threads.nthreads())
    println("estimated wall time = ~", round(est_seconds / 60; digits=1), " min single-threaded")
    println("estimated threaded wall time = ~", round((est_seconds / Threads.nthreads()) / 60; digits=1), " min on ", Threads.nthreads(), " threads")
    return (; total_runs, total_ticks, calib_elapsed, est_seconds)
end

function _jnum(x)
    x isa Integer && return string(x)
    xf = Float64(x)
    return isfinite(xf) ? string(round(xf; digits=5)) : "null"
end

_jarr(v) = "[" * join((_jnum(x) for x in v), ",") * "]"
_jmatrix(rows) = "[" * join((_jarr(v) for v in rows), ",") * "]"
_jstr(s) = "\"" * replace(String(s), "\\" => "\\\\", "\"" => "\\\"") * "\""

_metric_json(m) = "{\"mean\":$(_jarr(m.mean)),\"sd\":$(_jarr(m.sd)),\"per_seed\":$(_jmatrix(m.per_seed))}"

function _sweep_json(axis, result)
    heading_per_value = _jmatrix(result.heading.per_value)
    branching_per_value = _jmatrix(result.branching.per_value)
    return _jstr(axis.name) * ":{" *
           "\"kind\":$(_jstr(axis.kind))," *
           "\"values\":$(_jarr(axis.values))," *
           "\"mean_err\":$(_metric_json(result.mean_err))," *
           "\"m_mr\":$(_metric_json(result.m_mr))," *
           "\"rho\":$(_metric_json(result.rho))," *
           "\"rate\":$(_metric_json(result.rate))," *
           "\"timeseries\":{\"heading\":{\"t\":$(_jarr(result.heading.t)),\"per_value\":$heading_per_value}," *
           "\"branching\":{\"t\":$(_jarr(result.branching.t)),\"per_value\":$branching_per_value}}" *
           "}"
end

function _results_json(results, seeds::Vector{Int}; ticks::Integer, warmup::Integer, nnodes::Integer)
    sweep_blocks = [_sweep_json(axis, result) for (axis, result) in results]
    baseline = "\"input_amp\":$(_jnum(TRACKING_PARAM_BASELINE.input_amp))," *
               "\"lrate_wmat\":$(_jnum(TRACKING_PARAM_BASELINE.lrate_wmat))," *
               "\"lrate_targ\":$(_jnum(TRACKING_PARAM_BASELINE.lrate_targ))," *
               "\"leak\":$(_jnum(TRACKING_PARAM_BASELINE.leak))," *
               "\"movement_amp\":$(_jnum(TRACKING_PARAM_BASELINE.movement_amp))," *
               "\"eye_offset_deg\":$(_jnum(TRACKING_PARAM_BASELINE.eye_offset_deg))," *
               "\"stim_speed_deg_per_tick\":$(_jnum(TRACKING_PARAM_BASELINE.stim_speed_deg_per_tick))"
    return "{\n" *
           "\"experiment\":\"tracking_param_sweep\"," *
           "\"node\":\"falandays_base\"," *
           "\"nnodes\":$(Int(nnodes))," *
           "\"ticks\":$(Int(ticks))," *
           "\"warmup\":$(Int(warmup))," *
           "\"nseeds\":$(length(seeds))," *
           "\"seeds\":$(_jarr(seeds))," *
           "\"baseline\":{$baseline}," *
           "\n\"sweeps\":{\n" *
           join(sweep_blocks, ",\n") *
           "\n}\n}\n"
end

function _manifest(seeds::Vector{Int}; ticks::Integer, warmup::Integer, nnodes::Integer)
    lines = [
        "experiment = tracking_param_sweep",
        "node = falandays_base",
        "task = tracking",
        "nnodes = $(Int(nnodes))",
        "ticks = $(Int(ticks))",
        "warmup = $(Int(warmup))",
        "seeds = $(seeds)",
        "baseline = $(TRACKING_PARAM_BASELINE)",
    ]
    for axis in TRACKING_PARAM_SWEEPS
        push!(lines, "sweep.$(axis.name) ($(axis.kind)) = $(axis.values)")
    end
    push!(lines, "git = $(git_sha())")
    push!(lines, "stamp = $(stamp())")
    return join(lines, "\n") * "\n"
end

function run_tracking_param_sweep(; seeds=0:99, ticks=7200, warmup=100, nnodes=200, dry_run=false)
    seed_values = _seed_vector(seeds)
    isempty(seed_values) && throw(ArgumentError("seeds must not be empty"))
    ticks_i = Int(ticks)
    warmup_i = Int(warmup)
    nnodes_i = Int(nnodes)
    ticks_i > 0 || throw(ArgumentError("ticks must be positive"))
    0 <= warmup_i < ticks_i || throw(ArgumentError("warmup must satisfy 0 <= warmup < ticks"))
    nnodes_i > 0 || throw(ArgumentError("nnodes must be positive"))

    _print_cost_preview(seed_values; ticks=ticks_i, nnodes=nnodes_i)
    if _dry_run(dry_run)
        println("dry_run=true; skipping full sweep and run directory creation")
        return ""
    end

    println("=== tracking_param_sweep ===")
    results = Pair{Any,Any}[]
    for axis in TRACKING_PARAM_SWEEPS
        push!(results, axis => _run_axis(axis, seed_values; ticks=ticks_i, warmup=warmup_i, nnodes=nnodes_i))
    end

    dir = run_dir("tracking_param_sweep")
    write_text(dir, "results.json", _results_json(results, seed_values; ticks=ticks_i, warmup=warmup_i, nnodes=nnodes_i))
    write_text(dir, "manifest.txt", _manifest(seed_values; ticks=ticks_i, warmup=warmup_i, nnodes=nnodes_i))
    return dir
end

register_experiment!(:tracking_param_sweep, run_tracking_param_sweep;
    description="One-at-a-time parameter sweep of the paper Falandays object-tracking model (leak, lrate_targ, lrate_wmat, input_amp, movement_amp, eye_offset); post-warmup heading error + branching over N random-init seeds.")
