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

function NoisyInput(inner::Reservoir; sensory_noise::Real=0.1, seed::Integer=0)
    noise = Float64(sensory_noise)
    isfinite(noise) || throw(ArgumentError("sensory_noise must be finite, got $(sensory_noise)"))
    noise >= 0.0 || throw(ArgumentError("sensory_noise must be non-negative, got $(sensory_noise)"))
    seed_ = Int(seed)
    return NoisyInput(inner, noise, MersenneTwister(seed_ + 999983), seed_)
end

# Forward unknown field access to the inner reservoir (so the Recorder's :acts
# channel, metrics, etc. that read fields keep working through the wrapper).
function Base.getproperty(w::NoisyInput, s::Symbol)
    (s === :inner || s === :sensory_noise || s === :rng || s === :seed) ?
        getfield(w, s) : getproperty(getfield(w, :inner), s)
end

function Base.propertynames(w::NoisyInput, private::Bool=false)
    own = fieldnames(typeof(w))
    inner = propertynames(getfield(w, :inner), private)
    return Tuple(unique((own..., inner...)))
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
activations(w::NoisyInput) = activations(getfield(w, :inner))
weights(w::NoisyInput) = weights(getfield(w, :inner))
plasticity(w::NoisyInput) = plasticity(getfield(w, :inner))
windowing(w::NoisyInput) = windowing(getfield(w, :inner))
temporal_window(w::NoisyInput) = temporal_window(getfield(w, :inner))
network_snapshot(w::NoisyInput) = network_snapshot(getfield(w, :inner))

supports_intervention(intervention::Intervention, w::NoisyInput) =
    supports_intervention(intervention, getfield(w, :inner))

function apply!(intervention::Intervention, w::NoisyInput)
    supports_intervention(intervention, w) ||
        throw(MethodError(apply!, (intervention, w)))
    apply!(intervention, getfield(w, :inner))
    return w
end

function reset!(w::NoisyInput)
    reset!(getfield(w, :inner))
    setfield!(w, :rng, MersenneTwister(getfield(w, :seed) + 999983))
    return w
end

function snapshot_state(w::NoisyInput)
    return (
        wrapper=:noisy_input,
        schema_version=1,
        rng=deepcopy(getfield(w, :rng)),
        inner=snapshot_state(getfield(w, :inner)),
    )
end

function load_state!(w::NoisyInput, state)
    if state isa NamedTuple && hasproperty(state, :wrapper) &&
            getproperty(state, :wrapper) === :noisy_input
        hasproperty(state, :schema_version) && state.schema_version == 1 ||
            throw(ArgumentError("unsupported NoisyInput state snapshot version"))
        hasproperty(state, :inner) ||
            throw(ArgumentError("NoisyInput state snapshot is missing :inner"))
        hasproperty(state, :rng) ||
            throw(ArgumentError("NoisyInput state snapshot is missing :rng"))
        state.rng isa MersenneTwister ||
            throw(ArgumentError("NoisyInput state snapshot has incompatible RNG $(typeof(state.rng))"))
        load_state!(getfield(w, :inner), state.inner)
        setfield!(w, :rng, deepcopy(state.rng))
        return w
    end

    # Compatibility with snapshots written before the wrapper owned RNG state.
    load_state!(getfield(w, :inner), state)
    return w
end
