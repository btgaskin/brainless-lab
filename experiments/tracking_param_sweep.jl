# One-at-a-time Falandays tracking parameter sweep
# =================================================
# Registered for `experiments/run.jl`; run with:
#   julia --project=. experiments/run.jl tracking_param_sweep
#   julia --project=. experiments/run.jl tracking_param_sweep seeds=0:1 dry_run=true

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
    (name=:lrate_wmat, kind=:node, values=[0.01, 0.02, 0.03, 0.04, 0.05], baseline=TRACKING_PARAM_BASELINE.lrate_wmat),
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

    mean_err = Matrix{Float64}(undef, nvalues, nseeds)
    m_mr = similar(mean_err)
    rho = similar(mean_err)
    rate = similar(mean_err)
    ts_sum = zeros(Float64, nvalues, length(sample_ticks))
    branch_t = Float64[]
    branch_sum = [Float64[] for _ in 1:nvalues]
    branch_n = [Int[] for _ in 1:nvalues]

    for (vi, value) in enumerate(axis.values)
        println("[$(axis.name)] value=$(value) ($(vi)/$(nvalues))")
        for (si, seed) in enumerate(seeds)
            sim = _simulate_tracking(axis, value, seed; ticks=ticks, nnodes=nnodes)
            err_ts = heading_error(sim)
            mean_err[vi, si] = mean(@view err_ts[(Int(warmup) + 1):length(err_ts)])
            m_mr[vi, si] = branching_ratio_mr(sim; transient=warmup).m_mr
            rho[vi, si] = spectral_radius(sim).mean
            rate[vi, si] = _rate_mean(sim, warmup)
            @views ts_sum[vi, :] .+= err_ts[sample_ticks]

            if branch_window >= 100
                t_centers, m_series, _, _ = branching_ratio_mr_windowed(
                    sim;
                    level=:pooled,
                    window=branch_window,
                    stride=branch_stride,
                )
                if isempty(branch_t)
                    branch_t = collect(Float64, t_centers)
                end
                if isempty(branch_sum[vi])
                    branch_sum[vi] = zeros(Float64, length(m_series))
                    branch_n[vi] = zeros(Int, length(m_series))
                end
                @inbounds for wi in eachindex(m_series)
                    m = Float64(m_series[wi])
                    if !isnan(m)
                        branch_sum[vi][wi] += m
                        branch_n[vi][wi] += 1
                    end
                end
            end
        end
    end

    agg(mat) = (mean=vec(mean(mat; dims=2)), sd=vec(std(mat; dims=2)), per_seed=[vec(mat[vi, :]) for vi in axes(mat, 1)])
    heading_per_value = [vec(ts_sum[vi, :] ./ nseeds) for vi in 1:nvalues]
    branching_per_value = [
        [branch_n[vi][wi] == 0 ? NaN : branch_sum[vi][wi] / branch_n[vi][wi] for wi in eachindex(branch_sum[vi])]
        for vi in 1:nvalues
    ]
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
    println("estimated wall time = ~", round(est_seconds / 60; digits=1), " min single-threaded (threads reduce this)")
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
