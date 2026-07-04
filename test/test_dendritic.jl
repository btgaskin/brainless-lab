using BrainlessLab
using Test

@testset "Dendritic (eligibility-tag) node" begin
    @testset "registration + build" begin
        @test :falandays_dendritic in variants()
        r = DendriticReservoir(40, 3, 2; seed=1)
        @test n_receptors(r) == 3
        @test n_effectors(r) == 2
        @test size(r.wmat) == (40, 40)
        @test size(r.dend_id) == (40, 40)
        # dend_id is assigned exactly on recurrent edges (1..n_dendrites), 0 elsewhere.
        @test all((r.dend_id .!= 0) .== r.recurrent_mask)
        @test all(d -> 1 <= d <= 4, r.dend_id[r.recurrent_mask])
        @test size(r.dend_acts) == (40, 4)
    end

    @testset "determinism by seed" begin
        r1 = DendriticReservoir(30, 2, 2; seed=42)
        r2 = DendriticReservoir(30, 2, 2; seed=42)
        @test r1.wmat == r2.wmat
        @test r1.dend_id == r2.dend_id
        inp = [0.4, 0.3]
        for _ in 1:50
            @test step!(r1, inp) == step!(r2, inp)
        end
        @test r1.wmat == r2.wmat
        @test r1.targets == r2.targets
    end

    @testset "learns + stays alive on :wall" begin
        sim = simulate(:wall; node=:falandays_dendritic, ticks=300, seed=0)
        @test isfinite(sim.metrics.score)

        r = DendriticReservoir(60, 3, 2; seed=3)
        inp = [0.6, 0.2, 0.1]
        fired = false
        for _ in 1:300
            s = step!(r, inp)
            fired |= any(!=(0.0), s)
        end
        @test fired                          # network is not silent
        @test any(r.wmat .!= r.wmat0)        # recurrent weights learned
    end

    @testset "eligibility gate widens plasticity" begin
        # With no presynaptic spikes, base-style plasticity would make no update.
        # A dendritic spike (forced via a large dendritic drive) must still license
        # a weight change — the defining feature of this variant.
        driven = DendriticReservoir(8, 2, 2; seed=7,
                                    link_p=1.0, dend_drive=50.0, drive_floor=50.0)
        w0 = copy(driven.wmat)
        step!(driven, [0.0, 0.0])            # first tick: prev_spikes all zero
        @test any(driven.wmat .!= w0)

        # No dendritic drive + no presynaptic spikes ⇒ no recurrent weight change.
        quiet = DendriticReservoir(8, 2, 2; seed=7,
                                   link_p=1.0, dend_drive=0.0)
        wq = copy(quiet.wmat)
        step!(quiet, [0.0, 0.0])
        @test quiet.wmat == wq
    end

    @testset "eligibility_only=false injects somatic current" begin
        # Dendritic spikes should raise somatic activation when not eligibility-only.
        r = DendriticReservoir(12, 2, 2; seed=5,
                               link_p=1.0, dend_drive=50.0, drive_floor=50.0,
                               eligibility_only=false)
        # Seed some recurrent activity so dendrites receive input, then step.
        step!(r, [1.0, 1.0])
        s = step!(r, [0.0, 0.0])
        @test all(isfinite, r.acts)
        @test any(!=(0.0), s) || any(r.dend_acts .!= 0.0)
    end

    @testset "reset! restores initial state" begin
        r = DendriticReservoir(20, 2, 2; seed=9)
        inp = [0.5, 0.5]
        for _ in 1:40
            step!(r, inp)
        end
        reset!(r)
        @test r.wmat == r.wmat0
        @test all(==(0.0), r.acts)
        @test all(==(1.0), r.targets)
        @test all(==(0.0), r.spikes)
        @test all(==(0.0), r.dend_acts)
    end
end
