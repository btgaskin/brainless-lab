using BrainlessLab
using SHA
using Test
using TOML

@testset "checked-in plan examples resolve" begin
    root = normpath(joinpath(@__DIR__, "..", "plans", "examples"))
    paths = sort!(filter(path -> endswith(path, ".toml"), readdir(root; join=true)))
    @test basename.(paths) == [
        "ablate_tracking.toml",
        "benchmark_core.toml",
        "profile_tracking.toml",
        "sweep_tracking.toml",
    ]
    for path in paths
        plan = read_plan(path)
        @test validate(plan, DEFAULT_REGISTRY) === plan
        @test resolve(plan, DEFAULT_REGISTRY) isa BrainlessLab.AbstractResolvedOperationPlan
    end
end

@testset "a small plan reproduces byte-identical data and summaries" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    target = EvaluationTarget(
        :deterministic_tracking,
        CompositionSpec(
            :deterministic_tracking,
            :null_random,
            :tracking;
            n_nodes=4,
        ),
        EvaluationSpec(
            blocks=1,
            trials_per_block=2,
            horizon=3,
            root_seed=73,
        ),
    )
    plan = ProfilePlan(
        :deterministic_profile,
        target;
        analyses=(),
    )
    first = run_operation(
        plan;
        registry,
        root=mktempdir(),
        id="first",
    )
    second = run_operation(
        plan;
        registry,
        root=mktempdir(),
        id="second",
    )

    function artifact_paths(directory)
        paths = String["resolved.toml", "seeds.csv"]
        for subdirectory in ("data", "summary")
            root = joinpath(directory, subdirectory)
            append!(
                paths,
                replace(relpath(joinpath(path, file), directory), '\\' => '/')
                for (path, _, files) in walkdir(root)
                for file in files
            )
        end
        return sort!(paths)
    end

    paths = artifact_paths(first.directory)
    @test paths == artifact_paths(second.directory)
    for path in paths
        @test read(joinpath(first.directory, path)) ==
              read(joinpath(second.directory, path))
    end
end

@testset "generated documentation records match committed fixtures" begin
    repository = normpath(joinpath(@__DIR__, ".."))
    expected = joinpath(
        repository,
        "site",
        "src",
        "fixtures",
        "example-record",
    )
    generator = joinpath(repository, "tools", "docs", "generate_example_records.jl")

    function fixture_files(root)
        return sort!([
            replace(relpath(joinpath(directory, file), root), '\\' => '/')
            for (directory, _, files) in walkdir(root)
            for file in files
        ])
    end

    function validate_fixture_bundle(root)
        record_path = joinpath(root, "record.toml")
        record = TOML.parsefile(record_path)
        @test record["completion_marker"] == "DONE"
        @test isfile(joinpath(root, "DONE"))
        artifacts = String.(record["artifacts"])
        checksums = record["artifact_sha256"]
        @test Set(artifacts) == Set(keys(checksums))
        for artifact in artifacts
            digest = bytes2hex(sha256(read(joinpath(root, artifact))))
            @test digest == checksums[artifact]
        end
        manifest_relative = "environment/Manifest.toml"
        @test record["manifest_sha256"] == checksums[manifest_relative]
        manifest = TOML.parsefile(joinpath(root, manifest_relative))
        @test get(manifest, "manifest_format", nothing) == "2.0"
        @test haskey(manifest, "project_hash")
        dependencies = get(manifest, "deps", Dict{String,Any}())
        @test haskey(dependencies, "JLD2")
        @test haskey(dependencies, "StaticArrays")
        return record
    end

    function portable_record_metadata(record)
        copy_ = deepcopy(record)
        delete!(copy_, "manifest_sha256")
        delete!(copy_["artifact_sha256"], "environment/Manifest.toml")
        return copy_
    end

    mktempdir() do temporary
        actual = joinpath(temporary, "example-record")
        run(`$(Base.julia_cmd()) --threads=1 --project=$(repository) $(generator) --output $(actual)`)
        paths = fixture_files(expected)
        @test paths == fixture_files(actual)
        for path in paths
            path in ("profile/record.toml", "benchmark/record.toml") && continue
            endswith(path, "/environment/Manifest.toml") && continue
            @test read(joinpath(expected, path)) == read(joinpath(actual, path))
        end
        for operation in ("profile", "benchmark")
            expected_record = validate_fixture_bundle(joinpath(expected, operation))
            actual_record = validate_fixture_bundle(joinpath(actual, operation))
            @test portable_record_metadata(expected_record) ==
                  portable_record_metadata(actual_record)
        end
    end
end
