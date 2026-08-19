using BrainlessLab
using Test

mutable struct GainProbe <: Reservoir
    seen::Vector{Vector{Float64}}
end
BrainlessLab.n_nodes(::GainProbe) = 2
BrainlessLab.n_receptors(::GainProbe) = 2
BrainlessLab.n_effectors(::GainProbe) = 2
BrainlessLab.reset!(probe::GainProbe) = (empty!(probe.seen); probe)
function BrainlessLab.step!(probe::GainProbe, receptors)
    push!(probe.seen, Float64.(receptors))
    return [1.0, 0.0]
end
BrainlessLab.effectors(::GainProbe, output) = Float64.(output)

@testset "direct-control benchmark specification" begin
    spec = DIRECT_CONTROL_BENCHMARK
    @test spec.state === :frozen
    @test spec.n_nodes == 200
    @test Tuple(protocol.task for protocol in spec.task_protocols) ==
        (:tracking, :pong, :cartpole_plank_easy)
    @test Set(profile.node for profile in spec.profiles) == Set((:falandays, :sorn))
    @test benchmark_plan(spec) isa BenchmarkPlan

    @test DIRECT_CONTROL_INPUT_GAINS == (
        (profile=:falandays_direct_v1, task=:tracking, input_gain=1.0),
        (profile=:sorn_direct_v1, task=:tracking, input_gain=4.0),
        (profile=:falandays_direct_v1, task=:pong, input_gain=1.0),
        (profile=:sorn_direct_v1, task=:pong, input_gain=32.0),
        (profile=:falandays_direct_v1, task=:cartpole_plank_easy, input_gain=8.0),
        (profile=:sorn_direct_v1, task=:cartpole_plank_easy, input_gain=8.0),
    )
    @test DIRECT_CONTROL_EXPERIMENT.evidence_state === :frozen
    confirmation = benchmark_plan(spec)
    @test Tuple(condition.id for condition in DIRECT_CONTROL_EXPERIMENT.conditions) == Tuple(
        condition.id
        for case in confirmation.cases
        for condition in case.conditions
    )
    @test only(DIRECT_CONTROL_EXPERIMENT.operations).id === confirmation.id

    plans = calibration_plans(spec)
    @test length(plans) == 6
    @test all(plan -> only(plan.axes).scope === :interface, plans)
    @test all(plan -> only(plan.axes).parameter === :input_gain, plans)
    @test all(plan -> plan.target.evaluation.blocks == 16, plans)
    @test all(plan -> plan.target.composition.n_nodes == 200, plans)
    @test all(plan -> isempty(plan.target.composition.task_options), plans)
    @test all(plan -> plan.target.composition.body === nothing, plans)
    @test all(plan -> plan.target.composition.interaction_cycle === nothing, plans)

    planned = BrainlessLab._DIRECT_CONTROL_BENCHMARK_DEVELOPMENT
    selections = Dict(
        (entry.profile, entry.task) => 1.0
        for entry in planned.entries
    )
    frozen = freeze_benchmark(planned, selections)
    @test frozen.state === :frozen
    plan = benchmark_plan(frozen)
    @test length(plan.cases) == 3
    @test all(case -> length(case.conditions) == 2, plan.cases)
    @test all(
        condition -> condition.composition.n_nodes == 200 &&
                     condition.composition.interface.input_gain == 1.0 &&
                     condition.model === nothing,
        (condition for case in plan.cases for condition in case.conditions),
    )
    @test all(
        condition -> condition.evaluation.blocks == 32 &&
                     condition.evaluation.trials_per_block == 1,
        (condition for case in plan.cases for condition in case.conditions),
    )

    for profile in planned.profiles
        conditions = [
            condition
            for case in plan.cases
            for condition in case.conditions
            if condition.topology_key === profile.id
        ]
        @test length(conditions) == 3
        @test all(condition -> condition.composition.parameters == profile.parameters, conditions)
    end

    @test_throws ArgumentError freeze_benchmark(planned, Dict((:missing, :tracking) => 1.0))
    out_of_grid = copy(selections)
    out_of_grid[(:falandays_direct_v1, :tracking)] = 3.0
    @test_throws ArgumentError freeze_benchmark(planned, out_of_grid)
    @test_throws ArgumentError freeze_benchmark(frozen, selections)
    @test_throws MethodError InterfaceSpec(input_gain=1.0, output_gain=2.0)

    lower = BrainlessLab._select_profile_candidate((
        (gain=2.0, profile_value=4.0, profile_direction=:lower),
        (gain=1.0, profile_value=4.0, profile_direction=:lower),
        (gain=4.0, profile_value=5.0, profile_direction=:lower),
    ))
    higher = BrainlessLab._select_profile_candidate((
        (gain=2.0, profile_value=4.0, profile_direction=:higher),
        (gain=1.0, profile_value=4.0, profile_direction=:higher),
        (gain=4.0, profile_value=3.0, profile_direction=:higher),
    ))
    @test lower.gain == 1.0
    @test higher.gain == 1.0
end

@testset "interface gain acts after frame encoding" begin
    body = BrainlessLab.direct_embodiment(2, 2; readouts=(BrainlessLab.MeanReadout(),))
    identity_probe = GainProbe(Vector{Vector{Float64}}())
    gained_probe = GainProbe(Vector{Vector{Float64}}())
    identity = BrainlessLab.Agent(identity_probe, body; interface=InterfaceSpec())
    gained = BrainlessLab.Agent(
        gained_probe,
        deepcopy(body);
        interface=InterfaceSpec(input_gain=4.0),
    )
    BrainlessLab._run_interaction!(identity, [0.25, 0.5])
    BrainlessLab._run_interaction!(gained, [0.25, 0.5])
    @test only(identity_probe.seen) == [0.25, 0.5]
    @test only(gained_probe.seen) == [1.0, 2.0]
end
