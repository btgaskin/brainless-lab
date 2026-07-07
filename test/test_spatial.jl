using BrainlessLab
using Random
using StaticArrays
using Test

@testset "Spatial Falandays connectome" begin
    @test connection_prob(ExpKernel(0.5, 0.3), 0.0) >
          connection_prob(ExpKernel(0.5, 0.3), 1.0)

    r = resolve_node(:falandays_spatial)(24, 3, 2; seed=7)
    @test spatiality(r.connectome) == Embedded{2}()
    @test typeof(r) <: FalandaysReservoir
    @test all(!r.recurrent_mask[i, i] for i in axes(r.recurrent_mask, 1))
    @test count(r.recurrent_mask) > 0

    sim = simulate(:wall; node=:falandays_spatial, ticks=50, seed=1)
    @test isfinite(Float64(sim.metrics.score))

    space = MetricSpace(SVector(0.0, 0.0), SVector(1.0, 1.0))
    rule = SpatialRule(space, ExpKernel(0.5, 0.3), 0.1, 1.0)
    c1 = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11))
    c2 = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11))
    @test c1.recurrent_mask == c2.recurrent_mask
end

@testset "Hemispheric spatial connectome" begin
    params = FalandaysParams()

    build_test_connectome(N=8, R=4, E=4; seed=13, kwargs...) =
        build_hemispheric_connectome(
            N,
            R,
            E;
            rng=MersenneTwister(seed),
            weight_init_std=params.weight_init_std,
            input_weight=params.input_weight,
            kwargs...,
        )

    c0 = build_test_connectome(9, 4, 4; callosum_density=0.0, p0=1.0, link_p=0.5)
    left_nodes = findall(==(1), c0.regions)
    right_nodes = findall(==(2), c0.regions)
    @test Set(c0.regions) == Set([1, 2])
    @test !any(c0.recurrent_mask[left_nodes, right_nodes])
    @test !any(c0.recurrent_mask[right_nodes, left_nodes])

    c1 = build_test_connectome(9, 4, 4; seed=17, callosum_density=1.0, p0=1.0, link_p=0.5)
    left_nodes = findall(==(1), c1.regions)
    right_nodes = findall(==(2), c1.regions)
    na = length(left_nodes)
    nb = length(right_nodes)
    for i in 1:min(na, nb)
        a = left_nodes[i]
        b = right_nodes[i]
        @test c1.recurrent_mask[a, b]
        @test c1.recurrent_mask[b, a]
    end
    for a in left_nodes, b in right_nodes
        homotopic = a <= nb && b == na + a
        if !homotopic
            @test !c1.recurrent_mask[a, b]
            @test !c1.recurrent_mask[b, a]
        end
    end

    c_cross = build_test_connectome(8, 5, 5; seed=19, contralateral=true, link_p=1.0)
    left_nodes = findall(==(1), c_cross.regions)
    left_receptors = 1:cld(size(c_cross.input_wmat, 1), 2)
    left_effectors = 1:cld(size(c_cross.output_mask, 2), 2)
    @test all(iszero, c_cross.input_wmat[left_receptors, left_nodes])
    @test all(iszero, c_cross.output_mask[left_nodes, left_effectors])

    sim = simulate(:wall; node=:falandays_hemispheric, ticks=50, seed=1)
    @test isfinite(Float64(sim.metrics.score))

    ca = build_test_connectome(8, 4, 4; seed=23, callosum_density=0.5)
    cb = build_test_connectome(8, 4, 4; seed=23, callosum_density=0.5)
    @test ca.recurrent_mask == cb.recurrent_mask
    @test ca.input_wmat == cb.input_wmat
    @test ca.output_mask == cb.output_mask
    @test ca.wmat0 == cb.wmat0
    @test ca.embedding.node_pos == cb.embedding.node_pos
    @test ca.regions == cb.regions
end

@testset "Power-law spatial kernel" begin
    k = PowerLawKernel(0.5, 0.3, 2.0)
    @test connection_prob(k, 0.0) == 0.5
    @test connection_prob(k, 1.0) < connection_prob(k, 0.0)
    @test connection_prob(k, 0.5) > connection_prob(k, 5.0)
    @test connection_prob(k, 1e6) >= 0.0

    @test_throws ArgumentError BrainlessLab._spatial_kernel(:bogus, 0.5, 0.3, 0.3, 2.0)
    @test BrainlessLab._spatial_kernel(:exp, 0.5, 0.3, 0.3, 2.0) isa ExpKernel
    @test BrainlessLab._spatial_kernel(:power_law, 0.5, 0.3, 0.3, 2.0) isa PowerLawKernel

    space = MetricSpace(SVector(0.0, 0.0), SVector(1.0, 1.0))
    rule = SpatialRule(space, PowerLawKernel(0.9, 0.3, 1.5), 0.1, 1.0)
    c1 = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11))
    c2 = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11))
    @test c1.recurrent_mask == c2.recurrent_mask
    @test isempty(c1.embedding.effector_anchor)

    c_spatial_eff = build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11); effector_wiring=:spatial)
    @test length(c_spatial_eff.embedding.effector_anchor) == 2
    @test_throws ArgumentError build_spatial_connectome(24, 3, 2, rule, MersenneTwister(11); effector_wiring=:bogus)

    sim = simulate(:wall; node=:falandays_spatial, ticks=30, seed=1,
        node_kwargs=(kernel=:power_law, d0=0.3, alpha=2.0, effector_wiring=:spatial))
    @test isfinite(Float64(sim.metrics.score))
end

@testset "Hemispheric power-law kernel + spatial effector wiring" begin
    params = FalandaysParams()
    build_test_connectome(N=8, R=4, E=4; seed=13, kwargs...) =
        build_hemispheric_connectome(
            N,
            R,
            E;
            rng=MersenneTwister(seed),
            weight_init_std=params.weight_init_std,
            input_weight=params.input_weight,
            kwargs...,
        )

    c = build_test_connectome(9, 4, 4; kernel=:power_law, d0=0.3, alpha=1.5, p0=1.0, link_p=0.5)
    @test isempty(c.embedding.effector_anchor)

    c_spatial_eff = build_test_connectome(9, 4, 4; kernel=:power_law, d0=0.3, alpha=1.5, effector_wiring=:spatial)
    @test length(c_spatial_eff.embedding.effector_anchor) == 4

    ca = build_test_connectome(8, 4, 4; seed=23, kernel=:power_law, d0=0.3, alpha=1.5, effector_wiring=:spatial, callosum_density=0.5)
    cb = build_test_connectome(8, 4, 4; seed=23, kernel=:power_law, d0=0.3, alpha=1.5, effector_wiring=:spatial, callosum_density=0.5)
    @test ca.output_mask == cb.output_mask
    @test ca.embedding.effector_anchor == cb.embedding.effector_anchor

    @test_throws ArgumentError build_test_connectome(8, 4, 4; kernel=:bogus)
    @test_throws ArgumentError build_test_connectome(8, 4, 4; effector_wiring=:bogus)

    for cd in (0.0, 0.5, 1.0)
        sim = simulate(:wall; node=:falandays_hemispheric, ticks=30, seed=1,
            node_kwargs=(kernel=:power_law, d0=0.3, alpha=1.5, effector_wiring=:spatial, callosum_density=cd))
        @test isfinite(Float64(sim.metrics.score))
    end
end
