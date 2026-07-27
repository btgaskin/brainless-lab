using BrainlessLab
using Test

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
        root=mktempdir(),
        id="first",
    )
    second = run_operation(
        plan;
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
