using BrainlessLab
using Test

@testset "Fast non-dominated sort partitions correctly" begin
    # p1 dominates p2 and p3; p2 and p3 are mutually non-dominated; p4 is
    # dominated by everything.
    objs = [
        [1.0, 1.0],  # p1: dominates p2, p3, p4
        [1.0, 0.5],  # p2: dominated only by p1
        [0.5, 1.0],  # p3: dominated only by p1
        [0.1, 0.1],  # p4: dominated by everyone
    ]
    fronts = BrainlessLab._fast_nondominated_sort(objs)

    @test fronts[1] == [1]
    @test Set(fronts[2]) == Set([2, 3])
    @test fronts[3] == [4]
end

@testset "Crowding distance gives boundary points Inf" begin
    front = [1, 2, 3]
    objs = [
        [0.0, 1.0],
        [0.5, 0.5],
        [1.0, 0.0],
    ]
    dist = BrainlessLab._crowding_distance(front, objs)

    @test dist[1] == Inf
    @test dist[3] == Inf
    @test isfinite(dist[2])
    @test dist[2] >= 0.0
end

@testset "NSGA-II smoke" begin
    out = BrainlessLab.nsga2(
        model_sym=:compartmental_structured,
        train_tasks=(:wall, :tracking),
        popsize=8,
        generations=2,
        k_trials=1,
        N=8,
        ticks=20,
        sigma0=0.1,
        seed=5,
    )

    @test out.n_evaluated == 8 * 3  # initial pop + 2 generations of offspring
    @test !isempty(out.pareto_front)
    for entry in out.pareto_front
        @test length(entry.objectives) == 2
        @test all(o -> isfinite(o) && 0.0 <= o <= 1.0, entry.objectives)
    end
    @test length(out.best_mean_genome) == paramdim(StructuredCompartmental)
    @test all(o -> isfinite(o) && 0.0 <= o <= 1.0, out.best_mean_objectives)
end
