using BrainlessLab
using Random
using Test
import BrainlessLab: ask, tell!, result

mutable struct TestOptimizer <: AbstractEvolutionStrategy
    x0::Vector{Float64}
    popsize::Int
    best_x::Vector{Float64}
    best_value::Float64
    countiter::Int
    countevals::Int
end

function TestOptimizer(x0::AbstractVector{<:Real}, sigma0::Real; popsize=nothing, seed::Integer=0)
    x = Vector{Float64}(Float64.(x0))
    n = popsize === nothing ? 2 : Int(popsize)
    return TestOptimizer(x, n, copy(x), Inf, 0, 0)
end

ask(es::TestOptimizer) = [copy(es.x0) for _ in 1:es.popsize]

function tell!(es::TestOptimizer, solutions, losses)
    for i in eachindex(solutions, losses)
        loss = Float64(losses[i])
        if loss < es.best_value
            es.best_value = loss
            es.best_x = Vector{Float64}(Float64.(solutions[i]))
        end
    end
    es.countiter += 1
    es.countevals += length(solutions)
    return es
end

result(es::TestOptimizer) = (
    x=copy(es.best_x),
    value=Float64(es.best_value),
    xbest=copy(es.best_x),
    fbest=Float64(es.best_value),
    countiter=es.countiter,
    countevals=es.countevals,
)

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

@testset "Plastic rollout diagnostics wrap rollout" begin
    x0 = pack_params(FalandaysParams())
    plastic = BrainlessLab._plastic_rollout(:wall, x0, 7; N=16, ticks=30, window=30)
    shared = rollout(:wall, x0, 7; N=16, ticks=30, window=30, learn_on=true, return_ensemble=true)

    @test propertynames(plastic) == (
        :task,
        :model_sym,
        :seed,
        :ticks,
        :N,
        :score,
        :norm_score,
        :alive,
        :rate_mean,
        :rate_var,
        :total_spikes_window,
        :target_mean,
        :target_var,
        :weight_delta_norm,
        :weight_delta_mean_abs,
        :metrics,
    )
    @test hasproperty(shared, :ensemble)
    @test !hasproperty(plastic, :ensemble)
    @test plastic.score == shared.score
    @test plastic.norm_score == shared.norm_score
    @test plastic.metrics == shared.metrics
    @test isfinite(plastic.target_mean)
    @test isfinite(plastic.target_var)
    @test isfinite(plastic.weight_delta_norm)
    @test isfinite(plastic.weight_delta_mean_abs)
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

@testset "SORN evolve smoke" begin
    result = evolve(
        model_sym=:sorn,
        train_tasks=(:wall,),
        optimizer=TestOptimizer,
        generations=1,
        popsize=2,
        k_trials=1,
        N=8,
        ticks=20,
        sigma0=0.1,
        seed=4,
    )
    @test result.optimizer isa TestOptimizer
    @test isfinite(result.best_fitness)
    @test 0.0 <= result.best_fitness <= 1.0
end

@testset "Registered optimizer smoke" begin
    register_optimizer!(:test_optimizer, TestOptimizer)
    out = evolve(
        model_sym=:falandays,
        train_tasks=(:wall,),
        optimizer=:test_optimizer,
        generations=1,
        popsize=2,
        k_trials=1,
        N=8,
        ticks=20,
        seed=3,
    )
    @test out.optimizer isa TestOptimizer
    @test isfinite(out.best_fitness)
end
