using Random

"""One bounded, named genotype block targeting parameters of one stable component ID."""
struct DevelopmentBlock{P<:Tuple,B<:Tuple}
    id::Symbol
    component_id::Symbol
    paths::P
    bounds::B
end

function _development_path_segment(value::AbstractString)
    integer = tryparse(Int, value)
    return integer === nothing ? Symbol(value) : integer
end

function _development_path(value)
    if value isa Symbol
        return (value,)
    elseif value isa AbstractString
        parts = split(String(value), '.')
        (isempty(parts) || any(isempty, parts)) && throw(ArgumentError(
            "development parameter path `$(value)` contains an empty segment",
        ))
        path = Tuple(_development_path_segment(part) for part in parts)
        any(part -> part isa Integer && part < 1, path) && throw(ArgumentError(
            "development parameter path indices must be positive and one-based",
        ))
        return path
    elseif value isa Tuple && all(
        part -> part isa Union{Symbol,AbstractString,Integer} && !(part isa Bool),
        value,
    )
        isempty(value) && throw(ArgumentError("development parameter paths must not be empty"))
        path = Tuple(
            part isa AbstractString ? _development_path_segment(part) : part
            for part in value
        )
        any(part -> part isa Symbol && isempty(String(part)), path) && throw(ArgumentError(
            "development parameter paths must not contain empty segments",
        ))
        any(part -> part isa Integer && part < 1, path) && throw(ArgumentError(
            "development parameter path indices must be positive and one-based",
        ))
        return path
    end
    throw(ArgumentError(
        "development parameter paths must be symbols, dot strings, or tuples of names and positive indices",
    ))
end

function _development_bound(value, label::AbstractString)
    value isa Tuple && length(value) == 2 || throw(ArgumentError(
        "$(label) bounds must be a `(minimum, maximum)` tuple",
    ))
    lo, hi = value
    lo isa Real && !(lo isa Bool) && hi isa Real && !(hi isa Bool) || throw(ArgumentError(
        "$(label) bounds must be real numbers",
    ))
    lo_, hi_ = Float64(lo), Float64(hi)
    all(isfinite, (lo_, hi_)) && lo_ < hi_ || throw(ArgumentError(
        "$(label) bounds must be finite and strictly ordered",
    ))
    return (lo_, hi_)
end

function DevelopmentBlock(
    id::Union{Symbol,AbstractString},
    component_id::Union{Symbol,AbstractString},
    genes,
)
    id_, component_id_ = Symbol(id), Symbol(component_id)
    isempty(String(id_)) && throw(ArgumentError("development block ID must not be empty"))
    isempty(String(component_id_)) && throw(ArgumentError("development component ID must not be empty"))
    entries = Tuple(genes)
    isempty(entries) && throw(ArgumentError("development block :$(id_) requires at least one gene"))
    all(entry -> entry isa Pair, entries) || throw(ArgumentError(
        "development block genes must be `parameter_path => (minimum, maximum)` pairs",
    ))
    paths = Tuple(_development_path(first(entry)) for entry in entries)
    length(unique(paths)) == length(paths) || throw(ArgumentError(
        "development block :$(id_) targets a parameter more than once",
    ))
    bounds = Tuple(
        _development_bound(last(entry), "development block :$(id_) path $(join(path, '.'))")
        for (entry, path) in zip(entries, paths)
    )
    return DevelopmentBlock{typeof(paths),typeof(bounds)}(id_, component_id_, paths, bounds)
end

DevelopmentBlock(
    id::Union{Symbol,AbstractString},
    component_id::Union{Symbol,AbstractString},
    gene::Pair,
    genes::Pair...,
) = DevelopmentBlock(id, component_id, (gene, genes...))

"""
Deterministic identity for one development event. This context initializes
fresh component state; it does not schedule births or runtime replacement.
"""
struct DevelopmentContext
    seed::UInt64
    entity_id::EntityID
    generation::Int

    function DevelopmentContext(seed::Integer, entity_id::EntityID, generation::Integer)
        seed >= 0 || throw(ArgumentError("development seed must be non-negative"))
        generation >= 0 || throw(ArgumentError("development generation must be non-negative"))
        return new(UInt64(seed), entity_id, Int(generation))
    end
end

DevelopmentContext(; seed::Integer=0, entity_id=EntityID(1), generation::Integer=0) =
    DevelopmentContext(seed, entity_id isa EntityID ? entity_id : EntityID(entity_id), generation)

function _fnv_development(bytes, initial::UInt64=0xcbf29ce484222325)
    value = initial
    for byte in bytes
        value = xor(value, UInt64(byte)) * UInt64(0x00000100000001b3)
    end
    return value
end

function _mix_development_uint(value::UInt64, item::UInt64)
    out = value
    @inbounds for shift in 0:8:56
        out = xor(out, (item >> shift) & 0xff) * UInt64(0x00000100000001b3)
    end
    return out
end

"""Stable per-component/per-stream seed derived without Julia's randomized `hash`."""
function development_seed(
    context::DevelopmentContext,
    component_id::Union{Symbol,AbstractString},
    stream::Union{Symbol,AbstractString}=:state,
)
    value = _mix_development_uint(UInt64(0xcbf29ce484222325), context.seed)
    value = _mix_development_uint(value, context.entity_id.value)
    value = _mix_development_uint(value, UInt64(context.generation))
    value = _fnv_development(codeunits(String(component_id)), value)
    return _fnv_development(codeunits(String(stream)), value)
end

"""
Immutable structural plan for bounded development. Components, block IDs,
parameter paths, bounds, and slices are fixed for the lifetime of the plan.
Only existing real scalar parameters vary: component addition/removal and
topology evolution are deliberately outside this contract.
"""
struct DevelopmentSpec{C<:EmbodimentConfig,B<:Tuple,S<:Tuple}
    config::C
    blocks::B
    slices::S
    dim::Int
    physical::Bool
    signature::UInt64
end

function _component_by_id(config::EmbodimentConfig, id::Symbol)
    index = findfirst(component -> component.id === id, config.components)
    index === nothing && throw(ArgumentError("development targets unknown component ID :$(id)"))
    return config.components[index]
end

_development_path_label(path::Tuple) = join(string.(path), '.')

function _named_collection_index(collection::Tuple, name::Symbol, path::Tuple)
    matches = findall(collection) do entry
        entry isa NamedTuple && hasproperty(entry, :name) || return false
        entry_name = getproperty(entry, :name)
        return entry_name isa Union{Symbol,AbstractString} && Symbol(entry_name) === name
    end
    length(matches) == 1 || throw(ArgumentError(
        isempty(matches) ?
            "development targets missing named collection member :$(name) in path $(_development_path_label(path))" :
            "development path $(_development_path_label(path)) is ambiguous because :$(name) occurs more than once",
    ))
    return only(matches)
end

function _collection_index(collection::Tuple, key, path::Tuple)
    if key isa Integer
        1 <= key <= length(collection) || throw(ArgumentError(
            "development path $(_development_path_label(path)) indexes collection position $(key), " *
            "but valid positions are 1:$(length(collection))",
        ))
        return Int(key)
    elseif key isa Symbol
        return _named_collection_index(collection, key, path)
    end
    throw(ArgumentError(
        "development path $(_development_path_label(path)) requires a positive index or stable named member",
    ))
end

function _parameter_child(current, key, path::Tuple)
    if current isa NamedTuple && key isa Symbol && hasproperty(current, key)
        return getproperty(current, key)
    elseif current isa Tuple
        return current[_collection_index(current, key, path)]
    end
    throw(ArgumentError(
        "development targets missing parameter path $(_development_path_label(path))",
    ))
end

function _parameter_at(parameters::NamedTuple, path::Tuple)
    current = parameters
    for key in path
        current = _parameter_child(current, key, path)
    end
    return current
end

function _replace_development_parameter(current, path::Tuple, value, full_path::Tuple=path)
    key = first(path)
    tail = Base.tail(path)
    if current isa NamedTuple && key isa Symbol && hasproperty(current, key)
        names = propertynames(current)
        values = map(names) do name
            child = getproperty(current, name)
            if name === key
                return isempty(tail) ? value :
                    _replace_development_parameter(child, tail, value, full_path)
            end
            return child
        end
        return NamedTuple{names}(values)
    elseif current isa Tuple
        index = _collection_index(current, key, full_path)
        child = current[index]
        replacement = isempty(tail) ? value :
            _replace_development_parameter(child, tail, value, full_path)
        return Base.setindex(current, replacement, index)
    end
    throw(ArgumentError(
        "development targets missing parameter path $(_development_path_label(full_path))",
    ))
end

function _block_slices(blocks::Tuple)
    offset = 1
    return map(blocks) do block
        width = length(block.paths)
        slice = offset:(offset + width - 1)
        offset += width
        slice
    end
end

function _development_signature(config::EmbodimentConfig, blocks::Tuple, physical::Bool)
    value = _fnv_development(codeunits(canonical_embodiment_toml(config)))
    value = _fnv_development(codeunits(physical ? "physical" : "unconstrained"), value)
    for block in blocks
        value = _fnv_development(codeunits(String(block.id)), value)
        value = _fnv_development(codeunits(String(block.component_id)), value)
        for (path, bounds) in zip(block.paths, block.bounds)
            value = _fnv_development(codeunits(_development_path_label(path)), value)
            value = _mix_development_uint(value, reinterpret(UInt64, bounds[1]))
            value = _mix_development_uint(value, reinterpret(UInt64, bounds[2]))
        end
    end
    return value
end

function _family_components(config::EmbodimentConfig, family::Symbol)
    return Tuple(component for component in config.components if component.family === family)
end

function _validate_bilateral_references(config::EmbodimentConfig)
    components = Dict(component.id => component for component in config.components)
    for encoder in config.components
        encoder.family === :encoder && encoder.kind === :bilateral_contrast || continue
        for name in (:left, :right)
            hasproperty(encoder.parameters, name) || throw(ArgumentError(
                "bilateral encoder :$(encoder.id) requires parameter :$(name)",
            ))
            raw_reference = getproperty(encoder.parameters, name)
            raw_reference isa Union{Symbol,AbstractString} || throw(ArgumentError(
                "bilateral encoder :$(encoder.id) parameter :$(name) must be a component ID",
            ))
            reference = Symbol(raw_reference)
            haskey(components, reference) || throw(ArgumentError(
                "bilateral encoder :$(encoder.id) references missing component :$(reference)",
            ))
            dependency = components[reference]
            dependency.family === :sensor || throw(ArgumentError(
                "bilateral encoder :$(encoder.id) reference :$(reference) is not a sensor component",
            ))
        end
        Symbol(encoder.parameters.left) !== Symbol(encoder.parameters.right) || throw(ArgumentError(
            "bilateral encoder :$(encoder.id) must reference two distinct sensors",
        ))
    end
    return config
end

function _validate_command_compatibility(config::EmbodimentConfig)
    actuators = _family_components(config, :actuator)
    dynamics = _family_components(config, :dynamics)
    (length(actuators) == 1 && length(dynamics) == 1) || return config
    actuator = _materialize_component(only(actuators)).value
    dynamics_ = _materialize_component(only(dynamics)).value
    actuator isa AbstractActuator || throw(ArgumentError(
        "component :$(only(actuators).id) did not materialize to an AbstractActuator",
    ))
    dynamics_ isa AbstractDynamics || throw(ArgumentError(
        "component :$(only(dynamics).id) did not materialize to an AbstractDynamics",
    ))
    command = command_buffer(actuator)
    applicable(integrate!, MotionState2D(), dynamics_, command) || throw(ArgumentError(
        "actuator :$(only(actuators).id) ($(typeof(actuator))) produces $(typeof(command)), " *
        "which dynamics :$(only(dynamics).id) ($(typeof(dynamics_))) cannot integrate",
    ))
    return config
end

"""Validate fixed structure before mutation, crossover, or development."""
function validate_development_structure(config::EmbodimentConfig; physical::Bool=true)
    ids = Tuple(component.id for component in config.components)
    length(unique(ids)) == length(ids) || throw(ArgumentError("development component IDs must be unique"))
    _validate_standard_embodiment_structure(
        config;
        physical=physical,
        context="development embodiment",
    )
    _validate_bilateral_references(config)
    _validate_command_compatibility(config)
    return config
end

function DevelopmentSpec(config::C, blocks; physical::Bool=true) where {C<:EmbodimentConfig}
    blocks_ = Tuple(blocks)
    all(block -> block isa DevelopmentBlock, blocks_) || throw(ArgumentError(
        "development blocks must all be DevelopmentBlock values",
    ))
    ids = Tuple(block.id for block in blocks_)
    length(unique(ids)) == length(ids) || throw(ArgumentError("development block IDs must be unique"))
    targets = Tuple((block.component_id, path) for block in blocks_ for path in block.paths)
    length(unique(targets)) == length(targets) || throw(ArgumentError(
        "development blocks may not target the same component parameter more than once",
    ))
    validate_development_structure(config; physical=physical)
    for block in blocks_
        component = _component_by_id(config, block.component_id)
        for (path, bounds) in zip(block.paths, block.bounds)
            value = _parameter_at(component.parameters, path)
            value isa Real && !(value isa Bool) || throw(ArgumentError(
                "development path :$(component.id).$(join(path, '.')) is not a real scalar parameter",
            ))
            value_ = Float64(value)
            bounds[1] <= value_ <= bounds[2] || throw(ArgumentError(
                "initial value $(value_) for :$(component.id).$(join(path, '.')) lies outside bounds $(bounds)",
            ))
        end
    end
    slices = _block_slices(blocks_)
    dim = sum(length(block.paths) for block in blocks_; init=0)
    signature = _development_signature(config, blocks_, physical)
    return DevelopmentSpec{C,typeof(blocks_),typeof(slices)}(
        config, blocks_, slices, dim, physical, signature,
    )
end

DevelopmentSpec(config::EmbodimentConfig, block::DevelopmentBlock, blocks::DevelopmentBlock...; kwargs...) =
    DevelopmentSpec(config, (block, blocks...); kwargs...)

paramdim(spec::DevelopmentSpec) = spec.dim

function paramspace(spec::DevelopmentSpec)
    entries = _PARAMSPACE_ENTRY[]
    for block in spec.blocks, (path, bounds) in zip(block.paths, block.bounds)
        push!(entries, (
            label=Symbol(block.id, :__, join(string.(path), "__")),
            lo=bounds[1],
            hi=bounds[2],
        ))
    end
    return entries
end

function pack_params(spec::DevelopmentSpec)
    values = Float64[]
    sizehint!(values, spec.dim)
    for block in spec.blocks
        component = _component_by_id(spec.config, block.component_id)
        append!(values, Float64(_parameter_at(component.parameters, path)) for path in block.paths)
    end
    return values
end

"""Bounded parameter values for one fixed `DevelopmentSpec`; never transient state."""
struct DevelopmentGenotype{S<:DevelopmentSpec,V<:Tuple}
    spec::S
    values::V
end

function DevelopmentGenotype(spec::S, raw::AbstractVector{<:Real}=pack_params(spec)) where {S<:DevelopmentSpec}
    length(raw) == spec.dim || throw(DimensionMismatch(
        "development genotype expects $(spec.dim) values, got $(length(raw))",
    ))
    values = Tuple(Float64(value) for value in raw)
    all(isfinite, values) || throw(ArgumentError("development genotype values must be finite"))
    for (value, entry) in zip(values, paramspace(spec))
        entry.lo <= value <= entry.hi || throw(ArgumentError(
            "development gene :$(entry.label)=$(value) lies outside [$(entry.lo), $(entry.hi)]",
        ))
    end
    return DevelopmentGenotype{S,typeof(values)}(spec, values)
end

paramdim(genotype::DevelopmentGenotype) = paramdim(genotype.spec)
paramspace(genotype::DevelopmentGenotype) = paramspace(genotype.spec)
pack_params(genotype::DevelopmentGenotype) = collect(genotype.values)
unpack_params(spec::DevelopmentSpec, raw::AbstractVector{<:Real}) = DevelopmentGenotype(spec, raw)

function _development_patch(block::DevelopmentBlock, values)
    return (component_id=block.component_id, paths=block.paths, values=Tuple(Float64.(values)))
end

function composite_genome(spec::DevelopmentSpec)
    initial = pack_params(spec)
    blocks = GenomeBlock[]
    for (block, slice) in zip(spec.blocks, spec.slices)
        space = _PARAMSPACE_ENTRY[
            (label=Symbol(join(string.(path), "__")), lo=bounds[1], hi=bounds[2])
            for (path, bounds) in zip(block.paths, block.bounds)
        ]
        template = copy(initial[slice])
        push!(blocks, GenomeBlock(
            block.id,
            block.id,
            space,
            () -> copy(template),
            raw -> _development_patch(block, raw),
        ))
    end
    return CompositeGenome(blocks)
end

function _developed_config(genotype::DevelopmentGenotype)
    spec = genotype.spec
    components = spec.config.components
    for (block, slice) in zip(spec.blocks, spec.slices)
        index = findfirst(component -> component.id === block.component_id, components)
        component = components[index]
        parameters = component.parameters
        for (path, value) in zip(block.paths, genotype.values[slice])
            parameters = _replace_development_parameter(parameters, path, value)
        end
        components = Base.setindex(
            components,
            ComponentConfig(component.id, component.family, component.kind, parameters),
            index,
        )
    end
    return EmbodimentConfig(
        spec.config.schema_version,
        spec.config.name,
        components,
        spec.config.source,
    )
end

function _contextual_component(component::ComponentConfig, context::DevelopmentContext)
    if component.family === :sensor && component.kind === :field_probe
        shared = Int(mod(
            development_seed(context, :field_probe_common, :shared_noise),
            UInt64(typemax(Int)),
        ))
        independent = Int(mod(development_seed(context, component.id, :independent_noise), UInt64(typemax(Int))))
        parameters = merge(component.parameters, (shared_seed=shared, independent_seed=independent))
        return ComponentConfig(component.id, component.family, component.kind, parameters)
    elseif component.family === :physiology && component.kind === :regulated
        feedback_seed = Int(mod(
            development_seed(context, component.id, :feedback_noise),
            UInt64(typemax(Int)),
        ))
        parameters = merge(component.parameters, (seed=feedback_seed,))
        return ComponentConfig(component.id, component.family, component.kind, parameters)
    end
    return component
end

"""Fresh component blueprints produced by one explicit development event."""
struct DevelopedEmbodimentBlueprint{C<:Tuple,S<:Tuple}
    schema_version::Int
    name::Symbol
    components::C
    source::String
    context::DevelopmentContext
    component_seeds::S
    structure_signature::UInt64
end

"""Assemble one developed, context-resolved blueprint into a runnable body."""
function materialize_embodiment(blueprint::DevelopedEmbodimentBlueprint)
    return _compose_embodiment(EmbodimentBlueprint(
        blueprint.schema_version,
        blueprint.name,
        blueprint.components,
        blueprint.source,
    ))
end

function develop(genotype::DevelopmentGenotype, context::DevelopmentContext)
    config = _developed_config(genotype)
    validate_development_structure(config; physical=genotype.spec.physical)
    contextual = map(component -> _contextual_component(component, context), config.components)
    contextual_config = EmbodimentConfig(
        config.schema_version, config.name, contextual, config.source,
    )
    blueprint = materialize_blueprint(contextual_config)
    seeds = Tuple((
        id=component.id,
        state=development_seed(context, component.id, :state),
    ) for component in config.components)
    return DevelopedEmbodimentBlueprint(
        blueprint.schema_version,
        blueprint.name,
        blueprint.components,
        blueprint.source,
        context,
        seeds,
        genotype.spec.signature,
    )
end

develop(spec::DevelopmentSpec, context::DevelopmentContext) =
    develop(DevelopmentGenotype(spec), context)
develop(spec::DevelopmentSpec, raw::AbstractVector{<:Real}, context::DevelopmentContext) =
    develop(DevelopmentGenotype(spec, raw), context)

function mutate(
    genotype::DevelopmentGenotype,
    rng::AbstractRNG;
    sigma::Real=0.1,
)
    sigma_ = Float64(sigma)
    isfinite(sigma_) && sigma_ >= 0.0 || throw(ArgumentError("mutation sigma must be finite and non-negative"))
    space = paramspace(genotype)
    raw = Vector{Float64}(undef, length(genotype.values))
    for i in eachindex(raw)
        span = space[i].hi - space[i].lo
        raw[i] = clamp(genotype.values[i] + sigma_ * span * randn(rng), space[i].lo, space[i].hi)
    end
    return DevelopmentGenotype(genotype.spec, raw)
end

function _same_development_structure(left::DevelopmentSpec, right::DevelopmentSpec)
    left.physical == right.physical || return false
    left.dim == right.dim || return false
    canonical_embodiment_toml(left.config) == canonical_embodiment_toml(right.config) || return false
    length(left.blocks) == length(right.blocks) || return false
    return all(zip(left.blocks, right.blocks)) do (left_block, right_block)
        left_block.id === right_block.id &&
            left_block.component_id === right_block.component_id &&
            left_block.paths == right_block.paths &&
            left_block.bounds == right_block.bounds
    end
end

function recombine(
    left::DevelopmentGenotype,
    right::DevelopmentGenotype,
    rng::AbstractRNG;
    left_probability::Real=0.5,
)
    left.spec.signature == right.spec.signature &&
        _same_development_structure(left.spec, right.spec) || throw(ArgumentError(
        "development genotypes have incompatible structure signatures",
    ))
    probability = Float64(left_probability)
    0.0 <= probability <= 1.0 || throw(ArgumentError("left_probability must lie in [0, 1]"))
    raw = Float64[
        rand(rng) < probability ? left.values[i] : right.values[i]
        for i in eachindex(left.values)
    ]
    return DevelopmentGenotype(left.spec, raw)
end
