using Random

struct BelowSetpoint end
struct AboveSetpoint end
struct SetpointDistance end

abstract type FeedbackMode end

struct OffFeedback <: FeedbackMode end
struct TonicFeedback <: FeedbackMode end
struct BernoulliFeedback <: FeedbackMode end

"""
    ReplayFeedback(values; cycle=true)

Replay an explicit per-tick need-input sequence. The mode ignores the current
need value: it is intended for causal controls that preserve a realised input
stream while breaking its alignment to physiology (for example by circularly
shifting a contingent stream). `values` are copied on construction. With
`cycle=true` the sequence wraps; otherwise requesting a tick past its end is an
error.
"""
struct ReplayFeedback <: FeedbackMode
    values::Vector{Float64}
    cycle::Bool

    function ReplayFeedback(values; cycle::Bool=true)
        sequence = Float64.(vec(collect(values)))
        isempty(sequence) && throw(ArgumentError("feedback replay sequence must not be empty"))
        all(isfinite, sequence) || throw(ArgumentError(
            "feedback replay sequence must contain only finite values",
        ))
        return new(copy(sequence), cycle)
    end
end

struct NoFailure end
struct BelowFailure
    threshold::Float64

    function BelowFailure(threshold::Real)
        threshold_ = Float64(threshold)
        isfinite(threshold_) || throw(ArgumentError("failure threshold must be finite"))
        return new(threshold_)
    end
end
struct AboveFailure
    threshold::Float64

    function AboveFailure(threshold::Real)
        threshold_ = Float64(threshold)
        isfinite(threshold_) || throw(ArgumentError("failure threshold must be finite"))
        return new(threshold_)
    end
end

(::NoFailure)(value::Real) = false
(policy::BelowFailure)(value::Real) = Float64(value) <= policy.threshold
(policy::AboveFailure)(value::Real) = Float64(value) >= policy.threshold

"""
    RegulatedVariable(name; minimum=0, maximum=1, initial=maximum, setpoint=maximum,
             drift=0, deficit=BelowSetpoint(), curve=LinearFeedback(),
             mode=OffFeedback(), gain=1, emission_p=1, link_p=nothing,
             failure=NoFailure())

Immutable policy for one bounded regulated scalar. Feedback mode is off
by default, while drift and failure remain active for matched causal controls.
"""
struct RegulatedVariable{D,C,M,F}
    name::Symbol
    minimum::Float64
    maximum::Float64
    initial::Float64
    setpoint::Float64
    drift::Float64
    deficit::D
    curve::C
    mode::M
    gain::Float64
    emission_p::Float64
    link_p::Union{Nothing,Float64}
    failure::F
end

function RegulatedVariable(
    name::Symbol;
    minimum::Real=0.0,
    maximum::Real=1.0,
    initial::Real=maximum,
    setpoint::Real=maximum,
    drift::Real=0.0,
    deficit=BelowSetpoint(),
    curve=LinearFeedback(),
    mode=OffFeedback(),
    gain::Real=1.0,
    emission_p::Real=1.0,
    link_p=nothing,
    failure=NoFailure(),
)
    lo = Float64(minimum)
    hi = Float64(maximum)
    initial_ = Float64(initial)
    setpoint_ = Float64(setpoint)
    drift_ = Float64(drift)
    gain_ = Float64(gain)
    emission_p_ = Float64(emission_p)
    all(isfinite, (lo, hi, initial_, setpoint_, drift_, gain_, emission_p_)) ||
        throw(ArgumentError("regulated-variable bounds, state, drift, gain, and emission_p must be finite"))
    lo < hi || throw(ArgumentError("regulated-variable minimum must be below maximum"))
    lo <= initial_ <= hi || throw(ArgumentError("regulated-variable initial value must lie within its bounds"))
    lo <= setpoint_ <= hi || throw(ArgumentError("regulated-variable setpoint must lie within its bounds"))
    gain_ >= 0.0 || throw(ArgumentError("regulated-variable feedback gain must be non-negative"))
    0.0 <= emission_p_ <= 1.0 ||
        throw(ArgumentError("regulated-variable emission_p must lie in [0, 1]"))
    link_p_ = link_p === nothing ? nothing : Float64(link_p)
    link_p_ === nothing || 0.0 <= link_p_ <= 1.0 ||
        throw(ArgumentError("regulated-variable link_p must lie in [0, 1]"))
    mode isa FeedbackMode ||
        throw(ArgumentError("regulated-variable mode must be a FeedbackMode"))
    return RegulatedVariable{typeof(deficit),typeof(curve),typeof(mode),typeof(failure)}(
        Symbol(name), lo, hi, initial_, setpoint_, drift_, deficit, curve, mode,
        gain_, emission_p_, link_p_, failure,
    )
end

RegulatedVariable(name::AbstractString; kwargs...) = RegulatedVariable(Symbol(name); kwargs...)

struct Exposure
    name::Symbol
    amount::Float64

    function Exposure(name::Symbol, amount::Real)
        amount_ = Float64(amount)
        isfinite(amount_) || throw(ArgumentError("exposure amount must be finite"))
        return new(Symbol(name), amount_)
    end
end

Exposure(name::AbstractString, amount::Real) = Exposure(Symbol(name), amount)

mutable struct RegulatedPhysiology{N<:Tuple,R<:AbstractRNG,P<:UnknownEffectPolicy} <: AbstractPhysiology
    variables::N
    values::Vector{Float64}
    pending::Vector{Float64}
    last_feedback::Vector{Float64}
    feedback_rngs::Vector{R}
    feedback_seeds::Vector{Int}
    seed::Union{Nothing,Int}
    is_alive::Bool
    tick::Int
    last_feedback_tick::Int
    death_tick::Union{Nothing,Int}
    death_cause::Union{Nothing,Symbol}
    unknown_effects::P
end

function _feedback_stream_seed(base_seed::Int, name::Symbol)
    value = UInt64(0xcbf29ce484222325)
    for byte in codeunits(string(base_seed, '\0', name))
        value = xor(value, UInt64(byte)) * UInt64(0x00000100000001b3)
    end
    return Int(mod(value, UInt64(typemax(Int))))
end

function _feedback_base_seed(seed::Union{Nothing,Int})
    seed === nothing || return seed
    return Int(mod(rand(RandomDevice(), UInt64), UInt64(typemax(Int))))
end

function RegulatedPhysiology(
    variables::Tuple;
    seed=0,
    unknown_effects::UnknownEffectPolicy=RejectUnknownEffects(),
)
    all(variable -> variable isa RegulatedVariable, variables) ||
        throw(ArgumentError("RegulatedPhysiology variables must all be RegulatedVariable values"))
    names = Symbol[variable.name for variable in variables]
    length(unique(names)) == length(names) ||
        throw(ArgumentError("regulated-variable names must be unique"))
    seed_ = seed === nothing ? nothing : Int(seed)
    base_seed = _feedback_base_seed(seed_)
    feedback_seeds = Int[_feedback_stream_seed(base_seed, name) for name in names]
    feedback_rngs = MersenneTwister.(feedback_seeds)
    values = Float64[variable.initial for variable in variables]
    return RegulatedPhysiology{
        typeof(variables),
        eltype(feedback_rngs),
        typeof(unknown_effects),
    }(
        variables,
        values,
        zeros(Float64, length(variables)),
        zeros(Float64, length(variables)),
        feedback_rngs,
        feedback_seeds,
        seed_,
        true,
        0,
        0,
        nothing,
        nothing,
        unknown_effects,
    )
end

RegulatedPhysiology(variables; kwargs...) = RegulatedPhysiology(Tuple(variables); kwargs...)

physiology_ports(physiology::RegulatedPhysiology) =
    Port{NoPlacement}[Port(Symbol(:regulated_, variable.name)) for variable in physiology.variables]
physiology_alive(physiology::RegulatedPhysiology) = physiology.is_alive

function _need_deficit(::BelowSetpoint, value::Float64, need::RegulatedVariable)
    value >= need.setpoint && return 0.0
    span = need.setpoint - need.minimum
    return span <= 0.0 ? 0.0 : clamp((need.setpoint - value) / span, 0.0, 1.0)
end

function _need_deficit(::AboveSetpoint, value::Float64, need::RegulatedVariable)
    value <= need.setpoint && return 0.0
    span = need.maximum - need.setpoint
    return span <= 0.0 ? 0.0 : clamp((value - need.setpoint) / span, 0.0, 1.0)
end

function _need_deficit(::SetpointDistance, value::Float64, need::RegulatedVariable)
    if value <= need.setpoint
        return _need_deficit(BelowSetpoint(), value, need)
    end
    return _need_deficit(AboveSetpoint(), value, need)
end

function _need_deficit(rule, value::Float64, need::RegulatedVariable)
    result = applicable(rule, value, need) ? rule(value, need) : rule(value)
    return _unit_value(result, "deficit for need :$(need.name)")
end

function _unit_value(value, label::AbstractString)
    value_ = Float64(value)
    isfinite(value_) || throw(ArgumentError("$(label) must be finite"))
    0.0 <= value_ <= 1.0 || throw(ArgumentError("$(label) must lie in [0, 1], got $(value_)"))
    return value_
end

function regulation_urgency(need::RegulatedVariable, value::Real)
    deficit = _need_deficit(need.deficit, Float64(value), need)
    return _unit_value(response_value(need.curve, deficit), "feedback curve for need :$(need.name)")
end

"""Emit one need-input sample for a `FeedbackMode`. Extend for custom modes."""
emit_feedback(::OffFeedback, need, urgency, rng) = 0.0
emit_feedback(::TonicFeedback, need, urgency, rng) = need.gain * urgency

function emit_feedback(::BernoulliFeedback, need, urgency, rng)
    probability = clamp(need.emission_p * urgency, 0.0, 1.0)
    draw = rand(rng)
    return draw < probability ? need.gain : 0.0
end

# The indexed method keeps the existing four-argument extension seam intact.
# Stateful schedules dispatch here; ordinary feedback modes fall through to the
# historical method above.
emit_feedback(mode::FeedbackMode, need, urgency, rng, tick::Integer) =
    emit_feedback(mode, need, urgency, rng)

function emit_feedback(mode::ReplayFeedback, need, urgency, rng, tick::Integer)
    tick_ = Int(tick)
    tick_ >= 1 || throw(ArgumentError("feedback replay tick must be at least one"))
    index = if mode.cycle
        mod1(tick_, length(mode.values))
    else
        tick_ <= length(mode.values) || throw(BoundsError(mode.values, tick_))
        tick_
    end
    return mode.values[index]
end

function _refresh_feedback!(physiology::RegulatedPhysiology)
    feedback_tick = physiology.tick + 1
    physiology.last_feedback_tick == feedback_tick &&
        return physiology.last_feedback
    if !physiology_alive(physiology)
        fill!(physiology.last_feedback, 0.0)
        physiology.last_feedback_tick = feedback_tick
        return physiology.last_feedback
    end
    @inbounds for i in eachindex(physiology.variables)
        need = physiology.variables[i]
        urgency = regulation_urgency(need, physiology.values[i])
        value = Float64(emit_feedback(
            need.mode,
            need,
            urgency,
            physiology.feedback_rngs[i],
            feedback_tick,
        ))
        isfinite(value) || throw(ArgumentError(
            "feedback mode for need :$(need.name) returned a non-finite value",
        ))
        physiology.last_feedback[i] = value
    end
    physiology.last_feedback_tick = feedback_tick
    return physiology.last_feedback
end

function physiology_feedback!(
    destination::AbstractVector,
    physiology::RegulatedPhysiology,
)
    length(destination) == length(physiology.last_feedback) || throw(DimensionMismatch(
        "physiology feedback destination has length $(length(destination)); " *
        "expected $(length(physiology.last_feedback))",
    ))
    copyto!(destination, _refresh_feedback!(physiology))
    return destination
end

function physiology_feedback!(physiology::RegulatedPhysiology)
    destination = similar(physiology.last_feedback)
    return physiology_feedback!(destination, physiology)
end

function _variable_index(physiology::RegulatedPhysiology, name::Symbol)
    idx = findfirst(variable -> variable.name === name, physiology.variables)
    idx === nothing && throw(ArgumentError("physiology has no regulated variable named :$(name)"))
    return idx
end

function physiology_expose!(physiology::RegulatedPhysiology, exposure::Exposure)
    physiology.pending[_variable_index(physiology, exposure.name)] += exposure.amount
    return physiology
end

physiology_expose!(physiology::RegulatedPhysiology, effect) =
    _handle_unknown_effect(physiology.unknown_effects, effect)

function _need_failed(policy, value::Float64, need::RegulatedVariable)
    result = applicable(policy, value, need) ? policy(value, need) : policy(value)
    return Bool(result)
end

function physiology_update!(physiology::RegulatedPhysiology, effects=())
    physiology_alive(physiology) || return nothing
    physiology.tick += 1
    @inbounds for i in eachindex(physiology.variables)
        physiology.pending[i] += physiology.variables[i].drift
    end
    for effect in effects
        physiology_expose!(physiology, effect)
    end
    @inbounds for i in eachindex(physiology.variables)
        variable = physiology.variables[i]
        physiology.values[i] = clamp(
            physiology.values[i] + physiology.pending[i],
            variable.minimum,
            variable.maximum,
        )
    end
    fill!(physiology.pending, 0.0)
    @inbounds for i in eachindex(physiology.variables)
        variable = physiology.variables[i]
        _need_failed(variable.failure, physiology.values[i], variable) || continue
        physiology.is_alive = false
        physiology.death_tick = physiology.tick
        physiology.death_cause = variable.name
        break
    end
    return nothing
end

function regulated_values(physiology::RegulatedPhysiology)
    names = Tuple(variable.name for variable in physiology.variables)
    return NamedTuple{names}(Tuple(physiology.values))
end

regulated_values(body::Embodiment) = regulated_values(body.physiology)
regulation_feedback(physiology::RegulatedPhysiology) = copy(physiology.last_feedback)
regulation_feedback(body::Embodiment) = regulation_feedback(body.physiology)

receptor_link_profile(::AbstractBody, default_probability::Real) = nothing

function physiology_link_profile(physiology::RegulatedPhysiology, default_probability::Real)
    probabilities = Float64[]
    for variable in physiology.variables
        push!(probabilities, something(variable.link_p, Float64(default_probability)))
    end
    return probabilities
end

function physiology_reset!(physiology::RegulatedPhysiology)
    @inbounds for i in eachindex(physiology.variables)
        physiology.values[i] = physiology.variables[i].initial
    end
    fill!(physiology.pending, 0.0)
    fill!(physiology.last_feedback, 0.0)
    @inbounds for i in eachindex(physiology.feedback_rngs)
        Random.seed!(physiology.feedback_rngs[i], physiology.feedback_seeds[i])
    end
    physiology.is_alive = true
    physiology.tick = 0
    physiology.last_feedback_tick = 0
    physiology.death_tick = nothing
    physiology.death_cause = nothing
    return physiology
end

physiology_state(physiology::RegulatedPhysiology) = (
    variables=regulated_values(physiology),
    feedback=regulation_feedback(physiology),
    alive=physiology.is_alive,
    death=physiology.death_tick === nothing ? nothing : (
        tick=physiology.death_tick,
        cause=physiology.death_cause,
    ),
)
