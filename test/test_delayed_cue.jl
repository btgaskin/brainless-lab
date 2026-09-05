using BrainlessLab
using BrainlessLab: DelayedCueEnv
using Random
using Test

function cue_control_episode(seed; mode=:transient, memory=true)
    env = DelayedCueEnv(; rng=MersenneTwister(seed), cue_mode=mode)
    remembered = 1
    while !BrainlessLab.terminated(env)
        percept = sense(env)
        current = percept[2] > percept[1] ? 2 : 1
        if memory && percept[1] + percept[2] > 0
            remembered = current
        end
        choice = memory ? remembered : current
        step!(env, choice == 1 ? (1.0, 0.0) : (0.0, 1.0))
    end
    return metrics(env)
end

@testset "delayed-cue phases, action isolation, and replay" begin
    env = DelayedCueEnv(; rng=MersenneTwister(91), cue_ticks=2, delays=(3,), response_ticks=2)
    cue = env.cue
    @test n_receptors(env) == 3 && n_effectors(env) == 2
    @test sense(env)[cue] == 1.0 && sense(env)[3] == 0.0
    @test ismissing(metrics(env).recall_accuracy)
    for _ in 1:2
        step!(env, (0.0, 1.0))
    end
    for _ in 1:3
        @test Tuple(sense(env)) == (0.0, 0.0, 0.0)
        step!(env, (0.0, 1.0))
    end
    @test env.left_evidence == env.right_evidence == 0
    @test Tuple(sense(env)) == (0.0, 0.0, 1.0)
    step!(env, (1.0, 0.0))
    @test !env.done
    step!(env, (1.0, 0.0))
    @test env.done && env.decision == 1 && !env.tied
    @test metrics(env).recall_accuracy == Float64(cue == 1)
    @test Tuple(sense(env)) == (0.0, 0.0, 0.0)
    step!(env, (0.0, 1.0))
    @test env.decision == 1 && env.tick == 7
    reset!(env)
    @test env.cue == cue && env.delay == 3 && env.tick == 0
    for _ in 1:7
        step!(env, (0.0, 0.0))
    end
    @test env.tied && env.decision == 1
    @test_throws ArgumentError DelayedCueEnv(; delays=())
    @test_throws ArgumentError DelayedCueEnv(; delays=(1, 1))
    @test_throws ArgumentError DelayedCueEnv(; cue_mode=:unknown)
    reset!(env)
    @test_throws DimensionMismatch step!(env, (0.0,))
    @test_throws ArgumentError step!(env, (NaN, 0.0))
    @test_throws ArgumentError step!(env, (-1.0, 0.0))
end

@testset "recall needs information retained by the controller" begin
    controls = [cue_control_episode(seed) for seed in 1:1024]
    reactive = [cue_control_episode(seed; memory=false) for seed in 1:1024]
    hidden = [cue_control_episode(seed; mode=:hidden) for seed in 1:1024]
    visible = [cue_control_episode(seed; mode=:persistent, memory=false) for seed in 1:1024]
    @test all(row -> row.recall_accuracy == 1.0, controls)
    @test all(row -> row.recall_accuracy == 1.0, visible)
    @test all(i -> (controls[i].cue, controls[i].delay) ==
        (hidden[i].cue, hidden[i].delay), eachindex(controls))
    @test 0.45 <= sum(row.recall_accuracy for row in reactive) / 1024 <= 0.55
    @test getproperty.(hidden, :recall_accuracy) == getproperty.(reactive, :recall_accuracy)
    for delay in BrainlessLab.DELAYED_CUE_DELAYS
        rows = filter(row -> row.delay == delay, reactive)
        @test 0.40 <= sum(row.recall_accuracy for row in rows) / length(rows) <= 0.60
    end
end

@testset "delayed-cue typed evaluation and task outcome" begin
    composition = CompositionSpec(:cue, :null_random, :delayed_cue; n_nodes=10)
    target = EvaluationTarget(:cue, composition, EvaluationSpec(horizon=144, root_seed=917))
    batch = evaluate(target)
    trial = only(batch.trials)
    outcome = task_outcome(trial.simulation)
    @test outcome.key === :recall_accuracy
    @test outcome.raw in (0.0, 1.0)
    @test outcome.normalized == outcome.raw
    @test trial.initial_state.delay in BrainlessLab.DELAYED_CUE_DELAYS
    @test trial.simulation.metrics.completed
    @test trial.simulation.config.executed_scored_ticks == trial.initial_state.delay + 16
    @test BrainlessLab.trial_row(trial).profile_metric === :recall_accuracy
    @test_throws ArgumentError evaluate(EvaluationTarget(:short, composition,
        EvaluationSpec(horizon=143, root_seed=917)))
    @test_throws ArgumentError validate(ProfilePlan(:warm, EvaluationTarget(:warm, composition,
        EvaluationSpec(horizon=145, warmup=1, root_seed=917)); analyses=()), DEFAULT_REGISTRY)
    @test_throws ArgumentError validate(ProfilePlan(:long_delay, EvaluationTarget(:long_delay,
        CompositionSpec(:long_delay, :null_random, :delayed_cue; n_nodes=10,
            task_options=Dict(:delays => (256,))), EvaluationSpec(horizon=144)); analyses=()), DEFAULT_REGISTRY)
end
