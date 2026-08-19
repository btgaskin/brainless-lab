function _tracking_window_mean(values, start::Integer, window::Integer)
    stop = Int(start) + Int(window) - 1
    stop <= length(values) || return NaN
    return _analysis_finite_mean(@view values[Int(start):stop])
end

function _tracking_heading_relation(
    heading::AbstractVector{<:Real},
    m_values::AbstractVector{<:Real},
    delta_values::AbstractVector{<:Real},
    bins::Integer,
)
    edges = collect(range(0.0, Float64(pi); length=Int(bins) + 1))
    centres = [(edges[index] + edges[index + 1]) / 2 for index in 1:Int(bins)]
    m_by_heading = fill(NaN, Int(bins))
    delta_by_heading = fill(NaN, Int(bins))
    n_by_heading = zeros(Float64, Int(bins))
    for bin in 1:Int(bins)
        lower = edges[bin]
        upper = edges[bin + 1]
        selected = Int[]
        for index in eachindex(heading, m_values)
            h = Float64(heading[index])
            inside = bin == Int(bins) ? lower <= h <= upper : lower <= h < upper
            inside && push!(selected, index)
        end
        m_bin = Float64[
            Float64(m_values[index])
            for index in selected
            if isfinite(Float64(m_values[index]))
        ]
        delta_bin = Float64[
            Float64(delta_values[index])
            for index in selected
            if isfinite(Float64(delta_values[index]))
        ]
        n_by_heading[bin] = length(m_bin)
        isempty(m_bin) || (m_by_heading[bin] = mean(m_bin))
        isempty(delta_bin) || (delta_by_heading[bin] = mean(delta_bin))
    end
    return centres, m_by_heading, delta_by_heading, n_by_heading
end

"""
    tracking_plasticity_diagnostics(sim; window=400, stride=100, kmax=20,
        min_r2=0.0, heading_bins=18)

Return aligned, exploratory diagnostics for the Falandays Tracking plasticity
experiment. The analysis combines windowed MR branching estimates with their
fit quality, the legacy through-origin estimate, population rate, heading
error, stimulus visibility, and recorded spectral radius.

The MR estimator is experimental and currently biased on the declared
synthetic check. The legacy estimate is retained for visual comparison only.
Neither series establishes criticality.
"""
function tracking_plasticity_diagnostics(
    sim::SimResult;
    window::Integer=400,
    stride::Integer=100,
    kmax::Integer=20,
    min_r2::Real=0.0,
    heading_bins::Integer=18,
)
    sim.task === :tracking || throw(ArgumentError(
        "tracking_plasticity_diagnostics requires task :tracking",
    ))
    record_every = hasproperty(sim.config, :every) ? Int(sim.config.every) : 1
    record_every == 1 || throw(ArgumentError(
        "tracking_plasticity_diagnostics requires record_every=1 so windows are in ticks",
    ))
    window_ = Int(window)
    stride_ = Int(stride)
    kmax_ = Int(kmax)
    bins_ = Int(heading_bins)
    bins_ >= 2 || throw(ArgumentError(
        "tracking_plasticity_diagnostics requires heading_bins >= 2",
    ))

    rates = _analysis_population_rate_series(sim, :tracking_plasticity_diagnostics)
    heading = heading_error(sim)
    in_view = object_in_view(sim)
    rho = spectral_radius(sim).series
    rho isa AbstractVector{<:Real} || throw(ArgumentError(
        "tracking_plasticity_diagnostics requires one recorded reservoir",
    ))
    sample_count = minimum(length.((rates, heading, in_view, rho)))
    sample_count >= window_ || throw(ArgumentError(
        "tracking_plasticity_diagnostics needs at least $(window_) aligned samples",
    ))
    rates = rates[1:sample_count]
    heading = heading[1:sample_count]
    in_view = in_view[1:sample_count]
    rho = Float64.(rho[1:sample_count])

    centres, m_values, r2_values, n_used_values = branching_ratio_mr_windowed(
        sim;
        level=:pooled,
        window=window_,
        stride=stride_,
        kmax=kmax_,
        min_r2=Float64(min_r2),
    )
    starts = _branching_window_starts(sample_count, window_, stride_)
    n_windows = minimum((length(starts), length(centres), length(m_values)))
    centres = Float64.(centres[1:n_windows])
    m_values = Float64.(m_values[1:n_windows])
    r2_values = Float64.(r2_values[1:n_windows])
    n_used_values = Float64.(n_used_values[1:n_windows])

    legacy_sigma = Vector{Float64}(undef, n_windows)
    rate_mean = Vector{Float64}(undef, n_windows)
    heading_mean = Vector{Float64}(undef, n_windows)
    in_view_fraction = Vector{Float64}(undef, n_windows)
    spectral_radius_mean = Vector{Float64}(undef, n_windows)
    for index in 1:n_windows
        start = starts[index]
        stop = start + window_ - 1
        legacy_sigma[index] = _branching_from_rates(@view rates[start:stop]).sigma
        rate_mean[index] = _tracking_window_mean(rates, start, window_)
        heading_mean[index] = _tracking_window_mean(heading, start, window_)
        in_view_fraction[index] = _tracking_window_mean(in_view, start, window_)
        spectral_radius_mean[index] = _tracking_window_mean(rho, start, window_)
    end
    delta_m = fill(NaN, n_windows)
    for index in 2:n_windows
        if isfinite(m_values[index]) && isfinite(m_values[index - 1])
            delta_m[index] = m_values[index] - m_values[index - 1]
        end
    end

    heading_centres, m_by_heading, delta_by_heading, n_by_heading =
        _tracking_heading_relation(heading_mean, m_values, delta_m, bins_)
    valid_m = filter(isfinite, m_values)
    valid_r2 = filter(isfinite, r2_values)
    full_run = branching_ratio_mr(sim; level=:pooled, kmax=kmax_)

    return AnalysisResult(
        statistics=(
            m_mr_full=Float64(full_run.m_mr),
            mr_window_count=Float64(n_windows),
            mr_valid_count=Float64(length(valid_m)),
            mr_valid_fraction=n_windows == 0 ? NaN : length(valid_m) / n_windows,
            mr_r2_mean=_analysis_finite_mean(valid_r2),
            window=Float64(window_),
            stride=Float64(stride_),
            kmax=Float64(kmax_),
        ),
        series=(
            AnalysisSeries(
                :over_time,
                :tick,
                centres,
                (
                    m_mr=m_values,
                    delta_m_mr=delta_m,
                    mr_r2=r2_values,
                    mr_n_used=n_used_values,
                    legacy_sigma=legacy_sigma,
                    population_rate=rate_mean,
                    heading_error=heading_mean,
                    in_view_fraction=in_view_fraction,
                    spectral_radius=spectral_radius_mean,
                );
                metadata=(window=window_, stride=stride_, kmax=kmax_),
            ),
            AnalysisSeries(
                :by_heading_error,
                :heading_error,
                heading_centres,
                (
                    m_mr=m_by_heading,
                    delta_m_mr=delta_by_heading,
                    n_windows=n_by_heading,
                );
                metadata=(bins=bins_,),
            ),
        ),
    )
end
