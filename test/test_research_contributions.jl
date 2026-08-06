using BrainlessLab
import SHA
using TOML
using Test

const _CONTRIBUTION_SHA = repeat("a", 40)

function _contribution_experiment(; horizon=2_000)
    target = EvaluationTarget(
        :tracking,
        CompositionSpec(
            :contribution_tracking,
            :null_random,
            :tracking;
            n_nodes=8,
            interaction_cycle=BrainlessLab.FixedRateCycle(1),
        ),
        EvaluationSpec(blocks=1, trials_per_block=1, horizon=horizon, root_seed=919),
    )
    plan = ProfilePlan(:profile_tracking, target)
    return ExperimentSpec(
        :contribution_fixture,
        v"1.0.0";
        title="Contribution fixture",
        question="Can a contribution preserve and replay one declared operation?",
        conditions=(target,),
        operations=(plan,),
        evidence_state=:exploratory,
        limitations=("Test scale only.",),
    )
end

function _test_files(root)
    paths = String[]
    for (directory, _, files) in walkdir(root), file in files
        push!(paths, replace(relpath(joinpath(directory, file), root), '\\' => '/'))
    end
    return sort!(paths)
end

function _test_sha(path)
    return open(path, "r") do io
        bytes2hex(SHA.sha256(io))
    end
end

function _patch_record_git!(run_directory; state="clean", sha=_CONTRIBUTION_SHA)
    operations = joinpath(run_directory, "operations")
    for name in readdir(operations)
        path = joinpath(operations, name, "record.toml")
        document = TOML.parsefile(path)
        document["git_state"] = state
        document["git_sha"] = sha
        open(path, "w") do io
            TOML.print(io, document; sorted=true)
        end
    end
    return run_directory
end

function _refresh_record_checksum!(run_directory, relative)
    record_directory = only(
        joinpath(run_directory, "operations", name)
        for name in readdir(joinpath(run_directory, "operations"))
    )
    manifest_path = joinpath(record_directory, "record.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["artifact_sha256"][relative] = _test_sha(joinpath(record_directory, relative))
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    return run_directory
end

function _remove_record_artifact!(run_directory, relative)
    record_directory = only(
        joinpath(run_directory, "operations", name)
        for name in readdir(joinpath(run_directory, "operations"))
    )
    rm(joinpath(record_directory, relative))
    manifest_path = joinpath(record_directory, "record.toml")
    manifest = TOML.parsefile(manifest_path)
    filter!(artifact -> artifact != relative, manifest["artifacts"])
    delete!(manifest["artifact_sha256"], relative)
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    return run_directory
end

function _refresh_contribution_inventory!(directory)
    path = joinpath(directory, "contribution.toml")
    document = TOML.parsefile(path)
    for role in ("submission", "replay")
        root = joinpath(directory, document[role])
        files = _test_files(root)
        document[role * "_artifacts"] = files
        document[role * "_sha256"] = Dict(
            relative => _test_sha(joinpath(root, relative)) for relative in files
        )
    end
    open(path, "w") do io
        TOML.print(io, document; sorted=true)
    end
    return directory
end

function _make_contribution()
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    research_root = mktempdir()
    directory = joinpath(
        research_root,
        "contributions",
        "contribution_fixture",
        "v1.0.0",
        "first-run",
    )
    mkpath(directory)
    experiment = _contribution_experiment()
    submission = run_experiment(
        experiment;
        registry,
        root=directory,
        id="submission",
    )
    replay = run_experiment(
        experiment;
        registry,
        root=directory,
        id="replay",
    )
    _patch_record_git!(submission.directory)
    _patch_record_git!(replay.directory)
    document = Dict{String,Any}(
        "format" => BrainlessLab.CONTRIBUTION_FORMAT,
        "format_version" => BrainlessLab.CONTRIBUTION_FORMAT_VERSION,
        "id" => "first-run",
        "experiment_id" => "contribution_fixture",
        "experiment_version" => "1.0.0",
        "experiment_path" => "experiments/examples/contribution-fixture",
        "contributor" => "Example Contributor",
        "reviewer" => "Example Maintainer",
        "source_sha" => _CONTRIBUTION_SHA,
        "submission" => "submission",
        "replay" => "replay",
        "review_url" => "https://example.invalid/review/1",
        "accepted_utc" => "2026-07-24T00:00:00Z",
        "reproduction_state" => "accepted",
        "submission_artifacts" => String[],
        "submission_sha256" => Dict{String,String}(),
        "replay_artifacts" => String[],
        "replay_sha256" => Dict{String,String}(),
    )
    open(joinpath(directory, "contribution.toml"), "w") do io
        TOML.print(io, document; sorted=true)
    end
    _refresh_contribution_inventory!(directory)
    BrainlessLab.compare_contribution(directory; write=true)
    return (root=research_root, directory=directory)
end

function _copy_contribution(source)
    target_root = mktempdir()
    target = joinpath(
        target_root,
        "contributions",
        "contribution_fixture",
        "v1.0.0",
        "first-run",
    )
    mkpath(dirname(target))
    cp(source, target)
    return target
end

@testset "repository protocol must match complete submitted plans" begin
    fixture = _make_contribution()
    repository = mktempdir()
    run(Cmd(`git init -q`; dir=repository))
    run(Cmd(`git config user.email tests@example.invalid`; dir=repository))
    run(Cmd(`git config user.name "BrainlessLab tests"`; dir=repository))
    experiment_path = joinpath(repository, "experiments", "examples", "contribution-fixture")
    write_experiment(experiment_path, _contribution_experiment(; horizon=2_001))
    run(Cmd(`git add experiments`; dir=repository))
    run(Cmd(`git commit -qm protocol`; dir=repository))
    source_sha = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))

    directory = joinpath(
        repository,
        "research",
        "contributions",
        "contribution_fixture",
        "v1.0.0",
        "first-run",
    )
    mkpath(dirname(directory))
    cp(fixture.directory, directory)
    _patch_record_git!(joinpath(directory, "submission"); sha=source_sha)
    _patch_record_git!(joinpath(directory, "replay"); sha=source_sha)
    manifest_path = joinpath(directory, "contribution.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["source_sha"] = source_sha
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    _refresh_contribution_inventory!(directory)
    @test_throws ArgumentError BrainlessLab.validate_contribution(directory; repository)
end

@testset "repository protocol is read from the exact source revision" begin
    fixture = _make_contribution()
    repository = mktempdir()
    run(Cmd(`git init -q`; dir=repository))
    run(Cmd(`git config user.email tests@example.invalid`; dir=repository))
    run(Cmd(`git config user.name "BrainlessLab tests"`; dir=repository))
    experiment_path = joinpath(repository, "experiments", "examples", "contribution-fixture")
    write_experiment(experiment_path, _contribution_experiment())
    run(Cmd(`git add experiments`; dir=repository))
    run(Cmd(`git commit -qm source`; dir=repository))
    source_sha = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))

    plan_path = only(
        joinpath(experiment_path, "plans", name)
        for name in readdir(joinpath(experiment_path, "plans"))
    )
    plan = TOML.parsefile(plan_path)
    plan["targets"][1]["evaluation"]["horizon"] = 2_001
    open(plan_path, "w") do io
        TOML.print(io, plan; sorted=true)
    end
    run(Cmd(`git add experiments`; dir=repository))
    run(Cmd(`git commit -qm later-protocol`; dir=repository))
    main_ref = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))

    directory = joinpath(
        repository,
        "research",
        "contributions",
        "contribution_fixture",
        "v1.0.0",
        "first-run",
    )
    mkpath(dirname(directory))
    cp(fixture.directory, directory)
    _patch_record_git!(joinpath(directory, "submission"); sha=source_sha)
    _patch_record_git!(joinpath(directory, "replay"); sha=source_sha)
    manifest_path = joinpath(directory, "contribution.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["source_sha"] = source_sha
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    _refresh_contribution_inventory!(directory)
    @test BrainlessLab.validate_contribution(
        directory;
        repository,
        main_ref,
    ).manifest["source_sha"] == source_sha
end

@testset "accepted research contributions are exact and role-linked" begin
    fixture = _make_contribution()
    result = BrainlessLab.validate_contribution(
        fixture.directory;
        repository=nothing,
    )
    @test result.manifest["id"] == "first-run"
    @test result.experiment.id === :contribution_fixture
    @test !result.target_exceeded
    @test result.total_bytes > 0

    comparison = BrainlessLab.compare_contribution(fixture.directory)
    @test comparison["configuration_equal"]
    @test comparison["seeds_equal"]
    @test !comparison["replay_is_independent_evidence"]
    @test comparison == BrainlessLab.compare_contribution(fixture.directory)

    catalogue = BrainlessLab.research_catalogue(
        ;
        root=fixture.root,
        repository=nothing,
    )
    @test catalogue["format"] == BrainlessLab.RESEARCH_CATALOGUE_FORMAT
    entry = only(catalogue["contributions"])
    @test entry["admission"] == "accepted"
    @test getindex.(entry["runs"], "role") == ["submission", "maintainer_replay"]
    @test getindex.(entry["runs"], "independent_evidence") == [true, false]
    first_json = BrainlessLab._json(catalogue)
    @test first_json == BrainlessLab._json(BrainlessLab.research_catalogue(
        ;
        root=fixture.root,
        repository=nothing,
    ))
    @test !occursin("\"outcome\"", first_json)
end

@testset "pre-pipeline compatibility accepts a declared complete record" begin
    fixture = _make_contribution()
    submission = joinpath(fixture.directory, "submission")
    record_directory = only(
        joinpath(submission, "operations", name)
        for name in readdir(joinpath(submission, "operations"))
    )
    protocol_path = only(
        joinpath(submission, "protocol", "plans", name)
        for name in readdir(joinpath(submission, "protocol", "plans"))
    )
    root = mktempdir()
    open(joinpath(root, "pre-pipeline.toml"), "w") do io
        TOML.print(io, Dict(
            "record" => [Dict(
                "id" => "historical-fixture",
                "experiment_id" => "contribution-fixture",
                "experiment_version" => "1.0.0",
                "title" => "Historical fixture",
                "evidence_state" => "exploratory",
                "protocol_path" => replace(relpath(protocol_path, fixture.root), '\\' => '/'),
                "record_path" => replace(relpath(record_directory, fixture.root), '\\' => '/'),
                "note" => "Complete record created before the current intake pipeline.",
            )],
        ); sorted=true)
    end

    catalogue = BrainlessLab.research_catalogue(
        ;
        root,
        repository=fixture.root,
    )
    entry = only(catalogue["contributions"])
    @test entry["id"] == "historical-fixture"
    @test entry["admission"] == "pre-pipeline"
    @test entry["source_sha"] == _CONTRIBUTION_SHA
    @test only(entry["runs"])["role"] == "historical_record"
    @test !only(entry["runs"])["independent_evidence"]

    empty_catalogue = BrainlessLab.research_catalogue(
        ;
        root=mktempdir(),
        repository=nothing,
    )
    @test isempty(empty_catalogue["contributions"])
end

@testset "contribution validation rejects changed and unsafe files" begin
    fixture = _make_contribution()

    corrupted = _copy_contribution(fixture.directory)
    open(joinpath(corrupted, "submission", "DONE"), "a") do io
        write(io, "changed\n")
    end
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        corrupted;
        repository=nothing,
    )

    reduced = _copy_contribution(fixture.directory)
    _remove_record_artifact!(
        joinpath(reduced, "submission"),
        "summary/summary.json",
    )
    _refresh_contribution_inventory!(reduced)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        reduced;
        repository=nothing,
    )

    extra = _copy_contribution(fixture.directory)
    write(joinpath(extra, "submission", "extra.md"), "extra\n")
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        extra;
        repository=nothing,
    )

    binary = _copy_contribution(fixture.directory)
    write(joinpath(binary, "submission", "payload.bin"), UInt8[0x00, 0xff])
    _refresh_contribution_inventory!(binary)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        binary;
        repository=nothing,
    )

    gif = _copy_contribution(fixture.directory)
    write(joinpath(gif, "submission", "plot.gif"), "GIF89a")
    _refresh_contribution_inventory!(gif)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        gif;
        repository=nothing,
    )

    invalid_text = _copy_contribution(fixture.directory)
    write(
        joinpath(invalid_text, "submission", "invalid.md"),
        UInt8[0xc3, 0x28],
    )
    _refresh_contribution_inventory!(invalid_text)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        invalid_text;
        repository=nothing,
    )

    raw_trace = _copy_contribution(fixture.directory)
    mkpath(joinpath(raw_trace, "submission", "raw"))
    write(joinpath(raw_trace, "submission", "raw", "trace.csv"), "value\n1\n")
    _refresh_contribution_inventory!(raw_trace)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        raw_trace;
        repository=nothing,
    )

    figure = _copy_contribution(fixture.directory)
    mkpath(joinpath(figure, "submission", "figures"))
    write(joinpath(figure, "submission", "figures", "plot.html"), "<p>plot</p>\n")
    _refresh_contribution_inventory!(figure)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        figure;
        repository=nothing,
    )

    traversal = _copy_contribution(fixture.directory)
    manifest_path = joinpath(traversal, "contribution.toml")
    manifest = TOML.parsefile(manifest_path)
    push!(manifest["submission_artifacts"], "../outside.md")
    manifest["submission_sha256"]["../outside.md"] = repeat("0", 64)
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        traversal;
        repository=nothing,
    )

    symlinked = _copy_contribution(fixture.directory)
    symlink(
        joinpath(symlinked, "submission", "DONE"),
        joinpath(symlinked, "submission", "linked.md"),
    )
    _refresh_contribution_inventory!(symlinked)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        symlinked;
        repository=nothing,
    )

    linked_bundle = _copy_contribution(fixture.directory)
    mv(
        joinpath(linked_bundle, "submission"),
        joinpath(linked_bundle, "submission-real"),
    )
    symlink(
        joinpath(linked_bundle, "submission-real"),
        joinpath(linked_bundle, "submission"),
    )
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        linked_bundle;
        repository=nothing,
    )

    linked_directory_root = mktempdir()
    linked_directory = joinpath(
        linked_directory_root,
        "contributions",
        "contribution_fixture",
        "v1.0.0",
        "first-run",
    )
    mkpath(dirname(linked_directory))
    symlink(fixture.directory, linked_directory)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        linked_directory;
        repository=nothing,
    )

    oversized = _copy_contribution(fixture.directory)
    write(joinpath(oversized, "submission", "large.md"), repeat("x", 3 * 1024^2))
    write(joinpath(oversized, "replay", "large.md"), repeat("x", 3 * 1024^2))
    _refresh_contribution_inventory!(oversized)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        oversized;
        repository=nothing,
    )

    above_target = _copy_contribution(fixture.directory)
    write(joinpath(above_target, "submission", "note.md"), repeat("x", 600 * 1024))
    write(joinpath(above_target, "replay", "note.md"), repeat("x", 600 * 1024))
    _refresh_contribution_inventory!(above_target)
    @test BrainlessLab.validate_contribution(
        above_target;
        repository=nothing,
    ).target_exceeded
end

@testset "contribution comparison protects protocol, configuration, seeds, and roles" begin
    fixture = _make_contribution()

    dirty = _copy_contribution(fixture.directory)
    _patch_record_git!(joinpath(dirty, "submission"); state="dirty")
    _refresh_contribution_inventory!(dirty)
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        dirty;
        repository=nothing,
    )

    roles = _copy_contribution(fixture.directory)
    manifest_path = joinpath(roles, "contribution.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["reviewer"] = manifest["contributor"]
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        roles;
        repository=nothing,
    )

    unsafe_url = _copy_contribution(fixture.directory)
    manifest_path = joinpath(unsafe_url, "contribution.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["review_url"] = "javascript:alert(1)"
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        unsafe_url;
        repository=nothing,
    )

    renamed_run = _copy_contribution(fixture.directory)
    manifest_path = joinpath(renamed_run, "contribution.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["submission"] = "replay"
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted=true)
    end
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        renamed_run;
        repository=nothing,
    )

    config = _copy_contribution(fixture.directory)
    record = only(
        joinpath(config, "replay", "operations", name)
        for name in readdir(joinpath(config, "replay", "operations"))
    )
    resolved_path = joinpath(record, "resolved.toml")
    resolved = TOML.parsefile(resolved_path)
    resolved["targets"][1]["n_nodes"] = 99
    open(resolved_path, "w") do io
        TOML.print(io, resolved; sorted=true)
    end
    _refresh_record_checksum!(joinpath(config, "replay"), "resolved.toml")
    _refresh_contribution_inventory!(config)
    @test_throws ArgumentError BrainlessLab.compare_contribution(config)

    seeds = _copy_contribution(fixture.directory)
    record = only(
        joinpath(seeds, "replay", "operations", name)
        for name in readdir(joinpath(seeds, "replay", "operations"))
    )
    open(joinpath(record, "seeds.csv"), "a") do io
        write(io, "\n")
    end
    _refresh_record_checksum!(joinpath(seeds, "replay"), "seeds.csv")
    _refresh_contribution_inventory!(seeds)
    @test_throws ArgumentError BrainlessLab.compare_contribution(seeds)

    data = _copy_contribution(fixture.directory)
    record = only(
        joinpath(data, "replay", "operations", name)
        for name in readdir(joinpath(data, "replay", "operations"))
    )
    open(joinpath(record, "data", "trials.csv"), "a") do io
        write(io, "\n")
    end
    _refresh_record_checksum!(joinpath(data, "replay"), "data/trials.csv")
    _refresh_contribution_inventory!(data)
    comparison = BrainlessLab.compare_contribution(data; write=true)
    @test !only(comparison["operations"])["data_equal"]
    @test_throws ArgumentError BrainlessLab.validate_contribution(
        data;
        repository=nothing,
    )

    protocol = _copy_contribution(fixture.directory)
    plan_path = only(
        joinpath(protocol, "replay", "protocol", "plans", name)
        for name in readdir(joinpath(protocol, "replay", "protocol", "plans"))
    )
    plan = TOML.parsefile(plan_path)
    plan["targets"][1]["evaluation"]["horizon"] = 2_001
    open(plan_path, "w") do io
        TOML.print(io, plan; sorted=true)
    end
    _refresh_contribution_inventory!(protocol)
    @test_throws ArgumentError BrainlessLab.compare_contribution(protocol)
end

@testset "append-only validation rejects extension of an accepted record" begin
    repository = mktempdir()
    run(Cmd(`git init -q`; dir=repository))
    run(Cmd(`git config user.email tests@example.invalid`; dir=repository))
    run(Cmd(`git config user.name "BrainlessLab tests"`; dir=repository))
    contribution = joinpath(
        repository,
        "research",
        "contributions",
        "study",
        "v1.0.0",
        "accepted",
    )
    mkpath(contribution)
    write(joinpath(contribution, "contribution.toml"), "format = \"test\"\n")
    run(Cmd(`git add research`; dir=repository))
    run(Cmd(`git commit -qm base`; dir=repository))
    base = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))
    @test isnothing(BrainlessLab._check_contribution_append_only(
        contribution,
        repository,
        base,
    ))
    write(joinpath(contribution, "late.md"), "late\n")
    run(Cmd(`git add research`; dir=repository))
    run(Cmd(`git commit -qm late`; dir=repository))
    @test_throws ArgumentError BrainlessLab._check_contribution_append_only(
        contribution,
        repository,
        base,
    )
end

@testset "source revision validation rejects missing commits" begin
    repository = mktempdir()
    run(Cmd(`git init -q`; dir=repository))
    @test_throws ArgumentError BrainlessLab._verify_source_revision(
        repository,
        repeat("b", 40),
        nothing,
    )

    run(Cmd(`git config user.email tests@example.invalid`; dir=repository))
    run(Cmd(`git config user.name "BrainlessLab tests"`; dir=repository))
    write(joinpath(repository, "base.md"), "base\n")
    run(Cmd(`git add base.md`; dir=repository))
    run(Cmd(`git commit -qm base`; dir=repository))
    main_ref = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))
    run(Cmd(`git checkout -qb feature`; dir=repository))
    write(joinpath(repository, "feature.md"), "feature\n")
    run(Cmd(`git add feature.md`; dir=repository))
    run(Cmd(`git commit -qm feature`; dir=repository))
    feature_sha = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))
    @test_throws ArgumentError BrainlessLab._verify_source_revision(
        repository,
        feature_sha,
        main_ref,
    )
end

@testset "run-only validation rejects files outside the new contribution" begin
    repository = mktempdir()
    run(Cmd(`git init -q`; dir=repository))
    run(Cmd(`git config user.email tests@example.invalid`; dir=repository))
    run(Cmd(`git config user.name "BrainlessLab tests"`; dir=repository))
    write(joinpath(repository, "README.md"), "base\n")
    run(Cmd(`git add README.md`; dir=repository))
    run(Cmd(`git commit -qm base`; dir=repository))
    base = readchomp(Cmd(`git rev-parse HEAD`; dir=repository))
    contribution = joinpath(
        repository,
        "research",
        "contributions",
        "study",
        "v1.0.0",
        "new-record",
    )
    mkpath(contribution)
    write(joinpath(contribution, "contribution.toml"), "format = \"test\"\n")
    write(joinpath(repository, "source.jl"), "unexpected\n")
    run(Cmd(`git add research source.jl`; dir=repository))
    run(Cmd(`git commit -qm contribution`; dir=repository))
    @test_throws ArgumentError BrainlessLab._check_contribution_append_only(
        contribution,
        repository,
        base,
    )
end
