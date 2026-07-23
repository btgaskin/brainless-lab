"""
    EvaluationProtocol

Protocol-level sampling and reset rules for repeated evaluation. This is kept
separate from [`InteractionCycle`](@ref): the interaction cycle governs clocks
inside one world step, while this contract governs trials around a complete
task rollout.
"""
struct EvaluationProtocol
    trials::Int
    horizon::Int
    warmup::Int
    reset::Symbol
    design_scope::Symbol
    aggregation::Symbol

    function EvaluationProtocol(;
        trials::Integer,
        horizon::Integer,
        warmup::Integer=0,
        reset::Symbol=:full,
        design_scope::Symbol=:fixed,
        aggregation::Symbol=:mean,
    )
        trials_ = Int(trials)
        horizon_ = Int(horizon)
        warmup_ = Int(warmup)
        trials_ >= 1 || throw(ArgumentError("evaluation trials must be positive"))
        horizon_ >= 1 || throw(ArgumentError("evaluation horizon must be positive"))
        0 <= warmup_ < horizon_ || throw(ArgumentError(
            "evaluation warmup must lie in 0:(horizon - 1)",
        ))
        reset in (:full, :dynamic, :none) || throw(ArgumentError(
            "evaluation reset must be :full, :dynamic, or :none",
        ))
        design_scope in (:fixed, :per_trial) || throw(ArgumentError(
            "evaluation design_scope must be :fixed or :per_trial",
        ))
        aggregation in (:mean, :median, :raw) || throw(ArgumentError(
            "evaluation aggregation must be :mean, :median, or :raw",
        ))
        return new(trials_, horizon_, warmup_, reset, design_scope, aggregation)
    end
end

const PLANK_CARTPOLE_EVALUATION = EvaluationProtocol(
    trials=PLANK_CARTPOLE_EVAL_EPISODES,
    horizon=PLANK_CARTPOLE_MISSION_STEPS,
    reset=:full,
    design_scope=:fixed,
    aggregation=:mean,
)

"""Raw, auditable result of one repeated evaluation protocol."""
struct EvaluationResult{S,P,M}
    task::Symbol
    node::Symbol
    build_seed::Int
    trial_seed::Int
    initial_conditions::Vector{S}
    trials::Vector{NamedTuple}
    protocol::P
    summary::M
end

function _evaluation_mean(values)
    isempty(values) && return NaN
    return sum(Float64(value) for value in values) / length(values)
end

function _evaluation_median(values)
    isempty(values) && return NaN
    ordered = sort!(Float64.(collect(values)))
    middle = length(ordered) ÷ 2
    return isodd(length(ordered)) ? ordered[middle + 1] :
        (ordered[middle] + ordered[middle + 1]) / 2
end

"""
    plank_cartpole_initial_conditions(seed, trials; ranges=...)

Generate and return the complete held test set before evaluation. The explicit
states are retained in `EvaluationResult`, so a seed is not treated as a
portable replay guarantee.
"""
function plank_cartpole_initial_conditions(
    seed::Integer,
    trials::Integer;
    ranges=((-1.2, 1.2), (-0.05, 0.05), (-0.10475, 0.10475), (-0.05, 0.05)),
)
    count = Int(trials)
    count >= 1 || throw(ArgumentError("CartPole evaluation trials must be positive"))
    ranges_ = Tuple((Float64(range[1]), Float64(range[2])) for range in ranges)
    length(ranges_) == 4 || throw(DimensionMismatch(
        "CartPole initial-condition ranges must contain four ranges",
    ))
    all(range -> range[1] <= range[2], ranges_) || throw(ArgumentError(
        "CartPole initial-condition ranges must be ordered",
    ))
    rng = MersenneTwister(Int(seed))
    return NTuple{4,Float64}[
        ntuple(index -> _cartpole_sample(rng, ranges_[index]), 4)
        for _ in 1:count
    ]
end

function _require_plank_cartpole_task(task)
    spec = _task_spec(task)
    spec.setup isa PlankCartPoleSetup || throw(ArgumentError(
        "evaluate_plank_cartpole requires one of the four :cartpole_plank_* task profiles",
    ))
    return spec
end

function _reset_plank_trial!(ensemble::Ensemble, initial_condition, protocol::EvaluationProtocol)
    environment = ensemble.environment
    environment isa PlankCartPoleEnv || throw(ArgumentError(
        "Plank CartPole evaluation received environment $(typeof(environment))",
    ))
    if protocol.reset === :full
        foreach_group(ensemble) do group
            for agent in group_agents(group)
                reset!(agent)
            end
        end
    elseif protocol.reset === :dynamic
        foreach_group(ensemble) do group
            for agent in group_agents(group)
                reset!(agent.body)
            end
        end
    end
    set_plank_cartpole_state!(environment, initial_condition)
    ensemble.t = 0
    return ensemble
end

function _plank_trial!(ensemble::Ensemble, protocol::EvaluationProtocol)
    environment = ensemble.environment
    while !environment.done && environment.step_count < protocol.horizon
        step!(ensemble)
    end
    outcome = metrics(environment, protocol.horizon)
    return (
        fitness=Float64(outcome.fitness),
        steps=Int(outcome.steps_balanced),
        noop_fraction=Float64(outcome.noop_fraction),
        achieved=Bool(outcome.achieved),
    )
end

"""
    evaluate_plank_cartpole(task; node=:falandays, protocol=PLANK_CARTPOLE_EVALUATION,
                            build_seed=0, trial_seed=10_000, kwargs...)

Evaluate one fixed node construction across an explicit held set of CartPole
initial conditions. Each trial fully resets reservoir dynamics, plastic state,
and embodiment state while retaining the same constructed topology. Raw trials
and initial conditions are returned; the four Plank levels are never
collapsed into a cross-task aggregate.
"""
function evaluate_plank_cartpole(
    task;
    node=:falandays,
    protocol::EvaluationProtocol=PLANK_CARTPOLE_EVALUATION,
    build_seed::Integer=0,
    trial_seed::Integer=10_000,
    initial_conditions=nothing,
    kwargs...,
)
    spec = _require_plank_cartpole_task(task)
    protocol.design_scope === :fixed || throw(ArgumentError(
        "the current Plank CartPole evaluator requires design_scope=:fixed",
    ))
    protocol.warmup == 0 || throw(ArgumentError(
        "the Plank CartPole protocol has no unscored warmup; use warmup=0",
    ))
    protocol.horizon <= PLANK_CARTPOLE_MISSION_STEPS || throw(ArgumentError(
        "Plank CartPole horizon cannot exceed $(PLANK_CARTPOLE_MISSION_STEPS)",
    ))

    states = initial_conditions === nothing ?
        plank_cartpole_initial_conditions(trial_seed, protocol.trials) :
        NTuple{4,Float64}[Tuple(Float64(value) for value in state) for state in initial_conditions]
    length(states) == protocol.trials || throw(DimensionMismatch(
        "evaluation protocol declares $(protocol.trials) trials but received $(length(states)) initial conditions",
    ))

    node_ = Symbol(node)
    setup = _build_ensemble(
        spec,
        node_;
        ticks=protocol.horizon,
        seed=Int(build_seed),
        record=(),
        kwargs...,
    )
    ensemble = setup.ensemble
    ensemble.recorder = nothing
    trials = Vector{NamedTuple}(undef, protocol.trials)
    for index in eachindex(states)
        _reset_plank_trial!(ensemble, states[index], protocol)
        trials[index] = _plank_trial!(ensemble, protocol)
    end

    fitness = Float64[trial.fitness for trial in trials]
    achieved = count(trial -> trial.achieved, trials)
    aggregate = protocol.aggregation === :mean ? _evaluation_mean(fitness) :
        protocol.aggregation === :median ? _evaluation_median(fitness) : nothing
    summary = (
        n=length(trials),
        mean_fitness=_evaluation_mean(fitness),
        median_fitness=_evaluation_median(fitness),
        minimum_fitness=minimum(fitness),
        maximum_fitness=maximum(fitness),
        target_fitness=spec.setup.level.target_fitness,
        achieved=achieved,
        achieved_fraction=achieved / length(trials),
        aggregation=protocol.aggregation,
        aggregate=aggregate,
    )
    return EvaluationResult(
        spec.name,
        node_,
        Int(build_seed),
        Int(trial_seed),
        states,
        trials,
        protocol,
        summary,
    )
end
