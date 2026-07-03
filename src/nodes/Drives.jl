struct NoDrive <: Drive end

Base.@kwdef struct OosawaDrive <: Drive
    membrane_noise::Float64 = 0.0
    noise_gain::Float64 = 0.0
end

function _resolve_drive_instance(drive; kwargs...)
    drive === nothing && return NoDrive()
    drive isa Drive && return drive

    sym =
        drive isa Symbol ? drive :
        drive isa AbstractString ? Symbol(drive) :
        throw(ArgumentError("drive must be a Drive instance or registered drive symbol"))

    sym === :none && return NoDrive()
    ctor = resolve_drive(sym)

    if isempty(kwargs)
        return ctor()
    end

    try
        return ctor(; kwargs...)
    catch err
        err isa MethodError || rethrow()
        return ctor()
    end
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
