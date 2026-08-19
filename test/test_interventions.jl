using BrainlessLab
using Test
using Random

@testset "mid-rollout interventions" begin
    @testset "no-op identity (nothing / empty schedule)" begin
        s0 = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=60, seed=0)
        sn = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=60, seed=0, interventions=nothing)
        se = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=60, seed=0, interventions=[])
        @test s0.metrics.score == sn.metrics.score
        @test s0.metrics.score == se.metrics.score
        @test s0.config.interventions == ()
    end

    @testset "freeze@1 == build-time ablation freeze_plasticity" begin
        sf1 = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=80, seed=0,
                       interventions=[(tick=1, verb=:freeze_plasticity)])
        sab = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=80, seed=0, ablation=:freeze_plasticity)
        @test sf1.metrics.score == sab.metrics.score
        @test sf1.config.interventions == ((1, :freeze_plasticity),)
    end

    @testset "freeze freezes recurrent weights and flips learn_on" begin
        setup = BrainlessLabTestUtils.diagnostic_build_ensemble(
            :tracking,
            :falandays;
            ticks=80,
            seed=0,
            env_kwargs=(randomize_start=false,),
        )
        res = setup.ensemble.agents[1].reservoir
        w0 = copy(res.wmat)
        BrainlessLab.rollout!(setup.ensemble, 80; window=setup.window,
                              interventions=[(1, :freeze_plasticity)])
        @test res.params.learn_on == false
        @test res.wmat == w0

        # control: with learning on, recurrent weights DO change
        setup2 = BrainlessLabTestUtils.diagnostic_build_ensemble(
            :tracking,
            :falandays;
            ticks=80,
            seed=0,
            env_kwargs=(randomize_start=false,),
        )
        res2 = setup2.ensemble.agents[1].reservoir
        w0b = copy(res2.wmat)
        BrainlessLab.rollout!(setup2.ensemble, 80; window=setup2.window)
        @test res2.wmat != w0b
    end

    @testset "schedule validation + entry forms" begin
        @test_throws ArgumentError BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=5,
                                            interventions=[(tick=2, verb=:bogus)])
        @test_throws ArgumentError BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=5,
                                            interventions=[(tick=0, verb=:freeze_plasticity)])
        st = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=20, seed=0,
                      interventions=[(3, :clamp_target)])
        @test st.config.interventions == ((3, :clamp_target),)
        sp = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=20, seed=0,
                      interventions=[5 => :freeze_plasticity])
        @test sp.config.interventions == ((5, :freeze_plasticity),)
    end
end

@testset "typed scheduled interventions" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    composition = composition_spec(registry, :falandays_tracking)
    evaluation = EvaluationSpec(
        blocks=1,
        trials_per_block=1,
        horizon=20,
        root_seed=707,
    )
    continuous = evaluate(
        EvaluationTarget(:continuous, composition, evaluation);
        registry,
        record=(:rate,),
    )
    frozen = evaluate(
        EvaluationTarget(
            :frozen,
            composition,
            evaluation;
            interventions=(ScheduledIntervention(10, :freeze_plasticity),),
        );
        registry,
        record=(:rate,),
    )
    continuous_sim = only(continuous.trials).simulation
    frozen_sim = only(frozen.trials).simulation
    @test frozen_sim.config.interventions == ((10, :freeze_plasticity),)
    @test frozen_sim.recorder.channels[:rate][1:9] ==
          continuous_sim.recorder.channels[:rate][1:9]
    @test task_outcome(frozen_sim).key === :track_score

    warmup = EvaluationSpec(
        blocks=1,
        trials_per_block=1,
        horizon=20,
        warmup=5,
        root_seed=707,
    )
    split = evaluate(
        EvaluationTarget(
            :split,
            composition,
            warmup;
            interventions=(
                ScheduledIntervention(3, :clamp_target),
                ScheduledIntervention(10, :freeze_plasticity),
            ),
        );
        registry,
        record=(:rate,),
    )
    @test only(split.trials).simulation.config.interventions ==
          ((3, :clamp_target), (10, :freeze_plasticity))
    @test length(only(split.trials).simulation.recorder.channels[:rate]) == 15

    @test_throws ArgumentError EvaluationTarget(
        :duplicate,
        composition,
        evaluation;
        interventions=(
            ScheduledIntervention(10, :freeze_plasticity),
            ScheduledIntervention(10, :freeze_plasticity),
        ),
    )
    @test_throws ArgumentError evaluate(
        EvaluationTarget(
            :late,
            composition,
            evaluation;
            interventions=(ScheduledIntervention(21, :freeze_plasticity),),
        );
        registry,
    )
    @test_throws ArgumentError evaluate(
        EvaluationTarget(
            :legacy_only,
            composition,
            evaluation;
            interventions=(ScheduledIntervention(10, :zero_recurrent),),
        );
        registry,
    )
end

@testset "tracking learning-dynamics analyses" begin
    sim = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=1200, seed=0,
                   record=(:rate, :spikes, :scene, :percepts, :spectral_radius),
                   spectral_every=100)

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
        @test BrainlessLab.analysis_meta(:object_in_view).task === :tracking
        blind = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:falandays, ticks=20, record=(:rate,))
        @test_throws ArgumentError object_in_view(blind)
    end

    @testset "drive-conditioned windowed branching" begin
        w = BrainlessLab.branching_ratio_mr_windowed(sim; level=:pooled, window=150, stride=75, drive=:object_in_view)
        @test length(w[2]) > 0
        wh = BrainlessLab.branching_ratio_mr_windowed(sim; level=:pooled, window=150, stride=75, drive=:heading_error)
        @test length(wh[2]) == length(w[2])
        @test_throws ArgumentError BrainlessLab.branching_ratio_mr_windowed(sim; level=:pooled, window=150, stride=75, drive=:bogus)

        c = BrainlessLab.branching_ratio_mr_conditioned(sim; window=150, stride=75)
        @test hasproperty(c, :m_in) && hasproperty(c, :m_out) && hasproperty(c, :m_diff)
        @test c.n_in + c.n_out > 0
        @test resolve_analysis(:branching_ratio_mr_conditioned) ===
              BrainlessLab.branching_ratio_mr_conditioned
    end

    @testset "temporal_null (within-network, condition-shuffle)" begin
        cond = object_in_view(sim)
        mfn = (s, c) -> BrainlessLab.branching_ratio_mr_conditioned(s; condition=c, window=150, stride=75).m_diff
        r1 = BrainlessLab.temporal_null(sim, cond, mfn; n_shifts=20, rng=MersenneTwister(1))
        r2 = BrainlessLab.temporal_null(sim, cond, mfn; n_shifts=20, rng=MersenneTwister(1))
        @test isfinite(r1.real)
        @test r1.null_mean == r2.null_mean        # deterministic in the seed
        @test hasproperty(r1, :ratio) && hasproperty(r1, :null_std)
        @test resolve_analysis(:temporal_null) === BrainlessLab.temporal_null
    end

    @testset "registered tracking plasticity diagnostic" begin
        result = tracking_plasticity_diagnostics(
            sim;
            window=150,
            stride=75,
            kmax=20,
            heading_bins=12,
        )
        @test result isa AnalysisResult
        @test result.statistics.window == 150.0
        @test Tuple(series.id for series in result.series) ==
              (:over_time, :by_heading_error)
        @test length(result.series[1].coordinates) > 0
        @test length(result.series[2].coordinates) == 12
        @test resolve_analysis(:tracking_plasticity_diagnostics) ===
              tracking_plasticity_diagnostics
        @test BrainlessLab.analysis_meta(:tracking_plasticity_diagnostics).task ===
              :tracking
    end
end
