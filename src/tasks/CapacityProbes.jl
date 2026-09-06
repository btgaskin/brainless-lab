const CAPACITY_PROBE_DEFAULTS = (
    recall_interference=(cue_ticks=8, delay=32, response_ticks=8, distractors=1,
        distractor_ticks=4, cue_mode=:transient, distractor_mode=:random),
    delayed_xor=(cue_ticks=8, gap=32, response_ticks=8, cue_mode=:transient),
    evidence_accumulation=(pulse_count=32, evidence_fraction=0.25, pulse_ticks=1,
        response_ticks=8, input_mode=:visible),
    context_integration=(cue_ticks=8, pulse_count=32, evidence_fraction=0.25,
        pulse_ticks=1, response_ticks=8, context_mode=:transient, congruency=:mixed),
    temporal_order=(cue_ticks=8, gap=8, terminal_ticks=8, response_ticks=8, input_mode=:visible),
    reversal_adaptation=(rounds=96, cue_ticks=8, response_ticks=8, feedback_ticks=8,
        reversal_range=(32, 64), feedback_mode=:visible),
)

function _capacity_task(name, options)
    env = _capacity_probe(Val(name), MersenneTwister(0); options...)
    key = name === :reversal_adaptation ? :adaptation_accuracy : :probe_accuracy
    return TaskSpec(name, CapacityProbeSetup{name}(); env_type=CapacityProbeEnv,
        n_receptors=n_receptors(env), n_effectors=2, default_ticks=default_ticks(env),
        default_window=default_ticks(env), minimum_scored_ticks=1,
        interaction_cycle=FixedRateCycle(1), status=:experimental,
        tags=(:experimental, :capacity_probe), options,
        protocol=(chance_accuracy=0.5, benchmark_profile=(metric=key,
            label="Response accuracy", unit="fraction", direction=:higher)),
        score_key=key, floor=analytic(0.0; note="minimum accuracy; chance is separately 0.5"),
        ceiling=analytic(1.0; note="every scored response is correct"),
        descriptor_keys=(:completed, :tied))
end

function validate_task_evaluation(::CapacityProbeSetup{K}, options, evaluation::EvaluationSpec) where K
    env = _capacity_probe(Val(K), MersenneTwister(0); options...)
    evaluation.warmup == 0 || throw(ArgumentError("capacity probes require warmup=0"))
    evaluation.horizon >= default_ticks(env) || throw(ArgumentError(
        "capacity probe horizon must contain the complete episode or reversal session"))
    return nothing
end

"""
    capacity_probe_presets()

Return named development difficulty cells as `(id, task, task_options, horizon)`.
These are a probe library, not versioned core benchmark membership or evidence.
"""
function capacity_probe_presets()
    cells = NamedTuple[]
    function add(task, suffix; kwargs...)
        defaults = task === :delayed_cue ?
            (cue_ticks=8, delays=(8, 32, 128), response_ticks=8, cue_mode=:transient) :
            getproperty(CAPACITY_PROBE_DEFAULTS, task)
        options = merge(defaults, (; kwargs...))
        env = task === :delayed_cue ? DelayedCueEnv(; options...) :
            _capacity_probe(Val(task), MersenneTwister(0); options...)
        push!(cells, (id=Symbol(task, :__, suffix), task,
            task_options=Dict{Symbol,Any}(pairs(options)), horizon=default_ticks(env)))
    end
    for delay in (0, 8, 32, 128, 256)
        add(:delayed_cue, "delay_$delay"; delays=(delay,))
        if delay >= 32
            for distractors in (1, 3)
                add(:recall_interference, "delay_$(delay)_distractors_$distractors";
                    delay, distractors)
            end
        end
    end
    for gap in (0, 8, 32, 128)
        add(:delayed_xor, "gap_$gap"; gap)
    end
    for pulse_count in (16, 32, 64), evidence_fraction in (0.125, 0.25, 0.5)
        suffix = "pulses_$(pulse_count)_evidence_$(Int(1000evidence_fraction))"
        add(:evidence_accumulation, suffix; pulse_count, evidence_fraction)
        for congruency in (:congruent, :conflicting), context_mode in (:transient, :persistent)
            add(:context_integration, "$(suffix)_$(congruency)_$context_mode";
                pulse_count, evidence_fraction, congruency, context_mode)
        end
    end
    for gap in (0, 8, 32)
        add(:temporal_order, "gap_$gap"; gap)
    end
    add(:reversal_adaptation, "single_reversal")
    return Tuple(cells)
end

"""Observation-only reference controller for probe conformance and negative controls.

Call the returned controller on `sense(env)`, then send its two outputs to
`step!(env, output)`. Construct a fresh controller for each independent trial.
The oracle uses no environment labels, metadata, random seed, or hidden mapping.
"""
mutable struct ProbeController{K}
    policy::Symbol
    first::Int
    last::Int
    second::Int
    context::Int
    counts::MVector{2,Float64}
    mapping::Bool
    feedback_seen::Bool
    cue::Int
end

function probe_control(task::Symbol; policy=:oracle)
    task in (:delayed_cue, keys(CAPACITY_PROBE_DEFAULTS)...) ||
        throw(ArgumentError("no probe controller for :$task"))
    allowed = task === :reversal_adaptation ? (:oracle, :fixed_mapping) :
        task === :context_integration ? (:oracle, :context_blind, :irrelevant, :first, :last) :
        task === :evidence_accumulation ? (:oracle, :first, :last) :
        task === :temporal_order ? (:oracle, :bag, :last) :
        (:oracle, :memoryless, :last)
    policy in (allowed..., :constant_left, :constant_right) ||
        throw(ArgumentError("policy :$policy is not a control for :$task"))
    return ProbeController{task}(policy, 0, 1, 1, 1, MVector(0.0, 0.0), false, false, 1)
end

_probe_choice(x, y) = y > x ? 2 : 1
function _probe_observe!(c::ProbeController, p)
    if p[1] + p[2] > 0
        c.last = _probe_choice(p[1], p[2])
        c.first == 0 && (c.first = c.last)
    end
    return c.first == 0 ? 1 : c.first
end
function _probe_observe!(c::ProbeController{:delayed_xor}, p)
    if p[1] + p[2] > 0
        c.first = _probe_choice(p[1], p[2])
    end
    p[3] + p[4] > 0 && (c.second = _probe_choice(p[3], p[4]))
    c.last = c.second
    return c.first == c.second ? 1 : 2
end
function _probe_observe!(c::ProbeController{:evidence_accumulation}, p)
    if p[1] + p[2] > 0
        c.last = _probe_choice(p[1], p[2])
        c.first == 0 && (c.first = c.last)
        c.counts[1] += p[1] - p[2]
    end
    return c.counts[1] >= 0 ? 1 : 2
end
function _probe_observe!(c::ProbeController{:context_integration}, p)
    p[1] + p[2] > 0 && (c.context = _probe_choice(p[1], p[2]))
    c.counts[1] += p[3] - p[4]
    c.counts[2] += p[5] - p[6]
    stream = c.policy === :context_blind ? 1 : c.policy === :irrelevant ? 3 - c.context : c.context
    if p[2stream + 1] + p[2stream + 2] > 0
        c.last = _probe_choice(p[2stream + 1], p[2stream + 2])
        c.first == 0 && (c.first = c.last)
    end
    return c.counts[stream] >= 0 ? 1 : 2
end
function _probe_observe!(c::ProbeController{:temporal_order}, p)
    c.counts[1] += p[1]
    c.counts[2] += p[2]
    if p[1] + p[2] > 0
        c.last = _probe_choice(p[1], p[2])
        c.first == 0 && (c.first = c.last)
    elseif p[3] > 0
        c.last = 1 # the identical terminal symbol carries no order label
    end
    return c.policy === :bag ? _probe_choice(c.counts...) : max(c.first, 1)
end
function _probe_observe!(c::ProbeController{:reversal_adaptation}, p)
    if p[4] > 0
        if !c.feedback_seen && p[5] + p[6] > 0 && c.policy === :oracle
            chosen = _probe_choice(p[5], p[6])
            correct_choice = p[7] > p[8] ? chosen : 3 - chosen
            c.mapping = correct_choice != c.cue
        end
        c.feedback_seen = true
    else
        c.feedback_seen = false
        p[1] + p[2] > 0 && (c.cue = _probe_choice(p[1], p[2]))
    end
    return c.mapping ? 3 - c.cue : c.cue
end
_probe_memoryless(::ProbeController, p) = _probe_choice(p[1], p[2])
_probe_memoryless(::ProbeController{:delayed_xor}, p) =
    _probe_choice(p[1], p[2]) == _probe_choice(p[3], p[4]) ? 1 : 2

function (c::ProbeController)(percept)
    choice = _probe_observe!(c, percept)
    c.policy === :constant_left && (choice = 1)
    c.policy === :constant_right && (choice = 2)
    c.policy === :memoryless && (choice = _probe_memoryless(c, percept))
    c.policy === :first && (choice = max(c.first, 1))
    c.policy === :last && (choice = c.last)
    return choice == 1 ? SVector(1.0, 0.0) : SVector(0.0, 1.0)
end
