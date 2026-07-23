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
        @test resolve(plan, DEFAULT_REGISTRY) isa AbstractResolvedOperationPlan
    end
end
