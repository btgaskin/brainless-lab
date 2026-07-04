struct NoDrive <: Drive end

# Oosawa endogenous membrane drive — a minimal model of the *spontaneous* activity
# regime in Oosawa, F. (2007), "Spontaneous activity of living cells", BioSystems
# 88, 191–201 (see also Oosawa 2001, Bull. Math. Biol. 63, 643). Paramecium and
# similar cells generate input-independent behaviour from an internally-driven,
# metabolically-powered membrane-potential fluctuation; the drive reproduces that
# as target-gated Gaussian current on the membrane potential. See the docs page
# `nodes/falandays.mdx` §"The Oosawa drive".
#
# `OosawaDrive()` with both fields zero is deliberately inert (a NoDrive that still
# consumes a noise draw); it is the neutral primitive. The active `:falandays_oosawa`
# preset supplies `noise_gain = 0.8` at construction (see `falandays_oosawa` and
# `_falandays_oosawa_native`).
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

    # The noise is added to the membrane potential `acts` BEFORE rectify/threshold
    # (see `step!`), not to the output. The leak (`acts ← acts·(1−λ) + …`) then
    # integrates it into a temporally-correlated Ornstein–Uhlenbeck fluctuation
    # that occasionally crosses threshold → spontaneous, input-independent spikes.
    # This is Oosawa's Eq. (1), `C·dδV/dt = −G·δV + I(…)`: a Langevin/OU equation
    # for the *basic* membrane fluctuation, with the leak as the `−G·δV` relaxation
    # and the injected Gaussian current as the random force. Post-threshold noise
    # would be white output jitter, not an OU membrane process.
    #
    # The gain keys off the gap to the FIRING threshold `μ·T` (= 2T), not the
    # target `T`. Keying off `T − acts` would equilibrate the membrane at the
    # set-point and essentially never push past `μ·T` — no spontaneous spikes.
    # `max(0, μT − acts)` keeps the drive on until the node can actually fire and
    # switches it off at set-point: σ ramps up when a node is starved of input and
    # vanishes once satisfied, the biological analogue of Oosawa's internal-state
    # regulation of spontaneous-spike frequency (§5–6).
    @inbounds for i in eachindex(acts)
        deficit = targets[i] * p.threshold_mult - acts[i]
        sigma = d.membrane_noise + d.noise_gain * max(0.0, deficit)
        acts[i] += noise[i] * sigma
    end
    return acts
end
