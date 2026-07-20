const NODES = Dict{Symbol,Any}()
const TASKS = Dict{Symbol,Any}()
const DRIVES = Dict{Symbol,Any}()
const BODIES = Dict{Symbol,Any}()
const MOTORS = Dict{Symbol,Any}()
const SENSORS = Dict{Symbol,Any}()
const METRICS = Dict{Symbol,Any}()
const ANALYSES = Dict{Symbol,Any}()
const VIEWS = Dict{Symbol,Any}()
const OPTIMIZERS = Dict{Symbol,Any}()
const ABLATIONS = Dict{Symbol,Any}()
const NODE_GENOME_TYPES = Dict{Symbol,Any}()
const NODE_RECEPTOR_PROFILE_KEYWORDS = Dict{Symbol,Symbol}()

function _register!(registry::Dict{Symbol,Any}, kind::AbstractString, sym::Symbol, T)
    registry[sym] = T
    return T
end

function _resolve(registry::Dict{Symbol,Any}, kind::AbstractString, sym::Symbol)
    if haskey(registry, sym)
        return registry[sym]
    end

    known = sort!(collect(keys(registry)))
    known_msg = isempty(known) ? "none registered" : join(string.(known), ", ")
    throw(KeyError("Unknown $(kind) key :$(sym). Known keys: $(known_msg)."))
end

"""
    register_node!(sym, T; genome_type=nothing, receptor_profile_keyword=nothing)

Register a node constructor or concrete type under `sym`.

If the node can be evolved, pass `genome_type=<:NodeModel` so drivers can
derive parameter dimension and unpacking from the public node contract.

If the constructor accepts a body-specific receptor connection profile, pass
the constructor keyword as `receptor_profile_keyword` (for example
`:input_link_p`). This capability is declared at registration rather than
inferred from the node's symbol.
"""
function register_node!(
    sym::Symbol,
    T;
    genome_type=nothing,
    receptor_profile_keyword=nothing,
)
    if genome_type !== nothing
        genome_type isa Type && genome_type <: NodeModel ||
            throw(ArgumentError("genome_type for node :$(sym) must be a NodeModel type"))
    end
    profile_keyword = if receptor_profile_keyword === nothing
        nothing
    else
        receptor_profile_keyword isa Union{Symbol,AbstractString} || throw(ArgumentError(
            "receptor_profile_keyword for node :$(sym) must be a symbol or string",
        ))
        keyword = Symbol(receptor_profile_keyword)
        isempty(String(keyword)) && throw(ArgumentError(
            "receptor_profile_keyword for node :$(sym) must not be empty",
        ))
        keyword
    end

    registered = _register!(NODES, "node", sym, T)
    if genome_type !== nothing
        NODE_GENOME_TYPES[sym] = genome_type
    else
        delete!(NODE_GENOME_TYPES, sym)
    end
    if profile_keyword === nothing
        delete!(NODE_RECEPTOR_PROFILE_KEYWORDS, sym)
    else
        NODE_RECEPTOR_PROFILE_KEYWORDS[sym] = profile_keyword
    end
    return registered
end

"""
    node_receptor_profile_keyword(sym)

Return the constructor keyword registered for per-receptor input connection
probabilities, or `nothing` when the node does not declare that capability.
"""
node_receptor_profile_keyword(sym::Symbol) = get(NODE_RECEPTOR_PROFILE_KEYWORDS, sym, nothing)

"""
    resolve_node(sym)

Resolve a registered node symbol to its constructor or concrete type.
"""
resolve_node(sym::Symbol)::Any = _resolve(NODES, "node", sym)

function genome_type(node::Union{Symbol,AbstractString})
    sym = Symbol(node)
    if haskey(NODE_GENOME_TYPES, sym)
        return NODE_GENOME_TYPES[sym]
    end
    return genome_type(resolve_node(sym))
end

function genome_type(node)
    throw(ArgumentError("no evolvable genome_type is registered for node constructor $(node)"))
end

"""
    register_task!(sym, T)

Register a task constructor or concrete type under `sym`.
"""
register_task!(sym::Symbol, T) = _register!(TASKS, "task", sym, T)

"""
    resolve_task(sym)

Resolve a registered task symbol to its constructor or concrete type.
"""
resolve_task(sym::Symbol)::Any = _resolve(TASKS, "task", sym)

"""
    register_drive!(sym, T)

Register a drive constructor or concrete type under `sym`.
"""
register_drive!(sym::Symbol, T) = _register!(DRIVES, "drive", sym, T)

"""
    resolve_drive(sym)

Resolve a registered drive symbol to its constructor or concrete type.
"""
resolve_drive(sym::Symbol)::Any = _resolve(DRIVES, "drive", sym)

"""
    register_body!(sym, T)

Register a body constructor or concrete type under `sym`.
"""
register_body!(sym::Symbol, T) = _register!(BODIES, "body", sym, T)

"""
    resolve_body(sym)

Resolve a registered body symbol to its constructor or concrete type.
"""
resolve_body(sym::Symbol)::Any = _resolve(BODIES, "body", sym)

"""
    register_motor!(sym, T)

Register a motor (effector-decode policy) constructor or concrete type under
`sym`.
"""
register_motor!(sym::Symbol, T) = _register!(MOTORS, "motor", sym, T)

"""
    resolve_motor(sym)

Resolve a registered motor symbol to its constructor or concrete type.
"""
resolve_motor(sym::Symbol)::Any = _resolve(MOTORS, "motor", sym)

"""
    register_sensor!(sym, T)

Register a sensor (perception-geometry) spec constructor or concrete type under
`sym`.
"""
register_sensor!(sym::Symbol, T) = _register!(SENSORS, "sensor", sym, T)

"""
    resolve_sensor(sym)

Resolve a registered sensor symbol to its constructor or concrete type.
"""
resolve_sensor(sym::Symbol)::Any = _resolve(SENSORS, "sensor", sym)

"""
    register_metric!(sym, T)

Register a metric constructor, function, or concrete type under `sym`.
"""
register_metric!(sym::Symbol, T) = _register!(METRICS, "metric", sym, T)

"""
    resolve_metric(sym)

Resolve a registered metric symbol to its constructor, function, or concrete
type.
"""
resolve_metric(sym::Symbol)::Any = _resolve(METRICS, "metric", sym)

"""
    register_analysis!(sym, f; task=nothing, label=string(sym))

Register an analysis function under `sym`.
"""
function register_analysis!(
    sym::Symbol,
    f;
    task::Union{Nothing,Symbol}=nothing,
    label::AbstractString=string(sym),
)
    ANALYSES[sym] = (f=f, task=task, label=String(label))
    return sym
end

"""
    resolve_analysis(sym)

Resolve a registered analysis symbol to its function.
"""
resolve_analysis(sym::Symbol)::Any = _resolve(ANALYSES, "analysis", sym).f

"""
    analysis_meta(sym)

Return task scope and label metadata for a registered analysis.
"""
function analysis_meta(sym::Symbol)
    entry = _resolve(ANALYSES, "analysis", sym)
    return (task=entry.task, label=entry.label)
end

"""
    analyses(; task=nothing)

Return registered analysis symbols visible in the requested task scope. Global
analyses are always visible; task analyses are visible only for their task.
"""
function analyses(; task::Union{Nothing,Symbol}=nothing)
    return sort!([sym for (sym, entry) in ANALYSES if entry.task === nothing || entry.task === task])
end

"""
    task_analyses(task)

Return registered analysis symbols scoped exactly to `task`.
"""
function task_analyses(task::Symbol)
    return sort!([sym for (sym, entry) in ANALYSES if entry.task === task])
end

"""
    register_view!(sym, T)

Register a view constructor, function, or concrete type under `sym`.
"""
register_view!(sym::Symbol, T) = _register!(VIEWS, "view", sym, T)

"""
    resolve_view(sym)

Resolve a registered view symbol to its constructor, function, or concrete type.
"""
resolve_view(sym::Symbol)::Any = _resolve(VIEWS, "view", sym)

"""
    register_optimizer!(sym, T)

Register an optimizer constructor or concrete type under `sym`.
"""
register_optimizer!(sym::Symbol, T) = _register!(OPTIMIZERS, "optimizer", sym, T)

"""
    resolve_optimizer(sym)

Resolve a registered optimizer symbol to its constructor or concrete type.
"""
resolve_optimizer(sym::Symbol)::Any = _resolve(OPTIMIZERS, "optimizer", sym)

"""
    register_ablation!(sym, T)

Register an ablation constructor, function, or concrete type under `sym`.
"""
register_ablation!(sym::Symbol, T) = _register!(ABLATIONS, "ablation", sym, T)

"""
    resolve_ablation(sym)

Resolve a registered ablation symbol to its constructor, function, or concrete
type.
"""
resolve_ablation(sym::Symbol)::Any = _resolve(ABLATIONS, "ablation", sym)

"""
    ablations()

Return registered ablation symbols.
"""
ablations() = sort!(collect(keys(ABLATIONS)))
