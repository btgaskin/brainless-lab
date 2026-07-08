# One-at-a-time Falandays tracking parameter sweep
# =================================================
# Registered for `experiments/run.jl`; run with:
#   julia --project=. experiments/run.jl tracking_param_sweep
#   julia --project=. experiments/run.jl tracking_param_sweep seeds=0:1 dry_run=true
#   julia -t auto --project=. experiments/run.jl tracking_param_sweep  # use threads

using .ExpHarness, .ExpRegistry
using BrainlessLab
using Statistics

const TRACKING_RUN_MEASURE_KEYS = (
    :track_score,
    :mean_abs_error_deg,
    :frac_within_30deg,
    :mean_err,
    :m_mr,
    :rho,
    :rate_mean,
    :rate_var,
    :rate_sat,
    :nte_mean,
    :nte_p90,
    :nte_settle,
)

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
        record=(:rate, :scene, :spectral_radius, :acts, :targets),
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
        record=(:rate, :scene, :spectral_radius, :acts, :targets),
        spectral_every=50,
        env_kwargs=(randomize_start=true,),
    )
end

function _finite_mean(values)
    total = 0.0
    count = 0
    for value in values
        x = Float64(value)
        if isfinite(x)
            total += x
            count += 1
        end
    end
    return count == 0 ? NaN : total / count
end

function _finite_std(values)
    count = 0
    μ = 0.0
    m2 = 0.0
    for value in values
        x = Float64(value)
        if isfinite(x)
            count += 1
            δ = x - μ
            μ += δ / count
            m2 += δ * (x - μ)
        end
    end
    count == 0 && return NaN
    count == 1 && return 0.0
    return sqrt(m2 / (count - 1))
end

function _finite_population_var(values)
    count = 0
    μ = 0.0
    m2 = 0.0
    for value in values
        x = Float64(value)
        if isfinite(x)
            count += 1
            δ = x - μ
            μ += δ / count
            m2 += δ * (x - μ)
        end
    end
    return count == 0 ? NaN : m2 / count
end

function _finite_quantile(values, q::Real)
    finite = Float64[]
    for value in values
        x = Float64(value)
        isfinite(x) && push!(finite, x)
    end
    return isempty(finite) ? NaN : quantile(finite, q)
end

function _finite_fraction_gt(values, threshold::Real)
    count = 0
    passing = 0
    threshold_f = Float64(threshold)
    for value in values
        x = Float64(value)
        if isfinite(x)
            count += 1
            passing += x > threshold_f ? 1 : 0
        end
    end
    return count == 0 ? NaN : passing / count
end

function _post_range(len::Integer, warmup::Integer, name::Symbol)
    len_i = Int(len)
    warmup_i = Int(warmup)
    0 <= warmup_i < len_i ||
        throw(ArgumentError("$(name) needs 0 <= warmup < number of samples; got warmup=$(warmup_i), samples=$(len_i)"))
    return (warmup_i + 1):len_i
end

function measure_tracking_run(sim; warmup)::NamedTuple
    warmup_i = Int(warmup)
    err = heading_error(sim)
    post = _post_range(length(err), warmup_i, :measure_tracking_run)

    cos_sum = 0.0
    abs_deg_sum = 0.0
    err_sum = 0.0
    within = 0
    cutoff = deg2rad(30.0)
    @inbounds for i in post
        e = Float64(err[i])
        cos_sum += cos(e)
        abs_deg_sum += rad2deg(e)
        err_sum += e
        within += e <= cutoff ? 1 : 0
    end
    npost = length(post)

    rates = BrainlessLab._analysis_population_rate_series(sim, :x)
    rate_post = _post_range(length(rates), warmup_i, :measure_tracking_run_rate)
    rate_mean = _finite_mean(@view rates[rate_post])
    rate_var = _finite_population_var(@view rates[rate_post])
    rate_sat = mean(x -> Float64(x) >= 0.99, @view rates[rate_post])

    target = node_target_error(sim)
    nte_post_cols = _post_range(size(target.per_node_error, 2), warmup_i, :measure_tracking_run_node_target_error)
    nte_post = @view target.per_node_error[:, nte_post_cols]
    nte_mean = _finite_mean(nte_post)

    node_time_mean = Vector{Float64}(undef, size(nte_post, 1))
    @inbounds for node_i in axes(nte_post, 1)
        node_time_mean[node_i] = _finite_mean(@view nte_post[node_i, :])
    end
    nte_p90 = _finite_quantile(node_time_mean, 0.9)

    mean_over_nodes = @view target.mean_over_nodes[nte_post_cols]
    quarter = max(1, fld(length(mean_over_nodes), 4))
    first_q = _finite_mean(@view mean_over_nodes[1:quarter])
    last_q = _finite_mean(@view mean_over_nodes[(length(mean_over_nodes) - quarter + 1):length(mean_over_nodes)])
    nte_settle = isfinite(first_q) && first_q != 0.0 ? last_q / first_q : NaN

    return (;
        track_score=cos_sum / npost,
        mean_abs_error_deg=abs_deg_sum / npost,
        frac_within_30deg=within / npost,
        mean_err=err_sum / npost,
        m_mr=branching_ratio_mr(sim; transient=warmup_i).m_mr,
        rho=spectral_radius(sim).mean,
        rate_mean=rate_mean,
        rate_var=rate_var,
        rate_sat=rate_sat,
        nte_mean=nte_mean,
        nte_p90=nte_p90,
        nte_settle=nte_settle,
    )
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

    measures = NamedTuple{TRACKING_RUN_MEASURE_KEYS}(
        map(_ -> Matrix{Float64}(undef, nvalues, nseeds), TRACKING_RUN_MEASURE_KEYS),
    )
    heading_ts = Array{Float64}(undef, nvalues, nseeds, length(sample_ticks))
    branch_ts = fill(NaN, nvalues, nseeds, nwin)

    for (vi, value) in enumerate(axis.values)
        println("[$(axis.name)] value=$(value) ($(vi)/$(nvalues))")
        Threads.@threads for si in 1:nseeds
            seed = seeds[si]
            sim = _simulate_tracking(axis, value, seed; ticks=ticks, nnodes=nnodes)
            err_ts = heading_error(sim)
            run_measure = measure_tracking_run(sim; warmup=warmup)
            for key in TRACKING_RUN_MEASURE_KEYS
                getproperty(measures, key)[vi, si] = getproperty(run_measure, key)
            end
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

    agg(mat) = (
        mean=[_finite_mean(view(mat, vi, :)) for vi in axes(mat, 1)],
        sd=[_finite_std(view(mat, vi, :)) for vi in axes(mat, 1)],
        per_seed=[vec(mat[vi, :]) for vi in axes(mat, 1)],
    )
    measure_aggs = NamedTuple{TRACKING_RUN_MEASURE_KEYS}(
        map(key -> agg(getproperty(measures, key)), TRACKING_RUN_MEASURE_KEYS),
    )
    frac_within = measures.frac_within_30deg
    frac_viable = [
        _finite_fraction_gt(view(frac_within, vi, :), 0.25)
        for vi in axes(frac_within, 1)
    ]
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
        measure_aggs...,
        rate=measure_aggs.rate_mean,
        frac_viable=frac_viable,
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
           "\"track_score\":$(_metric_json(result.track_score))," *
           "\"mean_abs_error_deg\":$(_metric_json(result.mean_abs_error_deg))," *
           "\"frac_within_30deg\":$(_metric_json(result.frac_within_30deg))," *
           "\"mean_err\":$(_metric_json(result.mean_err))," *
           "\"m_mr\":$(_metric_json(result.m_mr))," *
           "\"rho\":$(_metric_json(result.rho))," *
           "\"rate\":$(_metric_json(result.rate))," *
           "\"rate_mean\":$(_metric_json(result.rate_mean))," *
           "\"rate_var\":$(_metric_json(result.rate_var))," *
           "\"rate_sat\":$(_metric_json(result.rate_sat))," *
           "\"nte_mean\":$(_metric_json(result.nte_mean))," *
           "\"nte_p90\":$(_metric_json(result.nte_p90))," *
           "\"nte_settle\":$(_metric_json(result.nte_settle))," *
           "\"frac_viable\":$(_jarr(result.frac_viable))," *
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
