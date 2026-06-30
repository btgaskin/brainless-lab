#!/usr/bin/env julia

include("src/Stats.jl")

using .Stats
using HypothesisTests
using Random
using Statistics
using Test

@testset "bootstrap and null MWU" begin
    xs = fill(1.0, 20)
    ys = fill(1.0, 20)

    @test Stats.mannwhitney_p(xs, ys) > 0.5

    lo, hi = Stats.bootstrap_ci(xs; rng=Random.Xoshiro(1))
    @test lo <= mean(xs) <= hi
end

@testset "shifted samples" begin
    rng = Random.Xoshiro(2)
    xs = randn(rng, 40)
    ys = 3.0 .+ randn(rng, 40)

    @test Stats.mannwhitney_p(xs, ys) < 0.001
    @test abs(Stats.cliffs_delta(xs, ys)) > 0.8

    power = Stats.achieved_power(xs, ys; B=200, rng=Random.Xoshiro(3))
    @test power > 0.95
end

@testset "cliffs delta edge cases" begin
    @test abs(Stats.cliffs_delta([1.0, 1.0, 1.0], [1.0, 1.0, 1.0])) < 1e-12
    @test isapprox(Stats.cliffs_delta([2.0, 3.0, 4.0], [1.0, 1.0, 1.0]), 1.0; atol=1e-12)
end

@testset "benjamini hochberg" begin
    p = [0.01, 0.04, 0.03, 0.20]
    q = Stats.benjamini_hochberg(p)

    @test all(q .>= p .- eps(Float64))
    order = sortperm(p)
    @test all(diff(q[order]) .>= -1e-12)
end
