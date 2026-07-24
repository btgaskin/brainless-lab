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
        axes=(SweepAxis(:gain, (0.5,)),),
        max_rollouts=1,
    )
end

function _record_evolution_plan(; iterations=1)
    composition = CompositionSpec(
        :record_structured_ctrnn,
        :compartmental_structured,
        :tracking;
        n_nodes=2,
    )
    training = EvaluationTarget(
        :tracking_development,
        composition,
        EvaluationSpec(
            horizon=1,
            root_seed=404,
            aggregate=:mean,
        ),
    )
    confirmation = EvaluationTarget(
        :tracking_confirmation,
        composition,
        EvaluationSpec(
            horizon=1,
            root_seed=505,
            aggregate=:mean,
        ),
    )
    run = Evolution.RunConfig(
        strategy=:sepcma,
        iterations=iterations,
        search_seed=606,
        initialisation=Evolution.NormalInitialisation(
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
    plan = _record_evolution_plan(iterations=2)
    resolved = resolve(plan, DEFAULT_REGISTRY)
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
            iteration == 1 && error("simulated interruption")
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
    resumed = Evolution.resume(directory)
    @test resumed.directory == directory
    @test length(resumed.result.candidates) == 4
    @test sort(readdir(joinpath(directory, "checkpoints"))) == [
        "generation-00000001",
        "generation-00000002",
    ]
    @test isfile(joinpath(directory, "DONE"))
    @test !isfile(joinpath(directory, "INCOMPLETE"))
    @test !isfile(joinpath(directory, "FAILED"))
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
        (BenchmarkCasePlan(:tracking, (target,)),),
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
    @test Set(metadata["artifacts"]) == Set(keys(metadata["artifact_sha256"]))
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
    @test resolved["operation_settings"]["rollouts"] == 1

    trials = read(joinpath(directory, "data", "trials.csv"), String)
    seeds = read(joinpath(directory, "seeds.csv"), String)
    report = read(joinpath(directory, "report", "index.html"), String)
    summary_json = read(joinpath(directory, "summary", "summary.json"), String)
    @test occursin("raw_score", trials)
    @test count(==('\n'), seeds) == 7
    @test startswith(
        seeds,
        "phase,case,cell,ablation,heldout_target,generation,individual,condition,block,trial,agent,stream,seed",
    )
    @test occursin(",1,topology,", seeds)
    @test occursin(",1,world,", seeds)
    @test occursin("record_smoke", report)
    @test occursin("Deterministic test coordinate", report)
    @test occursin("CSV tables are the authoritative tabular outputs", report)
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
    batch = evaluate(target)
    rows = BrainlessLab._append_seed_rows!(NamedTuple[], batch)
    @test length(rows) == 12
    @test Set(row.agent for row in rows) == Set((1, 2))
    @test Set(row.stream for row in rows) == Set(seed_stream_names(target.evaluation))
    @test trial_row(only(batch.trials)).seed_ledger_agents == 2
    @test ismissing(trial_row(only(batch.trials)).topology_seed)
end

@testset "run_operation executes and writes one record" begin
    registry = operation_registry()
    plan = _record_sweep_plan()
    root = mktempdir()
    run = run_operation(plan; registry, root, id="run-smoke")
    @test run.result isa SweepResult
    @test run.directory == joinpath(root, "run-smoke")
    @test isfile(joinpath(run.directory, "DONE"))
end


@testset "evolution records retain candidate trials and seeds" begin
    plan = _record_evolution_plan()
    run = run_operation(
        plan;
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
    @test occursin("development", seeds)
    @test occursin("heldout", seeds)
end
