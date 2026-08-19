using BrainlessLab
using Test

import BrainlessLab: effectors, n_effectors, n_nodes, n_receptors, reset!, step!

mutable struct _CycleCounterReservoir <: Reservoir
    steps::Int
    nr::Int
    ne::Int
end

n_receptors(reservoir::_CycleCounterReservoir) = reservoir.nr
n_effectors(reservoir::_CycleCounterReservoir) = reservoir.ne
n_nodes(::_CycleCounterReservoir) = 2
function step!(reservoir::_CycleCounterReservoir, receptors)
    reservoir.steps += 1
    return Float64[reservoir.steps, sum(receptors)]
end
effectors(reservoir::_CycleCounterReservoir, neural_output) =
    Float64[neural_output[index] for index in 1:reservoir.ne]
reset!(reservoir::_CycleCounterReservoir) = (reservoir.steps = 0; reservoir)

@testset "FixedRateCycle owns world-to-neural timing" begin
    @test BrainlessLab.neural_frames(BrainlessLab.FixedRateCycle()) == 1
    @test BrainlessLab.neural_frames(BrainlessLab.FixedRateCycle(24)) == 24
    @test_throws ArgumentError BrainlessLab.FixedRateCycle(0)

    body = BrainlessLab.direct_embodiment(2, 2; readouts=(BrainlessLab.MeanReadout(),))
    reservoir = _CycleCounterReservoir(0, 2, 2)
    agent = BrainlessLab.Agent(reservoir, body; cycle=BrainlessLab.FixedRateCycle(4))
    # The interaction helper is tested directly because WallEnv's native
    # observation width is unrelated to this minimal contract reservoir.
    receptors, neural, command = BrainlessLab._run_interaction!(agent, [0.25, 0.75])
    @test reservoir.steps == 4
    @test receptors == [0.25, 0.75]
    @test neural == [2.5, 1.0]
    @test BrainlessLab.command_values(command) == [1.0, 1.0]
end

@testset "default cycle preserves held-input window semantics" begin
    receptors = [0.3, 0.7, 0.1, 0.5]
    windowed = BrainlessLab._falandays_native(20, 4, 2; seed=5, substeps=3)
    manual = BrainlessLab._falandays_native(20, 4, 2; seed=5, substeps=1)
    agent = BrainlessLab.Agent(windowed, BrainlessLab.direct_embodiment(4, 2))
    held, neural_mean, _ = BrainlessLab._run_interaction!(agent, receptors)
    manual_outputs = [step!(manual, receptors) for _ in 1:3]
    @test held ≈ receptors
    @test neural_mean ≈ sum(manual_outputs) ./ 3
end

@testset "readout reductions are explicit and deterministic" begin
    reservoir = _CycleCounterReservoir(0, 1, 2)
    cycle = BrainlessLab.FixedRateCycle(3)

    mean_readout = BrainlessLab.MeanReadout()
    mean_state = BrainlessLab.readout_state(mean_readout, reservoir)
    BrainlessLab.begin_readout!(mean_state, mean_readout, cycle)
    for (frame, output) in enumerate(([1.0, 0.0], [0.0, 1.0], [1.0, 1.0]))
        BrainlessLab.observe_frame!(mean_state, mean_readout, reservoir, output, frame)
    end
    @test BrainlessLab.finish_readout!(mean_state, mean_readout, reservoir, cycle) ≈ [2 / 3, 2 / 3]

    voting = BrainlessLab.VotingReadout()
    voting_state = BrainlessLab.readout_state(voting, reservoir)
    BrainlessLab.begin_readout!(voting_state, voting, cycle)
    for (frame, output) in enumerate(([0.5, 0.5], [0.0, 1.0], [1.0, 0.0]))
        BrainlessLab.observe_frame!(voting_state, voting, reservoir, output, frame)
    end
    # Equal cumulative activity chooses the lower index.
    @test BrainlessLab.finish_readout!(voting_state, voting, reservoir, cycle) == [1.0, 0.0]
    @test BrainlessLab._readout_config(voting).aggregation === :cumulative_activity

    silent_cycle = BrainlessLab.FixedRateCycle(24)
    BrainlessLab.begin_readout!(voting_state, voting, silent_cycle)
    outputs = vcat(
        fill([0.0, 0.0], 15),
        fill([1.0, 0.0], 4),
        fill([0.0, 1.0], 5),
    )
    for (frame, output) in enumerate(outputs)
        BrainlessLab.observe_frame!(voting_state, voting, reservoir, output, frame)
    end
    # Silent frames do not become first-index votes. Cumulative output spikes
    # are 4 left and 5 right, so the source-compatible action is right.
    @test BrainlessLab.finish_readout!(
        voting_state,
        voting,
        reservoir,
        silent_cycle,
    ) == [0.0, 1.0]
end

@testset "Embodiment owns its readout component" begin
    body = BrainlessLab.direct_embodiment(2, 2; readouts=(BrainlessLab.InstantReadout(),))
    @test only(BrainlessLab.readout_components(body)) isa BrainlessLab.InstantReadout
    @test BrainlessLab.primary_readout(body) === only(body.readouts)
    @test BrainlessLab.component_id(only(BrainlessLab.component_slots(body).readouts)) === :readout_1
    @test BrainlessLab.readout_policy(body) === BrainlessLab.PASSTHROUGH_MOTOR
end
