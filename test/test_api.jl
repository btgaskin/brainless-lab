using BrainlessLab
using Test
# Extending a user node means adding METHODS to the package generics, so import them:
import BrainlessLab: step!, effectors, reset!, n_receptors, n_effectors, snapshot_state, load_state!
import BrainlessLab: pack_params, unpack_params, paramdim, receptors, decode_effectors, apply_drive!

struct MyNodeParams <: NodeModel
    gain::Float64
end

MyNodeParams() = MyNodeParams(1.0)

paramdim(::Type{MyNodeParams}) = 1
paramdim(::MyNodeParams) = 1
pack_params(p::MyNodeParams) = [p.gain]
pack_params(::Type{MyNodeParams}) = pack_params(MyNodeParams())
unpack_params(::Type{MyNodeParams}, raw::AbstractVector{<:Real}) = MyNodeParams(Float64(raw[1]))

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

struct MyBody <: Body end

receptors(::MyBody, percept) = percept
decode_effectors(::MyBody, e) = e

struct MyDrive <: Drive end

apply_drive!(::MyDrive, acts, targets, p, noise) = acts

_custom_metric(metrics) = (:score in propertynames(metrics)) ? Float64(metrics.score) + 1.0 : 1.0

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
    register_node!(:mynode, MyNode; genome_type=MyNodeParams)
    @test resolve_node(:mynode) === MyNode
    @test genome_type(:mynode) === MyNodeParams
    @test :mynode in variants()

    mytask = TaskSpec(:mytoy, WallEnv; default_ticks=20, default_window=10)
    register_task!(:mytoy, mytask)
    @test resolve_task(:mytoy).name == :mytoy
    @test :mytoy in tasks()

    register_view!(:myview, _myview)
    @test resolve_view(:myview) === _myview

    register_body!(:mybody, MyBody)
    @test resolve_body(:mybody) === MyBody

    register_drive!(:mydrive, MyDrive)
    @test resolve_drive(:mydrive) === MyDrive

    register_metric!(:custom_metric, _custom_metric)
    @test resolve_metric(:custom_metric) === _custom_metric

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
    @test view(custom, :myview) === custom

    body_sim = simulate(:wall; node=:mynode, body=:mybody, ticks=12, n_nodes=8)
    @test body_sim isa SimResult

    drive_sim = simulate(:wall; node=:falandays, drive=:mydrive, ticks=12, n_nodes=8)
    @test drive_sim isa SimResult

    metric_sim = simulate(:wall; node=:mynode, ticks=12, n_nodes=8, metrics=[:custom_metric])
    @test hasproperty(metric_sim.metrics, :score)
    @test hasproperty(metric_sim.metrics, :custom_metric)

    stamped = rollout(:wall, pack_params(MyNodeParams()), 2; model_sym=:mynode, N=8, ticks=12)
    @test stamped.model_sym == :mynode
    @test isfinite(stamped.norm_score)
end
