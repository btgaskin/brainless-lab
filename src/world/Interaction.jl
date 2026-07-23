"""
    InteractionCycle

Abstract timing contract between one world step and the native neural frames
used to sense, update a reservoir, and form one command. Reservoir-internal
integration remains owned by the reservoir and is not represented here.
"""
abstract type InteractionCycle end

"""
    FixedRateCycle(neural_frames=1)

Run exactly `neural_frames` native reservoir updates for every world step. The
world is sampled once, frame encoders may distribute that sample through time,
and the selected readout reduces the frame outputs to one effector signal.
"""
struct FixedRateCycle <: InteractionCycle
    neural_frames::Int

    function FixedRateCycle(neural_frames::Integer=1)
        frames = Int(neural_frames)
        frames >= 1 || throw(ArgumentError(
            "FixedRateCycle neural_frames must be positive, got $(frames)",
        ))
        return new(frames)
    end
end

neural_frames(cycle::FixedRateCycle) = cycle.neural_frames

"""Default legacy-compatible cycle for a reservoir."""
function default_interaction_cycle(reservoir::Reservoir)
    frames = windowing(reservoir) isa IntrinsicWindow ? 1 : temporal_window(reservoir)
    return FixedRateCycle(frames)
end

"""Abstract neural-output reduction carried by an embodiment."""
abstract type AbstractReadout end

"""
    MeanReadout(policy=PASSTHROUGH_MOTOR)

Mean-reduce native neural outputs over the interaction cycle, then project the
result through the legacy reservoir readout policy. This exactly represents the
previous held-input temporal-window behavior and is the default compatibility
readout.
"""
struct MeanReadout{P} <: AbstractReadout
    policy::P
end

"""Use only the final native neural output in the cycle."""
struct InstantReadout{P} <: AbstractReadout
    policy::P
end

"""
    VotingReadout(policy=PASSTHROUGH_MOTOR)

Project each neural frame to effectors, award one vote to the first maximal
effector, and emit a one-hot signal for the first maximal vote total. The stable
first-index tie rule matches the Plank CartPole protocol.
"""
struct VotingReadout{P} <: AbstractReadout
    policy::P
end

MeanReadout() = MeanReadout(PASSTHROUGH_MOTOR)
InstantReadout() = InstantReadout(PASSTHROUGH_MOTOR)
VotingReadout() = VotingReadout(PASSTHROUGH_MOTOR)

readout_policy(readout::AbstractReadout) = readout.policy

mutable struct MeanReadoutState
    neural_sum::Vector{Float64}
    neural_mean::Vector{Float64}
end

mutable struct InstantReadoutState
    neural_sum::Vector{Float64}
    neural_mean::Vector{Float64}
    neural_last::Vector{Float64}
end

mutable struct VotingReadoutState
    neural_sum::Vector{Float64}
    neural_mean::Vector{Float64}
    votes::Vector{Int}
    signal::Vector{Float64}
end

function readout_state(::MeanReadout, reservoir::Reservoir)
    return MeanReadoutState(zeros(n_nodes(reservoir)), zeros(n_nodes(reservoir)))
end

function readout_state(::InstantReadout, reservoir::Reservoir)
    return InstantReadoutState(
        zeros(n_nodes(reservoir)),
        zeros(n_nodes(reservoir)),
        zeros(n_nodes(reservoir)),
    )
end

function readout_state(::VotingReadout, reservoir::Reservoir)
    return VotingReadoutState(
        zeros(n_nodes(reservoir)),
        zeros(n_nodes(reservoir)),
        zeros(Int, n_effectors(reservoir)),
        zeros(n_effectors(reservoir)),
    )
end

function begin_readout!(state::MeanReadoutState, ::MeanReadout, ::FixedRateCycle)
    fill!(state.neural_sum, 0.0)
    fill!(state.neural_mean, 0.0)
    return state
end

function begin_readout!(state::InstantReadoutState, ::InstantReadout, ::FixedRateCycle)
    fill!(state.neural_sum, 0.0)
    fill!(state.neural_mean, 0.0)
    fill!(state.neural_last, 0.0)
    return state
end

function begin_readout!(state::VotingReadoutState, ::VotingReadout, ::FixedRateCycle)
    fill!(state.neural_sum, 0.0)
    fill!(state.neural_mean, 0.0)
    fill!(state.votes, 0)
    fill!(state.signal, 0.0)
    return state
end

function _require_neural_width(state_values, neural_output)
    length(neural_output) == length(state_values) || throw(DimensionMismatch(
        "readout expected $(length(state_values)) neural outputs, got $(length(neural_output))",
    ))
    return neural_output
end

function observe_frame!(
    state::MeanReadoutState,
    ::MeanReadout,
    ::Reservoir,
    neural_output,
    frame::Integer,
)
    _require_neural_width(state.neural_sum, neural_output)
    @inbounds for index in eachindex(state.neural_sum, neural_output)
        state.neural_sum[index] += Float64(neural_output[index])
    end
    return state
end

function observe_frame!(
    state::InstantReadoutState,
    ::InstantReadout,
    ::Reservoir,
    neural_output,
    frame::Integer,
)
    _require_neural_width(state.neural_last, neural_output)
    @inbounds for index in eachindex(state.neural_last, neural_output)
        value = Float64(neural_output[index])
        state.neural_sum[index] += value
        state.neural_last[index] = value
    end
    return state
end

function observe_frame!(
    state::VotingReadoutState,
    readout_component::VotingReadout,
    reservoir::Reservoir,
    neural_output,
    frame::Integer,
)
    _require_neural_width(state.neural_sum, neural_output)
    @inbounds for index in eachindex(state.neural_sum, neural_output)
        state.neural_sum[index] += Float64(neural_output[index])
    end
    projected = readout(readout_component.policy, reservoir, neural_output)
    length(projected) == length(state.votes) || throw(DimensionMismatch(
        "voting readout expected $(length(state.votes)) effectors, got $(length(projected))",
    ))
    _, winner = findmax(projected)
    state.votes[winner] += 1
    return state
end

function finish_readout!(
    state::MeanReadoutState,
    readout_component::MeanReadout,
    reservoir::Reservoir,
    cycle::FixedRateCycle,
)
    scale = inv(Float64(neural_frames(cycle)))
    @inbounds for index in eachindex(state.neural_mean, state.neural_sum)
        state.neural_mean[index] = state.neural_sum[index] * scale
    end
    return readout(readout_component.policy, reservoir, state.neural_mean)
end

function finish_readout!(
    state::InstantReadoutState,
    readout_component::InstantReadout,
    reservoir::Reservoir,
    cycle::FixedRateCycle,
)
    scale = inv(Float64(neural_frames(cycle)))
    @inbounds for index in eachindex(state.neural_mean, state.neural_sum)
        state.neural_mean[index] = state.neural_sum[index] * scale
    end
    return readout(readout_component.policy, reservoir, state.neural_last)
end

function finish_readout!(
    state::VotingReadoutState,
    ::VotingReadout,
    ::Reservoir,
    cycle::FixedRateCycle,
)
    scale = inv(Float64(neural_frames(cycle)))
    @inbounds for index in eachindex(state.neural_mean, state.neural_sum)
        state.neural_mean[index] = state.neural_sum[index] * scale
    end
    fill!(state.signal, 0.0)
    _, winner = findmax(state.votes)
    state.signal[winner] = 1.0
    return state.signal
end

recorded_neural_output(state::MeanReadoutState, ::FixedRateCycle) = state.neural_mean
recorded_neural_output(state::InstantReadoutState, ::FixedRateCycle) = state.neural_mean
recorded_neural_output(state::VotingReadoutState, ::FixedRateCycle) = state.neural_mean

"""Per-agent reusable buffers for one interaction cycle."""
mutable struct InteractionState{R}
    readout::R
    receptor_sum::Vector{Float64}
    receptor_mean::Vector{Float64}
end

function InteractionState(readout_component::AbstractReadout, reservoir::Reservoir, body::AbstractBody)
    return InteractionState(
        readout_state(readout_component, reservoir),
        zeros(n_receptors(body)),
        zeros(n_receptors(body)),
    )
end

function begin_interaction!(state::InteractionState, readout_component, cycle::FixedRateCycle)
    fill!(state.receptor_sum, 0.0)
    fill!(state.receptor_mean, 0.0)
    begin_readout!(state.readout, readout_component, cycle)
    return state
end

function observe_receptors!(state::InteractionState, receptors)
    length(receptors) == length(state.receptor_sum) || throw(DimensionMismatch(
        "interaction expected $(length(state.receptor_sum)) receptors, got $(length(receptors))",
    ))
    @inbounds for index in eachindex(state.receptor_sum, receptors)
        state.receptor_sum[index] += Float64(receptors[index])
    end
    return state
end

function finish_receptors!(state::InteractionState, cycle::FixedRateCycle)
    scale = inv(Float64(neural_frames(cycle)))
    @inbounds for index in eachindex(state.receptor_mean, state.receptor_sum)
        state.receptor_mean[index] = state.receptor_sum[index] * scale
    end
    return state.receptor_mean
end

# Memoryless encoders and legacy bodies encode once and hold that result across
# the cycle. Temporal encoders specialize these methods.
begin_encoding!(encoder::AbstractEncoder, samples, ::FixedRateCycle) = encode!(encoder, samples)
encode_frame!(::AbstractEncoder, state, ::Integer, ::FixedRateCycle) = state

begin_encoding!(body::AbstractBody, percept, ::FixedRateCycle) = sense!(body, percept)
encode_frame!(::AbstractBody, state, ::Integer, ::FixedRateCycle) = state

# Compatibility for custom bodies that still expose only a Motor policy.
readout_components(body::AbstractBody) = (MeanReadout(readout_policy(body)),)
primary_readout(body::AbstractBody) = only(readout_components(body))
