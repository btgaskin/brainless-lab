using BrainlessLab
using NPZ
using Random
using Test

function _cma_fixture_path()
    return joinpath(@__DIR__, "fixtures", "cma_sphere_trace.npz")
end

function _ensure_cma_trace_fixture(path)
    isfile(path) && return
    script = joinpath(@__DIR__, "oracle", "gen_cma_trace.py")
    v0_dir = normpath(joinpath(@__DIR__, "..", "..", "v0"))
    isdir(v0_dir) || error("missing fixture $path and cannot find v0 dir $v0_dir")
    try
        run(Cmd(`uv run python $script`; dir=v0_dir))
    catch err
        error("missing fixture $path and failed to generate it with $script from $v0_dir: $err")
    end
end

_sphere(x) = sum(abs2, x)

function _rosenbrock(x)
    total = 0.0
    for i in 1:(length(x) - 1)
        total += 100.0 * (x[i + 1] - x[i]^2)^2 + (1.0 - x[i])^2
    end
    return total
end

function _minimize_with_sepcma(f, x0; sigma0, popsize, seed, generations)
    es = SepCMA(Vector{Float64}(x0), sigma0; popsize=popsize, seed=seed)
    for _ in 1:generations
        X = ask(es)
        losses = [f(x) for x in X]
        tell!(es, X, losses)
    end
    return result(es)
end

@testset "SepCMA pycma trace parity" begin
    path = _cma_fixture_path()
    _ensure_cma_trace_fixture(path)
    data = npzread(path)

    x0 = Vector{Float64}(vec(Float64.(data["x0"])))
    sigma0 = BrainlessLabTestUtils.scalar(data, "sigma0")
    popsize = BrainlessLabTestUtils.int_scalar(data, "popsize")

    es = SepCMA(x0, sigma0; popsize=popsize, seed=0)
    X = Float64.(data["X"])
    losses = Float64.(data["losses"])
    means = Float64.(data["mean"])
    sigmas = Float64.(data["sigma"])
    cscales = haskey(data, "cscale") ? Float64.(data["cscale"]) : nothing

    for g in axes(X, 1)
        solutions = [Vector{Float64}(vec(X[g, p, :])) for p in axes(X, 2)]
        loss = Vector{Float64}(vec(losses[g, :]))
        tell!(es, solutions, loss)

        @test es.x_mean ≈ Vector{Float64}(vec(means[g, :])) atol = 1e-6 rtol = 1e-6
        @test es.sigma ≈ Float64(sigmas[g]) atol = 1e-6 rtol = 1e-6
        if cscales !== nothing
            @test sqrt.(es.C_diag) ≈ Vector{Float64}(vec(cscales[g, :])) atol = 1e-6 rtol = 1e-6
        end
    end

    # Older fixtures did not record pycma's diagonal scale; keep the existing parity gate green.
    cscales === nothing && @info "SepCMA fixture lacks cscale; skipped diagonal covariance parity check"
end

@testset "SepCMA toy convergence" begin
    sphere_result = _minimize_with_sepcma(
        _sphere,
        fill(2.0, 5);
        sigma0=0.8,
        popsize=16,
        seed=1,
        generations=220,
    )
    @test sphere_result.value < 1e-6

    rosen_result = _minimize_with_sepcma(
        _rosenbrock,
        [0.2, 0.2, 0.2, 0.2];
        sigma0=0.5,
        popsize=20,
        seed=3,
        generations=700,
    )
    @test rosen_result.value < 0.25
end
