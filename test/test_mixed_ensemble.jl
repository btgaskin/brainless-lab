using BrainlessLab
using Test

import BrainlessLab: alive, apply_commands!, component_state, decode!, effectors,
    inactive_command, metrics, n_effectors, n_nodes, n_receptors, sample!, sense!, step!, update!

struct _MixedBodyA <: AbstractBody end
struct _MixedBodyB <: AbstractBody end

n_receptors(::_MixedBodyA) = 1
n_effectors(::_MixedBodyA) = 1
n_receptors(::_MixedBodyB) = 2
n_effectors(::_MixedBodyB) = 1
sense!(::_MixedBodyA, percept) = Float64[percept[1]]
sense!(::_MixedBodyB, percept) = Float64[percept[1], percept[2]]
decode!(::_MixedBodyA, values) = Vector{Float64}(values)
decode!(::_MixedBodyB, values) = Vector{Float64}(values)
component_state(::_MixedBodyB) = (death=(tick=3, cause=:test),)

mutable struct _DyingBody <: AbstractBody
    is_alive::Bool
end
n_receptors(::_DyingBody) = 1
n_effectors(::_DyingBody) = 1
sense!(::_DyingBody, percept) = Float64[percept[1]]
decode!(::_DyingBody, values) = Vector{Float64}(values)
alive(body::_DyingBody) = body.is_alive
update!(body::_DyingBody, effects=()) = (body.is_alive = false; nothing)

mutable struct _MixedReservoir <: Reservoir
    nr::Int
    ne::Int
    last_input::Vector{Float64}
    steps::Int
end

_MixedReservoir(nr, ne) = _MixedReservoir(Int(nr), Int(ne), zeros(Float64, Int(nr)), 0)
n_receptors(r::_MixedReservoir) = r.nr
n_effectors(r::_MixedReservoir) = r.ne
n_nodes(::_MixedReservoir) = 1

function step!(r::_MixedReservoir, receptors)
    r.last_input = Vector{Float64}(receptors)
    r.steps += 1
    return [sum(r.last_input)]
end

effectors(r::_MixedReservoir, spikes) = fill(Float64(first(spikes)), r.ne)

mutable struct _MixedEnvironment <: Environment
    state::Float64
    samples::Vector{Vector{Vector{Float64}}}
    commands::Vector{Vector{Vector{Float64}}}
end

_MixedEnvironment() = _MixedEnvironment(1.0, Vector{Vector{Vector{Float64}}}(), Vector{Vector{Vector{Float64}}}())

function sample!(environment::_MixedEnvironment, bodies)
    percepts = [fill(environment.state, n_receptors(body)) for body in bodies]
    push!(environment.samples, deepcopy(percepts))
    return percepts
end

function apply_commands!(environment::_MixedEnvironment, bodies, commands)
    values = [Vector{Float64}(command) for command in commands]
    push!(environment.commands, deepcopy(values))
    environment.state += sum(sum, values)
    return [() for _ in bodies]
end

metrics(environment::_MixedEnvironment, window::Integer=1) = (state=environment.state,)

struct _MetriclessEnvironment <: Environment end
sample!(::_MetriclessEnvironment, bodies) =
    [zeros(Float64, n_receptors(body)) for body in bodies]
apply_commands!(::_MetriclessEnvironment, bodies, commands) = [() for _ in bodies]

struct _TypedCommand <: AbstractCommand
    value::Float64
end

mutable struct _TypedDyingBody <: AbstractBody
    is_alive::Bool
    sense_calls::Int
end
n_receptors(::_TypedDyingBody) = 1
n_effectors(::_TypedDyingBody) = 1
function sense!(body::_TypedDyingBody, percept)
    body.sense_calls += 1
    return Float64[percept[1]]
end
decode!(::_TypedDyingBody, values) = _TypedCommand(Float64(only(values)))
inactive_command(::_TypedDyingBody) = _TypedCommand(0.0)
alive(body::_TypedDyingBody) = body.is_alive
update!(body::_TypedDyingBody, effects=()) = (body.is_alive = false; nothing)

mutable struct _TypedEnvironment <: Environment
    commands::Vector{Vector{_TypedCommand}}
end
sample!(::_TypedEnvironment, bodies) = [ones(Float64, n_receptors(body)) for body in bodies]
function apply_commands!(environment::_TypedEnvironment, bodies, commands)
    typed = _TypedCommand[command::_TypedCommand for command in commands]
    push!(environment.commands, typed)
    return [() for _ in bodies]
end

mutable struct _CountingDyingBodyA <: AbstractBody
    is_alive::Bool
    sense_calls::Int
end
mutable struct _CountingDyingBodyB <: AbstractBody
    is_alive::Bool
    sense_calls::Int
end
for T in (_CountingDyingBodyA, _CountingDyingBodyB)
    @eval begin
        n_receptors(::$T) = 1
        n_effectors(::$T) = 1
        function sense!(body::$T, percept)
            body.sense_calls += 1
            return Float64[percept[1]]
        end
        decode!(::$T, values) = Vector{Float64}(values)
        alive(body::$T) = body.is_alive
        update!(body::$T, effects=()) = (body.is_alive = false; nothing)
    end
end

mutable struct _BorrowingBody <: AbstractBody
    receptor_buffer::Vector{Float64}
end
n_receptors(::_BorrowingBody) = 1
n_effectors(::_BorrowingBody) = 1
function sense!(body::_BorrowingBody, percept)
    body.receptor_buffer[1] = Float64(percept[1])
    return body.receptor_buffer
end
decode!(::_BorrowingBody, values) = Vector{Float64}(values)

struct _SlotEnvironment <: Environment end
sample!(::_SlotEnvironment, bodies) = [[Float64(i)] for i in eachindex(bodies)]
apply_commands!(::_SlotEnvironment, bodies, commands) = [() for _ in bodies]

struct _MixedSetup end
function (::_MixedSetup)(; kwargs...)
    return TaskSetup(_MixedEnvironment(), AbstractBody[_MixedBodyA(), _MixedBodyB()])
end

function _mixed_agents()
    body_a1 = _MixedBodyA()
    body_b = _MixedBodyB()
    body_a2 = _MixedBodyA()
    return Agent[
        Agent(_MixedReservoir(1, 1), body_a1),
        Agent(_MixedReservoir(2, 1), body_b),
        Agent(_MixedReservoir(1, 1), body_a2),
    ]
end

@testset "homogeneous and grouped stores" begin
    homogeneous_agents = _mixed_agents()[[1, 3]]
    homogeneous = Ensemble(homogeneous_agents, _MixedEnvironment())
    @test homogeneous.store isa BrainlessLab.HomogeneousStore
    @test nagents(homogeneous) == 2
    @test entity_ids(homogeneous) == EntityID.(1:2)

    mixed = Ensemble(_mixed_agents(), _MixedEnvironment(); ids=[11, 22, 33])
    @test mixed.store isa BrainlessLab.GroupedStore
    @test nagents(mixed) == 3
    @test entity_ids(mixed) == EntityID[EntityID(11), EntityID(22), EntityID(33)]
    @test body_at_slot(mixed, 1) isa _MixedBodyA
    @test body_at_slot(mixed, 2) isa _MixedBodyB
    @test body_at_slot(mixed, 3) isa _MixedBodyA
    @test agent_at_slot(mixed, 2).body isa _MixedBodyB
    @test length(mixed.store.groups) == 2
    @test group_slots(mixed.store.groups[1]) == [1, 3]
    @test group_slots(mixed.store.groups[2]) == [2]
    @test group_ids(mixed.store.groups[1]) == EntityID[EntityID(11), EntityID(33)]
    exposed_slots = group_slots(mixed.store.groups[1])
    exposed_slots[1] = 99
    @test group_slots(mixed.store.groups[1]) == [1, 3]
    exposed_agents = group_agents(mixed.store.groups[1])
    pop!(exposed_agents)
    @test length(group_agents(mixed.store.groups[1])) == 2
    sizes = Int[]
    foreach_group(group -> push!(sizes, length(group_agents(group))), mixed)
    @test sizes == [2, 1]
    @test_throws ArgumentError Ensemble(_mixed_agents(), _MixedEnvironment(); ids=[1, 1, 2])
    mismatched = Agent(_MixedReservoir(2, 1), _MixedBodyA())
    @test_throws DimensionMismatch Ensemble([mismatched], _MixedEnvironment())
end

@testset "mixed stepping remains synchronous" begin
    environment = _MixedEnvironment()
    ensemble = Ensemble(_mixed_agents(), environment; ids=[101, 202, 303])

    spikes = step!(ensemble)
    @test spikes == [[1.0], [2.0], [1.0]]
    @test environment.samples[1] == [[1.0], [1.0, 1.0], [1.0]]
    @test environment.commands[1] == [[1.0], [2.0], [1.0]]
    @test environment.state == 5.0

    step!(ensemble)
    @test environment.samples[2] == [[5.0], [5.0, 5.0], [5.0]]
end

@testset "environment metrics are public and optional" begin
    environment = _MixedEnvironment()
    result = rollout!(Ensemble(_mixed_agents(), environment), 2; window=2)
    @test result.state == environment.state

    metricless = _MetriclessEnvironment()
    @test metrics(metricless, 2) == NamedTuple()
    fallback_result = rollout!(
        Ensemble([Agent(_MixedReservoir(1, 1), _MixedBodyA())], metricless),
        2;
        window=2,
    )
    @test :state ∉ propertynames(fallback_result)
    @test !isempty(propertynames(fallback_result))
end

@testset "public reservoir contracts cover inactive ticks" begin
    body = _DyingBody(true)
    reservoir = _MixedReservoir(1, 1)
    ensemble = Ensemble([Agent(reservoir, body)], _MetriclessEnvironment())
    @test step!(ensemble) == [[0.0]]
    @test !alive(body)
    @test reservoir.steps == 1
    @test step!(ensemble) == [zeros(n_nodes(reservoir))]
    @test reservoir.steps == 1
end

@testset "custom typed commands and inactive sensing use public contracts" begin
    body = _TypedDyingBody(true, 0)
    environment = _TypedEnvironment(Vector{Vector{_TypedCommand}}())
    ensemble = Ensemble([Agent(_MixedReservoir(1, 1), body)], environment)

    step!(ensemble)
    @test body.sense_calls == 1
    @test only(environment.commands[1]) isa _TypedCommand
    @test only(environment.commands[1]).value == 1.0

    step!(ensemble)
    @test body.sense_calls == 1
    @test only(environment.commands[2]).value == 0.0
end

@testset "inactive sensing is skipped through grouped function barriers" begin
    body_a = _CountingDyingBodyA(true, 0)
    body_b = _CountingDyingBodyB(true, 0)
    ensemble = Ensemble(
        Agent[
            Agent(_MixedReservoir(1, 1), body_a),
            Agent(_MixedReservoir(1, 1), body_b),
        ],
        _MetriclessEnvironment(),
    )
    @test ensemble.store isa BrainlessLab.GroupedStore

    step!(ensemble)
    @test (body_a.sense_calls, body_b.sense_calls) == (1, 1)
    step!(ensemble)
    @test (body_a.sense_calls, body_b.sense_calls) == (1, 1)
end

@testset "borrowed receptor buffers are copied at the gather boundary" begin
    shared_body = _BorrowingBody(zeros(1))
    first_reservoir = _MixedReservoir(1, 1)
    second_reservoir = _MixedReservoir(1, 1)
    ensemble = Ensemble(
        [
            Agent(first_reservoir, shared_body),
            Agent(second_reservoir, shared_body),
        ],
        _SlotEnvironment(),
    )

    step!(ensemble)
    @test first_reservoir.last_input == [1.0]
    @test second_reservoir.last_input == [2.0]
end

@testset "concrete runtime paths remain inferred with bounded allocations" begin
    homogeneous = Ensemble(_mixed_agents()[[1, 3]], _MixedEnvironment())
    grouped = Ensemble(_mixed_agents(), _MixedEnvironment())

    @test @inferred(step!(homogeneous)) isa Vector{Vector{Float64}}
    @test @inferred(step!(grouped)) isa Vector{Vector{Float64}}

    # Characterization gates are deliberately broad: they catch accidental
    # type-erased explosions without imposing machine-sensitive timing claims.
    homogeneous_bytes = @allocated step!(homogeneous)
    grouped_bytes = @allocated step!(grouped)
    @test homogeneous_bytes < 5_000_000
    @test grouped_bytes < 5_000_000
end

@testset "entity-aware recording and manifests" begin
    sparse = EntityFrame([42, 7], ["forty-two", "seven"])
    @test entity_index(sparse, 42) == 1
    @test entity_value(sparse, EntityID(7)) == "seven"
    aligned = align_entities(sparse, [7, 42])
    @test aligned.ids == EntityID.([7, 42])
    @test aligned.values == ["seven", "forty-two"]
    @test_throws ArgumentError EntityFrame([7, 7], [1, 2])
    @test_throws ArgumentError align_entities(sparse, [7, 8])

    recorder = Recorder(enabled=(:spikes, :receptors, :effectors, :body_alive, :deaths))
    ensemble = Ensemble(_mixed_agents(), _MixedEnvironment(); ids=[7, 8, 9], recorder=recorder)
    step!(ensemble)

    for channel in (:spikes, :receptors, :effectors, :body_alive, :deaths)
        frame = only(getchannel(recorder, channel))
        @test frame isa EntityFrame
        @test frame.ids == EntityID[EntityID(7), EntityID(8), EntityID(9)]
        @test length(frame) == 3
    end
    @test only(getchannel(recorder, :deaths))[2] == (tick=3, cause=:test)

    config = BrainlessLab._simulation_config(
        ensemble;
        ticks=1,
        seed=4,
        record=(:spikes,),
        every=1,
        window=1,
        n_nodes=1,
    )
    @test config.n_agents == 3
    @test Tuple(agent.id for agent in config.agents) == Tuple(EntityID.((7, 8, 9)))
    @test Tuple(agent.slot for agent in config.agents) == (1, 2, 3)
    @test config.entity_ids == Tuple(EntityID.((7, 8, 9)))
    @test length(config.bodies) == length(config.networks) == 3
    @test !hasproperty(config, :network)
end

@testset "task setups expose per-body port layouts" begin
    setup = TaskSetup(_MixedEnvironment(), AbstractBody[_MixedBodyA(), _MixedBodyB()])
    @test length(setup.bodies) == 2
    @test eltype(setup.bodies) === AbstractBody

    task = TaskSpec(:mixed_ports, _MixedSetup(); score_key=nothing)
    layouts = resolved_task_ports(task)
    @test length(layouts) == 2
    @test (n_receptors(layouts[1]), n_effectors(layouts[1])) == (1, 1)
    @test (n_receptors(layouts[2]), n_effectors(layouts[2])) == (2, 1)
    err = try
        BrainlessLab._fixed_port_counts(layouts; context="mixed test")
        nothing
    catch caught
        caught
    end
    @test err isa ArgumentError
    @test occursin("requires one fixed", sprint(showerror, err))
end
