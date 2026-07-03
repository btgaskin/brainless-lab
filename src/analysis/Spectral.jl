using LinearAlgebra: eigvals

# Spectral radius of a square recurrent weight matrix.
function _spectral_radius(wmat::AbstractMatrix)
    (isempty(wmat) || size(wmat, 1) != size(wmat, 2)) && return 0.0
    return maximum(abs, eigvals(Matrix{Float64}(wmat)))
end

_spectral_radius(r::FalandaysReservoir) = _spectral_radius(weights(r))

"""
    spectral_radius(sim)

Return the recorded spectral-radius trajectory (ρ of each learned recurrent
weight matrix, sampled over the run). Requires the `:spectral_radius` channel
recorded: run `simulate(...; record=(:spectral_radius, ...), every=K)`.

Single-agent runs keep the historical vector-valued `series` convenience.
Multi-agent runs return `series` as a samples-by-agents matrix plus the final
per-agent `distribution`; `rho` is scalar for one agent and a vector otherwise.
"""
function spectral_radius(sim::SimResult)
    ch = getchannel(sim.recorder, :spectral_radius)
    isempty(ch) && throw(ArgumentError("spectral_radius needs the :spectral_radius channel recorded; run simulate(...; record=(:spectral_radius,), every=K)"))

    mat = _analysis_rate_matrix_from_raw(ch, :spectral_radius)
    distribution = copy(@view mat[end, :])
    if size(mat, 2) == 1
        series = vec(copy(mat))
        return (;
            series=series,
            rho=series[end],
            distribution=distribution,
            mean=series[end],
            std=0.0,
        )
    end

    return (;
        series=mat,
        rho=distribution,
        distribution=distribution,
        mean=_analysis_finite_mean(distribution),
        std=_analysis_finite_std(distribution),
    )
end
