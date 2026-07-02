using LinearAlgebra: eigvals

# Spectral radius of a square recurrent weight matrix.
function _spectral_radius(wmat::AbstractMatrix)
    (isempty(wmat) || size(wmat, 1) != size(wmat, 2)) && return 0.0
    return maximum(abs, eigvals(Matrix{Float64}(wmat)))
end

_spectral_radius(r::FalandaysReservoir) = _spectral_radius(weights(r))

"""
    spectral_radius(sim)

Return the recorded spectral-radius trajectory (ρ of the learned recurrent
weight matrix, sampled over the run). Requires the `:spectral_radius` channel
recorded: run `simulate(...; record=(:spectral_radius, ...), every=K)`.
"""
function spectral_radius(sim::SimResult)
    ch = getchannel(sim.recorder, :spectral_radius)
    isempty(ch) && throw(ArgumentError("spectral_radius needs the :spectral_radius channel recorded; run simulate(...; record=(:spectral_radius,), every=K)"))
    return (series=Float64.(ch),)
end
