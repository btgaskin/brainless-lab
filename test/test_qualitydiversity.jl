using BrainlessLab
using Test

@testset "Descriptor key discretizes and clamps" begin
    @test BrainlessLab._descriptor_key([0.0, 0.0], 3) == [0, 0]
    @test BrainlessLab._descriptor_key([0.99, 0.5], 3) == [2, 1]
    @test BrainlessLab._descriptor_key([1.0, 1.0], 3) == [2, 2]  # exact upper edge clamps into the last bin
end

@testset "Archive insertion: quality only improves per cell" begin
    archive = BrainlessLab.MEArchive(bins=3, n_tasks=2)
    genome_a = [1.0, 2.0]
    genome_b = [3.0, 4.0]
    genome_c = [5.0, 6.0]
    descriptor = [0.5, 0.5]

    improvement_empty = BrainlessLab._archive_offer!(archive, genome_a, descriptor, 0.5)
    @test improvement_empty == 0.5
    @test length(archive.cells) == 1

    key = BrainlessLab._descriptor_key(descriptor, 3)
    @test archive.cells[key].genome == genome_a

    improvement_worse = BrainlessLab._archive_offer!(archive, genome_b, descriptor, 0.3)
    @test improvement_worse == 0.0
    @test archive.cells[key].genome == genome_a  # rejected, elite unchanged

    improvement_better = BrainlessLab._archive_offer!(archive, genome_c, descriptor, 0.8)
    @test improvement_better ≈ 0.3
    @test archive.cells[key].genome == genome_c  # replaced
    @test archive.cells[key].quality == 0.8
end

@testset "CMA-ME smoke" begin
    out = BrainlessLab.cma_me(
        model_sym=:compartmental_structured,
        train_tasks=(:wall, :tracking),
        bins=3,
        n_emitters=2,
        emitter_popsize=4,
        iterations=2,
        k_trials=1,
        N=8,
        ticks=20,
        sigma0=0.1,
        seed=6,
    )

    @test out.n_cells_filled >= 1
    @test 0.0 <= out.coverage <= 1.0
    @test isfinite(out.best_quality)
    @test 0.0 <= out.best_quality <= 1.0
    @test length(out.best_genome) == paramdim(StructuredCompartmental)
    @test !isempty(out.pareto_front)
    for entry in out.pareto_front
        @test length(entry.descriptor) == 2
        @test all(d -> isfinite(d) && 0.0 <= d <= 1.0, entry.descriptor)
    end
end
