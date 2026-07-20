const COMPONENT_READINESS_LEVELS = (:available, :integrated, :core)
const _COMPONENT_READINESS_RANK = Dict(level => rank for (rank, level) in enumerate(COMPONENT_READINESS_LEVELS))
const _COMPONENT_PACKAGE_ROOT = normpath(joinpath(@__DIR__, "..", ".."))

"""Focused contract check supporting one component-readiness claim."""
struct ComponentConformance
    name::Symbol
    path::String

    function ComponentConformance(name::Symbol, path::AbstractString)
        isempty(String(name)) && throw(ArgumentError("component conformance name must not be empty"))
        isempty(strip(path)) && throw(ArgumentError("component conformance path must not be empty"))
        return new(name, String(path))
    end
end

"""
    ComponentDescriptor(family, kind, config_resolver; kwargs...)

Typed, cold-path discovery metadata for one experimental component. Relative
evidence paths are resolved against `root`, which defaults to the BrainlessLab
package root; extensions should pass their own package root.

`readiness` is one of `:available`, `:integrated`, or `:core`:

- `:available` means the component can be discovered and materialized with a
  focused conformance check;
- `:integrated` means it also participates in a standard runtime, serialization,
  documentation, and an executable example;
- `:core` is reserved for default/stable surfaces with named core-test coverage.

Every claim points to conformance, documentation, and executable-example paths.
A `:core` claim must additionally declare the focused core-test symbols that
cover it. Readiness is lightweight discovery metadata, not a blanket CI gate.
"""
struct ComponentDescriptor{F,C<:Tuple,T<:Tuple,P<:NamedTuple}
    family::Symbol
    kind::Symbol
    config_resolver::F
    status::Symbol
    readiness::Symbol
    capabilities::C
    parameters::P
    conformance::ComponentConformance
    docs_path::String
    example_path::String
    core_tests::T
    root::String
end

function _component_parameter_schema(schema)
    schema isa NamedTuple || throw(ArgumentError(
        "component parameters must be a NamedTuple with :required and :optional fields",
    ))
    propertynames(schema) == (:required, :optional) || throw(ArgumentError(
        "component parameters must have exactly (:required, :optional) fields",
    ))
    required = _component_symbols(schema.required, "required parameters")
    optional = _component_symbols(schema.optional, "optional parameters")
    overlap = intersect(Set(required), Set(optional))
    isempty(overlap) || throw(ArgumentError(
        "component required and optional parameters overlap: $(sort!(collect(overlap); by=String))",
    ))
    return (required=required, optional=optional)
end

function _component_symbols(values, label::AbstractString)
    source = values isa Union{Symbol,AbstractString} ? (values,) : values
    result = Tuple(Symbol(value) for value in source)
    all(value -> !isempty(String(value)), result) ||
        throw(ArgumentError("component $(label) must not contain empty symbols"))
    length(unique(result)) == length(result) ||
        throw(ArgumentError("component $(label) must be unique"))
    return result
end

function ComponentDescriptor(
    family::Union{Symbol,AbstractString},
    kind::Union{Symbol,AbstractString},
    config_resolver;
    status::Symbol=:experimental,
    readiness::Symbol=:available,
    capabilities=(),
    parameters=(required=(), optional=()),
    conformance::Union{Symbol,AbstractString},
    conformance_path::AbstractString,
    docs_path::AbstractString,
    example_path::AbstractString,
    core_tests=(),
    root::AbstractString=_COMPONENT_PACKAGE_ROOT,
)
    family_ = Symbol(family)
    kind_ = Symbol(kind)
    isempty(String(family_)) && throw(ArgumentError("component family must not be empty"))
    isempty(String(kind_)) && throw(ArgumentError("component kind must not be empty"))
    capabilities_ = _component_symbols(capabilities, "capabilities")
    parameters_ = _component_parameter_schema(parameters)
    core_tests_ = _component_symbols(core_tests, "core tests")
    return ComponentDescriptor{typeof(config_resolver),typeof(capabilities_),typeof(core_tests_),typeof(parameters_)}(
        family_,
        kind_,
        config_resolver,
        status,
        readiness,
        capabilities_,
        parameters_,
        ComponentConformance(Symbol(conformance), conformance_path),
        String(docs_path),
        String(example_path),
        core_tests_,
        abspath(String(root)),
    )
end

const COMPONENTS = Dict{Tuple{Symbol,Symbol},ComponentDescriptor}()

_component_key(family, kind) = (Symbol(family), Symbol(kind))
_component_path(descriptor::ComponentDescriptor, path::AbstractString) =
    isabspath(path) ? normpath(path) : normpath(joinpath(descriptor.root, path))

function _is_component_callable(value)
    try
        return !isempty(methods(value))
    catch
        return false
    end
end

function _require_component_path(descriptor::ComponentDescriptor, label::AbstractString, path::AbstractString)
    isempty(strip(path)) && throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) $(label) path must not be empty",
    ))
    resolved = _component_path(descriptor, path)
    ispath(resolved) || throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) $(label) path does not exist: $(resolved)",
    ))
    return resolved
end

"""
    validate_component_descriptor(descriptor)

Validate the lightweight evidence attached to a descriptor. This checks claims,
not component behaviour: focused conformance suites remain responsible for the
runtime contract itself.
"""
function validate_component_descriptor(descriptor::ComponentDescriptor)
    descriptor.status === :experimental || throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) status must be :experimental",
    ))
    haskey(_COMPONENT_READINESS_RANK, descriptor.readiness) || throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) readiness must be one of " *
        join(":" .* string.(COMPONENT_READINESS_LEVELS), ", "),
    ))
    _is_component_callable(descriptor.config_resolver) || throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) config_resolver must be callable",
    ))
    isdir(descriptor.root) || throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) root does not exist: $(descriptor.root)",
    ))
    _require_component_path(descriptor, "conformance", descriptor.conformance.path)
    _require_component_path(descriptor, "documentation", descriptor.docs_path)
    _require_component_path(descriptor, "example", descriptor.example_path)
    if descriptor.readiness === :core && isempty(descriptor.core_tests)
        throw(ArgumentError(
            "component :$(descriptor.family)/:$(descriptor.kind) readiness :core requires declared core-test coverage",
        ))
    end
    return descriptor
end

"""Register a validated descriptor; pass `replace=true` for an intentional replacement."""
function register_component!(descriptor::ComponentDescriptor; replace::Bool=false)
    validate_component_descriptor(descriptor)
    key = (descriptor.family, descriptor.kind)
    haskey(COMPONENTS, key) && !replace && throw(ArgumentError(
        "component :$(descriptor.family)/:$(descriptor.kind) is already registered; " *
        "pass replace=true to replace it intentionally",
    ))
    COMPONENTS[key] = descriptor
    return descriptor
end

function register_component!(family, kind, config_resolver; replace::Bool=false, kwargs...)
    return register_component!(
        ComponentDescriptor(family, kind, config_resolver; kwargs...);
        replace=replace,
    )
end

"""Resolve a registered component descriptor, throwing a registry-style `KeyError`."""
function resolve_component(family::Union{Symbol,AbstractString}, kind::Union{Symbol,AbstractString})
    key = _component_key(family, kind)
    haskey(COMPONENTS, key) && return COMPONENTS[key]
    known = sort!(collect(keys(COMPONENTS)))
    known_msg = isempty(known) ? "none registered" : join((":$(f)/:$(k)" for (f, k) in known), ", ")
    throw(KeyError("Unknown component key :$(key[1])/:$(key[2]). Known keys: $(known_msg)."))
end

"""Return metadata for one registered component."""
component_info(family::Union{Symbol,AbstractString}, kind::Union{Symbol,AbstractString}) =
    resolve_component(family, kind)

function _readiness_rank(level::Symbol)
    haskey(_COMPONENT_READINESS_RANK, level) || throw(ArgumentError(
        "readiness filter must be one of " * join(":" .* string.(COMPONENT_READINESS_LEVELS), ", "),
    ))
    return _COMPONENT_READINESS_RANK[level]
end

"""
    components(; family=nothing, readiness=nothing)

Return registered descriptors sorted by family and kind. `readiness` is a
minimum readiness filter: `:available` includes every registered level, while
`:core` includes only core components.
"""
function components(; family=nothing, readiness=nothing)
    family_ = family === nothing ? nothing : Symbol(family)
    rank = readiness === nothing ? nothing : _readiness_rank(Symbol(readiness))
    found = ComponentDescriptor[]
    for descriptor in values(COMPONENTS)
        family_ === nothing || descriptor.family === family_ || continue
        rank === nothing || _COMPONENT_READINESS_RANK[descriptor.readiness] >= rank || continue
        push!(found, descriptor)
    end
    sort!(found; by=descriptor -> (String(descriptor.family), String(descriptor.kind)))
    return found
end

function _readiness_row(descriptor::ComponentDescriptor)
    return (
        family=descriptor.family,
        kind=descriptor.kind,
        status=descriptor.status,
        readiness=descriptor.readiness,
        capabilities=descriptor.capabilities,
        parameters=descriptor.parameters,
        conformance=descriptor.conformance.name,
        docs=descriptor.docs_path,
        example=descriptor.example_path,
        core_tests=descriptor.core_tests,
    )
end

"""Return sorted readiness rows for all registered components."""
readiness() = [_readiness_row(descriptor) for descriptor in components()]

"""Return the readiness level claimed by one registered component."""
readiness(family::Union{Symbol,AbstractString}, kind::Union{Symbol,AbstractString}) =
    component_info(family, kind).readiness

_markdown_cell(value) = replace(string(value), '|' => "\\|", '\n' => ' ')
_markdown_symbols(values) = isempty(values) ? "—" : join((":$(value)" for value in values), ", ")

"""
    readiness_markdown()

Generate a compact Markdown readiness table from the live component catalog.
"""
function readiness_markdown()
    rows = String[
        "| Family | Component | Status | Readiness | Capabilities | Conformance | Core tests |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for descriptor in components()
        push!(rows, join((
            "| :$(_markdown_cell(descriptor.family)) ",
            " :$(_markdown_cell(descriptor.kind)) ",
            " :$(_markdown_cell(descriptor.status)) ",
            " :$(_markdown_cell(descriptor.readiness)) ",
            " $(_markdown_symbols(descriptor.capabilities)) ",
            " :$(_markdown_cell(descriptor.conformance.name)) ",
            " $(_markdown_symbols(descriptor.core_tests)) |",
        ), "|"))
    end
    return join(rows, '\n') * "\n"
end
