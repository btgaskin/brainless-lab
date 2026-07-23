const IMPLEMENTATION_STABILITIES = (:reference, :stable, :experimental, :control)
const CONSTRUCTION_SCOPES = (:evaluation, :block, :trial)
const RESET_POLICIES = (:full, :body_environment, :none)
const AGGREGATE_POLICIES = (:none, :mean, :median, :sum, :minimum, :maximum)
const EVOLUTION_SCALES = (:linear, :log, :integer)

function _nonempty_symbol(value, label::AbstractString)
    symbol = Symbol(value)
    isempty(String(symbol)) && throw(ArgumentError("$(label) must not be empty"))
    return symbol
end

function _symbol_tuple(values, label::AbstractString)
    source = values isa Union{Symbol,AbstractString} ? (values,) : values
    result = Tuple(_nonempty_symbol(value, label) for value in source)
    length(unique(result)) == length(result) ||
        throw(ArgumentError("$(label) must be unique"))
    return result
end

"""
    Registry{K,V}(name=:registry)

A small typed registry for resolved component descriptors. Registration rejects
duplicate keys; replacement is deliberately a separate concern so accidental
load-order changes cannot silently alter an experiment.
"""
struct Registry{K,V}
    name::Symbol
    entries::Dict{K,V}

    function Registry{K,V}(name::Union{Symbol,AbstractString}=:registry) where {K,V}
        name_ = _nonempty_symbol(name, "registry name")
        return new{K,V}(name_, Dict{K,V}())
    end
end

Base.length(registry::Registry) = length(registry.entries)
Base.isempty(registry::Registry) = isempty(registry.entries)
Base.haskey(registry::Registry, key) = haskey(registry.entries, key)
Base.keys(registry::Registry) = keys(registry.entries)
Base.values(registry::Registry) = values(registry.entries)
Base.iterate(registry::Registry, state...) = iterate(registry.entries, state...)

"""
    register!(registry, key, value)

Register `value` under `key`. Duplicate keys are always rejected.
"""
function register!(registry::Registry{K,V}, key::K, value::V) where {K,V}
    haskey(registry.entries, key) && throw(ArgumentError(
        "$(registry.name) registry key $(repr(key)) is already registered",
    ))
    registry.entries[key] = value
    return value
end

"""
    resolve(registry, key)

Resolve a registered key, reporting the sorted known keys when resolution
fails.
"""
function resolve(registry::Registry{K}, key::K) where {K}
    haskey(registry.entries, key) && return registry.entries[key]
    known = sort!(collect(keys(registry.entries)); by=string)
    known_message = isempty(known) ? "none registered" : join(repr.(known), ", ")
    throw(KeyError(
        "Unknown $(registry.name) registry key $(repr(key)). Known keys: $(known_message).",
    ))
end

Base.getindex(registry::Registry{K}, key::K) where {K} = resolve(registry, key)

"""
    ImplementationSpec(key, implementation; kwargs...)

Generic discovery metadata for a registered implementation. This descriptor
does not assume that the implementation is callable: tasks, bodies, analyses,
and immutable specifications can all be registered through the same contract.
"""
struct ImplementationSpec{I,T<:Tuple,C<:Tuple,M<:NamedTuple}
    key::Symbol
    implementation::I
    label::String
    description::String
    origin::String
    stability::Symbol
    tags::T
    capabilities::C
    metadata::M
end

function ImplementationSpec(
    key::Union{Symbol,AbstractString},
    implementation;
    label::AbstractString=string(key),
    description::AbstractString="",
    origin::AbstractString="BrainlessLab",
    stability::Symbol=:experimental,
    tags=(),
    capabilities=(),
    metadata::NamedTuple=NamedTuple(),
)
    key_ = _nonempty_symbol(key, "implementation key")
    isempty(strip(label)) && throw(ArgumentError("implementation label must not be empty"))
    isempty(strip(origin)) && throw(ArgumentError("implementation origin must not be empty"))
    stability in IMPLEMENTATION_STABILITIES || throw(ArgumentError(
        "implementation stability must be one of " *
        join(":" .* string.(IMPLEMENTATION_STABILITIES), ", "),
    ))
    tags_ = _symbol_tuple(tags, "implementation tags")
    capabilities_ = _symbol_tuple(capabilities, "implementation capabilities")
    return ImplementationSpec{
        typeof(implementation),
        typeof(tags_),
        typeof(capabilities_),
        typeof(metadata),
    }(
        key_,
        implementation,
        String(label),
        String(description),
        String(origin),
        stability,
        tags_,
        capabilities_,
        metadata,
    )
end

"""
    EquationSpec(name, latex; kwargs...)

Human-readable mathematical metadata suitable for generated reports. Variable
definitions are stored as unique `Symbol => description` pairs; references are
plain citation identifiers or URLs.
"""
struct EquationSpec{V<:Tuple,R<:Tuple}
    name::Symbol
    title::String
    latex::String
    description::String
    variables::V
    references::R
end

function _equation_variables(variables)
    source = variables isa Pair ? (variables,) : variables
    result = Tuple(begin
        variable isa Pair || throw(ArgumentError(
            "equation variables must be pairs of symbol => description",
        ))
        name = _nonempty_symbol(first(variable), "equation variable")
        description = String(last(variable))
        isempty(strip(description)) && throw(ArgumentError(
            "equation variable descriptions must not be empty",
        ))
        name => description
    end for variable in source)
    names = first.(result)
    length(unique(names)) == length(names) ||
        throw(ArgumentError("equation variables must be unique"))
    return result
end

function _equation_references(references)
    source = references isa AbstractString ? (references,) : references
    result = Tuple(String(reference) for reference in source)
    all(reference -> !isempty(strip(reference)), result) ||
        throw(ArgumentError("equation references must not be empty"))
    length(unique(result)) == length(result) ||
        throw(ArgumentError("equation references must be unique"))
    return result
end

function EquationSpec(
    name::Union{Symbol,AbstractString},
    latex::AbstractString;
    title::AbstractString=string(name),
    description::AbstractString="",
    variables=(),
    references=(),
)
    name_ = _nonempty_symbol(name, "equation name")
    isempty(strip(title)) && throw(ArgumentError("equation title must not be empty"))
    isempty(strip(latex)) && throw(ArgumentError("equation LaTeX must not be empty"))
    variables_ = _equation_variables(variables)
    references_ = _equation_references(references)
    return EquationSpec{typeof(variables_),typeof(references_)}(
        name_,
        String(title),
        String(latex),
        String(description),
        variables_,
        references_,
    )
end

function _parameter_value_valid(validator, value, name::Symbol)
    validator === nothing && return value
    applicable(validator, value) || throw(ArgumentError(
        "validator for parameter :$(name) is not callable with $(typeof(value))",
    ))
    verdict = validator(value)
    verdict isa Bool || throw(ArgumentError(
        "validator for parameter :$(name) must return Bool, got $(typeof(verdict))",
    ))
    verdict || throw(ArgumentError(
        "invalid value $(repr(value)) for parameter :$(name)",
    ))
    return value
end

function _parameter_sweep(sweep, validator, name::Symbol)
    sweep === nothing && return nothing
    sweep isa Union{AbstractString,Symbol,Number} && throw(ArgumentError(
        "sweep metadata for parameter :$(name) must be an iterable of candidate values",
    ))
    values = Tuple(sweep)
    isempty(values) && throw(ArgumentError(
        "sweep metadata for parameter :$(name) must not be empty",
    ))
    length(unique(values)) == length(values) || throw(ArgumentError(
        "sweep metadata for parameter :$(name) must contain unique values",
    ))
    foreach(value -> _parameter_value_valid(validator, value, name), values)
    return values
end

function _categorical_evolution(evolve::NamedTuple, validator, name::Symbol)
    propertynames(evolve) == (:values,) || throw(ArgumentError(
        "categorical evolution metadata for parameter :$(name) must contain only :values",
    ))
    values = _parameter_sweep(evolve.values, validator, name)
    values === nothing && throw(ArgumentError(
        "categorical evolution metadata for parameter :$(name) requires candidate values",
    ))
    return (values=values,)
end

function _bounded_evolution(evolve::NamedTuple, validator, name::Symbol, default)
    allowed = (:lower, :upper, :scale, :mutation_scale)
    unknown = setdiff(propertynames(evolve), allowed)
    isempty(unknown) || throw(ArgumentError(
        "unknown evolution metadata for parameter :$(name): " *
        join(":" .* string.(unknown), ", "),
    ))
    hasproperty(evolve, :lower) && hasproperty(evolve, :upper) || throw(ArgumentError(
        "bounded evolution metadata for parameter :$(name) requires :lower and :upper",
    ))
    lower = evolve.lower
    upper = evolve.upper
    lower isa Real && upper isa Real && default isa Real || throw(ArgumentError(
        "bounded evolution metadata for parameter :$(name) requires numeric bounds and default",
    ))
    isfinite(lower) && isfinite(upper) || throw(ArgumentError(
        "evolution bounds for parameter :$(name) must be finite",
    ))
    lower <= upper || throw(ArgumentError(
        "evolution lower bound for parameter :$(name) exceeds its upper bound",
    ))
    lower <= default <= upper || throw(ArgumentError(
        "default for parameter :$(name) lies outside its evolution bounds",
    ))
    _parameter_value_valid(validator, lower, name)
    _parameter_value_valid(validator, upper, name)

    scale = hasproperty(evolve, :scale) ? Symbol(evolve.scale) : :linear
    scale in EVOLUTION_SCALES || throw(ArgumentError(
        "evolution scale for parameter :$(name) must be one of " *
        join(":" .* string.(EVOLUTION_SCALES), ", "),
    ))
    if scale === :log
        lower > zero(lower) || throw(ArgumentError(
            "log-scaled evolution for parameter :$(name) requires a positive lower bound",
        ))
    elseif scale === :integer
        all(value -> value isa Integer, (lower, default, upper)) || throw(ArgumentError(
            "integer-scaled evolution for parameter :$(name) requires integer bounds and default",
        ))
    end

    mutation_scale = hasproperty(evolve, :mutation_scale) ? evolve.mutation_scale : nothing
    if mutation_scale !== nothing
        mutation_scale isa Real && isfinite(mutation_scale) && mutation_scale > 0 ||
            throw(ArgumentError(
                "evolution mutation_scale for parameter :$(name) must be finite and positive",
            ))
    end
    return (
        lower=lower,
        upper=upper,
        scale=scale,
        mutation_scale=mutation_scale,
    )
end

function _parameter_evolution(evolve, validator, name::Symbol, default)
    evolve === nothing && return nothing
    evolve isa NamedTuple || throw(ArgumentError(
        "evolution metadata for parameter :$(name) must be a NamedTuple",
    ))
    hasproperty(evolve, :values) &&
        return _categorical_evolution(evolve, validator, name)
    return _bounded_evolution(evolve, validator, name, default)
end

"""
    ParameterSpec(name, default; kwargs...)

One configurable parameter and its cold-path research metadata. `owner`
identifies the component level that interprets the value; node count therefore
need not be owned by a node model. `sweep` is a finite candidate set. `evolve`
is either `(values=(...),)` or bounded metadata with `lower`, `upper`, and
optional `scale`/`mutation_scale`.
"""
struct ParameterSpec{T,V,S,E}
    name::Symbol
    owner::Symbol
    default::T
    validator::V
    sweep::S
    evolve::E
    description::String
    units::Union{Nothing,String}
end

function ParameterSpec(
    name::Union{Symbol,AbstractString},
    default;
    owner::Union{Symbol,AbstractString}=:node,
    validator=nothing,
    sweep=nothing,
    evolve=nothing,
    description::AbstractString="",
    units::Union{Nothing,AbstractString}=nothing,
)
    name_ = _nonempty_symbol(name, "parameter name")
    owner_ = _nonempty_symbol(owner, "parameter owner")
    units_ = units === nothing ? nothing : String(units)
    units_ !== nothing && isempty(strip(units_)) &&
        throw(ArgumentError("parameter units must not be empty"))
    _parameter_value_valid(validator, default, name_)
    sweep_ = _parameter_sweep(sweep, validator, name_)
    evolve_ = _parameter_evolution(evolve, validator, name_, default)
    return ParameterSpec{
        typeof(default),
        typeof(validator),
        typeof(sweep_),
        typeof(evolve_),
    }(
        name_,
        owner_,
        default,
        validator,
        sweep_,
        evolve_,
        String(description),
        units_,
    )
end

"""Validate and return a candidate value for a parameter."""
validate_parameter(spec::ParameterSpec, value) =
    _parameter_value_valid(spec.validator, value, spec.name)

sweepable(spec::ParameterSpec) = spec.sweep !== nothing
evolvable(spec::ParameterSpec) = spec.evolve !== nothing

"""
    SeedStreamSpec(name; description="")

A declared independent random stream. Stream names become stable inputs to seed
derivation and must therefore be treated as part of an evaluation protocol.
"""
struct SeedStreamSpec
    name::Symbol
    description::String

    function SeedStreamSpec(
        name::Union{Symbol,AbstractString};
        description::AbstractString="",
    )
        name_ = _nonempty_symbol(name, "seed stream name")
        return new(name_, String(description))
    end
end

const DEFAULT_SEED_STREAMS = (
    SeedStreamSpec(:environment),
    SeedStreamSpec(:node_construction),
    SeedStreamSpec(:runtime),
    SeedStreamSpec(:trial),
    SeedStreamSpec(:optimizer),
    SeedStreamSpec(:bootstrap),
)

function _seed_streams(streams)
    source = streams isa Union{Symbol,AbstractString,SeedStreamSpec} ? (streams,) : streams
    result = Tuple(
        stream isa SeedStreamSpec ? stream : SeedStreamSpec(stream)
        for stream in source
    )
    isempty(result) && throw(ArgumentError("evaluation must declare at least one seed stream"))
    names = getfield.(result, :name)
    length(unique(names)) == length(names) ||
        throw(ArgumentError("evaluation seed stream names must be unique"))
    return result
end

function _root_seed(seed::Integer)
    seed >= 0 || throw(ArgumentError("evaluation root_seed must be non-negative"))
    try
        return UInt64(seed)
    catch
        throw(ArgumentError("evaluation root_seed must fit in UInt64"))
    end
end

"""
    EvaluationSpec(; kwargs...)

Outer replication protocol for a resolved composition. Construction scope,
reset policy, and aggregation are explicit so trials cannot silently share
state or change their inferential unit.
"""
struct EvaluationSpec{S<:Tuple}
    blocks::Int
    trials_per_block::Int
    horizon::Int
    warmup::Int
    construction_scope::Symbol
    reset::Symbol
    root_seed::UInt64
    streams::S
    aggregate::Symbol
end

function EvaluationSpec(;
    blocks::Integer=1,
    trials_per_block::Integer=1,
    horizon::Integer,
    warmup::Integer=0,
    construction_scope::Symbol=:trial,
    reset::Symbol=:full,
    root_seed::Integer=0,
    streams=DEFAULT_SEED_STREAMS,
    aggregate::Symbol=:mean,
)
    blocks_ = Int(blocks)
    trials_ = Int(trials_per_block)
    horizon_ = Int(horizon)
    warmup_ = Int(warmup)
    blocks_ > 0 || throw(ArgumentError("evaluation blocks must be positive"))
    trials_ > 0 || throw(ArgumentError("evaluation trials_per_block must be positive"))
    horizon_ > 0 || throw(ArgumentError("evaluation horizon must be positive"))
    warmup_ >= 0 || throw(ArgumentError("evaluation warmup must be non-negative"))
    construction_scope in CONSTRUCTION_SCOPES || throw(ArgumentError(
        "evaluation construction_scope must be one of " *
        join(":" .* string.(CONSTRUCTION_SCOPES), ", "),
    ))
    reset in RESET_POLICIES || throw(ArgumentError(
        "evaluation reset must be one of " *
        join(":" .* string.(RESET_POLICIES), ", "),
    ))
    aggregate in AGGREGATE_POLICIES || throw(ArgumentError(
        "evaluation aggregate must be one of " *
        join(":" .* string.(AGGREGATE_POLICIES), ", "),
    ))
    streams_ = _seed_streams(streams)
    return EvaluationSpec{typeof(streams_)}(
        blocks_,
        trials_,
        horizon_,
        warmup_,
        construction_scope,
        reset,
        _root_seed(root_seed),
        streams_,
        aggregate,
    )
end

seed_stream_names(spec::EvaluationSpec) = getfield.(spec.streams, :name)

const _FNV64_OFFSET = UInt64(0xcbf29ce484222325)
const _FNV64_PRIME = UInt64(0x00000100000001b3)
const _SPLITMIX64_GAMMA = UInt64(0x9e3779b97f4a7c15)
const _SPLITMIX64_MIX1 = UInt64(0xbf58476d1ce4e5b9)
const _SPLITMIX64_MIX2 = UInt64(0x94d049bb133111eb)

function _stable_symbol_word(name::Symbol)
    value = _FNV64_OFFSET
    for byte in codeunits(String(name))
        value = (value ⊻ UInt64(byte)) * _FNV64_PRIME
    end
    return value
end

@inline function _splitmix64(value::UInt64)
    mixed = value + _SPLITMIX64_GAMMA
    mixed = (mixed ⊻ (mixed >> 30)) * _SPLITMIX64_MIX1
    mixed = (mixed ⊻ (mixed >> 27)) * _SPLITMIX64_MIX2
    return mixed ⊻ (mixed >> 31)
end

"""
    derive_seed(spec, stream, coordinates...)

Derive a schedule-independent `UInt64` seed from the evaluation root, declared
stream name, and non-negative integer coordinates such as block and trial.
The algorithm uses stable UTF-8/FNV name encoding followed by SplitMix64; it
never calls Julia's version-dependent `hash`.
"""
function derive_seed(
    spec::EvaluationSpec,
    stream::Union{Symbol,AbstractString},
    coordinates::Integer...,
)
    stream_ = Symbol(stream)
    stream_ in seed_stream_names(spec) || throw(KeyError(
        "Unknown evaluation seed stream :$(stream_). Declared streams: " *
        join(":" .* string.(seed_stream_names(spec)), ", "),
    ))
    seed = _splitmix64(spec.root_seed ⊻ _stable_symbol_word(stream_))
    for (position, coordinate) in enumerate(coordinates)
        coordinate >= 0 || throw(ArgumentError("seed coordinates must be non-negative"))
        coordinate_ = try
            UInt64(coordinate)
        catch
            throw(ArgumentError("seed coordinates must fit in UInt64"))
        end
        position_word = UInt64(position) * _SPLITMIX64_GAMMA
        seed = _splitmix64(seed ⊻ coordinate_ ⊻ position_word)
    end
    return seed
end
