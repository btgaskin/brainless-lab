using BrainlessLab
using Test

function _single_agent_rates(sim)
    return [sum(entry[1]) / length(entry[1]) for entry in getchannel(sim.recorder, :spikes)]
end

@testset "SORN reservoir" begin
    @test :sorn in variants()
    @test genome_type(:sorn) === SORNParams
    @test paramdim(SORNParams) == length(pack_params(SORNParams()))

    raw = pack_params(SORNParams())
    params = unpack_params(SORNParams, raw)
    @test pack_params(params) ≈ raw

    sim = simulate(:wall; node=:sorn, ticks=200, seed=0)
    rates = _single_agent_rates(sim)
    mean_rate = sum(rates) / length(rates)
    @test 0.01 < mean_rate < 0.99
    @test any(>(0.0), rates)
    @test any(<(1.0), rates)

    sim_a = simulate(:wall; node=:sorn, ticks=120, seed=11)
    sim_b = simulate(:wall; node=:sorn, ticks=120, seed=11)
    @test getchannel(sim_a.recorder, :spikes) == getchannel(sim_b.recorder, :spikes)

    tracking = simulate(:tracking; node=:sorn, ticks=80, seed=2)
    @test tracking isa SimResult
    @test !isempty(getchannel(tracking.recorder, :spikes))

    reservoir = SORNReservoir(30, 2, 2; seed=3)
    @test plasticity(reservoir) isa OnlinePlasticity

    replay_source = SORNReservoir(25, 2, 2; seed=7)
    step!(replay_source, [0.4, 0.8])
    state = snapshot_state(replay_source)
    replay_copy = SORNReservoir(25, 2, 2; seed=7)
    load_state!(replay_copy, state)
    @test step!(replay_copy, [0.9, 0.1]) == step!(replay_source, [0.9, 0.1])

    frozen = SORNReservoir(30, 2, 2; seed=4, learn_on=false)
    weights_before = copy(frozen.W_EE)
    thresholds_before = copy(frozen.T_E)
    step!(frozen, [0.75, 0.25])
    @test frozen.W_EE == weights_before
    @test frozen.T_E == thresholds_before
end
