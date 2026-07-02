using BrainlessLab
using Random
using Test

@testset "Evolve runner smoke" begin
    result = evolve(
        model_sym=:falandays,
        train_tasks=(:wall,),
        generations=4,
        popsize=8,
        k_trials=3,
        N=60,
        ticks=200,
        seed=0,
    )

    fitnesses = reduce(vcat, result.fitnesses)
    @test !isempty(fitnesses)
    @test all(isfinite, fitnesses)
    @test all(0.0 .<= fitnesses .<= 1.0)
    @test isfinite(result.best_fitness)
    @test 0.0 <= result.best_fitness <= 1.0
    @test length(result.history.generation) == 4
end

@testset "Parallel rollout determinism" begin
    rng = Random.Xoshiro(11)
    x0 = pack_params(FalandaysParams())
    solutions = [x0 .+ 0.05 .* randn(rng, length(x0)) for _ in 1:5]
    seeds = (123, 124, 125)

    serial = BrainlessLab.evaluate_fitness_matrix(
        solutions,
        :wall,
        seeds;
        model_sym=:falandays,
        N=32,
        ticks=80,
        threaded=false,
    )
    threaded = BrainlessLab.evaluate_fitness_matrix(
        solutions,
        :wall,
        seeds;
        model_sym=:falandays,
        N=32,
        ticks=80,
        threaded=true,
    )

    @test serial == threaded
end

@testset "Compartmental evolve smoke" begin
    x0 = zeros(Float64, paramdim(StructuredCompartmental))
    result = evolve(
        model_sym=:compartmental_structured,
        train_tasks=(:wall,),
        generations=1,
        popsize=4,
        k_trials=1,
        N=8,
        ticks=20,
        sigma0=0.1,
        x0=x0,
        seed=2,
    )
    @test isfinite(result.best_fitness)
    @test 0.0 <= result.best_fitness <= 1.0
end
