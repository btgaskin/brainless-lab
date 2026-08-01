using BrainlessLab
using Random
using Test

struct _NeedWallSetup end

const _RECEPTOR_PROFILE_CAPTURE = Ref{Any}(nothing)
function _profile_aware_test_node(
    n_nodes,
    n_receptors,
    n_effectors;
    seed=0,
    input_link_p=nothing,
    kwargs...,
)
    _RECEPTOR_PROFILE_CAPTURE[] = copy(input_link_p)
    return BrainlessLab.NullRandomReservoir(n_nodes, n_receptors, n_effectors; seed=seed)
end

function _regulated_direct(n_receptors, n_effectors, variables; seed=0)
    return BrainlessLab.direct_embodiment(
        n_receptors,
        n_effectors;
        physiology=BrainlessLab.RegulatedPhysiology(variables; seed=seed),
    )
end

function _feedback_trace!(physiology, n_ticks::Integer)
    names = Tuple(variable.name for variable in physiology.variables)
    traces = Dict(name => Float64[] for name in names)
    for _ in 1:n_ticks
        feedback = BrainlessLab.physiology_feedback!(physiology)
        for (index, name) in enumerate(names)
            push!(traces[name], feedback[index])
        end
        BrainlessLab.physiology_update!(physiology)
    end
    return traces
end

function (::_NeedWallSetup)(; seed=0, rng=nothing, body=nothing, n_nodes=8, kwargs...)
    env_rng = rng === nothing ? MersenneTwister(seed) : rng
    env = BrainlessLab.WallEnv(; rng=env_rng)
    need = BrainlessLab.RegulatedVariable(
        :hunger;
        initial=0.5,
        drift=-0.5,
        mode=BrainlessLab.TonicFeedback(),
        link_p=1.0,
        failure=BrainlessLab.BelowFailure(0.0),
    )
    return TaskSetup(env, [_regulated_direct(2, 2, (need,); seed=seed + 100)])
end

@testset "Need curves and signal modes" begin
    @test BrainlessLab.response_value(BrainlessLab.ConstantResponse(0.3), 0.9) == 0.3
    @test BrainlessLab.response_value(BrainlessLab.LinearResponse(), 0.4) == 0.4
    @test BrainlessLab.response_value(BrainlessLab.PowerResponse(2), 0.5) == 0.25
    @test BrainlessLab.response_value(BrainlessLab.LogisticResponse(), 0.0) ≈ 0.0 atol=eps()
    @test BrainlessLab.response_value(BrainlessLab.LogisticResponse(), 1.0) ≈ 1.0 atol=eps()
    @test BrainlessLab.response_value(BrainlessLab.LogisticResponse(1e-20), 0.37) ≈ 0.37
    @test isfinite(BrainlessLab.response_value(BrainlessLab.LogisticResponse(1e6), 0.5))
    @test BrainlessLab.response_value(BrainlessLab.ThresholdResponse(0.4), 0.39) == 0.0
    @test_throws ArgumentError BrainlessLab.response_value(BrainlessLab.LinearResponse(), 1.1)
    @test_throws ArgumentError BrainlessLab.response_value(x -> 2x, 0.75)

    linear = BrainlessLab.RegulatedVariable(:hunger; initial=0.25)
    @test BrainlessLab.regulation_urgency(linear, 0.25) ≈ 0.75

    power = BrainlessLab.RegulatedVariable(:hunger; initial=0.25, curve=BrainlessLab.PowerFeedback(2.0))
    @test BrainlessLab.regulation_urgency(power, 0.25) ≈ 0.75^2
    @test BrainlessLab.regulation_urgency(BrainlessLab.RegulatedVariable(:x; curve=BrainlessLab.LogisticFeedback()), 0.0) ≈ 1.0
    @test BrainlessLab.regulation_urgency(BrainlessLab.RegulatedVariable(:x; curve=BrainlessLab.ThresholdFeedback(0.4)), 0.5) == 1.0
    @test BrainlessLab.regulation_urgency(BrainlessLab.RegulatedVariable(:x; curve=x -> x / 2), 0.0) ≈ 0.5
    @test_throws ArgumentError BrainlessLab.regulation_urgency(BrainlessLab.RegulatedVariable(:x; curve=x -> 2x), 0.0)
    @test_throws ArgumentError BrainlessLab.BelowFailure(NaN)

    off = _regulated_direct(1, 1, (BrainlessLab.RegulatedVariable(:x; initial=0.0),); seed=4)
    @test BrainlessLab.sense!(off, [0.2]) == [0.2, 0.0]
    @test BrainlessLab.sense!(off, [0.2]) === BrainlessLab.sense!(off, [0.2])

    tonic = _regulated_direct(
        1,
        1,
        (BrainlessLab.RegulatedVariable(:x; initial=0.0, mode=BrainlessLab.TonicFeedback(), gain=2.5),);
        seed=4,
    )
    @test BrainlessLab.sense!(tonic, [0.2]) == [0.2, 2.5]

    spike = _regulated_direct(
        1,
        1,
        (BrainlessLab.RegulatedVariable(:x; initial=0.0, mode=BrainlessLab.BernoulliFeedback(), emission_p=1.0, gain=3.0),);
        seed=4,
    )
    @test BrainlessLab.sense!(spike, [0.2]) == [0.2, 3.0]
end

@testset "Atomic need updates, rescue, mortality, and reset" begin
    need = BrainlessLab.RegulatedVariable(
        :hunger;
        initial=0.1,
        drift=-0.2,
        mode=BrainlessLab.BernoulliFeedback(),
        emission_p=0.5,
        failure=BrainlessLab.BelowFailure(0.0),
    )
    rescued = _regulated_direct(1, 1, (need,); seed=8)
    BrainlessLab.update!(rescued, (BrainlessLab.Exposure(:hunger, 0.2), BrainlessLab.Exposure(:hunger, 0.1)))
    @test BrainlessLab.regulated_values(rescued).hunger ≈ 0.2
    @test BrainlessLab.alive(rescued)

    doomed = _regulated_direct(1, 1, (need,); seed=8)
    BrainlessLab.update!(doomed)
    @test !BrainlessLab.alive(doomed)
    @test doomed.physiology.death_tick == 1
    @test doomed.physiology.death_cause == :hunger
    @test all(iszero, BrainlessLab.sense!(doomed, [1.0]))

    reset!(rescued)
    sequence_a = Float64[]
    for _ in 1:8
        push!(sequence_a, last(BrainlessLab.sense!(rescued, [0.0])))
        BrainlessLab.update!(rescued, (BrainlessLab.Exposure(:hunger, 0.2),))
    end
    reset!(rescued)
    sequence_b = Float64[]
    for _ in 1:8
        push!(sequence_b, last(BrainlessLab.sense!(rescued, [0.0])))
        BrainlessLab.update!(rescued, (BrainlessLab.Exposure(:hunger, 0.2),))
    end
    @test sequence_a == sequence_b

    needs = (
        BrainlessLab.RegulatedVariable(:hunger),
        BrainlessLab.RegulatedVariable(:temperature; deficit=BrainlessLab.SetpointDistance()),
    )
    multiple = _regulated_direct(1, 1, needs)
    @test [port.id for port in BrainlessLab.ports(multiple).receptors[end-1:end]] ==
          [:physiology__regulated_hunger, :physiology__regulated_temperature]
    @test_throws ArgumentError BrainlessLab.expose!(multiple, BrainlessLab.Exposure(:missing, 1.0))

    coupled = _regulated_direct(1, 1, (
        BrainlessLab.RegulatedVariable(:hunger; initial=0.4, drift=-0.1),
        BrainlessLab.RegulatedVariable(
            :thirst;
            initial=0.4,
            drift=-0.2,
            curve=BrainlessLab.PowerFeedback(2.0),
            mode=BrainlessLab.TonicFeedback(),
            failure=BrainlessLab.BelowFailure(0.25),
        ),
    ))
    BrainlessLab.update!(coupled, (BrainlessLab.Exposure(:hunger, 0.2), BrainlessLab.Exposure(:thirst, 0.05)))
    @test BrainlessLab.regulated_values(coupled).hunger ≈ 0.5
    @test BrainlessLab.regulated_values(coupled).thirst ≈ 0.25
    @test !BrainlessLab.alive(coupled)
    @test coupled.physiology.death_cause === :thirst
end


@testset "Bernoulli feedback rate and amplitude" begin
    need = BrainlessLab.RegulatedVariable(
        :hunger;
        initial=0.5,
        setpoint=1.0,
        mode=BrainlessLab.BernoulliFeedback(),
        emission_p=0.2,
        gain=3.0,
    )
    body = _regulated_direct(
        1,
        1,
        (need,);
        seed=17,
    )
    emissions = Float64[]
    for _ in 1:20_000
        push!(emissions, last(BrainlessLab.sense!(body, [0.0])))
        BrainlessLab.update!(body)
    end
    @test all(value -> value == 0.0 || value == 3.0, emissions)
    @test count(==(3.0), emissions) / length(emissions) ≈ 0.1 atol=0.01
end

@testset "Feedback RNG streams are tick-stable and compositional" begin
    zero_probability = BrainlessLab.RegulatedVariable(
        :zero;
        initial=0.0,
        mode=BrainlessLab.BernoulliFeedback(),
        emission_p=0.0,
    )
    rng = MersenneTwister(91)
    @test BrainlessLab.emit_feedback(BrainlessLab.BernoulliFeedback(), zero_probability, 1.0, rng) == 0.0
    reference_rng = MersenneTwister(91)
    rand(reference_rng)
    @test rand(rng) == rand(reference_rng)

    energy = BrainlessLab.RegulatedVariable(
        :energy;
        initial=0.0,
        mode=BrainlessLab.BernoulliFeedback(),
        emission_p=0.41,
    )
    hydration = BrainlessLab.RegulatedVariable(
        :hydration;
        initial=0.0,
        mode=BrainlessLab.BernoulliFeedback(),
        emission_p=0.37,
    )
    social = BrainlessLab.RegulatedVariable(
        :social;
        initial=0.0,
        mode=BrainlessLab.BernoulliFeedback(),
        emission_p=0.29,
    )
    ordered = BrainlessLab.RegulatedPhysiology((energy, hydration); seed=29)
    reordered = BrainlessLab.RegulatedPhysiology((hydration, energy); seed=29)
    extended = BrainlessLab.RegulatedPhysiology((social, energy, hydration); seed=29)
    ordered_trace = _feedback_trace!(ordered, 256)
    reordered_trace = _feedback_trace!(reordered, 256)
    extended_trace = _feedback_trace!(extended, 256)
    @test ordered_trace[:energy] == reordered_trace[:energy] == extended_trace[:energy]
    @test ordered_trace[:hydration] ==
          reordered_trace[:hydration] ==
          extended_trace[:hydration]

    sampled_twice = BrainlessLab.RegulatedPhysiology((energy, hydration); seed=43)
    sampled_once = BrainlessLab.RegulatedPhysiology((energy, hydration); seed=43)
    destination = fill(NaN, 2)
    for _ in 1:128
        first = BrainlessLab.physiology_feedback!(sampled_twice)
        returned = BrainlessLab.physiology_feedback!(destination, sampled_twice)
        @test returned === destination
        @test destination == first
        @test BrainlessLab.physiology_feedback!(sampled_twice) == first
        @test BrainlessLab.physiology_feedback!(sampled_once) == first
        BrainlessLab.physiology_update!(sampled_twice)
        BrainlessLab.physiology_update!(sampled_once)
    end
    @test_throws DimensionMismatch BrainlessLab.physiology_feedback!(zeros(1), sampled_once)

    BrainlessLab.physiology_reset!(sampled_twice)
    reset_trace_a = _feedback_trace!(sampled_twice, 128)
    BrainlessLab.physiology_reset!(sampled_twice)
    reset_trace_b = _feedback_trace!(sampled_twice, 128)
    @test reset_trace_a == reset_trace_b
end

@testset "Replay feedback is indexed, cyclic, and resettable" begin
    need = BrainlessLab.RegulatedVariable(
        :hunger;
        initial=0.0,
        mode=BrainlessLab.ReplayFeedback([0.0, 2.0, 0.5]),
    )
    body = _regulated_direct(1, 1, (need,); seed=17)
    values = Float64[]
    for _ in 1:5
        push!(values, last(BrainlessLab.sense!(body, [0.0])))
        BrainlessLab.update!(body)
    end
    @test values == [0.0, 2.0, 0.5, 0.0, 2.0]

    reset!(body)
    @test last(BrainlessLab.sense!(body, [0.0])) == 0.0
    @test_throws ArgumentError BrainlessLab.ReplayFeedback(Float64[])
    @test_throws ArgumentError BrainlessLab.ReplayFeedback([NaN])
    @test_throws BoundsError BrainlessLab.emit_feedback(
        BrainlessLab.ReplayFeedback([1.0]; cycle=false),
        need,
        0.0,
        MersenneTwister(1),
        2,
    )
end

@testset "Per-receptor Falandays wiring" begin
    scalar = BrainlessLab.bernoulli_mask(5, 9, 0.3, MersenneTwister(12); diagonal=true)
    profile = BrainlessLab.bernoulli_mask(fill(0.3, 5), 9, MersenneTwister(12); diagonal=true)
    @test scalar == profile

    scalar_reservoir = FalandaysReservoir(12, 5, 2; seed=12, link_p=0.3, repair_masks=true)
    profile_reservoir = FalandaysReservoir(
        12,
        5,
        2;
        seed=12,
        link_p=0.3,
        input_link_p=fill(0.3, 5),
        repair_masks=true,
    )
    @test scalar_reservoir.input_wmat == profile_reservoir.input_wmat
    @test scalar_reservoir.recurrent_mask == profile_reservoir.recurrent_mask
    @test scalar_reservoir.output_mask == profile_reservoir.output_mask

    needs = (
        BrainlessLab.RegulatedVariable(:silent; link_p=0.0),
        BrainlessLab.RegulatedVariable(:dense; link_p=1.0),
    )
    body = _regulated_direct(
        2,
        1,
        needs,
    )
    probabilities = BrainlessLab.receptor_link_profile(body, 0.25)
    @test probabilities == [0.25, 0.25, 0.0, 1.0]
    reservoir = FalandaysReservoir(
        12,
        4,
        1;
        seed=3,
        link_p=0.25,
        input_link_p=probabilities,
        repair_masks=true,
    )
    @test all(iszero, reservoir.input_wmat[3, :])
    @test all(!iszero, reservoir.input_wmat[4, :])

    task = TaskSpec(
        :need_wall,
        _NeedWallSetup();
        n_receptors=3,
        n_effectors=2,
        default_ticks=3,
        score_key=nothing,
    )
    @test BrainlessLab.make_env(task; rng=MersenneTwister(9)) isa BrainlessLab.WallEnv
    resolved = only(BrainlessLab.resolved_task_ports(task))
    @test (n_receptors(resolved), n_effectors(resolved)) == (3, 2)
    sim = BrainlessLabTestUtils.diagnostic_simulate(
        task;
        node=:falandays,
        n_nodes=8,
        ticks=3,
        seed=2,
        record=(:spikes, :needs, :body_alive, :deaths, :feedback, :receptors),
    )
    @test getchannel(sim.recorder, :body_alive) == Any[Bool[0], Bool[0], Bool[0]]
    @test only(getchannel(sim.recorder, :deaths)[1]) == (tick=1, cause=:hunger)
    @test only(getchannel(sim.recorder, :needs)[1]).hunger == 0.0
    @test only(only(getchannel(sim.recorder, :feedback)[1])) == 0.5
    @test last(only(getchannel(sim.recorder, :receptors)[1])) == 0.5
    @test all(iszero, only(getchannel(sim.recorder, :receptors)[2]))
    @test all(iszero, only(getchannel(sim.recorder, :spikes)[2]))
    @test length(only(getchannel(sim.recorder, :receptors)[1])) == 3

    try
        register_node!(
            :profile_aware_test,
            _profile_aware_test_node;
            receptor_profile_keyword=:input_link_p,
        )
        @test BrainlessLab.node_receptor_profile_keyword(
            :profile_aware_test,
        ) === :input_link_p
        BrainlessLabTestUtils.diagnostic_simulate(task; node=:profile_aware_test, n_nodes=8, ticks=1, seed=2)
        @test _RECEPTOR_PROFILE_CAPTURE[] == [0.1, 0.1, 1.0]
        @test_throws ArgumentError register_node!(
            :empty_profile_test,
            _profile_aware_test_node;
            receptor_profile_keyword="",
        )
        @test_throws KeyError resolve_node(:empty_profile_test)
    finally
        delete!(BrainlessLab.NODE_RECEPTOR_PROFILE_KEYWORDS, :profile_aware_test)
        delete!(BrainlessLab.NODE_GENOME_TYPES, :profile_aware_test)
        delete!(BrainlessLab.NODES, :profile_aware_test)
    end

    expected_profile = (0.1, 0.1, 1.0)
    @test BrainlessLabTestUtils.diagnostic_simulate(
        task;
        node=:falandays,
        n_nodes=8,
        ticks=1,
        seed=2,
        node_kwargs=(input_link_p=expected_profile,),
    ) isa SimResult
    @test_throws ArgumentError BrainlessLabTestUtils.diagnostic_simulate(
        task;
        node=:falandays,
        n_nodes=8,
        ticks=1,
        seed=2,
        node_kwargs=(input_link_p=(0.1, 0.1, 0.5),),
    )
    @test_throws ArgumentError BrainlessLabTestUtils.diagnostic_simulate(task; node=:sorn, n_nodes=8, ticks=1)
end

@testset "Death keeps a stable slot and leaves the situated world" begin
    config = BrainlessLab.SwarmConfig(
        n_agents=2,
        space_size=10.0,
        sensory_noise=0.0,
        motor=BrainlessLab.KinematicMotor(top_speed=1.0, accel_time=1.0),
    )
    environment = BrainlessLab.TorusEnvironment(
        BrainlessLab.Torus(10.0),
        NTuple{2,Float64}[(5.0, 5.0), (6.0, 5.0)];
        headings=[0.0, pi],
        config=config,
        rng=MersenneTwister(4),
    ).world
    bodies = [
        BrainlessLab.situated_embodiment(
            BrainlessLab.SituatedSensorLayout(),
            config.motor;
            radius=config.agent_radius,
            physiology=BrainlessLab.RegulatedPhysiology((
                BrainlessLab.RegulatedVariable(:hunger; initial=0.0, failure=BrainlessLab.BelowFailure(threshold)),
            ); seed=20 + i),
        )
        for (i, threshold) in enumerate((0.0, -1.0))
    ]
    agents = [
        BrainlessLab.Agent(BrainlessLab.NullRandomReservoir(6, n_receptors(body), n_effectors(body); seed=30 + i), body)
        for (i, body) in enumerate(bodies)
    ]
    ensemble = BrainlessLab.Ensemble(agents, environment)

    step!(ensemble)
    @test environment.active_agents == BitVector([false, true])
    @test environment.activity_history == BitVector[BitVector([false, true])]
    dead_position = environment.positions[1]
    dead_effectors = copy(agents[1].reservoir.effector_buffer)
    @test all(iszero, BrainlessLab.sample!(environment, bodies)[2].conspecific)

    spikes = step!(ensemble)
    @test all(iszero, spikes[1])
    @test environment.positions[1] == dead_position
    @test agents[1].reservoir.effector_buffer == dead_effectors
    @test length(environment.history[1]) == length(environment.history[2]) == 2
    @test environment.activity_history ==
          BitVector[BitVector([false, true]), BitVector([false, true])]
    @test metrics(environment, 2).active_count == 1
    @test metrics(environment, 2).active_fraction == 0.5
    @test BrainlessLab.segregation(environment, 2) == (same_dist=0.0, cross_dist=0.0, assortativity=0.0)
end

@testset "situated historical metrics use activity at each recorded tick" begin
    environment = BrainlessLab.TorusEnvironment(
        BrainlessLab.Torus(10.0),
        NTuple{2,Float64}[(2.0, 2.0), (8.0, 8.0)];
        headings=[0.0, pi],
        config=BrainlessLab.SwarmConfig(n_agents=2, space_size=10.0, record_inputs=false),
        rng=MersenneTwister(44),
    ).world
    environment.history[1] = [(2.0, 2.0, 0.0), (2.0, 2.0, 0.0)]
    environment.history[2] = [(8.0, 8.0, pi), (8.0, 8.0, pi)]
    environment.activity_history = BitVector[
        BitVector([true, true]),
        BitVector([false, true]),
    ]
    environment.active_agents .= (false, true)

    result = BrainlessLab.swarm_metrics(environment, 2)
    @test result.polarization ≈ 0.5 atol=1e-12
    @test result.active_count == 1
    @test result.active_fraction == 0.5
end
