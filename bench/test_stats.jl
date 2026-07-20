#!/usr/bin/env julia

include("src/Stats.jl")

using .Stats
using Random
using Statistics
using Test

@testset "bootstrap and paired null" begin
    xs = fill(1.0, 20)
    ys = fill(1.0, 20)

    @test Stats.paired_signflip_p(xs, ys) == 1.0
    @test Stats.paired_superiority(xs, ys) == 0.0

    lo, hi = Stats.bootstrap_ci(xs; rng=Random.Xoshiro(1))
    @test lo <= mean(xs) <= hi
    dlo, dhi = Stats.paired_mean_diff_ci(xs, ys; rng=Random.Xoshiro(1))
    @test dlo == dhi == 0.0
end

@testset "paired shifted samples" begin
    rng = Random.Xoshiro(2)
    xs = randn(rng, 40)
    ys = xs .+ 3.0

    @test Stats.paired_signflip_p(xs, ys; nperm=2_000, rng=Random.Xoshiro(3)) < 0.001
    @test Stats.paired_superiority(xs, ys) == -1.0
    lo, hi = Stats.paired_mean_diff_ci(xs, ys; rng=Random.Xoshiro(4))
    @test lo <= -3.0 <= hi
end

@testset "repeated-measures omnibus" begin
    blocks = collect(1.0:24.0)
    @test Stats.repeated_measures_p(blocks, blocks, blocks; nperm=500) == 1.0
    p = Stats.repeated_measures_p(
        blocks,
        blocks .+ 2.0,
        blocks .+ 4.0;
        nperm=2_000,
        rng=Random.Xoshiro(5),
    )
    @test p < 0.01
    @test_throws DimensionMismatch Stats.repeated_measures_p([1.0, 2.0], [1.0])
end

@testset "benjamini hochberg" begin
    p = [0.01, 0.04, 0.03, 0.20]
    q = Stats.benjamini_hochberg(p)

    @test all(q .>= p .- eps(Float64))
    order = sortperm(p)
    @test all(diff(q[order]) .>= -1e-12)
end

@testset "task analysis reports paired fields" begin
    groups = Dict(
        :baseline => collect(1.0:20.0),
        :candidate => collect(1.0:20.0) .+ 1.0,
    )
    result = Stats.analyze_task(
        groups;
        baseline=:baseline,
        nperm=1_000,
        rng=Random.Xoshiro(6),
    )
    @test result.omnibus_rm_p < 0.01
    @test length(result.pairwise) == 1
    @test only(result.baseline).delta_mean == 1.0
    @test only(result.baseline).paired_superiority == 1.0
end
