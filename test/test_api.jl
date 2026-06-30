using BrainlessLab
using Test
# Extending a user node means adding METHODS to the package generics, so import them:
import BrainlessLab: step!, effectors, reset!, n_receptors, n_effectors, snapshot_state, load_state!

mutable struct MyNode <: Reservoir
    n_receptors_::Int
    n_effectors_::Int
    spikes::Vector{Float64}
end

function MyNode(n_nodes::Integer, n_receptors_::Integer, n_effectors_::Integer; seed=0, kwargs...)
    return MyNode(Int(n_receptors_), Int(n_effectors_), zeros(Float64, Int(n_nodes)))
end

function step!(r::MyNode, receptor_currents)
    inputs = Float64.(vec(collect(receptor_currents)))
    gate = isempty(inputs) ? 0.0 : maximum(inputs)
    @inbounds for i in eachindex(r.spikes)
        r.spikes[i] = gate > 0.5 ? 1.0 : 0.0
    end
    return copy(r.spikes)
end

function effectors(r::MyNode, spikes)
    values = Float64.(vec(collect(spikes)))
    mean_spike = isempty(values) ? 0.0 : sum(values) / length(values)
    return fill(mean_spike, r.n_effectors_)
end

effectors(r::MyNode) = effectors(r, r.spikes)
n_receptors(r::MyNode) = r.n_receptors_
n_effectors(r::MyNode) = r.n_effectors_

function reset!(r::MyNode)
    fill!(r.spikes, 0.0)
    return r
end

snapshot_state(r::MyNode) = (spikes=copy(r.spikes),)

function load_state!(r::MyNode, state)
    copyto!(r.spikes, Float64.(state.spikes))
    return r
end

_myview(x; kwargs...) = x

@testset "High-level API variants and tasks" begin
    required_variants = (
        :falandays,
        :falandays_oosawa,
        :compartmental_dense,
        :compartmental_structured,
    )

    @test !isempty(variants())
    @test !isempty(tasks())

    for sym in required_variants
        @test sym in variants()
        sim = simulate(:wall; node=sym, ticks=60, seed=3)
        @test sim isa SimResult
        @test sim.task == :wall
        @test sim.node == sym
        @test !isempty(getchannel(sim.recorder, :spikes))
        @test !isempty(getchannel(sim.recorder, :rate))
    end

    for sym in (:wall, :tracking, :pong, :cartpole, :torus)
        @test sym in tasks()
    end

    swarm = simulate(:torus; node=:falandays, n_agents=3, ticks=40, seed=5)
    @test swarm isa SimResult
    @test swarm.task == :torus
    @test swarm.node == :falandays
    @test !isempty(getchannel(swarm.recorder, :spikes))
    @test !isempty(getchannel(swarm.recorder, :rate))
    @test hasproperty(swarm.metrics, :polarization)
    @test hasproperty(swarm.metrics, :milling)
end

@testset "Tinkering smoke" begin
    register_node!(:mynode, MyNode)
    @test resolve_node(:mynode) === MyNode
    @test :mynode in variants()

    mytask = TaskSpec(:mytoy, WallEnv; default_ticks=20, default_window=10)
    register_task!(:mytoy, mytask)
    @test resolve_task(:mytoy).name == :mytoy
    @test :mytoy in tasks()

    register_view!(:myview, _myview)
    @test resolve_view(:myview) === _myview

    wall = simulate(:wall; node=:mynode, ticks=20, n_nodes=8)
    @test wall isa SimResult
    @test wall.node == :mynode
    @test wall.task == :wall
    @test !isempty(getchannel(wall.recorder, :spikes))
    @test !isempty(getchannel(wall.recorder, :rate))

    custom = simulate(:mytoy; node=:mynode, ticks=12, n_nodes=8)
    @test custom isa SimResult
    @test custom.task == :mytoy
    @test !isempty(getchannel(custom.recorder, :spikes))
    @test resolve_view(:myview)(custom) === custom
end
