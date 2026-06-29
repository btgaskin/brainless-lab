struct NoDrive <: Drive end

Base.@kwdef struct OosawaDrive <: Drive
    membrane_noise::Float64 = 0.0
    noise_gain::Float64 = 0.0
end

function apply_drive!(::NoDrive, acts, targets, p, noise)
    return acts
end

function apply_drive!(d::OosawaDrive, acts, targets, p, noise)
    length(noise) == length(acts) ||
        throw(DimensionMismatch("noise length $(length(noise)) does not match acts length $(length(acts))"))

    @inbounds for i in eachindex(acts)
        deficit = targets[i] * p.threshold_mult - acts[i]
        sigma = d.membrane_noise + d.noise_gain * max(0.0, deficit)
        acts[i] += noise[i] * sigma
    end
    return acts
end
