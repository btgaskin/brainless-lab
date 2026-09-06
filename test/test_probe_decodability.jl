using BrainlessLab
using Random
using Test

@testset "decoder separation, train-only transforms and permutation control" begin
    rng = MersenneTwister(411)
    y = repeat([1, 2], 160)
    X = hcat(ifelse.(y .== 1, 1.0, -1.0), randn(rng, 320, 3))
    options = (fit_trials=128, validation_trials=64, evaluation_trials=128,
        split_seed=412, permutation_seed=413)
    result = BrainlessLab._probe_decode(X, y, zeros(320); options...)
    @test result.statistics.accuracy == 1
    @test result.statistics.native_accuracy == 0
    @test 0.35 <= result.statistics.permutation_accuracy <= 0.65
    @test result.statistics.lambda == 1e-4
    @test isempty(intersect(result.split.fit, result.split.validation))
    @test isempty(intersect(result.split.fit, result.split.evaluation))
    @test isempty(intersect(result.split.validation, result.split.evaluation))
    changed = copy(X)
    changed[result.split.evaluation, :] .+= 10000
    changed_result = BrainlessLab._probe_decode(changed, y, zeros(320); options...)
    @test changed_result.fitted.centre == result.fitted.centre
    @test changed_result.fitted.scale == result.fitted.scale
    @test changed_result.fitted.weights == result.fitted.weights
    @test changed_result.fitted.lambda == result.fitted.lambda
    @test_throws ArgumentError BrainlessLab._probe_decode(X, ones(Int, 320), zeros(320); options...)
    @test_throws ArgumentError BrainlessLab._probe_decode(X, y, zeros(320); options..., lambdas=(0.0,))
    @test_throws ArgumentError BrainlessLab._probe_decode(X, y, zeros(320))
end

@testset "benchmark task options survive calibration, freezing and plan records" begin
    development = EvaluationSpec(blocks=2, horizon=24, root_seed=771)
    confirmation = EvaluationSpec(blocks=2, horizon=24, root_seed=772)
    options = Dict(:gap => 0)
    protocol = BenchmarkTaskProtocol(:delayed_xor; development, confirmation, task_options=options)
    options[:gap] = 128
    @test protocol.task_options[:gap] == 0
    profile = ModelProfileSpec(:probe_random, :null_random; n_nodes=8,
        parameters=Dict(), mechanism="Software test random controller")
    spec = BenchmarkSpec(:probe_options, v"1.0.0"; title="Software test", n_nodes=8,
        profiles=(profile,), task_protocols=(protocol,),
        entries=(BenchmarkEntrySpec(profile.id, :delayed_xor),), gain_grid=(1.0,),
        baseline_profile=profile.id)
    sweep = only(calibration_plans(spec))
    @test sweep.target.composition.task_options[:gap] == 0
    frozen = freeze_benchmark(spec, Dict((profile.id, :delayed_xor) => 1.0))
    plan = benchmark_plan(frozen)
    @test only(only(plan.cases).conditions).composition.task_options[:gap] == 0
    @test only(benchmark_evolution_targets(frozen, :null_random;
        root_seed=773)).composition.task_options[:gap] == 0
    mktempdir() do root
        path = joinpath(root, "probe.toml")
        write_plan(path, plan)
        loaded = read_plan(path)
        @test only(only(loaded.cases).conditions).composition.task_options[:gap] == 0
        result = run_operation(loaded; root, id="probe-benchmark")
        @test isfile(joinpath(result.directory, "DONE"))
    end
    @test all(isempty(p.task_options) for p in DIRECT_CONTROL_BENCHMARK.task_protocols)
    @test all(isempty(p.task_options) for p in DIRECT_CONTROL_BENCHMARK_V2.task_protocols)
end

@testset "planned capacity bundles retain models and evidence boundaries" begin
    include(joinpath(@__DIR__, "..", "tools", "capacity_probes", "plan_study.jl"))
    bundles = capacity_study_bundles()
    @test length(bundles.calibration.operations) == 28
    @test length(bundles.decoding.operations) == 24
    @test length(only(bundles.native_pilot.operations).cases) == 7
    for (name, experiment) in pairs(bundles)
        @test experiment.evidence_state === :planned
        @test validate(experiment, DEFAULT_REGISTRY) === experiment
        saved = read_experiment(joinpath(@__DIR__, "..", "experiments", "capacity-probes", "v1", string(name)))
        @test BrainlessLab.experiment_document(saved) == BrainlessLab.experiment_document(experiment)
        for (actual, expected) in zip(saved.operations, experiment.operations)
            @test BrainlessLab.plan_document(actual) == BrainlessLab.plan_document(expected)
        end
    end
    profiles = capacity_study_profiles()
    @test all(p -> p.n_nodes == 200, profiles)
    @test all(p -> p.model !== nothing, profiles[3:4])
    for profile in profiles
        conditions = filter(c -> c.topology_key == profile.id, bundles.native_pilot.conditions)
        @test all(c -> c.composition.parameters == profile.parameters, conditions)
        @test all(c -> c.model == profile.model, conditions)
    end
end

@testset "block profile decoding and standard records" begin
    composition = CompositionSpec(:decoder, :null_random, :delayed_cue; n_nodes=8,
        task_options=Dict(:delays => (0,)))
    evaluation = EvaluationSpec(blocks=2, trials_per_block=64, horizon=16,
        construction_scope=:block, root_seed=551)
    target = EvaluationTarget(:decoder, composition, evaluation)
    options = Dict(:probe_decodability => Dict(:fit_trials => 32,
        :validation_trials => 16, :evaluation_trials => 16))
    plan = ProfilePlan(:decoder, target; analyses=(:probe_decodability,), analysis_options=options)
    result = execute(resolve(plan, DEFAULT_REGISTRY))
    output = BrainlessLab.tables(result)
    @test isempty(output.analyses)
    @test length(output.probe_decoders) == 6
    @test length(output.probe_events) == 2 * 64 * 3
    @test all(row -> row.n_blocks == 2, output.block_statistics)
    @test all(row -> row.feature_count == 8 && row.independent_blocks == 1, output.probe_decoders)
    @test all(t -> length(getchannel(t.simulation.recorder, :probe_events)) == 3, result.batch.trials)
    for block in 1:2, trial in 1:64
        rows = filter(r -> r.block == block && r.trial == trial, output.probe_predictions)
        @test length(rows) == 3 && length(unique(r.split for r in rows)) == 1
    end
    mktempdir() do root
        directory = write_record(plan, result; root, id="decoder")
        @test isfile(joinpath(directory, "data", "probe_events.csv"))
        @test isfile(joinpath(directory, "data", "probe_decoders.csv"))
        @test isfile(joinpath(directory, "data", "probe_predictions.csv"))
        @test isfile(joinpath(directory, "data", "block_statistics.csv"))
        @test read_plan(joinpath(directory, "request.toml")) isa ProfilePlan
    end
    trials = Tuple(t for t in result.batch.trials if t.block == 1)
    @test_throws ArgumentError probe_decodability(ProfileBlock(:decoder, 1, trials,
        EvaluationSpec(blocks=2, trials_per_block=64, horizon=16)); options[:probe_decodability]...)
    @test_throws ArgumentError probe_decodability(ProfileBlock(:decoder, 1,
        (trials..., first(trials)), evaluation); options[:probe_decodability]...)
    @test_throws ArgumentError validate(ProfilePlan(:stride, target;
        analyses=(:probe_decodability,), record_every=2), DEFAULT_REGISTRY)
    reversal = EvaluationTarget(:reversal,
        CompositionSpec(:reversal, :null_random, :reversal_adaptation; n_nodes=8),
        EvaluationSpec(trials_per_block=64, horizon=2304, construction_scope=:block))
    @test_throws ArgumentError validate(ProfilePlan(:reversal, reversal;
        analyses=(:probe_decodability,), analysis_options=options), DEFAULT_REGISTRY)
    for invalid in (Dict(:points => (:unknown,)), Dict(:lambdas => (0.0,)))
        invalid_options = Dict(:probe_decodability => merge(options[:probe_decodability], invalid))
        @test_throws ArgumentError validate(ProfilePlan(:invalid_decoder, target;
            analyses=(:probe_decodability,), analysis_options=invalid_options), DEFAULT_REGISTRY)
    end
    other = only(evaluate(EvaluationTarget(:decoder, composition,
        EvaluationSpec(horizon=16, construction_scope=:block, root_seed=9999));
        record=(:probe_events,)).trials)
    mixed = (trials[1:63]..., BrainlessLab.EvaluationTrial(other.condition, 1, 64,
        other.seeds, other.initial_state, other.simulation))
    @test_throws ArgumentError probe_decodability(ProfileBlock(:decoder, 1, mixed, evaluation);
        options[:probe_decodability]...)
end
