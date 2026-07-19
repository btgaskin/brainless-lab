import TOML

const EMBODIMENT_SCHEMA_VERSION = 1
const _EMBODIMENT_TOP_LEVEL_KEYS = Set(("schema_version", "name", "extends", "components", "overrides"))
const _EMBODIMENT_COMPONENT_KEYS = Set(("id", "family", "kind", "parameters"))
const _EMBODIMENT_LEGACY_KEYS = Set(("ven", "body", "morphology", "motor"))
const _COMPOSABLE_EMBODIMENT_FAMILIES =
    (:geometry, :sensor, :encoder, :actuator, :dynamics, :physiology)

"""Runtime-independent configuration for one named embodiment component."""
struct ComponentConfig{P<:NamedTuple}
    id::Symbol
    family::Symbol
    kind::Symbol
    parameters::P

    function ComponentConfig{P}(id::Symbol, family::Symbol, kind::Symbol, parameters::P) where {P<:NamedTuple}
        isempty(String(id)) && throw(ArgumentError("component id must not be empty"))
        occursin('.', String(id)) && throw(ArgumentError(
            "component id :$(id) must not contain `.` because IDs anchor dot-path overrides",
        ))
        isempty(String(family)) && throw(ArgumentError("component family must not be empty"))
        isempty(String(kind)) && throw(ArgumentError("component kind must not be empty"))
        family in (:body, :morphology, :motor, :ven) && throw(ArgumentError(
            "legacy component family :$(family) is unsupported; use generic families such as " *
            ":geometry, :sensor, :encoder, :actuator, :dynamics, or :physiology",
        ))
        kind === :ven && throw(ArgumentError(
            "legacy component kind :ven is unsupported; compose the required generic components explicitly",
        ))
        return new{P}(id, family, kind, parameters)
    end
end

function ComponentConfig(
    id::Union{Symbol,AbstractString},
    family::Union{Symbol,AbstractString},
    kind::Union{Symbol,AbstractString},
    parameters::NamedTuple=NamedTuple(),
)
    id_ = Symbol(id)
    family_ = Symbol(family)
    kind_ = Symbol(kind)
    return ComponentConfig{typeof(parameters)}(id_, family_, kind_, parameters)
end

"""Resolved, schema-versioned embodiment definition independent of runtime types."""
struct EmbodimentConfig{C<:Tuple}
    schema_version::Int
    name::Symbol
    components::C
    source::String

    function EmbodimentConfig{C}(schema_version::Int, name::Symbol, components::C, source::String) where {C<:Tuple}
        schema_version == EMBODIMENT_SCHEMA_VERSION || throw(ArgumentError(
            "unsupported embodiment schema_version $(schema_version); expected $(EMBODIMENT_SCHEMA_VERSION)",
        ))
        isempty(String(name)) && throw(ArgumentError("embodiment name must not be empty"))
        all(component -> component isa ComponentConfig, components) || throw(ArgumentError(
            "embodiment components must all be ComponentConfig values",
        ))
        ids = Symbol[component.id for component in components]
        length(unique(ids)) == length(ids) || throw(ArgumentError(
            "embodiment component ids must be unique; got $(ids)",
        ))
        isempty(components) && throw(ArgumentError("embodiment requires at least one component"))
        return new{C}(schema_version, name, components, source)
    end
end

function EmbodimentConfig(
    schema_version::Integer,
    name::Union{Symbol,AbstractString},
    components::Tuple,
    source::AbstractString="<memory>",
)
    version = Int(schema_version)
    name_ = Symbol(name)
    return EmbodimentConfig{typeof(components)}(version, name_, components, String(source))
end

"""One materialized component value, retaining its stable configuration identity."""
struct ComponentBlueprint{V}
    id::Symbol
    family::Symbol
    kind::Symbol
    value::V
end

"""Typed tuple of independently materialized, stably identified components."""
struct EmbodimentBlueprint{C<:Tuple}
    schema_version::Int
    name::Symbol
    components::C
    source::String
end

_embodiment_key(key) = String(key)

function _legacy_embodiment_error(key::AbstractString, context::AbstractString)
    replacement =
        key == "motor" ? "declare separate :actuator and :dynamics components" :
        key == "body" || key == "morphology" ? "declare generic [[components]] entries" :
        "compose the former VEN behaviour from generic components"
    throw(ArgumentError("legacy embodiment key `$(key)` in $(context) is unsupported; $(replacement)"))
end

function _reject_unknown_keys(table::AbstractDict, allowed, context::AbstractString)
    keys_ = sort!(_embodiment_key.(collect(keys(table))))
    for key in keys_
        key in _EMBODIMENT_LEGACY_KEYS && _legacy_embodiment_error(key, context)
        key in allowed || throw(ArgumentError(
            "unknown embodiment key `$(key)` in $(context); allowed keys: $(join(sort!(collect(allowed)), ", "))",
        ))
    end
    return table
end

function _required_embodiment_value(table::AbstractDict, key::AbstractString, context::AbstractString)
    haskey(table, key) || throw(ArgumentError("$(context) requires `$(key)`"))
    return table[key]
end

function _identifier(value, label::AbstractString)
    value isa Union{Symbol,AbstractString} || throw(ArgumentError("$(label) must be a string"))
    isempty(strip(String(value))) && throw(ArgumentError("$(label) must not be empty"))
    return Symbol(value)
end

function _canonical_parameter_value(value, context::AbstractString)
    if value isa AbstractDict
        names = sort!(Symbol.(String.(collect(keys(value)))); by=String)
        length(unique(names)) == length(names) || throw(ArgumentError("duplicate parameter keys in $(context)"))
        for name in names
            isempty(String(name)) && throw(ArgumentError("empty parameter key in $(context)"))
            occursin('.', String(name)) && throw(ArgumentError(
                "parameter key `$(name)` in $(context) must not contain `.`; use nested TOML tables for dot paths",
            ))
        end
        values = Tuple(
            _canonical_parameter_value(value[String(name)], "$(context).$(name)")
            for name in names
        )
        return NamedTuple{Tuple(names)}(values)
    elseif value isa AbstractVector || value isa Tuple
        return Tuple(_canonical_parameter_value(item, context) for item in value)
    elseif value isa Union{AbstractString,Bool,Integer,AbstractFloat}
        value isa AbstractFloat && !isfinite(value) && throw(ArgumentError(
            "non-finite parameter in $(context) is not valid TOML",
        ))
        return value isa AbstractString ? String(value) : value
    end
    throw(ArgumentError("unsupported parameter value $(typeof(value)) in $(context)"))
end

function _component_from_table(table, index::Int, context::AbstractString)
    table isa AbstractDict || throw(ArgumentError("$(context) component $(index) must be a TOML table"))
    label = "$(context) component $(index)"
    _reject_unknown_keys(table, _EMBODIMENT_COMPONENT_KEYS, label)
    id = _identifier(_required_embodiment_value(table, "id", label), "$(label) id")
    family = _identifier(_required_embodiment_value(table, "family", label), "$(label) family")
    kind = _identifier(_required_embodiment_value(table, "kind", label), "$(label) kind")
    raw_parameters = get(table, "parameters", Dict{String,Any}())
    raw_parameters isa AbstractDict || throw(ArgumentError("$(label) parameters must be a TOML table"))
    parameters = _canonical_parameter_value(raw_parameters, "component :$(id)")
    return ComponentConfig(id, family, kind, parameters)
end

function _components_from_data(data::AbstractDict, context::AbstractString)
    raw = get(data, "components", nothing)
    raw === nothing && throw(ArgumentError("$(context) requires at least one `[[components]]` table"))
    raw isa AbstractVector || throw(ArgumentError("$(context) `components` must be an array of tables"))
    components = Tuple(_component_from_table(table, index, context) for (index, table) in enumerate(raw))
    ids = Symbol[component.id for component in components]
    length(unique(ids)) == length(ids) || throw(ArgumentError(
        "$(context) component ids must be unique; got $(ids)",
    ))
    isempty(components) && throw(ArgumentError("$(context) requires at least one component"))
    return components
end

function _parameter_has(parameters::NamedTuple, path::Tuple{Vararg{Symbol}})
    current = parameters
    for (index, key) in enumerate(path)
        current isa NamedTuple || return false
        hasproperty(current, key) || return false
        current = getproperty(current, key)
        index == length(path) || current isa NamedTuple || return false
    end
    return true
end

function _replace_parameter(parameters::NamedTuple, path::Tuple{Vararg{Symbol}}, value)
    key = first(path)
    names = propertynames(parameters)
    values = map(names) do name
        current = getproperty(parameters, name)
        if name === key
            return length(path) == 1 ? value : _replace_parameter(current, Base.tail(path), value)
        end
        return current
    end
    return NamedTuple{names}(values)
end

function _override_entries(raw, context::AbstractString)
    raw === nothing && return Pair{String,Any}[]
    raw isa AbstractDict || throw(ArgumentError("$(context) `overrides` must be a TOML table"))
    entries = Pair{String,Any}[]
    for (key, value) in raw
        value isa AbstractDict && throw(ArgumentError(
            "override `$(key)` in $(context) must be an explicit quoted dot path, for example " *
            "\"camera.range\" = 8.0",
        ))
        push!(entries, String(key) => value)
    end
    sort!(entries; by=first)
    return entries
end

function _apply_overrides(components::Tuple, raw, context::AbstractString)
    entries = _override_entries(raw, context)
    isempty(entries) && return components
    updated = components
    for (path_string, raw_value) in entries
        segments = split(path_string, '.')
        length(segments) >= 2 || throw(ArgumentError(
            "override `$(path_string)` must have the form component_id.parameter_key",
        ))
        any(isempty, segments) && throw(ArgumentError("override `$(path_string)` contains an empty path segment"))
        component_id = Symbol(first(segments))
        parameter_path = Tuple(Symbol(segment) for segment in segments[2:end])
        first(parameter_path) in (:id, :family, :kind, :components) && throw(ArgumentError(
            "override `$(path_string)` targets structure; overrides may change existing parameter keys only",
        ))
        component_index = findfirst(component -> component.id === component_id, updated)
        component_index === nothing && throw(ArgumentError(
            "override `$(path_string)` targets unknown component id :$(component_id); overrides cannot append components",
        ))
        component = updated[component_index]
        _parameter_has(component.parameters, parameter_path) || throw(ArgumentError(
            "override `$(path_string)` targets a missing parameter; overrides cannot add parameter keys",
        ))
        value = _canonical_parameter_value(raw_value, "override $(path_string)")
        parameters = _replace_parameter(component.parameters, parameter_path, value)
        replacement = ComponentConfig(component.id, component.family, component.kind, parameters)
        updated = Base.setindex(updated, replacement, component_index)
    end
    return updated
end

function _schema_version(data::AbstractDict, context::AbstractString)
    raw = _required_embodiment_value(data, "schema_version", context)
    raw isa Integer || throw(ArgumentError("$(context) schema_version must be an integer"))
    version = Int(raw)
    version == EMBODIMENT_SCHEMA_VERSION || throw(ArgumentError(
        "unsupported embodiment schema_version $(version) in $(context); expected $(EMBODIMENT_SCHEMA_VERSION)",
    ))
    return version
end

function _read_embodiment_data(path::AbstractString; allow_extends::Bool)
    resolved_path = abspath(String(path))
    isfile(resolved_path) || throw(ArgumentError("embodiment config does not exist: $(resolved_path)"))
    data = TOML.parsefile(resolved_path)
    context = "embodiment config $(resolved_path)"
    _reject_unknown_keys(data, _EMBODIMENT_TOP_LEVEL_KEYS, context)
    version = _schema_version(data, context)
    name = _identifier(_required_embodiment_value(data, "name", context), "$(context) name")
    extends = get(data, "extends", nothing)

    components = if extends === nothing
        _components_from_data(data, context)
    else
        allow_extends || throw(ArgumentError(
            "$(context) uses nested or recursive `extends`; embodiment inheritance is limited to one level",
        ))
        extends isa AbstractString || throw(ArgumentError("$(context) `extends` must be a relative file path"))
        isabspath(extends) && throw(ArgumentError("$(context) `extends` must be relative to the referring file"))
        haskey(data, "components") && throw(ArgumentError(
            "$(context) cannot declare `components` while extending another definition; use overrides of existing parameters",
        ))
        base_path = normpath(joinpath(dirname(resolved_path), String(extends)))
        base_path == resolved_path && throw(ArgumentError("$(context) cannot extend itself"))
        base = _read_embodiment_data(base_path; allow_extends=false)
        base.schema_version == version || throw(ArgumentError(
            "$(context) and its base must use the same schema_version",
        ))
        base.components
    end
    components = _apply_overrides(components, get(data, "overrides", nothing), context)
    return EmbodimentConfig(version, name, components, resolved_path)
end

"""Read, resolve, and strictly validate an embodiment TOML definition."""
read_embodiment_config(path::AbstractString) = _read_embodiment_data(path; allow_extends=true)

function _canonical_named_value(value)
    if value isa NamedTuple
        return NamedTuple{propertynames(value)}(Tuple(_canonical_named_value(v) for v in values(value)))
    elseif value isa Tuple
        return Tuple(_canonical_named_value(v) for v in value)
    elseif value isa Symbol
        return String(value)
    end
    return value
end

"""Return the resolved, source-independent canonical NamedTuple representation."""
function embodiment_config_namedtuple(config::EmbodimentConfig)
    return (
        schema_version=config.schema_version,
        name=String(config.name),
        components=Tuple((
            id=String(component.id),
            family=String(component.family),
            kind=String(component.kind),
            parameters=_canonical_named_value(component.parameters),
        ) for component in config.components),
    )
end

function _toml_dict(value::NamedTuple)
    return Dict{String,Any}(String(key) => _toml_dict(item) for (key, item) in pairs(value))
end
_toml_dict(value::Tuple) = Any[_toml_dict(item) for item in value]
_toml_dict(value) = value

"""Serialize a resolved embodiment definition to deterministic canonical TOML."""
function canonical_embodiment_toml(config::EmbodimentConfig)
    io = IOBuffer()
    TOML.print(io, _toml_dict(embodiment_config_namedtuple(config)); sorted=true)
    return String(take!(io))
end

"""Write deterministic resolved embodiment TOML to `path`."""
function write_embodiment_config(path::AbstractString, config::EmbodimentConfig)
    open(path, "w") do io
        write(io, canonical_embodiment_toml(config))
    end
    return String(path)
end

function _materialize_component(component::ComponentConfig)
    descriptor = resolve_component(component.family, component.kind)
    value = descriptor.config_resolver(component)
    return ComponentBlueprint(component.id, component.family, component.kind, value)
end

function _materialize_blueprint(config::EmbodimentConfig)
    components = map(_materialize_component, config.components)
    return EmbodimentBlueprint(config.schema_version, config.name, components, config.source)
end

"""Resolve independently constructed components while retaining their stable IDs."""
materialize_blueprint(config::EmbodimentConfig) = _materialize_blueprint(config)

_family_components(blueprint::EmbodimentBlueprint, family::Symbol) =
    Tuple(component for component in blueprint.components if component.family === family)

function _validate_composable_families(blueprint::EmbodimentBlueprint)
    unsupported = Tuple(
        (id=component.id, family=component.family)
        for component in blueprint.components
        if !(component.family in _COMPOSABLE_EMBODIMENT_FAMILIES)
    )
    isempty(unsupported) || throw(ArgumentError(
        "embodiment :$(blueprint.name) contains component families that the standard " *
        "Embodiment cannot compose: $(unsupported); supported families are " *
        "$(_COMPOSABLE_EMBODIMENT_FAMILIES)",
    ))
    return nothing
end

function _single_component(blueprint, family::Symbol, default)
    found = _family_components(blueprint, family)
    length(found) <= 1 || throw(ArgumentError(
        "embodiment :$(blueprint.name) declares multiple :$(family) components; this family is singular",
    ))
    return isempty(found) ? (id=family, value=default) : only(found)
end

function _sensor_identity_ids(sensors)
    ids = Symbol[]
    for sensor in sensors
        append!(ids, _sensor_identity_port_ids(sensor.id, sensor.value))
    end
    length(unique(ids)) == length(ids) || throw(ArgumentError(
        "embodiment sensor-derived receptor IDs must be unique",
    ))
    return Tuple(ids)
end

function _compose_embodiment(blueprint::EmbodimentBlueprint)
    _validate_composable_families(blueprint)
    geometry = _single_component(blueprint, :geometry, NoGeometry())
    dynamics = _single_component(blueprint, :dynamics, NoDynamics())
    physiology = _single_component(blueprint, :physiology, NoPhysiology())
    sensors = _family_components(blueprint, :sensor)
    actuators = _family_components(blueprint, :actuator)
    encoder_components = _family_components(blueprint, :encoder)
    isempty(sensors) && throw(ArgumentError("embodiment :$(blueprint.name) requires at least one sensor"))
    isempty(actuators) && throw(ArgumentError("embodiment :$(blueprint.name) requires at least one actuator"))

    encoders = if isempty(encoder_components)
        ((
            id=:identity_encoder,
            value=IdentityEncoder(
                _sensor_identity_ids(sensors);
                sources=Tuple(component.id for component in sensors),
            ),
        ),)
    else
        encoder_components
    end

    body = Embodiment(;
        geometry=geometry.value,
        sensors=Tuple(component.value for component in sensors),
        encoders=Tuple(component.value for component in encoders),
        actuators=Tuple(component.value for component in actuators),
        dynamics=dynamics.value,
        physiology=physiology.value,
        traits=(preset=blueprint.name, source=blueprint.source),
        state=(schema_version=blueprint.schema_version,),
        component_ids=(
            geometry=geometry.id,
            sensors=Tuple(component.id for component in sensors),
            encoders=Tuple(component.id for component in encoders),
            actuators=Tuple(component.id for component in actuators),
            dynamics=dynamics.id,
            physiology=physiology.id,
        ),
    )

    if !(body.dynamics isa NoDynamics)
        length(body.state.commands) == 1 || throw(ArgumentError(
            "embodiment :$(blueprint.name) needs one actuator command for its single dynamics component",
        ))
        command = only(body.state.commands)
        applicable(integrate!, MotionState2D(), body.dynamics, command) || throw(ArgumentError(
            "embodiment :$(blueprint.name) dynamics $(typeof(body.dynamics)) cannot integrate command $(typeof(command))",
        ))
    end
    return body
end

"""
    materialize_embodiment(config)

Resolve the registered component graph into a fresh, runnable `Embodiment`.
Use [`materialize_blueprint`](@ref) when component-level cold-path metadata is
needed without assembly.
"""
materialize_embodiment(config::EmbodimentConfig) =
    _compose_embodiment(_materialize_blueprint(config))
