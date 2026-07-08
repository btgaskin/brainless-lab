using BrainlessLab
using Test
using Random

@testset "mid-rollout interventions" begin
    @testset "no-op identity (nothing / empty schedule)" begin
        s0 = simulate(:tracking; node=:falandays_base, ticks=60, seed=0)
        sn = simulate(:tracking; node=:falandays_base, ticks=60, seed=0, interventions=nothing)
        se = simulate(:tracking; node=:falandays_base, ticks=60, seed=0, interventions=[])
        @test s0.metrics.score == sn.metrics.score
        @test s0.metrics.score == se.metrics.score
        @test s0.config.interventions == ()
    end

    @testset "freeze@1 == build-time ablation freeze_plasticity" begin
        sf1 = simulate(:tracking; node=:falandays_base, ticks=80, seed=0,
                       interventions=[(tick=1, verb=:freeze_plasticity)])
        sab = simulate(:tracking; node=:falandays_base, ticks=80, seed=0, ablation=:freeze_plasticity)
        @test sf1.metrics.score == sab.metrics.score
        @test sf1.config.interventions == ((1, :freeze_plasticity),)
    end

    @testset "freeze freezes recurrent weights and flips learn_on" begin
        setup = BrainlessLab._build_ensemble(:tracking, :falandays_base; ticks=80, seed=0)
        res = setup.ensemble.agents[1].reservoir
        w0 = copy(res.wmat)
        BrainlessLab.rollout!(setup.ensemble, 80; window=setup.window,
                              interventions=[(1, :freeze_plasticity)])
        @test res.params.learn_on == false
        @test res.wmat == w0

        # control: with learning on, recurrent weights DO change
        setup2 = BrainlessLab._build_ensemble(:tracking, :falandays_base; ticks=80, seed=0)
        res2 = setup2.ensemble.agents[1].reservoir
        w0b = copy(res2.wmat)
        BrainlessLab.rollout!(setup2.ensemble, 80; window=setup2.window)
        @test res2.wmat != w0b
    end

    @testset "schedule validation + entry forms" begin
        @test_throws ArgumentError simulate(:tracking; node=:falandays_base, ticks=5,
                                            interventions=[(tick=2, verb=:bogus)])
        @test_throws ArgumentError simulate(:tracking; node=:falandays_base, ticks=5,
                                            interventions=[(tick=0, verb=:freeze_plasticity)])
        st = simulate(:tracking; node=:falandays_base, ticks=20, seed=0,
                      interventions=[(3, :clamp_target)])
        @test st.config.interventions == ((3, :clamp_target),)
        sp = simulate(:tracking; node=:falandays_base, ticks=20, seed=0,
                      interventions=[5 => :freeze_plasticity])
        @test sp.config.interventions == ((5, :freeze_plasticity),)
    end
end

@testset "tracking learning-dynamics analyses" begin
    sim = simulate(:tracking; node=:falandays_base, ticks=1200, seed=0,
                   record=(:rate, :spikes, :scene, :percepts))

    @testset "object_in_view" begin
        oiv = object_in_view(sim)
        he = heading_error(sim)
        @test length(oiv) == length(he)
        @test all(x -> x == 0.0 || x == 1.0, oiv)
        inm = oiv .== 1.0
        if any(inm) && any(.!inm)
            @test sum(he[inm]) / count(inm) < sum(he[.!inm]) / count(.!inm)
        end
        @test resolve_analysis(:object_in_view) === object_in_view
        @test analysis_meta(:object_in_view).task === :tracking
        blind = simulate(:tracking; node=:falandays_base, ticks=20, record=(:rate,))
        @test_throws ArgumentError object_in_view(blind)
    end

    @testset "drive-conditioned windowed branching" begin
        w = branching_ratio_mr_windowed(sim; level=:pooled, window=150, stride=75, drive=:object_in_view)
        @test length(w[2]) > 0
        wh = branching_ratio_mr_windowed(sim; level=:pooled, window=150, stride=75, drive=:heading_error)
        @test length(wh[2]) == length(w[2])
        @test_throws ArgumentError branching_ratio_mr_windowed(sim; level=:pooled, window=150, stride=75, drive=:bogus)

        c = branching_ratio_mr_conditioned(sim; window=150, stride=75)
        @test hasproperty(c, :m_in) && hasproperty(c, :m_out) && hasproperty(c, :m_diff)
        @test c.n_in + c.n_out > 0
        @test resolve_analysis(:branching_ratio_mr_conditioned) === branching_ratio_mr_conditioned
    end

    @testset "temporal_null (within-network, condition-shuffle)" begin
        cond = object_in_view(sim)
        mfn = (s, c) -> branching_ratio_mr_conditioned(s; condition=c, window=150, stride=75).m_diff
        r1 = temporal_null(sim, cond, mfn; n_shifts=20, rng=MersenneTwister(1))
        r2 = temporal_null(sim, cond, mfn; n_shifts=20, rng=MersenneTwister(1))
        @test isfinite(r1.real)
        @test r1.null_mean == r2.null_mean        # deterministic in the seed
        @test hasproperty(r1, :ratio) && hasproperty(r1, :null_std)
        @test resolve_analysis(:temporal_null) === temporal_null
    end
end
