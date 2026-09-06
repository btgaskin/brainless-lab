using BrainlessLab
using Random
using Statistics
using Test

function capacity_episode(task, seed; policy=:oracle, kwargs...)
    env = BrainlessLab.setup_task(resolve_task(task); seed, kwargs...).environment
    controller = probe_control(task; policy)
    while !BrainlessLab.terminated(env)
        step!(env, controller(sense(env)))
    end
    return env
end

@testset "capacity task interface works with every study substrate" begin
    for node in (:falandays, :sorn, :compartmental_dense, :compartmental_structured)
        source = node in (:compartmental_dense, :compartmental_structured) ?
            first(first(read_plan(joinpath(@__DIR__, "..", "benchmarks", "ctrnn-readiness",
                "development", "$(node)-selection-plan.toml")).cases).conditions) : nothing
        model = source === nothing ? nothing : source.model
        parameters = source === nothing ? Dict{Symbol,Any}() : source.composition.parameters
        for task in keys(BrainlessLab.CAPACITY_PROBE_DEFAULTS)
            target = EvaluationTarget(:conformance,
                CompositionSpec(:conformance, node, task; n_nodes=16, parameters),
                EvaluationSpec(horizon=resolve_task(task).default_ticks, root_seed=1610900); model)
            sim = only(evaluate(target; record=(:probe_events,)).trials).simulation
            @test sim.metrics.completed
            @test task_outcome(sim).key in (:probe_accuracy, :adaptation_accuracy)
            @test task_outcome(sim).raw == task_outcome(sim).normalized
            @test all(e -> length(only(e.features)) == 16, getchannel(sim.recorder, :probe_events))
        end
    end
end

@testset "capacity library and observation-only conformance" begin
    presets = capacity_probe_presets()
    @test length(presets) == length(unique(c.id for c in presets)) == 64
    for cell in presets, seed in 1:4
        env = capacity_episode(cell.task, seed; cell.task_options...)
        @test default_ticks(env) == cell.horizon
        @test metrics(env).score == (cell.task === :reversal_adaptation ? 15 / 16 : 1.0)
    end
    pairs = Set{Tuple{Int,Int}}()
    for seed in 1:64
        env = capacity_episode(:delayed_xor, seed)
        push!(pairs, (env.metadata.first_cue, env.metadata.second_cue))
        @test metrics(env).score == 1
        reversal = capacity_episode(:reversal_adaptation, seed)
        @test metrics(reversal).adaptation_accuracy == 15 / 16
        @test metrics(reversal).recovery_rounds == 1
        @test sum(reversal.decisions .!= reversal.labels) in (1, 2)
        irrelevant = capacity_episode(:context_integration, seed;
            congruency=:conflicting, policy=:irrelevant)
        @test metrics(irrelevant).score == 0
    end
    @test pairs == Set(((1, 1), (1, 2), (2, 1), (2, 2)))
end

@testset "probe timing, reset, output isolation and hidden channels" begin
    for task in keys(BrainlessLab.CAPACITY_PROBE_DEFAULTS)
        env = BrainlessLab.setup_task(resolve_task(task); seed=71).environment
        original = copy(env.stimuli)
        labels = copy(env.labels)
        @test ismissing(metrics(env).score)
        @test_throws DimensionMismatch step!(env, (0.0,))
        @test_throws ArgumentError step!(env, (NaN, 0.0))
        @test_throws ArgumentError step!(env, (1.1, 0.0))
        response = first(env.responses)
        for _ in 1:first(response) - 1
            step!(env, (0.0, 1.0))
        end
        @test all(iszero, env.evidence)
        while !BrainlessLab.terminated(env)
            step!(env, (0.0, 0.0))
        end
        @test all(env.ties) && all(==(1), env.decisions)
        @test Tuple(sense(env)) == ntuple(_ -> 0.0, n_receptors(env))
        reset!(env)
        @test env.tick == 0 && env.round == 1 && all(iszero, env.decisions)
        @test env.labels == labels && env.stimuli == original
        composition = CompositionSpec(:short, :null_random, task; n_nodes=8)
        @test_throws ArgumentError evaluate(EvaluationTarget(:short, composition,
            EvaluationSpec(horizon=default_ticks(env) - 1)))
    end
    @test_throws ArgumentError capacity_episode(:recall_interference, 1; delay=8)
    @test_throws ArgumentError capacity_episode(:recall_interference, 1; distractors=20)
    @test_throws ArgumentError capacity_episode(:delayed_xor, 1; gap=-1)
    @test_throws ArgumentError capacity_episode(:evidence_accumulation, 1; evidence_fraction=1)
    @test_throws ArgumentError capacity_episode(:evidence_accumulation, 1; pulse_count=17)
    @test_throws ArgumentError capacity_episode(:temporal_order, 1; terminal_ticks=0)
    @test_throws ArgumentError capacity_episode(:reversal_adaptation, 1; reversal_range=(90, 95))
    @test_throws ArgumentError probe_control(:pong)
    @test_throws ArgumentError probe_control(:delayed_xor; policy=:irrelevant)
    for seed in 1:32
        visible = capacity_episode(:recall_interference, seed)
        hidden = capacity_episode(:recall_interference, seed; cue_mode=:hidden)
        @test visible.labels == hidden.labels
        @test visible.metadata.distractor_labels == hidden.metadata.distractor_labels
        @test metrics(capacity_episode(:recall_interference, seed;
            cue_mode=:persistent, policy=:memoryless)).score == 1
        @test metrics(capacity_episode(:delayed_xor, seed; cue_mode=:persistent)).score == 1
        @test metrics(capacity_episode(:delayed_xor, seed;
            cue_mode=:persistent, policy=:memoryless)).score == 1
        for distractor_mode in (:matched, :opposite, :absent)
            @test metrics(capacity_episode(:recall_interference, seed; distractor_mode)).score == 1
        end
        reversal = capacity_episode(:reversal_adaptation, seed; feedback_mode=:hidden)
        fixed = capacity_episode(:reversal_adaptation, seed; policy=:fixed_mapping)
        @test reversal.labels == fixed.labels
        @test reversal.decisions == fixed.decisions
        context_hidden = capacity_episode(:context_integration, seed;
            context_mode=:hidden, congruency=:conflicting)
        context_blind = capacity_episode(:context_integration, seed;
            policy=:context_blind, congruency=:conflicting)
        @test context_hidden.labels == context_blind.labels
        @test context_hidden.decisions == context_blind.decisions
    end
    for mode in (:visible, :hidden)
        env = BrainlessLab.setup_task(resolve_task(:reversal_adaptation);
            seed=71, feedback_mode=mode).environment
        for _ in 1:16
            @test all(iszero, sense(env)[5:8])
            step!(env, (0.0, 1.0))
        end
        feedback = sense(env)
        @test feedback[4] == 1
        if mode === :visible
            @test Tuple(feedback[5:8]) == (0.0, 1.0,
                Float64(env.labels[1] == 2), Float64(env.labels[1] != 2))
        else
            @test all(iszero, feedback[5:8])
        end
    end
end

@testset "counterbalancing and shortcut controls" begin
    bags, final_frames = Dict{Int,Any}(), Dict{Int,Any}()
    counts = zeros(Int, 2, 2)
    for seed in 1:1024
        env = capacity_episode(:evidence_accumulation, seed)
        final = env.stimuli[first(only(env.responses)) - 1]
        pulse = final[1] > final[2] ? 1 : 2
        counts[only(env.labels), pulse] += 1
        order = capacity_episode(:temporal_order, seed; policy=:bag)
        bags[only(order.labels)] = sum(order.stimuli)
        final_frames[only(order.labels)] = order.stimuli[end - 8:end]
        @test only(order.decisions) == 1
    end
    @test all(x -> 210 <= x <= 300, counts)
    @test bags[1] == bags[2]
    @test final_frames[1] == final_frames[2]
    for task in (:delayed_cue, :recall_interference, :delayed_xor,
        :evidence_accumulation, :context_integration, :temporal_order)
        scores = [metrics(capacity_episode(task, seed; policy=:constant_left)).score for seed in 1:512]
        @test 0.42 <= mean(scores) <= 0.58
    end
end

@testset "sparse probe recordings preserve native trajectories and own features" begin
    composition = CompositionSpec(:events, :null_random, :delayed_xor; n_nodes=8)
    target = EvaluationTarget(:events, composition, EvaluationSpec(horizon=56, root_seed=131))
    recorded = only(evaluate(target; record=(:spikes, :probe_events)).trials).simulation
    plain = only(evaluate(target; record=(:spikes,)).trials).simulation
    @test task_outcome(recorded) == task_outcome(plain)
    @test getchannel(recorded.recorder, :spikes) == getchannel(plain.recorder, :spikes)
    events = getchannel(recorded.recorder, :probe_events)
    @test [e.point for e in events] == [:cue_end, :delay_end, :response]
    spikes = getchannel(recorded.recorder, :spikes)
    @test only(events[1].features) == only(spikes[8])
    @test only(events[2].features) == only(spikes[48])
    @test only(events[3].features) ≈ mean(only.(spikes[49:56]))
    @test events[1].features.ids == spikes[1].ids
    before = copy(only(events[1].features))
    only(spikes[8])[1] = 999
    @test only(events[1].features) == before
    @test_throws ArgumentError evaluate(target; record=(:probe_events,), record_every=2)
end
