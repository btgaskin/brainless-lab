# Composable sensory-noise wrapper.
#
# In the Falandays line, *sensory noise* is distinct from the Oosawa *membrane
# noise*: it perturbs the SENSED INPUT, not the membrane. v0.2 applies it in the
# body (`bodies.py sense_agents`) as `sens += Uniform(-s, +s)` then clips `>= 0`.
# Here we expose it as a transparent wrapper node so any reservoir gains a
# sensory-noise axis without touching the (oracle-validated) inner model.

"""
    NoisyInput(inner; sensory_noise=0.1, seed=0)

Wrap a reservoir so that each `step!` perturbs the receptor input with
`Uniform(-sensory_noise, +sensory_noise)` and clips it to `>= 0` (the v0.2 /
Falandays sensory-noise formula), then delegates to `inner`. The wrapper is
transparent: state/field access and the node contract forward to `inner`.
"""
mutable struct NoisyInput{R<:Reservoir} <: Reservoir
    inner::R
    sensory_noise::Float64
    rng::MersenneTwister
    seed::Int
end

NoisyInput(inner::Reservoir; sensory_noise::Real=0.1, seed::Integer=0) =
    NoisyInput(inner, Float64(sensory_noise), MersenneTwister(Int(seed) + 999983), Int(seed))

# Forward unknown field access to the inner reservoir (so the Recorder's :acts
# channel, metrics, etc. that read fields keep working through the wrapper).
function Base.getproperty(w::NoisyInput, s::Symbol)
    (s === :inner || s === :sensory_noise || s === :rng || s === :seed) ?
        getfield(w, s) : getproperty(getfield(w, :inner), s)
end

function step!(w::NoisyInput, receptors)
    s = getfield(w, :sensory_noise)
    s > 0.0 || return step!(getfield(w, :inner), receptors)
    rc = Float64.(vec(collect(receptors)))
    rng = getfield(w, :rng)
    @inbounds for i in eachindex(rc)
        rc[i] += (2.0 * rand(rng) - 1.0) * s   # Uniform(-s, +s)
        rc[i] < 0.0 && (rc[i] = 0.0)           # clip >= 0 (matches v0.2)
    end
    return step!(getfield(w, :inner), rc)
end

effectors(w::NoisyInput, spikes) = effectors(getfield(w, :inner), spikes)
n_receptors(w::NoisyInput) = n_receptors(getfield(w, :inner))
n_effectors(w::NoisyInput) = n_effectors(getfield(w, :inner))
n_nodes(w::NoisyInput) = n_nodes(getfield(w, :inner))

function reset!(w::NoisyInput)
    reset!(getfield(w, :inner))
    setfield!(w, :rng, MersenneTwister(getfield(w, :seed) + 999983))
    return w
end

snapshot_state(w::NoisyInput) = snapshot_state(getfield(w, :inner))
load_state!(w::NoisyInput, state) = (load_state!(getfield(w, :inner), state); w)
