using BrainlessLab
using Test
using Random

_hfr2_mean(x) = sum(x) / length(x)
_hfr2_frac(pred, x) = count(pred, x) / length(x)

function _hfr2_corr(x, y)
    mx, my = _hfr2_mean(x), _hfr2_mean(y)
    cov = sum((x .- mx) .* (y .- my))
    sx = sqrt(sum((x .- mx) .^ 2))
    sy = sqrt(sum((y .- my) .^ 2))
    return cov / (sx * sy)
end

function _hfr2_port_health(node_kwargs; n_nodes=120, n_receptors=3, n_effectors=2, ticks=300, seed=1)
    r = BrainlessLab.HomeostaticFlowV2Reservoir(n_nodes, n_receptors, n_effectors; seed=seed, node_kwargs...)
    rng = MersenneTwister(seed + 999)
    Es = zeros(Float64, ticks, n_effectors)
    for t in 1:ticks
        R = 0.4 .* randn(rng, n_receptors)
        s = step!(r, R)
        Es[t, :] .= effectors(r, s)
    end
    rms(x) = sqrt(_hfr2_mean(x .^ 2))
    return (
        rms_E=[rms(@view Es[:, k]) for k in 1:n_effectors],
        corr12=n_effectors >= 2 ? _hfr2_corr((@view Es[:, 1]), (@view Es[:, 2])) : NaN,
        frac_near_zero=[_hfr2_frac(<(1e-3), abs.(@view Es[:, k])) for k in 1:n_effectors],
        frac_saturated=[_hfr2_frac(>(5.0), abs.(@view Es[:, k])) for k in 1:n_effectors],
    )
end

@testset "HomeostaticFlowV2 reservoir" begin
    @test :homeostatic_flow_v2 in variants()
    @test genome_type(:homeostatic_flow_v2) === HomeostaticFlowV2Params
    @test paramdim(HomeostaticFlowV2Params) == length(pack_params(HomeostaticFlowV2Params()))

    raw = pack_params(HomeostaticFlowV2Params())
    params = unpack_params(HomeostaticFlowV2Params, raw)
    @test pack_params(params) ≈ raw

    # nonnegative internal activity -- the change that motivated this node --
    # must hold under real input, not just at construction.
    r = BrainlessLab.HomeostaticFlowV2Reservoir(30, 3, 2; seed=11)
    for t in 1:20
        step!(r, [0.3 * sin(t * 0.3), 0.2 * cos(t * 0.2), 0.1])
    end
    @test all(a -> 0.0 <= a <= 1.0, r.a)

    sim = simulate(:wall; node=:homeostatic_flow_v2, ticks=120, seed=0)
    @test sim isa SimResult

    sim_a = simulate(:wall; node=:homeostatic_flow_v2, ticks=80, seed=11)
    sim_b = simulate(:wall; node=:homeostatic_flow_v2, ticks=80, seed=11)
    @test getchannel(sim_a.recorder, :spikes) == getchannel(sim_b.recorder, :spikes)

    tracking = simulate(:tracking; node=:homeostatic_flow_v2, ticks=80, seed=2)
    @test tracking isa SimResult

    reservoir = BrainlessLab.HomeostaticFlowV2Reservoir(30, 2, 2; seed=3)
    @test plasticity(reservoir) isa OnlinePlasticity
    @test plasticity(BrainlessLab.HomeostaticFlowV2Reservoir(30, 2, 2; seed=3, learn_on=false)) isa NoPlasticity

    # step!/effectors must return copies -- a caller retaining values across
    # ticks must not see them silently rewritten by the next tick's mutation.
    history = Vector{Float64}[]
    hr = BrainlessLab.HomeostaticFlowV2Reservoir(10, 2, 2; seed=5)
    for t in 1:5
        push!(history, step!(hr, [0.2, -0.1]))
    end
    @test length(unique(history)) == 5

    replay_source = BrainlessLab.HomeostaticFlowV2Reservoir(25, 2, 2; seed=7)
    step!(replay_source, [0.4, 0.8])
    state = snapshot_state(replay_source)
    replay_copy = BrainlessLab.HomeostaticFlowV2Reservoir(25, 2, 2; seed=7)
    load_state!(replay_copy, state)
    @test step!(replay_copy, [0.9, 0.1]) == step!(replay_source, [0.9, 0.1])

    # every ablation-table combination must construct and run
    for output_mode in (:masked_average, :balanced, :tonic_balanced)
        for heterogeneous_leaks in (false, true), input_plasticity in (false, true),
            recurrent_plasticity in (false, true), novelty_gate in (false, true)

            kwargs = (
                heterogeneous_leaks=heterogeneous_leaks,
                input_plasticity=input_plasticity,
                recurrent_plasticity=recurrent_plasticity,
                novelty_gate=novelty_gate,
                output_mode=output_mode,
            )
            sim = simulate(:wall; node=:homeostatic_flow_v2, ticks=20, seed=1, node_kwargs=kwargs)
            @test sim isa SimResult
        end
    end

    # n_nodes=1 self-loop edge case (recurrent in-degree can't be nonzero
    # without one when there is only one unit)
    r1 = BrainlessLab.HomeostaticFlowV2Reservoir(1, 2, 2; seed=3)
    step!(r1, [0.5, -0.5])

    # Port-health smoke test (default :tonic_balanced mode): a nondegenerate
    # reservoir must still produce a nondegenerate, non-saturated, differentiated
    # effector signal -- the generic, task-agnostic criteria from the V2.1
    # readout fix, not a task score. Guards against the exact regression this
    # fix addressed (rms(E) collapsing toward 0, or effector channels
    # collapsing to near-identical).
    health = _hfr2_port_health(NamedTuple())
    @test all(x -> 0.05 < x < 2.0, health.rms_E)
    @test all(x -> x < 1e-6, health.frac_saturated)
    @test all(x -> x < 0.5, health.frac_near_zero)
    @test abs(health.corr12) < 0.97
end
