"""Observation-only word sequences from the Falandays, Nguyen and Spivey model.

Subject/object roles belong to the grammar; the reservoir sees five lexical channels.
Outputs do not affect the sequence. Completion probes continue the same trial after
the training sequence; each condition is rebuilt from paired seeds.
"""
mutable struct WordSequenceEnv <: TaskWorld
    stream::Vector{Int}
    probabilities::Vector{Float64}
    visible::BitVector
    training_ticks::Int
    tick::Int
end

const _WORD_LEXEMES = (1, 2, 3, 4, 2, 1, 5)

function WordSequenceEnv(; seed=0, rng=nothing, sentences::Integer=1000,
    completion_cues::Integer=0, completion_subject::Integer=1)
    sentences >= 10 || throw(ArgumentError("word sequences require at least 10 sentences"))
    completion_cues in (0, 1, 2) || throw(ArgumentError("completion_cues must be 0, 1 or 2"))
    completion_subject in (1, 2) || throw(ArgumentError("completion_subject must be 1 or 2"))
    random = rng === nothing ? MersenneTwister(Int(seed)) : rng
    stream, probabilities = Int[], Float64[]
    for sentence in 1:Int(sentences)
        subject = rand(random) < 0.5 ? 1 : 2
        # The single-run source alternates subjects in the early/late display trials.
        if (2 <= sentence <= 8 || sentence >= sentences - 8) && !isempty(stream)
            subject = 3 - stream[end - 3]
        end
        verb_common = rand(random) < 0.75
        verb = subject == 1 ? (verb_common ? 3 : 4) : (verb_common ? 4 : 3)
        object_common = rand(random) < 0.75
        object = verb == 3 ? (object_common ? 5 : 6) : (object_common ? 6 : 5)
        append!(stream, (subject, verb, object, 7))
        append!(probabilities, (0.5, verb_common ? 0.75 : 0.25,
                               object_common ? 0.75 : 0.25, 1.0))
    end
    train = length(stream)
    visible = trues(train)
    if completion_cues > 0
        sequence = completion_subject == 1 ? (1, 3, 5, 7) : (2, 4, 6, 7)
        append!(stream, sequence)
        append!(probabilities, (0.5, 1.0, 1.0, 1.0))
        append!(visible, [i <= completion_cues for i in 1:4])
    end
    return WordSequenceEnv(stream, probabilities, visible, train, 0)
end

n_receptors(::WordSequenceEnv) = 5
n_effectors(::WordSequenceEnv) = 1
default_ticks(env::WordSequenceEnv) = length(env.stream)
default_window(env::WordSequenceEnv) = length(env.stream)
terminated(env::WordSequenceEnv) = env.tick >= length(env.stream)
function sense(env::WordSequenceEnv)
    index = env.tick + 1
    terminated(env) && return zeros(5)
    return [env.visible[index] && i == _WORD_LEXEMES[env.stream[index]] ? 1.0 : 0.0 for i in 1:5]
end
function step!(env::WordSequenceEnv, output)
    terminated(env) || (env.tick += 1)
    return env
end
reset!(env::WordSequenceEnv) = (env.tick = 0; env)
function metrics(env::WordSequenceEnv, window::Integer=default_window(env))
    return (name="word_sequence_2021", completed=terminated(env),
        training_ticks=env.training_ticks, word_stream=Tuple(env.stream),
        grammar_probabilities=Tuple(env.probabilities), visible=Tuple(env.visible))
end

struct WordSequenceSetup end
function validate_task_evaluation(::WordSequenceSetup, options, evaluation::EvaluationSpec)
    expected = 4 * options[:sentences] + (options[:completion_cues] > 0 ? 4 : 0)
    evaluation.warmup == 0 && evaluation.horizon == expected || throw(ArgumentError(
        "word sequence evaluation requires zero warmup and its exact complete sequence horizon"))
    return nothing
end
function (::WordSequenceSetup)(; seed=0, rng=nothing, body=nothing, n_nodes=nothing, kwargs...)
    body === nothing || body === :direct || throw(ArgumentError("word sequences require a direct body"))
    env = WordSequenceEnv(; seed, rng, kwargs...)
    return TaskSetup(env, [direct_embodiment(5, 1)])
end
