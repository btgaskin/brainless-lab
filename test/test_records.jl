using BrainlessLab
import SHA
using TOML
using Test

function _record_sweep_plan()
    base = default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    composition = CompositionSpec(
        :record_tracking,
        base.node,
        base.task;
        n_nodes=8,
        parameters=base.parameters,
    )
    target = EvaluationTarget(
        :tracking,
        composition,
        EvaluationSpec(
            blocks=1,
            trials_per_block=1,
            horizon=2,
            root_seed=303,
            aggregate=:mean,
        ),
    )
    return SweepPlan(
        :record_smoke,
        target;
        axes=(SweepAxis(:leak, (0.25,)),),
        max_rollouts=1,
    )
end

function _record_evolution_plan()
    base = default_composition(DEFAULT_REGISTRY, :falandays, :tracking)
    composition = CompositionSpec(
        :record_evolution_tracking,
        base.node,
        base.task;
        n_nodes=8,
        parameters=base.parameters,
    )
    training = EvaluationTarget(
        :tracking_development,
        composition,
        EvaluationSpec(horizon=2, root_seed=404, aggregate=:mean),
    )
    confirmation = EvaluationTarget(
        :tracking_confirmation,
        composition,
        EvaluationSpec(horizon=2, root_seed=505, aggregate=:mean),
    )
    return EvolutionPlan(
        :record_evolution_smoke,
        training;
        heldout_targets=(confirmation,),
        generations=1,
        popsize=2,
        sigma0=0.1,
    )
end

@testset "version-one records are complete and portable" begin
    plan = _record_sweep_plan()
    result = execute(resolve(plan, DEFAULT_REGISTRY))
    root = mktempdir()
    directory = write_record(plan, result; root=root, id="record-smoke")
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
    @test read_plan(joinpath(directory, "request.toml")) isa SweepPlan

    resolved = TOML.parsefile(joinpath(directory, "resolved.toml"))
    @test resolved["operation"] == "sweep"
    @test resolved["targets"][1]["parameters"]["lrate_targ"] == 0.01
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
    @test occursin("Falandays equations", report)
    @test occursin("CSV tables are the authoritative tabular outputs", report)
    @test startswith(summary_json, "{")

    for path in expected
        content = read(joinpath(directory, path), String)
        @test !occursin("/private/tmp", content)
        @test !occursin("/Users/", content)
    end
    @test_throws ArgumentError write_record(plan, result; root=root, id="record-smoke")
    @test_throws ArgumentError write_record(plan, result; root=root, id="../escape")

    mismatched = SweepPlan(
        :different_plan,
        plan.target;
        axes=plan.axes,
        max_rollouts=plan.max_rollouts,
    )
    @test_throws ArgumentError write_record(
        mismatched,
        result;
        root=root,
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
    plan = _record_sweep_plan()
    root = mktempdir()
    run = run_operation(plan; root=root, id="run-smoke")
    @test run.result isa SweepResult
    @test run.directory == joinpath(root, "run-smoke")
    @test isfile(joinpath(run.directory, "DONE"))
end


@testset "evolution records retain candidate trials and seeds" begin
    plan = _record_evolution_plan()
    result = execute(resolve(plan, DEFAULT_REGISTRY))
    directory = write_record(plan, result; root=mktempdir(), id="evolution-record")
    @test isfile(joinpath(directory, "data", "candidate_trials.csv"))
    @test count(==('\n'), read(joinpath(directory, "data", "candidate_trials.csv"), String)) == 3
    seeds = read(joinpath(directory, "seeds.csv"), String)
    @test occursin("development", seeds)
    @test occursin("training", seeds)
    @test occursin("heldout", seeds)
end
