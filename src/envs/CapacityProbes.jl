using Random

"""A scheduled, stimulus-driven binary probe, or one continuous reversal session.

Labels and timing metadata are available to diagnostics, never to `sense`.
All actions before each response window are discarded. A full reset replays
the same stimuli; an independent trial is constructed with a new world seed.
"""
mutable struct CapacityProbeEnv{K,N,M} <: TaskWorld
    stimuli::Vector{SVector{N,Float64}}
    responses::Vector{UnitRange{Int}}
    cue_ends::Vector{Int}
    labels::Vector{Int}
    metadata::M
    tick::Int
    round::Int
    evidence::MVector{2,Float64}
    decisions::Vector{Int}
    ties::BitVector
    done::Bool
end

function _probe_episode(::Val{K}, stimuli::Matrix, responses, cue_ends, labels, metadata) where K
    N = size(stimuli, 1)
    frames = [SVector{N,Float64}(col) for col in eachcol(stimuli)]
    return CapacityProbeEnv{K,N,typeof(metadata)}(frames, responses, cue_ends,
        labels, metadata, 0, 1, MVector(0.0, 0.0), zeros(Int, length(labels)),
        falses(length(labels)), false)
end

function _probe_integer(value, name; minimum=1)
    value isa Integer && value >= minimum || throw(ArgumentError(
        "$name must be an integer ≥ $minimum"))
    return Int(value)
end

function _probe_mode(value, name, allowed)
    mode = Symbol(value)
    mode in allowed || throw(ArgumentError("$name must be one of $allowed"))
    return mode
end

_probe_name(::CapacityProbeEnv{K}) where K = K
n_receptors(::CapacityProbeEnv{K,N}) where {K,N} = N
n_effectors(::CapacityProbeEnv) = 2
default_ticks(env::CapacityProbeEnv) = length(env.stimuli)
default_window(env::CapacityProbeEnv) = default_ticks(env)
terminated(env::CapacityProbeEnv) = env.done

sense(env::CapacityProbeEnv) = env.done ? zero(first(env.stimuli)) : env.stimuli[env.tick + 1]

function sense(env::CapacityProbeEnv{:reversal_adaptation,N}) where N
    env.done && return zero(first(env.stimuli))
    frame = env.stimuli[env.tick + 1]
    # Feedback channels: chosen left, chosen right, correct, incorrect.
    # The phase marker is present even when feedback content is hidden.
    previous = env.round - 1
    if frame[4] == 1 && previous >= 1 && env.metadata.feedback_mode === :visible
        choice = env.decisions[previous]
        correct = choice == env.labels[previous]
        return SVector{N,Float64}(frame[1], frame[2], frame[3], frame[4],
            choice == 1, choice == 2, correct, !correct)
    end
    return frame
end

function step!(env::CapacityProbeEnv, output)
    env.done && return env
    length(output) == 2 || throw(DimensionMismatch("capacity probes require two effectors"))
    all(x -> x isa Real && isfinite(x) && 0 <= x <= 1, output) ||
        throw(ArgumentError("probe effectors must be finite and within [0, 1]"))
    frame = env.tick + 1
    if env.round <= length(env.responses)
        response = env.responses[env.round]
        if frame in response
            env.evidence[1] += output[1]
            env.evidence[2] += output[2]
        end
        if frame == last(response)
            env.ties[env.round] = env.evidence[1] == env.evidence[2]
            env.decisions[env.round] = env.evidence[1] >= env.evidence[2] ? 1 : 2
            env.evidence .= 0
            env.round += 1
        end
    end
    env.tick = frame
    env.done = frame == length(env.stimuli)
    return env
end

function reset!(env::CapacityProbeEnv)
    env.tick = 0
    env.round = 1
    env.evidence .= 0
    fill!(env.decisions, 0)
    fill!(env.ties, false)
    env.done = false
    return env
end

function metrics(env::CapacityProbeEnv, window::Integer=default_window(env))
    accuracy = env.done ? Float64(only(env.decisions) == only(env.labels)) : missing
    return (name=string(_probe_name(env)), score=accuracy, probe_accuracy=accuracy,
        completed=env.done, decision=only(env.decisions), tied=only(env.ties),
        chance_accuracy=0.5, metadata=env.metadata, xy_path=nothing)
end

function metrics(env::CapacityProbeEnv{:reversal_adaptation}, window::Integer=default_window(env))
    reversal = env.metadata.reversal_round
    correct = env.decisions .== env.labels
    accuracy = env.done ? sum(@view correct[reversal:reversal + 15]) / 16 : missing
    pre = env.done ? sum(@view correct[1:reversal - 1]) / (reversal - 1) : missing
    # Recovery is the first run of eight correct responses after the reversal;
    # report missing if that run is not observed, rather than a horizon sentinel.
    recovery = env.done ? findfirst(i -> all(@view correct[i:i + 7]),
        reversal:length(correct) - 7) : nothing
    return (name="reversal_adaptation", score=accuracy, adaptation_accuracy=accuracy,
        pre_reversal_accuracy=pre, recovery_rounds=recovery === nothing ? missing : recovery - 1,
        completed=env.done, tied=count(env.ties), chance_accuracy=0.5,
        metadata=env.metadata, xy_path=nothing)
end

"""Construct a registered capacity probe. Options are validated before rollout."""
struct CapacityProbeSetup{K} end
function (::CapacityProbeSetup{K})(; seed=0, rng=nothing, body=nothing, n_nodes=nothing, kwargs...) where K
    body === nothing || body === :direct || throw(ArgumentError(
        "capacity probes use their declared direct observation and action interface"))
    env = _capacity_probe(Val(K), rng === nothing ? MersenneTwister(Int(seed)) : rng; kwargs...)
    return TaskSetup(env, [direct_embodiment(n_receptors(env), 2)])
end

function _capacity_probe(kind::Val{:recall_interference}, rng;
    cue_ticks=8, delay=32, response_ticks=8, distractors=1, distractor_ticks=4,
    cue_mode=:transient, distractor_mode=:random)
    c = _probe_integer(cue_ticks, :cue_ticks)
    d = _probe_integer(delay, :delay; minimum=0)
    r = _probe_integer(response_ticks, :response_ticks)
    k = _probe_integer(distractors, :distractors; minimum=0)
    w = _probe_integer(distractor_ticks, :distractor_ticks)
    k == 0 || (d >= 32 && k * w + k + 1 <= d) || throw(ArgumentError(
        "distractors require delay ≥ 32 and at least one blank frame between cues"))
    mode = _probe_mode(cue_mode, :cue_mode, (:transient, :persistent, :hidden))
    dm = _probe_mode(distractor_mode, :distractor_mode, (:random, :matched, :opposite, :absent))
    cue = rand(rng, 1:2)
    distractor_labels = rand(rng, 1:2, k) # invariant across visibility controls
    frame = zeros(3, c + d + r)
    mode !== :hidden && (frame[cue, 1:c] .= 1)
    mode === :persistent && (frame[cue, c + 1:end] .= 1)
    starts = [c + fld(i * (d - w), k + 1) + 1 for i in 1:k]
    for (i, start) in enumerate(starts)
        label = dm === :matched ? cue : dm === :opposite ? 3 - cue : distractor_labels[i]
        if dm !== :absent
            frame[1:2, start:start + w - 1] .= 0
            frame[label, start:start + w - 1] .= 1
        end
    end
    response = c + d + 1:c + d + r
    frame[3, response] .= 1
    return _probe_episode(kind, frame, [response], [c], [cue],
        (; cue, delay=d, cue_ticks=c, distractors=k, distractor_ticks=w,
            distractor_labels=Tuple(distractor_labels), distractor_starts=Tuple(starts),
            cue_mode=mode, distractor_mode=dm))
end

function _capacity_probe(kind::Val{:delayed_xor}, rng;
    cue_ticks=8, gap=32, response_ticks=8, cue_mode=:transient)
    c = _probe_integer(cue_ticks, :cue_ticks)
    g = _probe_integer(gap, :gap; minimum=0)
    r = _probe_integer(response_ticks, :response_ticks)
    mode = _probe_mode(cue_mode, :cue_mode, (:transient, :persistent, :hidden))
    a, b = rand(rng, 1:2, 2)
    frame = zeros(5, 2c + g + r)
    if mode !== :hidden
        frame[a, 1:c] .= 1
        frame[2 + b, c + g + 1:2c + g] .= 1
    end
    if mode === :persistent
        frame[a, :] .= 1
        frame[2 + b, c + g + 1:end] .= 1
    end
    response = 2c + g + 1:2c + g + r
    frame[5, response] .= 1
    return _probe_episode(kind, frame, [response], [c], [a == b ? 1 : 2],
        (; first_cue=a, second_cue=b, gap=g, cue_mode=mode))
end

function _probe_pulses(rng, n, fraction, label)
    count_left = n * (1 + (label == 1 ? fraction : -fraction)) / 2
    isinteger(count_left) || throw(ArgumentError(
        "pulse_count and evidence_fraction must give integral evidence counts"))
    # The final pulse is sampled independently of the answer. The remaining
    # sequence is shuffled conditional on that pulse and the exact evidence.
    final = rand(rng, 1:2)
    left = Int(count_left) - (final == 1)
    0 <= left <= n - 1 || throw(ArgumentError("evidence must permit either final pulse"))
    pulses = vcat(fill(1, left), fill(2, n - 1 - left))
    shuffle!(rng, pulses)
    push!(pulses, final)
    return pulses
end

function _probe_evidence_options(pulse_count, evidence_fraction, pulse_ticks, response_ticks)
    n = _probe_integer(pulse_count, :pulse_count; minimum=4)
    p = _probe_integer(pulse_ticks, :pulse_ticks)
    r = _probe_integer(response_ticks, :response_ticks)
    f = Float64(evidence_fraction)
    isfinite(f) && 0 < f < 1 || throw(ArgumentError("evidence_fraction must be within (0, 1)"))
    return n, f, p, r
end

function _capacity_probe(kind::Val{:evidence_accumulation}, rng;
    pulse_count=32, evidence_fraction=0.25, pulse_ticks=1, response_ticks=8, input_mode=:visible)
    n, f, p, r = _probe_evidence_options(pulse_count, evidence_fraction, pulse_ticks, response_ticks)
    mode = _probe_mode(input_mode, :input_mode, (:visible, :hidden))
    label = rand(rng, 1:2)
    pulses = _probe_pulses(rng, n, f, label)
    frame = zeros(3, n * p + r)
    for (i, pulse) in enumerate(pulses)
        mode === :visible && (frame[pulse, (i - 1) * p + 1:i * p] .= 1)
    end
    response = n * p + 1:n * p + r
    frame[3, response] .= 1
    return _probe_episode(kind, frame, [response], [p], [label],
        (; pulse_count=n, evidence_fraction=f, pulse_ticks=p, input_mode=mode))
end

function _capacity_probe(kind::Val{:context_integration}, rng;
    cue_ticks=8, pulse_count=32, evidence_fraction=0.25, pulse_ticks=1,
    response_ticks=8, context_mode=:transient, congruency=:mixed)
    c = _probe_integer(cue_ticks, :cue_ticks)
    n, f, p, r = _probe_evidence_options(pulse_count, evidence_fraction, pulse_ticks, response_ticks)
    mode = _probe_mode(context_mode, :context_mode, (:transient, :persistent, :hidden))
    congruency = _probe_mode(congruency, :congruency, (:mixed, :congruent, :conflicting))
    context, label, other_draw = rand(rng, 1:2, 3)
    other = congruency === :congruent ? label : congruency === :conflicting ? 3 - label : other_draw
    labels = context == 1 ? (label, other) : (other, label)
    streams = [_probe_pulses(rng, n, f, x) for x in labels]
    frame = zeros(7, c + n * p + r)
    mode !== :hidden && (frame[context, 1:c] .= 1)
    mode === :persistent && (frame[context, :] .= 1)
    for stream in 1:2, (i, pulse) in enumerate(streams[stream])
        frame[2stream + pulse, c + (i - 1) * p + 1:c + i * p] .= 1
    end
    response = c + n * p + 1:c + n * p + r
    frame[7, response] .= 1
    return _probe_episode(kind, frame, [response], [c], [label],
        (; context, context_mode=mode, congruency, congruent=label == other,
            pulse_count=n, evidence_fraction=f, pulse_ticks=p))
end

function _capacity_probe(kind::Val{:temporal_order}, rng;
    cue_ticks=8, gap=8, terminal_ticks=8, response_ticks=8, input_mode=:visible)
    c = _probe_integer(cue_ticks, :cue_ticks)
    g = _probe_integer(gap, :gap; minimum=0)
    t = _probe_integer(terminal_ticks, :terminal_ticks)
    r = _probe_integer(response_ticks, :response_ticks)
    mode = _probe_mode(input_mode, :input_mode, (:visible, :hidden))
    label = rand(rng, 1:2)
    frame = zeros(4, 2c + g + t + r)
    if mode === :visible
        frame[label, 1:c] .= 1
        frame[3 - label, c + g + 1:2c + g] .= 1
    end
    frame[3, 2c + g + 1:2c + g + t] .= 1
    response = 2c + g + t + 1:2c + g + t + r
    frame[4, response] .= 1
    return _probe_episode(kind, frame, [response], [c], [label],
        (; gap=g, cue_ticks=c, terminal_ticks=t, input_mode=mode))
end

function _capacity_probe(kind::Val{:reversal_adaptation}, rng;
    rounds=96, cue_ticks=8, response_ticks=8, feedback_ticks=8,
    reversal_range=(32, 64), feedback_mode=:visible)
    n = _probe_integer(rounds, :rounds; minimum=48)
    c = _probe_integer(cue_ticks, :cue_ticks)
    r = _probe_integer(response_ticks, :response_ticks)
    f = _probe_integer(feedback_ticks, :feedback_ticks)
    length(reversal_range) == 2 || throw(ArgumentError("reversal_range needs two endpoints"))
    lo, hi = (_probe_integer(x, :reversal_range; minimum=2) for x in reversal_range)
    lo <= hi <= n - 15 || throw(ArgumentError("reversal must leave sixteen scored rounds"))
    mode = _probe_mode(feedback_mode, :feedback_mode, (:visible, :hidden))
    mapping = rand(rng, Bool)
    reversal = rand(rng, lo:hi)
    cues = rand(rng, 1:2, n)
    frame = zeros(8, n * (c + r + f))
    responses = UnitRange{Int}[]
    ends = Int[]
    labels = Int[]
    for round in 1:n
        start = (round - 1) * (c + r + f)
        # Keep the cue present during response: this probes adapting a rule,
        # rather than adding an undeclared within-round memory requirement.
        frame[cues[round], start + 1:start + c + r] .= 1
        response = start + c + 1:start + c + r
        frame[3, response] .= 1
        frame[4, start + c + r + 1:start + c + r + f] .= 1
        push!(responses, response)
        push!(ends, start + c)
        push!(labels, xor(mapping, round >= reversal) ? 3 - cues[round] : cues[round])
    end
    return _probe_episode(kind, frame, responses, ends, labels,
        (; rounds=n, cue_ticks=c, response_ticks=r, feedback_ticks=f,
            reversal_round=reversal, initial_mapping=mapping, feedback_mode=mode))
end
