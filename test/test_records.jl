using BrainlessLab
import SHA
using TOML
using Test
using .BrainlessLabTestUtils: operation_registry, operation_target

function _record_sweep_plan()
    target = operation_target(
        :tracking,
        :tracking;
        horizon=2,
        root_seed=303,
    )
    return SweepPlan(
        :record_smoke,
        target;
        axes=(BrainlessLab.SweepAxis(:gain, (0.5,)),),
        max_rollouts=1,
    )
end

function _record_evolution_plan(
    ;
    iterations=1,
    task=:tracking,
    node=:compartmental_structured,
    measure=:normalized_score,
)
    horizon = task === :tracking ? 2000 : task === :pong ? 6000 : 200
    composition = CompositionSpec(
        Symbol("record_$(node)_$(task)"),
        node,
        task;
        n_nodes=2,
    )
    training = EvaluationTarget(
        Symbol("$(task)_development"),
        composition,
        EvaluationSpec(
            horizon=horizon,
            root_seed=404,
            aggregate=:mean,
        ),
    )
    confirmation = EvaluationTarget(
        Symbol("$(task)_confirmation"),
        composition,
        EvaluationSpec(
            horizon=horizon,
            root_seed=505,
            aggregate=:mean,
        ),
    )
    run = BrainlessLab.Evolution.RunConfig(
        strategy=:sepcma,
        iterations=iterations,
        search_seed=606,
        measure=measure,
        initialisation=BrainlessLab.Evolution.NormalInitialisation(
            centre=:zero,
            scale=0.1,
        ),
        options=(population=2, reducer=:mean,),
    )
    return EvolutionPlan(
        :record_evolution_smoke,
        (training,);
        run,
        heldout_targets=(confirmation,),
    )
end

@testset "evolution resumes from the last complete generation" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:wall,))
    plan = _record_evolution_plan(
        iterations=4,
        task=:wall,
        node=:falandays,
        measure=:distance_window,
    )
    resolved = resolve(plan, registry)
    uninterrupted = execute(resolved)
    directory = joinpath(mktempdir(), "resume-record")
    mkpath(directory)
    write_plan(joinpath(directory, "request.toml"), plan)
    open(joinpath(directory, "resolved.toml"), "w") do io
        TOML.print(
            io,
            BrainlessLab._resolved_document(plan, resolved);
            sorted=true,
        )
    end
    BrainlessLab._mark_incomplete(directory)
    git = BrainlessLab._record_git()
    digests = BrainlessLab._evolution_operation_digests(
        plan,
        resolved,
        git,
    )
    write_checkpoint = BrainlessLab._evolution_checkpoint_callback(
        directory,
        digests,
        :sepcma,
        plan,
        git,
    )
    @test_throws ErrorException execute(
        resolved;
        checkpoint=(iteration, state, candidates) -> begin
            write_checkpoint(iteration, state, candidates)
            iteration == 2 && error("simulated interruption")
        end,
    )
    @test TOML.parsefile(joinpath(directory, "record.toml"))[
        "completion_marker"
    ] == "INCOMPLETE"
    @test isfile(joinpath(directory, "resolved.toml"))
    @test occursin(
        "development",
        read(joinpath(directory, "seeds.csv"), String),
    )
    @test "measure_value" in split(
        first(split(
            read(joinpath(directory, "data", "candidate_trials.csv"), String),
            '\n',
        )),
        ',',
    )
    @test sort(readdir(joinpath(directory, "checkpoints"))) == [
        "generation-00000001",
        "generation-00000002",
    ]
    partial_models = joinpath(directory, "models")
    mkpath(partial_models)
    write(joinpath(partial_models, "schema.toml"), "format = \"partial\"\n")
    BrainlessLab._write_partial_evolution_state(
        directory,
        filter(candidate -> candidate.iteration <= 3, uninterrupted.candidates),
    )
    @test BrainlessLab.Evolution.latest_checkpoint(directory).completed_iteration == 2
    resumed = BrainlessLab.Evolution.resume(directory; registry)
    @test resumed.directory == directory
    @test isequal(
        BrainlessLab.tables(resumed.result),
        BrainlessLab.tables(uninterrupted),
    )
    @test isequal(
        BrainlessLab.summary(resumed.result),
        BrainlessLab.summary(uninterrupted),
    )
    resumed_tables = BrainlessLab.tables(resumed.result)
    @test only(resumed_tables.heldout_trials).measure_value ==
          only(only(resumed.result.heldout).values)
    @test length(resumed.result.candidates) == 8
    @test sort(readdir(joinpath(directory, "checkpoints"))) == [
        "generation-00000003",
        "generation-00000004",
    ]
    latest = BrainlessLab.Evolution.latest_checkpoint(directory)
    @test Set(keys(latest.runner_document)) == Set(("strategy",))
    @test !occursin(
        "candidates",
        read(joinpath(latest.path, "runner.toml"), String),
    )
    @test isfile(joinpath(directory, "DONE"))
    @test !isfile(joinpath(directory, "INCOMPLETE"))
    @test !isfile(joinpath(directory, "FAILED"))
    @test Set(readdir(partial_models)) ==
          Set(("schema.toml", "models.csv", "coordinates.csv"))
end

function _record_anchor_benchmark_plan()
    target = operation_target(
        :tracking_anchor,
        :tracking;
        blocks=2,
        horizon=2,
        root_seed=606,
    )
    return BenchmarkPlan(
        :record_anchor_benchmark,
        (BrainlessLab.BenchmarkCasePlan(:tracking, (target,)),),
    )
end

@testset "version-one records are complete and portable" begin
    registry = operation_registry()
    plan = _record_sweep_plan()
    result = execute(resolve(plan, registry))
    root = mktempdir()
    directory = write_record(
        plan,
        result;
        registry,
        root,
        id="record-smoke",
    )
    expected = (
        "record.toml",
        "request.toml",
        "resolved.toml",
        "environment/Manifest.toml",
        "seeds.csv",
        "data/trials.csv",
        "data/task_metrics.csv",
        "data/sweep_cells.csv",
        "summary/statistics.csv",
        "summary/contrasts.csv",
        "summary/summary.json",
        "report/index.html",
        "DONE",
    )
    @test all(path -> isfile(joinpath(directory, path)), expected)
    @test isdir(joinpath(directory, "figures"))
    @test !isfile(joinpath(directory, "FAILED"))

    metadata = TOML.parsefile(joinpath(directory, "record.toml"))
    @test metadata["format"] == "brainlesslab-record"
    @test metadata["format_version"] == 1
    @test metadata["kind"] == "sweep"
    @test metadata["git_state"] in ("clean", "dirty", "unknown")
    @test metadata["git_sha"] != "unknown"
    source_manifest = joinpath(@__DIR__, "..", "Manifest.toml")
    recorded_manifest = joinpath(directory, "environment", "Manifest.toml")
    @test read(recorded_manifest) == read(source_manifest)
    expected_manifest_digest = open(source_manifest, "r") do io
        bytes2hex(SHA.sha256(io))
    end
    @test metadata["manifest_sha256"] == expected_manifest_digest
    @test Set(metadata["artifacts"]) == Set(keys(metadata["artifact_sha256"]))
    @test "environment/Manifest.toml" in metadata["artifacts"]
    @test metadata["artifact_sha256"]["environment/Manifest.toml"] ==
          expected_manifest_digest
    @test "data/sweep_cells.csv" in metadata["artifacts"]
    for artifact in metadata["artifacts"]
        digest = open(joinpath(directory, artifact), "r") do io
            bytes2hex(SHA.sha256(io))
        end
        @test digest == metadata["artifact_sha256"][artifact]
    end
    @test read_plan(
        joinpath(directory, "request.toml");
        registry,
    ) isa SweepPlan

    resolved = TOML.parsefile(joinpath(directory, "resolved.toml"))
    @test resolved["operation"] == "sweep"
    @test resolved["targets"][1]["parameters"]["gain"] == 0.5
    @test resolved["targets"][1]["task_options"]["movement_amp"] == 10.0
    @test resolved["targets"][1]["task_options"]["theta0"][
        BrainlessLab._NOTHING_TOML_KEY
    ] === true
    @test resolved["operation_settings"]["rollouts"] == 1

    trials = read(joinpath(directory, "data", "trials.csv"), String)
    task_metrics = read(joinpath(directory, "data", "task_metrics.csv"), String)
    seeds = read(joinpath(directory, "seeds.csv"), String)
    report = read(joinpath(directory, "report", "index.html"), String)
    summary_json = read(joinpath(directory, "summary", "summary.json"), String)
    @test occursin("raw_score", trials)
    @test occursin("normalized_bound", trials)
    @test "window" in split(first(split(trials, '\n')), ',')
    @test "window" in split(first(split(task_metrics, '\n')), ',')
    @test only(result.trial_rows).window == 2
    @test resolved["targets"][1]["effective_window"] == 2
    @test count(==('\n'), seeds) == 3
    @test startswith(
        seeds,
        "phase,case,cell,ablation,heldout_target,generation,individual,condition,block,trial,agent,stream,seed",
    )
    @test occursin(",1,topology,", seeds)
    @test occursin(",1,world,", seeds)
    @test occursin("record_smoke", report)
    @test occursin("Deterministic test coordinate", report)
    @test occursin("CSV tables are the authoritative tabular outputs", report)
    @test occursin("Student-t interval over censored values is not a calibrated interval", report)
    @test startswith(summary_json, "{")

    for path in expected
        content = read(joinpath(directory, path), String)
        @test !occursin("/private/tmp", content)
        @test !occursin("/Users/", content)
    end
    @test_throws ArgumentError write_record(
        plan,
        result;
        registry,
        root,
        id="record-smoke",
    )
    @test_throws ArgumentError write_record(
        plan,
        result;
        registry,
        root,
        id="../escape",
    )

    mismatched = SweepPlan(
        :different_plan,
        plan.target;
        axes=plan.axes,
        max_rollouts=plan.max_rollouts,
    )
    @test_throws ArgumentError write_record(
        mismatched,
        result;
        registry,
        root,
        id="mismatched",
    )
    @test !ispath(joinpath(root, "mismatched"))
end

@testset "record CSV keeps heterogeneous fields" begin
    path = tempname() * ".csv"
    BrainlessLab._write_csv(path, [(phase=:training, value=1), (phase=:heldout, target=:pong, value=2)])
    csv = read(path, String)
    @test first(split(csv, '\n')) == "phase,value,target"
    @test occursin("heldout,2,pong", csv)
end

@testset "anchor-only benchmark records omit a baseline" begin
    registry = operation_registry()
    plan = _record_anchor_benchmark_plan()
    result = execute(resolve(plan, registry))
    directory = write_record(
        plan,
        result;
        registry,
        root=mktempdir(),
        id="anchor-record",
    )

    request = TOML.parsefile(joinpath(directory, "request.toml"))
    resolved = TOML.parsefile(joinpath(directory, "resolved.toml"))
    contrasts = read(joinpath(directory, "summary", "contrasts.csv"), String)
    report = read(joinpath(directory, "report", "index.html"), String)

    @test !haskey(only(request["benchmark"]["cases"]), "baseline")
    @test !haskey(only(resolved["operation_settings"]["cases"]), "baseline")
    @test count(==('\n'), contrasts) == 1
    @test occursin("Cases with a declared baseline", report)
    @test isfile(joinpath(directory, "DONE"))
end

@testset "seed ledger preserves every agent and stream" begin
    target = EvaluationTarget(
        :torus_seed_smoke,
        CompositionSpec(
            :torus_seed_smoke,
            :null_random,
            :torus;
            n_agents=2,
            n_nodes=8,
        ),
        EvaluationSpec(horizon=2, root_seed=919),
    )
    registry = BrainlessLabTestUtils.diagnostic_registry((:torus,))
    batch = BrainlessLab.evaluate(target; registry)
    rows = BrainlessLab._append_seed_rows!(NamedTuple[], batch)
    @test length(rows) == 4
    @test Set(row.agent for row in rows) == Set((1, 2))
    @test Set(row.stream for row in rows) == Set(BrainlessLab.seed_stream_names(target.evaluation))
    @test BrainlessLab.trial_row(only(batch.trials)).seed_ledger_agents == 2
    @test ismissing(BrainlessLab.trial_row(only(batch.trials)).topology_seed)
end

@testset "run_operation executes and writes one record" begin
    registry = operation_registry()
    plan = _record_sweep_plan()
    root = mktempdir()
    run = run_operation(plan; registry, root, id="run-smoke")
    @test run.result isa BrainlessLab.SweepResult
    @test run.directory == joinpath(root, "run-smoke")
    @test isfile(joinpath(run.directory, "DONE"))

    existing_inventory = sort(readdir(run.directory))
    @test_throws ArgumentError run_operation(
        plan;
        registry,
        root,
        id="run-smoke",
    )
    @test sort(readdir(run.directory)) == existing_inventory

    invalid = SweepPlan(
        :invalid_before_execution,
        plan.target;
        axes=(BrainlessLab.SweepAxis(:unknown, (0.5,)),),
        max_rollouts=1,
    )
    @test_throws KeyError run_operation(
        invalid;
        registry,
        root,
        id="failed-resolution",
    )
    @test isfile(joinpath(root, "failed-resolution", "request.toml"))
    @test isfile(joinpath(root, "failed-resolution", "FAILED"))
end


@testset "evolution records retain candidate trials and seeds" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:wall,))
    plan = _record_evolution_plan(task=:wall)
    run = run_operation(
        plan;
        registry,
        root=mktempdir(),
        id="evolution-record",
    )
    result = run.result
    directory = run.directory
    @test isfile(joinpath(directory, "data", "candidate_trials.csv"))
    @test count(==('\n'), read(joinpath(directory, "data", "candidate_trials.csv"), String)) == 3
    @test isfile(joinpath(directory, "models", "schema.toml"))
    @test isfile(joinpath(
        directory,
        "checkpoints",
        "generation-00000001",
        "DONE",
    ))
    @test isempty(filter(name -> name in ("INCOMPLETE", "FAILED"), readdir(directory)))
    @test only(result.model_references).model_id == "selected"
    seeds = read(joinpath(directory, "seeds.csv"), String)
    report = read(joinpath(directory, "report", "index.html"), String)
    @test occursin("development", seeds)
    @test occursin("heldout", seeds)
    heldout_header = first(split(
        read(joinpath(directory, "data", "heldout_trials.csv"), String),
        '\n',
    ))
    @test "measure_value" in split(heldout_header, ',')
    @test occursin("Cells are development results, not confirmed optima", report)
end

@testset "operation report methods use plan vocabulary" begin
    ablate = BrainlessLab._operation_method(:ablate)
    evolve = BrainlessLab._operation_method(:evolve)
    @test occursin("implicit baseline", ablate)
    @test occursin("development results, not confirmed optima", evolve)
    @test BrainlessLab._operation_method(:ablation) ==
          "Executes the declared BrainlessLab operation."
    @test BrainlessLab._operation_method(:evolution) ==
          "Executes the declared BrainlessLab operation."
end
