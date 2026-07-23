"""Cold-path context supplied to a registered node builder."""
struct NodeBuildContext{P,S,R}
    n_nodes::Int
    ports::P
    seeds::S
    receptor_profile::R

    function NodeBuildContext(
        n_nodes::Integer,
        ports,
        seeds;
        receptor_profile=nothing,
    )
        count = Int(n_nodes)
        count > 0 || throw(ArgumentError("node build context requires a positive n_nodes"))
        return new{typeof(ports),typeof(seeds),typeof(receptor_profile)}(
            count,
            ports,
            seeds,
            receptor_profile,
        )
    end
end

"""
    NodeSpec

Discoverable contract for one neural substrate. Node count and the task/body
ports are supplied by `NodeBuildContext`; the node owns only its mechanism and
declared parameter surface.
"""
struct NodeSpec{B,G,P,E,M}
    id::Symbol
    build::B
    genome_type::G
    stability::Symbol
    tags::Tuple{Vararg{Symbol}}
    capabilities::Tuple{Vararg{Symbol}}
    parameters::P
    parameter_sets::Dict{Symbol,Tuple{Vararg{Symbol}}}
    equations::E
    default_analyses::Tuple{Vararg{Symbol}}
    metadata::M
end

function NodeSpec(
    id::Union{Symbol,AbstractString},
    build;
    genome_type=nothing,
    stability::Symbol=:experimental,
    tags=(),
    capabilities=(),
    parameters=(),
    parameter_sets=Dict{Symbol,Tuple{Vararg{Symbol}}}(),
    equations=(),
    default_analyses=(),
    metadata::NamedTuple=NamedTuple(),
)
    id_ = _nonempty_symbol(id, "node id")
    stability in IMPLEMENTATION_STABILITIES || throw(ArgumentError(
        "node :$(id_) has invalid stability :$(stability)",
    ))
    genome_type === nothing ||
        (genome_type isa Type && genome_type <: NodeModel) ||
        throw(ArgumentError("node :$(id_) genome_type must be a NodeModel type or nothing"))
    tags_ = _symbol_tuple(tags, "node tags")
    capabilities_ = _symbol_tuple(capabilities, "node capabilities")
    parameters_ = Tuple(parameters)
    all(parameter -> parameter isa ParameterSpec, parameters_) || throw(ArgumentError(
        "node :$(id_) parameters must all be ParameterSpec values",
    ))
    parameter_names = Tuple(parameter.name for parameter in parameters_)
    length(unique(parameter_names)) == length(parameter_names) || throw(ArgumentError(
        "node :$(id_) parameter names must be unique",
    ))
    sets_ = Dict{Symbol,Tuple{Vararg{Symbol}}}()
    for (set_name, members) in pairs(parameter_sets)
        set_name_ = _nonempty_symbol(set_name, "parameter-set name")
        members_ = _symbol_tuple(members, "parameter-set members")
        unknown = setdiff(members_, parameter_names)
        isempty(unknown) || throw(ArgumentError(
            "node :$(id_) parameter set :$(set_name_) references unknown parameters $(unknown)",
        ))
        sets_[set_name_] = members_
    end
    equations_ = Tuple(equations)
    all(equation -> equation isa EquationSpec, equations_) || throw(ArgumentError(
        "node :$(id_) equations must all be EquationSpec values",
    ))
    analyses_ = _symbol_tuple(default_analyses, "default analyses")
    return NodeSpec{
        typeof(build),
        typeof(genome_type),
        typeof(parameters_),
        typeof(equations_),
        typeof(metadata),
    }(
        id_,
        build,
        genome_type,
        stability,
        tags_,
        capabilities_,
        parameters_,
        sets_,
        equations_,
        analyses_,
        metadata,
    )
end

node_parameter(spec::NodeSpec, name::Union{Symbol,AbstractString}) = begin
    name_ = Symbol(name)
    index = findfirst(parameter -> parameter.name === name_, spec.parameters)
    index === nothing && throw(KeyError("node :$(spec.id) has no parameter :$(name_)"))
    spec.parameters[index]
end

function node_parameter_set(spec::NodeSpec, name::Union{Symbol,AbstractString})
    name_ = Symbol(name)
    haskey(spec.parameter_sets, name_) || throw(KeyError(
        "node :$(spec.id) has no parameter set :$(name_)",
    ))
    return spec.parameter_sets[name_]
end

function resolve_parameters(spec::NodeSpec, overrides=Dict{Symbol,Any}())
    override_dict = Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(overrides))
    known = Set(parameter.name for parameter in spec.parameters)
    unknown = sort!(collect(setdiff(Set(keys(override_dict)), known)); by=string)
    isempty(unknown) || throw(ArgumentError(
        "node :$(spec.id) received unknown parameters $(unknown)",
    ))
    resolved = Dict{Symbol,Any}()
    for parameter in spec.parameters
        value = get(override_dict, parameter.name, parameter.default)
        resolved[parameter.name] = validate_parameter(parameter, value)
    end
    return resolved
end

"""One serializable, runnable node-task-body composition."""
Base.@kwdef struct CompositionSpec
    id::Symbol
    node::Symbol
    task::Symbol
    body::Union{Nothing,Symbol}=nothing
    n_agents::Union{Nothing,Int}=nothing
    n_nodes::Int
    parameters::Dict{Symbol,Any}=Dict{Symbol,Any}()
    task_options::Dict{Symbol,Any}=Dict{Symbol,Any}()
    body_options::Dict{Symbol,Any}=Dict{Symbol,Any}()
    interaction_cycle::Union{Nothing,InteractionCycle}=nothing
end

function CompositionSpec(
    id::Union{Symbol,AbstractString},
    node::Union{Symbol,AbstractString},
    task::Union{Symbol,AbstractString};
    body=nothing,
    n_agents=nothing,
    n_nodes::Integer,
    parameters=Dict{Symbol,Any}(),
    task_options=Dict{Symbol,Any}(),
    body_options=Dict{Symbol,Any}(),
    interaction_cycle::Union{Nothing,InteractionCycle}=nothing,
)
    id_ = _nonempty_symbol(id, "composition id")
    node_ = _nonempty_symbol(node, "composition node")
    task_ = _nonempty_symbol(task, "composition task")
    count = Int(n_nodes)
    count > 0 || throw(ArgumentError("composition :$(id_) requires positive n_nodes"))
    agents = n_agents === nothing ? nothing : Int(n_agents)
    agents === nothing || agents > 0 || throw(ArgumentError(
        "composition :$(id_) requires positive n_agents when specified",
    ))
    body_ = body === nothing ? nothing : _nonempty_symbol(body, "composition body")
    return CompositionSpec(
        id_,
        node_,
        task_,
        body_,
        agents,
        count,
        Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(parameters)),
        Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(task_options)),
        Dict{Symbol,Any}(Symbol(key) => value for (key, value) in pairs(body_options)),
        interaction_cycle,
    )
end

struct ResolvedComposition{N,T,B,C}
    id::Symbol
    node::N
    task::T
    body::B
    n_agents::Union{Nothing,Int}
    n_nodes::Int
    parameters::Dict{Symbol,Any}
    task_options::Dict{Symbol,Any}
    body_options::Dict{Symbol,Any}
    interaction_cycle::C
end

mutable struct RegistrySet
    nodes::Registry{Symbol,NodeSpec}
    tasks::Registry{Symbol,TaskSpec}
    bodies::Registry{Symbol,ImplementationSpec}
    drives::Registry{Symbol,ImplementationSpec}
    motors::Registry{Symbol,ImplementationSpec}
    sensors::Registry{Symbol,ImplementationSpec}
    metrics::Registry{Symbol,ImplementationSpec}
    analyses::Registry{Symbol,ImplementationSpec}
    views::Registry{Symbol,ImplementationSpec}
    optimizers::Registry{Symbol,ImplementationSpec}
    ablations::Registry{Symbol,ImplementationSpec}
    compositions::Registry{Symbol,CompositionSpec}
    composition_defaults::Dict{Tuple{Symbol,Symbol},Symbol}
end

function RegistrySet()
    return RegistrySet(
        Registry{Symbol,NodeSpec}(:nodes),
        Registry{Symbol,TaskSpec}(:tasks),
        Registry{Symbol,ImplementationSpec}(:bodies),
        Registry{Symbol,ImplementationSpec}(:drives),
        Registry{Symbol,ImplementationSpec}(:motors),
        Registry{Symbol,ImplementationSpec}(:sensors),
        Registry{Symbol,ImplementationSpec}(:metrics),
        Registry{Symbol,ImplementationSpec}(:analyses),
        Registry{Symbol,ImplementationSpec}(:views),
        Registry{Symbol,ImplementationSpec}(:optimizers),
        Registry{Symbol,ImplementationSpec}(:ablations),
        Registry{Symbol,CompositionSpec}(:compositions),
        Dict{Tuple{Symbol,Symbol},Symbol}(),
    )
end

register!(registry::RegistrySet, spec::NodeSpec) = register!(registry.nodes, spec.id, spec)
register!(registry::RegistrySet, spec::TaskSpec) = register!(registry.tasks, spec.name, spec)
register!(registry::RegistrySet, spec::CompositionSpec) =
    register!(registry.compositions, spec.id, spec)

function register!(registry::RegistrySet, kind::Symbol, spec::ImplementationSpec)
    kind in (:bodies, :drives, :motors, :sensors, :metrics, :analyses, :views, :optimizers, :ablations) ||
        throw(ArgumentError("unknown implementation registry :$(kind)"))
    return register!(getfield(registry, kind), spec.key, spec)
end

function register_default!(registry::RegistrySet, composition::CompositionSpec)
    key = (composition.node, composition.task)
    haskey(registry.composition_defaults, key) && throw(ArgumentError(
        "default composition for node :$(composition.node) and task :$(composition.task) is already registered",
    ))
    register!(registry, composition)
    registry.composition_defaults[key] = composition.id
    return composition
end

node_spec(registry::RegistrySet, id::Union{Symbol,AbstractString}) =
    resolve(registry.nodes, Symbol(id))
task_spec(registry::RegistrySet, id::Union{Symbol,AbstractString}) =
    resolve(registry.tasks, Symbol(id))
composition_spec(registry::RegistrySet, id::Union{Symbol,AbstractString}) =
    resolve(registry.compositions, Symbol(id))

nodes(registry::RegistrySet) = sort!(collect(keys(registry.nodes)); by=string)
function tasks(registry::RegistrySet; tag=nothing, status=nothing)
    tag_ = tag === nothing ? nothing : Symbol(tag)
    status_ = status === nothing ? nothing : Symbol(status)
    found = Symbol[]
    for (name, task) in registry.tasks
        tag_ === nothing || tag_ in task.tags || continue
        status_ === nothing || task.status === status_ || continue
        push!(found, name)
    end
    return sort!(found; by=string)
end

function analyses(registry::RegistrySet; task=nothing)
    task_ = task === nothing ? nothing : Symbol(task)
    found = Symbol[]
    for (name, analysis) in registry.analyses
        scope = hasproperty(analysis.metadata, :task) ? analysis.metadata.task : nothing
        task_ === nothing || scope === nothing || scope === task_ || continue
        push!(found, name)
    end
    return sort!(found; by=string)
end

ablations(registry::RegistrySet) = sort!(collect(keys(registry.ablations)); by=string)
compositions(registry::RegistrySet) = sort!(collect(keys(registry.compositions)); by=string)

function default_composition(
    registry::RegistrySet,
    node::Union{Symbol,AbstractString},
    task::Union{Symbol,AbstractString},
)
    key = (Symbol(node), Symbol(task))
    haskey(registry.composition_defaults, key) || throw(KeyError(
        "no default composition for node :$(key[1]) and task :$(key[2])",
    ))
    return composition_spec(registry, registry.composition_defaults[key])
end

function _materialize_registered_body(spec::ImplementationSpec, options::Dict{Symbol,Any})
    implementation = spec.implementation
    implementation isa AbstractBody && return deepcopy(implementation)
    values = (; (key => value for (key, value) in options)...)
    applicable(implementation; values...) || throw(ArgumentError(
        "registered body :$(spec.key) does not accept its declared options",
    ))
    body = implementation(; values...)
    body isa AbstractBody || throw(ArgumentError(
        "registered body :$(spec.key) returned $(typeof(body)), not AbstractBody",
    ))
    return body
end

function resolve_composition(spec::CompositionSpec, registry::RegistrySet)
    node = node_spec(registry, spec.node)
    task = task_spec(registry, spec.task)
    body = spec.body === nothing ? nothing : resolve(registry.bodies, spec.body)
    parameters = resolve_parameters(node, spec.parameters)
    task_options = copy(spec.task_options)
    spec.n_agents === nothing || (task_options[:n_agents] = spec.n_agents)
    return ResolvedComposition(
        spec.id,
        node,
        task,
        body,
        spec.n_agents,
        spec.n_nodes,
        parameters,
        task_options,
        copy(spec.body_options),
        spec.interaction_cycle === nothing ? task.interaction_cycle : spec.interaction_cycle,
    )
end
