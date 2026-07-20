const _PARAMSPACE_ENTRY = NamedTuple{(:label, :lo, :hi),Tuple{Symbol,Float64,Float64}}
const _PARAMSPACE_VECTOR = Vector{_PARAMSPACE_ENTRY}

struct GenomeBlock
    label::Symbol
    channel::Symbol
    space::_PARAMSPACE_VECTOR
    pack::Function
    unpack::Function
end

struct CompositeGenome
    blocks::Vector{GenomeBlock}
    slices::Vector{UnitRange{Int}}
    dim::Int

    function CompositeGenome(blocks::AbstractVector{<:GenomeBlock})
        block_vec = Vector{GenomeBlock}(blocks)
        slices = UnitRange{Int}[]
        offset = 1
        for block in block_vec
            n = length(block.space)
            push!(slices, offset:(offset + n - 1))
            offset += n
        end
        return new(block_vec, slices, offset - 1)
    end
end

paramdim(g::CompositeGenome) = g.dim

function pack_params(g::CompositeGenome)
    return reduce(vcat, (Vector{Float64}(Float64.(block.pack())) for block in g.blocks); init=Float64[])
end

function paramspace(g::CompositeGenome)
    space = _PARAMSPACE_ENTRY[]
    for block in g.blocks, entry in block.space
        push!(
            space,
            (
                label=Symbol(block.label, :__, entry.label),
                lo=Float64(entry.lo),
                hi=Float64(entry.hi),
            ),
        )
    end
    return space
end

function unpack_params(g::CompositeGenome, raw::AbstractVector{<:Real})
    length(raw) == g.dim ||
        throw(DimensionMismatch("CompositeGenome expects $(g.dim) raw parameters, got $(length(raw))"))

    keys = Symbol[]
    values = Any[]
    for (block, slice) in zip(g.blocks, g.slices)
        push!(keys, block.channel)
        push!(values, block.unpack(view(raw, slice)))
    end
    return NamedTuple{Tuple(keys)}(Tuple(values))
end

function paramspace(::Type{FalandaysParams})
    return _PARAMSPACE_ENTRY[
        (label=:leak, lo=-Inf, hi=Inf),
        (label=:lrate_wmat, lo=-Inf, hi=Inf),
        (label=:lrate_targ, lo=-Inf, hi=Inf),
        (label=:threshold_mult, lo=-Inf, hi=Inf),
        (label=:targ_min, lo=-Inf, hi=Inf),
        (label=:input_weight, lo=-Inf, hi=Inf),
        (label=:weight_init_std, lo=-Inf, hi=Inf),
    ]
end

paramspace(::FalandaysParams) = paramspace(FalandaysParams)

function node_block(node_sym; template=nothing)
    sym = Symbol(node_sym)
    T = genome_type(sym)
    template_ = template === nothing ? T() : template
    return GenomeBlock(
        :node,
        :node,
        _PARAMSPACE_ENTRY[paramspace(T)...],
        () -> pack_params(template_),
        raw -> unpack_params(T, raw),
    )
end

function motor_block(m::KinematicMotor)
    return GenomeBlock(
        :motor,
        :motor,
        _PARAMSPACE_ENTRY[paramspace(m)...],
        () -> pack_params(m),
        raw -> unpack_params(m, raw),
    )
end

function sensor_block(s::AbstractSensor)
    return GenomeBlock(
        :sensor,
        :sensor,
        _PARAMSPACE_ENTRY[paramspace(s)...],
        () -> pack_params(s),
        raw -> unpack_params(s, raw),
    )
end

function compose_genome(; node=:falandays_base, motor=nothing, sensor=nothing, node_template=nothing)
    blocks = GenomeBlock[]
    node === nothing || push!(blocks, node_block(node; template=node_template))
    motor === nothing || push!(blocks, motor_block(motor))
    sensor === nothing || push!(blocks, sensor_block(sensor))
    return CompositeGenome(blocks)
end

function _route_parts(parts)
    node_kwargs = Dict{Symbol,Any}()
    swarm_kwargs = Dict{Symbol,Any}()
    for channel in propertynames(parts)
        value = getproperty(parts, channel)
        if channel === :node
            node_kwargs[:params] = value
        elseif channel === :motor
            swarm_kwargs[:motor] = value
        elseif channel === :sensor
            swarm_kwargs[:sensor] = value
        else
            throw(ArgumentError("unknown composite genome channel :$(channel)"))
        end
    end
    return (node_kwargs=node_kwargs, swarm_kwargs=swarm_kwargs)
end

_default_swarm_fitness(window) = ensemble -> segregation(ensemble, Int(window)).assortativity

function swarm_rollout(
    genome::CompositeGenome,
    raw,
    seed;
    task=:torus,
    n_agents::Integer=16,
    n_nodes::Integer=250,
    substeps::Integer=1,
    ticks::Integer=600,
    window::Integer=200,
    n_colours::Integer=2,
    fitness=nothing,
)
    parts = unpack_params(genome, raw)
    routed = _route_parts(parts)
    node_kwargs = copy(routed.node_kwargs)
    swarm_kwargs = copy(routed.swarm_kwargs)
    node_kwargs[:substeps] = Int(substeps)
    swarm_kwargs = merge(
        swarm_kwargs,
        Dict{Symbol,Any}(
            :n_colours => Int(n_colours),
            :colour_sensing => true,
        ),
    )

    task_spec = _task_spec(task)
    is_multiagent(task_spec.setup) || throw(ArgumentError(
        "swarm_rollout requires a multi-agent TaskSpec, got :$(task_spec.name)",
    ))
    swarm_kwargs[:n_agents] = Int(n_agents)
    ensemble, _ = _make_ensemble(
        task_spec,
        :falandays_base,
        resolve_node(:falandays_base);
        seed=Int(seed),
        n_nodes=Int(n_nodes),
        record=[:pose],
        node_kwargs=node_kwargs,
        task_kwargs=swarm_kwargs,
    )
    rollout!(ensemble, Int(ticks); window=Int(window))
    fit = fitness === nothing ? _default_swarm_fitness(window) : fitness
    return Float64(fit(ensemble))
end

swarm_evaluate(g::CompositeGenome; kwargs...) = (raw, seed) -> swarm_rollout(g, raw, seed; kwargs...)
