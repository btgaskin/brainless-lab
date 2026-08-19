using BrainlessLab
using Test

function _single_agent_rates(sim)
    return [sum(entry[1]) / length(entry[1]) for entry in getchannel(sim.recorder, :spikes)]
end

@testset "SORN reservoir" begin
    @test :sorn in variants()
    @test BrainlessLab.genome_type(:sorn) === BrainlessLab.SORNParams
    @test node_spec(DEFAULT_REGISTRY, :sorn).stability === :stable
    @test paramdim(BrainlessLab.SORNParams) == length(pack_params(BrainlessLab.SORNParams()))

    raw = pack_params(BrainlessLab.SORNParams())
    params = unpack_params(BrainlessLab.SORNParams, raw)
    @test pack_params(params) ≈ raw

    sim = BrainlessLabTestUtils.diagnostic_simulate(:wall; node=:sorn, ticks=200, seed=0)
    rates = _single_agent_rates(sim)
    mean_rate = sum(rates) / length(rates)
    @test 0.01 < mean_rate < 0.99
    @test any(>(0.0), rates)
    @test any(<(1.0), rates)

    sim_a = BrainlessLabTestUtils.diagnostic_simulate(:wall; node=:sorn, ticks=120, seed=11)
    sim_b = BrainlessLabTestUtils.diagnostic_simulate(:wall; node=:sorn, ticks=120, seed=11)
    @test getchannel(sim_a.recorder, :spikes) == getchannel(sim_b.recorder, :spikes)

    tracking = BrainlessLabTestUtils.diagnostic_simulate(:tracking; node=:sorn, ticks=80, seed=2)
    @test tracking isa SimResult
    @test !isempty(getchannel(tracking.recorder, :spikes))

    reservoir = BrainlessLab.SORNReservoir(30, 2, 2; seed=3)
    @test n_nodes(reservoir) == 30
    @test reservoir.N_E == 25
    @test reservoir.N_I == 5
    @test length(step!(reservoir, [0.0, 0.0])) == 30
    resources = BrainlessLab.resource_report(reservoir)
    @test resources.dynamic_nodes == 30
    @test resources.excitatory_nodes == 25
    @test resources.inhibitory_nodes == 5
    @test plasticity(reservoir) isa OnlinePlasticity

    replay_source = BrainlessLab.SORNReservoir(25, 2, 2; seed=7)
    step!(replay_source, [0.4, 0.8])
    state = snapshot_state(replay_source)
    replay_copy = BrainlessLab.SORNReservoir(25, 2, 2; seed=7)
    load_state!(replay_copy, state)
    @test step!(replay_copy, [0.9, 0.1]) == step!(replay_source, [0.9, 0.1])

    frozen = BrainlessLab.SORNReservoir(30, 2, 2; seed=4, learn_on=false)
    @test plasticity(frozen) isa NoPlasticity
    weights_before = copy(frozen.W_EE)
    thresholds_before = copy(frozen.T_E)
    step!(frozen, [0.75, 0.25])
    @test frozen.W_EE == weights_before
    @test frozen.T_E == thresholds_before
end

@testset "SORN structural plasticity and fixed fanout" begin
    reservoir = BrainlessLab.SORNReservoir(200, 8, 2; seed=9)
    @test reservoir.N_E == 167
    @test reservoir.N_I == 33
    @test all(sum(reservoir.W_EU .> 0.0; dims=1) .== 8)
    @test all(sum(reservoir.output_mask; dims=1) .== 8)

    edge = findfirst(reservoir.EE_mask)
    @test edge !== nothing
    reservoir.W_EE[edge] = 0.0005
    reservoir.x .= 0.0
    reservoir.prev_x .= 0.0
    reservoir.prev_x[edge[2]] = 1.0
    reservoir.x[edge[1]] = 0.0
    reservoir.prev_x[edge[1]] = 1.0
    reservoir.x[edge[2]] = 1.0
    BrainlessLab._sorn_stdp!(reservoir)
    @test reservoir.W_EE[edge] == 0.0
    @test !reservoir.EE_mask[edge]
    reset!(reservoir)
    @test reservoir.EE_mask[edge]
    @test reservoir.W_EE[edge] == reservoir.W_EE0[edge]
end
