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
    return NullRandomReservoir(n_nodes, n_receptors, n_effectors; seed=seed)
end

function _regulated_direct(n_receptors, n_effectors, variables; seed=0)
    return direct_embodiment(
        n_receptors,
        n_effectors;
        physiology=RegulatedPhysiology(variables; seed=seed),
    )
end

function _feedback_trace!(physiology, n_ticks::Integer)
    names = Tuple(variable.name for variable in physiology.variables)
    traces = Dict(name => Float64[] for name in names)
    for _ in 1:n_ticks
        feedback = physiology_feedback!(physiology)
        for (index, name) in enumerate(names)
            push!(traces[name], feedback[index])
        end
        physiology_update!(physiology)
    end
    return traces
end

function (::_NeedWallSetup)(; seed=0, rng=nothing, body=nothing, n_nodes=8, kwargs...)
    env_rng = rng === nothing ? MersenneTwister(seed) : rng
    env = WallEnv(; rng=env_rng)
    need = RegulatedVariable(
        :hunger;
        initial=0.5,
        drift=-0.5,
        mode=TonicFeedback(),
        link_p=1.0,
        failure=BelowFailure(0.0),
    )
    return TaskSetup(env, [_regulated_direct(2, 2, (need,); seed=seed + 100)])
end

@testset "Need curves and signal modes" begin
    @test response_value(ConstantResponse(0.3), 0.9) == 0.3
    @test response_value(LinearResponse(), 0.4) == 0.4
    @test response_value(PowerResponse(2), 0.5) == 0.25
    @test response_value(LogisticResponse(), 0.0) ≈ 0.0 atol=eps()
    @test response_value(LogisticResponse(), 1.0) ≈ 1.0 atol=eps()
    @test response_value(LogisticResponse(1e-20), 0.37) ≈ 0.37
    @test isfinite(response_value(LogisticResponse(1e6), 0.5))
    @test response_value(ThresholdResponse(0.4), 0.39) == 0.0
    @test_throws ArgumentError response_value(LinearResponse(), 1.1)
    @test_throws ArgumentError response_value(x -> 2x, 0.75)

    linear = RegulatedVariable(:hunger; initial=0.25)
    @test regulation_urgency(linear, 0.25) ≈ 0.75

    power = RegulatedVariable(:hunger; initial=0.25, curve=PowerFeedback(2.0))
    @test regulation_urgency(power, 0.25) ≈ 0.75^2
    @test regulation_urgency(RegulatedVariable(:x; curve=LogisticFeedback()), 0.0) ≈ 1.0
    @test regulation_urgency(RegulatedVariable(:x; curve=ThresholdFeedback(0.4)), 0.5) == 1.0
    @test regulation_urgency(RegulatedVariable(:x; curve=x -> x / 2), 0.0) ≈ 0.5
    @test_throws ArgumentError regulation_urgency(RegulatedVariable(:x; curve=x -> 2x), 0.0)
    @test_throws ArgumentError BelowFailure(NaN)

    off = _regulated_direct(1, 1, (RegulatedVariable(:x; initial=0.0),); seed=4)
    @test sense!(off, [0.2]) == [0.2, 0.0]
    @test sense!(off, [0.2]) === sense!(off, [0.2])

    tonic = _regulated_direct(
        1,
        1,
        (RegulatedVariable(:x; initial=0.0, mode=TonicFeedback(), gain=2.5),);
        seed=4,
    )
    @test sense!(tonic, [0.2]) == [0.2, 2.5]

    spike = _regulated_direct(
        1,
        1,
        (RegulatedVariable(:x; initial=0.0, mode=BernoulliFeedback(), emission_p=1.0, gain=3.0),);
        seed=4,
    )
    @test sense!(spike, [0.2]) == [0.2, 3.0]
end

@testset "Atomic need updates, rescue, mortality, and reset" begin
    need = RegulatedVariable(
        :hunger;
        initial=0.1,
        drift=-0.2,
        mode=BernoulliFeedback(),
        emission_p=0.5,
        failure=BelowFailure(0.0),
    )
    rescued = _regulated_direct(1, 1, (need,); seed=8)
    update!(rescued, (Exposure(:hunger, 0.2), Exposure(:hunger, 0.1)))
    @test regulated_values(rescued).hunger ≈ 0.2
    @test alive(rescued)

    doomed = _regulated_direct(1, 1, (need,); seed=8)
    update!(doomed)
    @test !alive(doomed)
    @test doomed.physiology.death_tick == 1
    @test doomed.physiology.death_cause == :hunger
    @test all(iszero, sense!(doomed, [1.0]))

    reset!(rescued)
    sequence_a = Float64[]
    for _ in 1:8
        push!(sequence_a, last(sense!(rescued, [0.0])))
        update!(rescued, (Exposure(:hunger, 0.2),))
    end
    reset!(rescued)
    sequence_b = Float64[]
    for _ in 1:8
        push!(sequence_b, last(sense!(rescued, [0.0])))
        update!(rescued, (Exposure(:hunger, 0.2),))
    end
    @test sequence_a == sequence_b

    needs = (
        RegulatedVariable(:hunger),
        RegulatedVariable(:temperature; deficit=SetpointDistance()),
    )
    multiple = _regulated_direct(1, 1, needs)
    @test [port.id for port in ports(multiple).receptors[end-1:end]] ==
          [:physiology__regulated_hunger, :physiology__regulated_temperature]
    @test_throws ArgumentError expose!(multiple, Exposure(:missing, 1.0))

    coupled = _regulated_direct(1, 1, (
        RegulatedVariable(:hunger; initial=0.4, drift=-0.1),
        RegulatedVariable(
            :thirst;
            initial=0.4,
            drift=-0.2,
            curve=PowerFeedback(2.0),
            mode=TonicFeedback(),
            failure=BelowFailure(0.25),
        ),
    ))
    update!(coupled, (Exposure(:hunger, 0.2), Exposure(:thirst, 0.05)))
    @test regulated_values(coupled).hunger ≈ 0.5
    @test regulated_values(coupled).thirst ≈ 0.25
    @test !alive(coupled)
    @test coupled.physiology.death_cause === :thirst
end


@testset "Bernoulli feedback rate and amplitude" begin
    need = RegulatedVariable(
        :hunger;
        initial=0.5,
        setpoint=1.0,
        mode=BernoulliFeedback(),
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
        push!(emissions, last(sense!(body, [0.0])))
        update!(body)
    end
    @test all(value -> value == 0.0 || value == 3.0, emissions)
    @test count(==(3.0), emissions) / length(emissions) ≈ 0.1 atol=0.01
end

@testset "Feedback RNG streams are tick-stable and compositional" begin
    zero_probability = RegulatedVariable(
        :zero;
        initial=0.0,
        mode=BernoulliFeedback(),
        emission_p=0.0,
    )
    rng = MersenneTwister(91)
    @test emit_feedback(BernoulliFeedback(), zero_probability, 1.0, rng) == 0.0
    reference_rng = MersenneTwister(91)
    rand(reference_rng)
    @test rand(rng) == rand(reference_rng)

    energy = RegulatedVariable(
        :energy;
        initial=0.0,
        mode=BernoulliFeedback(),
        emission_p=0.41,
    )
    hydration = RegulatedVariable(
        :hydration;
        initial=0.0,
        mode=BernoulliFeedback(),
        emission_p=0.37,
    )
    social = RegulatedVariable(
        :social;
        initial=0.0,
        mode=BernoulliFeedback(),
        emission_p=0.29,
    )
    ordered = RegulatedPhysiology((energy, hydration); seed=29)
    reordered = RegulatedPhysiology((hydration, energy); seed=29)
    extended = RegulatedPhysiology((social, energy, hydration); seed=29)
    ordered_trace = _feedback_trace!(ordered, 256)
    reordered_trace = _feedback_trace!(reordered, 256)
    extended_trace = _feedback_trace!(extended, 256)
    @test ordered_trace[:energy] == reordered_trace[:energy] == extended_trace[:energy]
    @test ordered_trace[:hydration] ==
          reordered_trace[:hydration] ==
          extended_trace[:hydration]

    sampled_twice = RegulatedPhysiology((energy, hydration); seed=43)
    sampled_once = RegulatedPhysiology((energy, hydration); seed=43)
    destination = fill(NaN, 2)
    for _ in 1:128
        first = physiology_feedback!(sampled_twice)
        returned = physiology_feedback!(destination, sampled_twice)
        @test returned === destination
        @test destination == first
        @test physiology_feedback!(sampled_twice) == first
        @test physiology_feedback!(sampled_once) == first
        physiology_update!(sampled_twice)
        physiology_update!(sampled_once)
    end
    @test_throws DimensionMismatch physiology_feedback!(zeros(1), sampled_once)

    physiology_reset!(sampled_twice)
    reset_trace_a = _feedback_trace!(sampled_twice, 128)
    physiology_reset!(sampled_twice)
    reset_trace_b = _feedback_trace!(sampled_twice, 128)
    @test reset_trace_a == reset_trace_b
end

@testset "Replay feedback is indexed, cyclic, and resettable" begin
    need = RegulatedVariable(
        :hunger;
        initial=0.0,
        mode=ReplayFeedback([0.0, 2.0, 0.5]),
    )
    body = _regulated_direct(1, 1, (need,); seed=17)
    values = Float64[]
    for _ in 1:5
        push!(values, last(sense!(body, [0.0])))
        update!(body)
    end
    @test values == [0.0, 2.0, 0.5, 0.0, 2.0]

    reset!(body)
    @test last(sense!(body, [0.0])) == 0.0
    @test_throws ArgumentError ReplayFeedback(Float64[])
    @test_throws ArgumentError ReplayFeedback([NaN])
    @test_throws BoundsError emit_feedback(
        ReplayFeedback([1.0]; cycle=false),
        need,
        0.0,
        MersenneTwister(1),
        2,
    )
end

@testset "Per-receptor Falandays wiring" begin
    scalar = bernoulli_mask(5, 9, 0.3, MersenneTwister(12); diagonal=true)
    profile = bernoulli_mask(fill(0.3, 5), 9, MersenneTwister(12); diagonal=true)
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
        RegulatedVariable(:silent; link_p=0.0),
        RegulatedVariable(:dense; link_p=1.0),
    )
    body = _regulated_direct(
        2,
        1,
        needs,
    )
    probabilities = receptor_link_profile(body, 0.25)
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
    @test make_env(task; rng=MersenneTwister(9)) isa WallEnv
    resolved = only(resolved_task_ports(task))
    @test (n_receptors(resolved), n_effectors(resolved)) == (3, 2)
    sim = simulate(
        task;
        node=:falandays_base,
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

    register_node!(
        :profile_aware_test,
        _profile_aware_test_node;
        receptor_profile_keyword=:input_link_p,
    )
    @test node_receptor_profile_keyword(:profile_aware_test) === :input_link_p
    simulate(task; node=:profile_aware_test, n_nodes=8, ticks=1, seed=2)
    @test _RECEPTOR_PROFILE_CAPTURE[] == [0.1, 0.1, 1.0]
    @test_throws ArgumentError register_node!(
        :empty_profile_test,
        _profile_aware_test_node;
        receptor_profile_keyword="",
    )
    @test_throws KeyError resolve_node(:empty_profile_test)
    @test_throws ArgumentError simulate(task; node=:sorn, n_nodes=8, ticks=1)
end

@testset "Death keeps a stable slot and leaves the situated world" begin
    config = SwarmConfig(
        n_agents=2,
        space_size=10.0,
        sensory_noise=0.0,
        motor=KinematicMotor(top_speed=1.0, accel_time=1.0),
    )
    environment = TorusEnvironment(
        Torus(10.0),
        NTuple{2,Float64}[(5.0, 5.0), (6.0, 5.0)];
        headings=[0.0, pi],
        config=config,
        rng=MersenneTwister(4),
    ).world
    bodies = [
        situated_embodiment(
            SituatedSensorLayout(),
            config.motor;
            radius=config.agent_radius,
            physiology=RegulatedPhysiology((
                RegulatedVariable(:hunger; initial=0.0, failure=BelowFailure(threshold)),
            ); seed=20 + i),
        )
        for (i, threshold) in enumerate((0.0, -1.0))
    ]
    agents = [
        Agent(NullRandomReservoir(6, n_receptors(body), n_effectors(body); seed=30 + i), body)
        for (i, body) in enumerate(bodies)
    ]
    ensemble = Ensemble(agents, environment)

    step!(ensemble)
    @test environment.active_agents == BitVector([false, true])
    dead_position = environment.positions[1]
    dead_effectors = copy(agents[1].reservoir.effector_buffer)
    @test all(iszero, sample!(environment, bodies)[2].conspecific)

    spikes = step!(ensemble)
    @test all(iszero, spikes[1])
    @test environment.positions[1] == dead_position
    @test agents[1].reservoir.effector_buffer == dead_effectors
    @test length(environment.history[1]) == length(environment.history[2]) == 2
    @test segregation(environment, 2) == (same_dist=0.0, cross_dist=0.0, assortativity=0.0)
end
