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
    @test neural_frames(FixedRateCycle()) == 1
    @test neural_frames(FixedRateCycle(24)) == 24
    @test_throws ArgumentError FixedRateCycle(0)

    body = direct_embodiment(2, 2; readouts=(MeanReadout(),))
    reservoir = _CycleCounterReservoir(0, 2, 2)
    agent = Agent(reservoir, body; cycle=FixedRateCycle(4))
    # The interaction helper is tested directly because WallEnv's native
    # observation width is unrelated to this minimal contract reservoir.
    receptors, neural, command = BrainlessLab._run_interaction!(agent, [0.25, 0.75])
    @test reservoir.steps == 4
    @test receptors == [0.25, 0.75]
    @test neural == [2.5, 1.0]
    @test command_values(command) == [1.0, 1.0]
end

@testset "default cycle preserves held-input window semantics" begin
    receptors = [0.3, 0.7, 0.1, 0.5]
    windowed = BrainlessLab._falandays_native(20, 4, 2; seed=5, substeps=3)
    manual = BrainlessLab._falandays_native(20, 4, 2; seed=5, substeps=1)
    agent = Agent(windowed, direct_embodiment(4, 2))
    held, neural_mean, _ = BrainlessLab._run_interaction!(agent, receptors)
    manual_outputs = [step!(manual, receptors) for _ in 1:3]
    @test held ≈ receptors
    @test neural_mean ≈ sum(manual_outputs) ./ 3
end

@testset "readout reductions are explicit and deterministic" begin
    reservoir = _CycleCounterReservoir(0, 1, 2)
    cycle = FixedRateCycle(3)

    mean_readout = MeanReadout()
    mean_state = BrainlessLab.readout_state(mean_readout, reservoir)
    begin_readout!(mean_state, mean_readout, cycle)
    for (frame, output) in enumerate(([1.0, 0.0], [0.0, 1.0], [1.0, 1.0]))
        observe_frame!(mean_state, mean_readout, reservoir, output, frame)
    end
    @test finish_readout!(mean_state, mean_readout, reservoir, cycle) ≈ [2 / 3, 2 / 3]

    voting = VotingReadout()
    voting_state = BrainlessLab.readout_state(voting, reservoir)
    begin_readout!(voting_state, voting, cycle)
    for (frame, output) in enumerate(([0.5, 0.5], [0.0, 1.0], [1.0, 0.0]))
        observe_frame!(voting_state, voting, reservoir, output, frame)
    end
    # Both the frame-one tie and the final vote tie choose the lower index.
    @test finish_readout!(voting_state, voting, reservoir, cycle) == [1.0, 0.0]
end

@testset "Embodiment owns its readout component" begin
    body = direct_embodiment(2, 2; readouts=(InstantReadout(),))
    @test only(readout_components(body)) isa InstantReadout
    @test primary_readout(body) === only(body.readouts)
    @test component_id(only(component_slots(body).readouts)) === :readout_1
    @test readout_policy(body) === BrainlessLab.PASSTHROUGH_MOTOR
end
