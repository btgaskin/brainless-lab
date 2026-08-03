using BrainlessLab
using Test
# Extending a user node means adding METHODS to the package generics, so import them:
import BrainlessLab: step!, effectors, reset!, n_nodes, n_receptors, n_effectors, snapshot_state, load_state!
import BrainlessLab: pack_params, unpack_params, paramdim, sense!, decode!, apply_drive!, network_snapshot

struct MyNodeParams <: NodeModel
    gain::Float64
end

@testset "short scored runs reject starvation" begin
    error = try
        simulate(
            :pong;
            node=:null_random,
            n_nodes=2,
            ticks=300,
            seed=4,
            record=(),
        )
        nothing
    catch caught
        caught
    end
    message = error === nothing ? "" : sprint(showerror, error)
    @test error isa ArgumentError
    @test occursin("task :pong", message)
    @test occursin("300", message)
    @test occursin("6000", message)

    composition = CompositionSpec(
        :starved_pong_convenience,
        :null_random,
        :pong;
        n_nodes=2,
    )
    @test_throws ArgumentError simulate(
        composition;
        ticks=300,
        seed=4,
        record=(),
    )
end

@testset "an explicit scoring-window override permits a diagnostic run" begin
    sim = simulate(
        :pong;
        node=:null_random,
        n_nodes=2,
        ticks=300,
        window=300,
        seed=4,
        record=(),
    )
    outcome = task_outcome(sim)
    @test sim.config.window == 300
    @test outcome.window == 300

    composition = CompositionSpec(
        :short_pong_diagnostic,
        :null_random,
        :pong;
        n_nodes=2,
    )
    composition_sim = simulate(
        composition;
        ticks=300,
        window=120,
        seed=4,
        record=(),
    )
    @test composition_sim.config.window == 120
    @test task_outcome(composition_sim).window == 120
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
    gain::Float64
    spikes::Vector{Float64}
end

function MyNode(
    n_nodes::Integer,
    n_receptors_::Integer,
    n_effectors_::Integer;
    seed=0,
    params::MyNodeParams=MyNodeParams(),
    kwargs...,
)
    return MyNode(
        Int(n_receptors_),
        Int(n_effectors_),
        params.gain,
        zeros(Float64, Int(n_nodes)),
    )
end

function step!(r::MyNode, receptor_currents)
    inputs = Float64.(vec(collect(receptor_currents)))
    gate = isempty(inputs) ? 0.0 : r.gain * maximum(inputs)
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
n_nodes(r::MyNode) = length(r.spikes)

function reset!(r::MyNode)
    fill!(r.spikes, 0.0)
    return r
end

snapshot_state(r::MyNode) = (spikes=copy(r.spikes),)
BrainlessLab.network_snapshot(r::MyNode) = (kind=:mynode, gain=r.gain)

function load_state!(r::MyNode, state)
    copyto!(r.spikes, Float64.(state.spikes))
    return r
end

_myview(x; kwargs...) = x

struct MyBody <: AbstractBody end

BrainlessLab.sense!(::MyBody, percept) = percept
BrainlessLab.decode!(::MyBody, e) = e
n_receptors(::MyBody) = 2
n_effectors(::MyBody) = 2

struct MyDrive <: BrainlessLab.Drive end

BrainlessLab.apply_drive!(::MyDrive, acts, targets, p, noise) = acts

_custom_metric(metrics) = (:score in propertynames(metrics)) ? Float64(metrics.score) + 1.0 : 1.0

@testset "Public API names resolve" begin
    public_names = names(BrainlessLab; all=false, imported=false)
    @test all(name -> isdefined(BrainlessLab, name), public_names)
end

@testset "High-level API variants and tasks" begin
    required_variants = (
        :falandays,
        :sorn,
        :compartmental_dense,
        :compartmental_structured,
    )

    @test !isempty(variants())
    @test !isempty(tasks())

    for sym in required_variants
        @test sym in variants()
        sim = simulate(:wall; node=sym, ticks=60, window=60, seed=3)
        @test sim isa SimResult
        @test sim.task == :wall
        @test sim.node == sym
        @test !isempty(getchannel(sim.recorder, :spikes))
        @test !isempty(getchannel(sim.recorder, :rate))
    end

    for sym in (:wall, :tracking, :pong, :cartpole, :torus)
        @test sym in tasks()
        @test resolve_task(sym) isa TaskSpec
    end
    @test resolve_task(:forage) isa TaskSpec
    @test !BrainlessLab.has_objective(resolve_task(:torus))
    @test BrainlessLab.has_objective(resolve_task(:forage))

    unregistered = TaskSpec(:unregistered_wall, BrainlessLab.WallEnv; default_ticks=4, default_window=4)
    direct = simulate(unregistered; node=:null_random, ticks=4, seed=9, record=Symbol[])
    @test direct.task == :unregistered_wall

    swarm = simulate(:torus; node=:falandays, n_agents=3, ticks=40, window=40, seed=5)
    @test swarm isa SimResult
    @test swarm.task == :torus
    @test swarm.node == :falandays
    @test !isempty(getchannel(swarm.recorder, :spikes))
    @test !isempty(getchannel(swarm.recorder, :rate))
    @test hasproperty(swarm.metrics, :polarization)
    @test hasproperty(swarm.metrics, :milling)
end

@testset "Tinkering smoke" begin
    try
        register_node!(:mynode, MyNode; genome_type=MyNodeParams)
        @test resolve_node(:mynode) === MyNode
        @test BrainlessLab.genome_type(:mynode) === MyNodeParams
        @test :mynode in variants()

        mytask = TaskSpec(
            :mytoy,
            BrainlessLab.WallEnv;
            default_ticks=20,
            default_window=10,
        )
        register_task!(:mytoy, mytask)
        @test resolve_task(:mytoy).name == :mytoy
        @test :mytoy in tasks()

        BrainlessLab.register_view!(:myview, _myview)
        @test resolve_view(:myview) === _myview

        register_body!(:mybody, MyBody)
        @test resolve_body(:mybody) === MyBody

        register_drive!(:mydrive, MyDrive)
        @test resolve_drive(:mydrive) === MyDrive

        register_metric!(:custom_metric, _custom_metric)
        @test resolve_metric(:custom_metric) === _custom_metric

        wall = simulate(:wall; node=:mynode, ticks=20, window=20, n_nodes=8)
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
        @test BrainlessLab.view(custom, :myview) === custom

        body_sim = simulate(
            :wall;
            node=:mynode,
            body=:mybody,
            ticks=12,
            window=12,
            n_nodes=8,
        )
        @test body_sim isa SimResult

        drive_sim = simulate(
            :wall;
            node=:falandays,
            drive=:mydrive,
            ticks=12,
            window=12,
            n_nodes=8,
        )
        @test drive_sim isa SimResult

        metric_sim = simulate(
            :wall;
            node=:mynode,
            ticks=12,
            window=12,
            n_nodes=8,
            metrics=[:custom_metric],
        )
        @test hasproperty(metric_sim.metrics, :score)
        @test hasproperty(metric_sim.metrics, :custom_metric)

        packed = pack_params(MyNodeParams(1.25))
        params = unpack_params(BrainlessLab.genome_type(:mynode), packed)
        stamped = simulate(
            :wall;
            node=:mynode,
            seed=2,
            N=8,
            ticks=12,
            window=12,
            node_kwargs=(; params),
        )
        outcome = task_outcome(stamped)
        @test stamped.node == :mynode
        @test stamped.config.networks[1].gain == params.gain
        @test ismissing(outcome.normalized)
        @test outcome.normalization_status === :anchor_window_mismatch
        @test outcome.anchor_scored_ticks == 200
    finally
        delete!(BrainlessLab.METRICS, :custom_metric)
        delete!(BrainlessLab.DRIVES, :mydrive)
        delete!(BrainlessLab.BODY_OPTION_DEFAULTS, :mybody)
        delete!(BrainlessLab.BODIES, :mybody)
        delete!(BrainlessLab.VIEWS, :myview)
        delete!(BrainlessLab.TASKS, :mytoy)
        delete!(BrainlessLab.NODE_RECEPTOR_PROFILE_KEYWORDS, :mynode)
        delete!(BrainlessLab.NODE_GENOME_TYPES, :mynode)
        delete!(BrainlessLab.NODES, :mynode)
    end
end
