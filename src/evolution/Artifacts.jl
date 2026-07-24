using TOML
import SHA

const _EVOLUTION_MODEL_FORMAT = "brainlesslab-model-artifact"
const _EVOLUTION_MODEL_FORMAT_VERSION = 1
const _EVOLUTION_CHECKPOINT_FORMAT = "brainlesslab-evolution-checkpoint"
const _EVOLUTION_CHECKPOINT_FORMAT_VERSION = 1

for name in (
    :write_models,
    :model_reference,
    :read_model,
    :write_checkpoint,
    :read_checkpoint,
    :latest_checkpoint,
)
    isdefined(Evolution, name) || Core.eval(Evolution, :(function $name end))
end

_evolution_sha256(path::AbstractString) = open(path, "r") do io
    bytes2hex(SHA.sha256(io))
end

function _evolution_safe_relative_path(path::AbstractString, context::AbstractString)
    portable = replace(String(path), '\\' => '/')
    isempty(portable) && throw(ArgumentError("$(context) must not be empty"))
    startswith(portable, "/") && throw(ArgumentError("$(context) must be relative"))
    occursin(r"^[A-Za-z]:", portable) &&
        throw(ArgumentError("$(context) must be relative"))
    parts = split(portable, '/')
    any(part -> isempty(part) || part in (".", ".."), parts) && throw(ArgumentError(
        "$(context) must not contain empty, . or .. path components",
    ))
    return join(parts, '/')
end

function _evolution_child(root::AbstractString, relative, context)
    portable = _evolution_safe_relative_path(relative, context)
    path = normpath(joinpath(root, split(portable, '/')...))
    absolute_root = normpath(abspath(root))
    absolute_path = normpath(abspath(path))
    (absolute_path == absolute_root ||
        startswith(
            absolute_path,
            absolute_root * string(Base.Filesystem.path_separator),
        )) || throw(ArgumentError("$(context) escapes its artifact root"))
    return path
end

function _evolution_reject_symlink_components(path::AbstractString, context)
    if isabspath(path)
        islink(path) && throw(ArgumentError(
            "$(context) must not be a symbolic link: $(path)",
        ))
        return path
    end
    current = ""
    for part in splitpath(path)
        part in ("", string(Base.Filesystem.path_separator)) && continue
        current = isempty(current) ? part : joinpath(current, part)
        islink(current) && throw(ArgumentError(
            "$(context) must not contain symbolic links: $(current)",
        ))
    end
    return path
end

function _evolution_stable_id(value, context)
    text = String(value)
    occursin(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$", text) || throw(ArgumentError(
        "$(context) must be a stable lower-case identifier",
    ))
    return text
end

function _evolution_portable_record_path(record_directory::AbstractString)
    if isabspath(record_directory)
        return _evolution_safe_relative_path(
            basename(normpath(record_directory)),
            "persisted model record path",
        )
    end
    return _evolution_safe_relative_path(
        normpath(record_directory),
        "persisted model record path",
    )
end

function _evolution_digest(value, context)
    digest = String(value)
    occursin(r"^[0-9a-f]{64}$", digest) || throw(ArgumentError(
        "$(context) must be a lower-case SHA-256 digest",
    ))
    return digest
end

function _evolution_design_document(design::Evolution.NodeDesignSpec)
    blocks = collect(design.blocks)
    dimension = design.dimension
    dimension > 0 || throw(ArgumentError("node design dimension must be positive"))
    covered = Int[]
    block_documents = Dict{String,Any}[]
    for block in blocks
        isempty(String(block.name)) &&
            throw(ArgumentError("design block name must not be empty"))
        isempty(block.shape) && throw(ArgumentError("design block shape must not be empty"))
        all(>(0), block.shape) || throw(ArgumentError(
            "design block dimensions must be positive",
        ))
        length(block.range) == prod(block.shape) || throw(ArgumentError(
            "design block $(block.name) range does not match its shape",
        ))
        append!(covered, block.range)
        push!(block_documents, Dict{String,Any}(
            "name" => String(block.name),
            "shape" => collect(block.shape),
            "first" => first(block.range),
            "last" => last(block.range),
        ))
    end
    sort(covered) == collect(1:dimension) || throw(ArgumentError(
        "node design blocks must cover each coordinate exactly once",
    ))
    return Dict{String,Any}(
        "model_type" => string(design.model_type),
        "dimension" => dimension,
        "stability" => String(design.stability),
        "blocks" => block_documents,
    )
end

function _evolution_model_entries(models, design::Evolution.NodeDesignSpec)
    entries = NamedTuple[]
    seen = Set{String}()
    for entry in models
        hasproperty(entry, :model_id) || throw(ArgumentError(
            "each model entry requires model_id",
        ))
        hasproperty(entry, :role) || throw(ArgumentError(
            "each model entry requires role",
        ))
        hasproperty(entry, :model) || throw(ArgumentError(
            "each model entry requires model",
        ))
        model_id = _evolution_stable_id(getproperty(entry, :model_id), "model id")
        role = _evolution_stable_id(getproperty(entry, :role), "model role")
        model_id in seen && throw(ArgumentError("duplicate model id $(repr(model_id))"))
        push!(seen, model_id)
        model = getproperty(entry, :model)
        model isa design.model_type || throw(ArgumentError(
            "model $(model_id) is not a $(design.model_type)",
        ))
        coordinates = Evolution.encode(design, model)
        push!(entries, (
            model_id=model_id,
            role=role,
            model=model,
            coordinates=coordinates,
        ))
    end
    isempty(entries) && throw(ArgumentError("model artifact requires at least one model"))
    sort!(entries; by=entry -> entry.model_id)
    return entries
end

function Evolution.write_models(
    record_directory::AbstractString,
    node::Symbol,
    design::Evolution.NodeDesignSpec,
    models,
)
    _evolution_reject_symlink_components(
        record_directory,
        "model record directory",
    )
    portable_record = _evolution_portable_record_path(record_directory)
    path = joinpath(record_directory, "models")
    ispath(path) && throw(ArgumentError("model artifact path already exists: $(path)"))
    entries = _evolution_model_entries(models, design)
    mkpath(path)
    coordinates_path = joinpath(path, "coordinates.csv")
    open(coordinates_path, "w") do io
        println(io, "model_id,coordinate,value")
        for entry in entries, coordinate in eachindex(entry.coordinates)
            println(
                io,
                entry.model_id,
                ',',
                coordinate,
                ',',
                repr(entry.coordinates[coordinate]),
            )
        end
    end
    coordinates_sha256 = _evolution_sha256(coordinates_path)

    index_path = joinpath(path, "models.csv")
    open(index_path, "w") do io
        println(io, "model_id,role,coordinate_count")
        for entry in entries
            println(io, entry.model_id, ',', entry.role, ',', length(entry.coordinates))
        end
    end
    index_sha256 = _evolution_sha256(index_path)

    schema_path = joinpath(path, "schema.toml")
    document = Dict{String,Any}(
        "format" => _EVOLUTION_MODEL_FORMAT,
        "format_version" => _EVOLUTION_MODEL_FORMAT_VERSION,
        "node" => String(node),
        "model_index" => "models.csv",
        "model_index_sha256" => index_sha256,
        "coordinates" => "coordinates.csv",
        "coordinates_sha256" => coordinates_sha256,
        "design" => _evolution_design_document(design),
    )
    open(schema_path, "w") do io
        TOML.print(io, document; sorted=true)
    end
    schema_sha256 = _evolution_sha256(schema_path)
    return [
        Evolution.ModelReference(
            portable_record,
            entry.model_id,
            node,
            schema_sha256,
            coordinates_sha256,
        )
        for entry in entries
    ]
end

function _evolution_split_csv_line(line::AbstractString, columns::Int, context)
    fields = split(chomp(line), ','; keepempty=true)
    length(fields) == columns || throw(ArgumentError(
        "$(context) must contain $(columns) comma-separated fields",
    ))
    return fields
end

function _evolution_read_index(path::AbstractString)
    lines = readlines(path)
    !isempty(lines) && first(lines) == "model_id,role,coordinate_count" ||
        throw(ArgumentError("model index has an invalid header"))
    rows = Dict{String,NamedTuple}()
    for line in Iterators.drop(lines, 1)
        model_id, role, count = _evolution_split_csv_line(line, 3, "model index row")
        _evolution_stable_id(model_id, "model id")
        _evolution_stable_id(role, "model role")
        haskey(rows, model_id) && throw(ArgumentError("duplicate model id $(model_id)"))
        coordinate_count = tryparse(Int, count)
        coordinate_count === nothing && throw(ArgumentError(
            "model index coordinate_count must be an integer",
        ))
        rows[model_id] = (role=role, coordinate_count=coordinate_count)
    end
    return rows
end

function _evolution_read_coordinates(path::AbstractString, dimension::Int)
    lines = readlines(path)
    !isempty(lines) && first(lines) == "model_id,coordinate,value" ||
        throw(ArgumentError("coordinate table has an invalid header"))
    rows = Dict{String,Vector{Union{Missing,Float64}}}()
    for line in Iterators.drop(lines, 1)
        model_id, coordinate_text, value_text =
            _evolution_split_csv_line(line, 3, "coordinate row")
        _evolution_stable_id(model_id, "model id")
        coordinate = tryparse(Int, coordinate_text)
        coordinate === nothing && throw(ArgumentError(
            "coordinate index must be an integer",
        ))
        1 <= coordinate <= dimension || throw(ArgumentError(
            "coordinate index $(coordinate) is outside 1:$(dimension)",
        ))
        value = tryparse(Float64, value_text)
        value === nothing && throw(ArgumentError("coordinate value must be numeric"))
        isfinite(value) || throw(ArgumentError("coordinate value must be finite"))
        values = get!(
            rows,
            model_id,
            Union{Missing,Float64}[missing for _ in 1:dimension],
        )
        ismissing(values[coordinate]) || throw(ArgumentError(
            "duplicate coordinate $(coordinate) for model $(model_id)",
        ))
        values[coordinate] = value
    end
    return rows
end

function _evolution_validate_coordinate_rows(index, coordinates, dimension::Int)
    Set(keys(coordinates)) == Set(keys(index)) || throw(ArgumentError(
        "coordinate table model ids do not match the model index",
    ))
    for (model_id, row) in pairs(index)
        row.coordinate_count == dimension || throw(ArgumentError(
            "model $(model_id) coordinate count does not match the schema",
        ))
        all(value -> !ismissing(value), coordinates[model_id]) || throw(ArgumentError(
            "model $(model_id) coordinate table is incomplete",
        ))
    end
    return coordinates
end

function Evolution.model_reference(
    record_directory::AbstractString,
    model_id::AbstractString,
)
    _evolution_reject_symlink_components(
        record_directory,
        "model record directory",
    )
    record = _evolution_portable_record_path(record_directory)
    path = joinpath(record_directory, "models")
    isdir(path) || throw(ArgumentError("model record is missing models/"))
    islink(path) && throw(ArgumentError("model record models/ must not be a symbolic link"))
    stable_model_id = _evolution_stable_id(model_id, "model id")
    Set(readdir(path)) == Set(("schema.toml", "models.csv", "coordinates.csv")) ||
        throw(ArgumentError("model artifact contains unexpected or missing files"))
    any(islink(joinpath(path, name)) for name in readdir(path)) &&
        throw(ArgumentError("model artifact files must not be symbolic links"))
    schema_path = joinpath(path, "schema.toml")
    schema = TOML.parsefile(schema_path)
    get(schema, "format", nothing) == _EVOLUTION_MODEL_FORMAT ||
        throw(ArgumentError("model artifact format is invalid"))
    get(schema, "format_version", nothing) == _EVOLUTION_MODEL_FORMAT_VERSION ||
        throw(ArgumentError("model artifact format version is invalid"))
    node_text = get(schema, "node", "")
    _evolution_stable_id(node_text, "model artifact node")
    get(schema, "model_index", nothing) == "models.csv" ||
        throw(ArgumentError("model index path must be models.csv"))
    index_path = joinpath(path, "models.csv")
    _evolution_digest(schema["model_index_sha256"], "model index digest") ==
        _evolution_sha256(index_path) || throw(ArgumentError(
            "model index checksum failed",
        ))
    index = _evolution_read_index(index_path)
    haskey(index, stable_model_id) || throw(ArgumentError(
        "model id $(repr(stable_model_id)) is absent from the model index",
    ))
    get(schema, "coordinates", nothing) == "coordinates.csv" ||
        throw(ArgumentError("coordinate table path must be coordinates.csv"))
    coordinate_path = joinpath(path, "coordinates.csv")
    coordinate_sha256 = _evolution_digest(
        schema["coordinates_sha256"],
        "coordinate table digest",
    )
    coordinate_sha256 == _evolution_sha256(coordinate_path) ||
        throw(ArgumentError("coordinate table checksum failed"))
    dimension = get(get(schema, "design", Dict{String,Any}()), "dimension", 0)
    dimension isa Integer && dimension > 0 ||
        throw(ArgumentError("model schema dimension is invalid"))
    _evolution_validate_coordinate_rows(
        index,
        _evolution_read_coordinates(coordinate_path, Int(dimension)),
        Int(dimension),
    )
    return Evolution.ModelReference(
        record,
        stable_model_id,
        Symbol(node_text),
        _evolution_sha256(schema_path),
        coordinate_sha256,
    )
end

function Evolution.read_model(
    reference::Evolution.ModelReference,
    node::Symbol,
    design::Evolution.NodeDesignSpec,
)
    record = _evolution_safe_relative_path(reference.path, "model reference path")
    _evolution_reject_symlink_components(record, "model reference path")
    path = joinpath(record, "models")
    isdir(path) || throw(ArgumentError("model record is missing models/"))
    islink(path) && throw(ArgumentError("model record models/ must not be a symbolic link"))
    _evolution_stable_id(reference.model_id, "model reference id")
    reference.node === node || throw(ArgumentError(
        "model reference node $(reference.node) does not match requested node $(node)",
    ))
    schema_path = _evolution_child(path, "schema.toml", "model schema path")
    isfile(schema_path) || throw(ArgumentError("model artifact is missing schema.toml"))
    _evolution_digest(reference.schema_sha256, "model schema digest") ==
        _evolution_sha256(schema_path) || throw(ArgumentError(
            "model schema checksum does not match its reference",
        ))
    schema = TOML.parsefile(schema_path)
    get(schema, "format", nothing) == _EVOLUTION_MODEL_FORMAT || throw(ArgumentError(
        "model artifact format must be $(repr(_EVOLUTION_MODEL_FORMAT))",
    ))
    get(schema, "format_version", nothing) == _EVOLUTION_MODEL_FORMAT_VERSION ||
        throw(ArgumentError(
            "model artifact format_version must be $(_EVOLUTION_MODEL_FORMAT_VERSION)",
        ))
    get(schema, "node", nothing) == String(node) || throw(ArgumentError(
        "model artifact node does not match the requested node",
    ))
    get(schema, "design", nothing) == _evolution_design_document(design) ||
        throw(ArgumentError("model artifact schema does not match NodeDesignSpec"))
    Set(readdir(path)) == Set(("schema.toml", "models.csv", "coordinates.csv")) ||
        throw(ArgumentError("model artifact contains unexpected or missing files"))
    any(islink(joinpath(path, name)) for name in readdir(path)) &&
        throw(ArgumentError("model artifact files must not be symbolic links"))

    index_relative = _evolution_safe_relative_path(
        get(schema, "model_index", ""),
        "model index path",
    )
    index_relative == "models.csv" ||
        throw(ArgumentError("model index path must be models.csv"))
    index_path = _evolution_child(path, index_relative, "model index path")
    _evolution_digest(schema["model_index_sha256"], "model index digest") ==
        _evolution_sha256(index_path) || throw(ArgumentError(
            "model index checksum failed",
        ))
    coordinate_relative = _evolution_safe_relative_path(
        get(schema, "coordinates", ""),
        "coordinate table path",
    )
    coordinate_relative == "coordinates.csv" || throw(ArgumentError(
        "coordinate table path must be coordinates.csv",
    ))
    coordinate_path = _evolution_child(path, coordinate_relative, "coordinate table path")
    coordinate_digest = _evolution_sha256(coordinate_path)
    _evolution_digest(schema["coordinates_sha256"], "coordinate table digest") ==
        coordinate_digest || throw(ArgumentError("coordinate table checksum failed"))
    _evolution_digest(reference.coordinates_sha256, "model coordinate digest") ==
        coordinate_digest || throw(ArgumentError(
            "coordinate table checksum does not match its reference",
        ))

    index = _evolution_read_index(index_path)
    haskey(index, reference.model_id) || throw(ArgumentError(
        "model id $(repr(reference.model_id)) is absent from the model index",
    ))
    coordinates = _evolution_read_coordinates(coordinate_path, design.dimension)
    _evolution_validate_coordinate_rows(index, coordinates, design.dimension)
    values = coordinates[reference.model_id]
    return Evolution.decode(design, Float64[value for value in values])
end

_evolution_portable(value::Nothing) = Dict("kind" => "nothing")
_evolution_portable(value::Missing) = Dict("kind" => "missing")
_evolution_portable(value::Bool) = Dict("kind" => "bool", "value" => value)
_evolution_portable(value::Core.Unsigned) = Dict(
    "kind" => "unsigned",
    "value" => string(value),
)
_evolution_portable(value::Integer) = Dict("kind" => "integer", "value" => Int64(value))
function _evolution_portable(value::AbstractFloat)
    isfinite(value) || throw(ArgumentError("checkpoint values must be finite"))
    return Dict("kind" => "float", "value" => Float64(value))
end
_evolution_portable(value::AbstractString) =
    Dict("kind" => "string", "value" => String(value))
_evolution_portable(value::Symbol) =
    Dict("kind" => "symbol", "value" => String(value))
_evolution_portable(value::Tuple) = Dict(
    "kind" => "tuple",
    "items" => [_evolution_portable(item) for item in value],
)
_evolution_portable(value::AbstractVector) = Dict(
    "kind" => "vector",
    "items" => [_evolution_portable(item) for item in value],
)
_evolution_portable(value::NamedTuple) = Dict(
    "kind" => "namedtuple",
    "entries" => [
        Dict(
            "name" => String(name),
            "value" => _evolution_portable(getproperty(value, name)),
        )
        for name in propertynames(value)
    ],
)
function _evolution_portable(value::AbstractDict)
    entries = [
        Dict(
            "key" => _evolution_portable(key),
            "value" => _evolution_portable(item),
        )
        for (key, item) in pairs(value)
    ]
    sort!(entries; by=entry -> sprint(show, entry["key"]))
    return Dict("kind" => "dict", "entries" => entries)
end
_evolution_portable(value) = throw(ArgumentError(
    "checkpoint snapshot contains unsupported $(typeof(value))",
))

function _evolution_from_portable(document::AbstractDict)
    kind = get(document, "kind", nothing)
    kind == "nothing" && return nothing
    kind == "missing" && return missing
    kind == "bool" && return Bool(document["value"])
    kind == "unsigned" && return parse(UInt64, document["value"])
    kind == "integer" && return Int(document["value"])
    kind == "float" && return Float64(document["value"])
    kind == "string" && return String(document["value"])
    kind == "symbol" && return Symbol(document["value"])
    kind == "tuple" && return Tuple(
        _evolution_from_portable(item) for item in document["items"]
    )
    kind == "vector" && return [
        _evolution_from_portable(item) for item in document["items"]
    ]
    if kind == "namedtuple"
        names = Tuple(Symbol(entry["name"]) for entry in document["entries"])
        values = Tuple(
            _evolution_from_portable(entry["value"]) for entry in document["entries"]
        )
        return NamedTuple{names}(values)
    end
    if kind == "dict"
        return Dict(
            _evolution_from_portable(entry["key"]) =>
                _evolution_from_portable(entry["value"])
            for entry in document["entries"]
        )
    end
    throw(ArgumentError("checkpoint snapshot has unknown portable kind $(repr(kind))"))
end

function _evolution_checkpoint_name(completed_iteration::Integer)
    completed_iteration >= 0 || throw(ArgumentError(
        "completed iteration must be non-negative",
    ))
    return string("generation-", lpad(Int(completed_iteration), 8, '0'))
end

function Evolution.write_checkpoint(
    record_directory::AbstractString;
    completed_iteration::Integer,
    run_digest::AbstractString,
    resolution_digest::AbstractString,
    provenance_digest::AbstractString,
    strategy_key,
    runner_document::Union{Nothing,AbstractDict}=nothing,
    strategy_snapshot::Union{Nothing,AbstractDict}=nothing,
    committed_candidate_count::Integer,
)
    _evolution_reject_symlink_components(
        record_directory,
        "checkpoint record directory",
    )
    root = joinpath(record_directory, "checkpoints")
    islink(root) && throw(ArgumentError(
        "record checkpoints/ must not be a symbolic link",
    ))
    run_sha = _evolution_digest(run_digest, "run digest")
    resolution_sha = _evolution_digest(resolution_digest, "resolution digest")
    provenance_sha = _evolution_digest(provenance_digest, "provenance digest")
    strategy = _evolution_stable_id(strategy_key, "strategy key")
    committed_candidate_count >= 0 || throw(ArgumentError(
        "committed candidate count must be non-negative",
    ))
    (runner_document === nothing) != (strategy_snapshot === nothing) ||
        throw(ArgumentError(
            "provide exactly one of runner_document or strategy_snapshot",
        ))
    portable_runner = if runner_document === nothing
        Dict{String,Any}("strategy" => strategy_snapshot)
    else
        Dict{String,Any}(String(key) => value for (key, value) in pairs(runner_document))
    end
    haskey(portable_runner, "strategy") || throw(ArgumentError(
        "checkpoint runner_document requires a strategy entry",
    ))
    name = _evolution_checkpoint_name(completed_iteration)
    final = joinpath(root, name)
    ispath(final) && throw(ArgumentError("checkpoint already exists: $(final)"))
    mkpath(root)
    staging = joinpath(
        root,
        string(".staging-", name, "-", string(time_ns(); base=16)),
    )
    mkpath(staging)
    state_path = joinpath(staging, "runner.toml")
    open(state_path, "w") do io
        TOML.print(io, Dict{String,Any}(
            "format" => "brainlesslab-portable-runner-snapshot",
            "format_version" => 1,
            "runner" => _evolution_portable(portable_runner),
        ); sorted=true)
    end
    state_sha256 = _evolution_sha256(state_path)
    manifest_path = joinpath(staging, "checkpoint.toml")
    open(manifest_path, "w") do io
        TOML.print(io, Dict{String,Any}(
            "format" => _EVOLUTION_CHECKPOINT_FORMAT,
            "format_version" => _EVOLUTION_CHECKPOINT_FORMAT_VERSION,
            "completed_iteration" => Int(completed_iteration),
            "run_digest" => run_sha,
            "resolution_digest" => resolution_sha,
            "provenance_digest" => provenance_sha,
            "strategy_key" => strategy,
            "runner_document" => "runner.toml",
            "runner_document_sha256" => state_sha256,
            "committed_candidate_count" => Int(committed_candidate_count),
            "completion_marker" => "DONE",
        ); sorted=true)
    end
    manifest_sha256 = _evolution_sha256(manifest_path)
    open(joinpath(staging, "DONE"), "w") do io
        write(io, manifest_sha256, '\n')
    end
    mv(staging, final)
    return final
end

function Evolution.write_checkpoint(
    record_directory::AbstractString,
    state;
    kwargs...,
)
    return Evolution.write_checkpoint(
        record_directory;
        runner_document=Dict{String,Any}(
            "strategy" => Evolution.snapshot(state),
        ),
        kwargs...,
    )
end

function _evolution_read_checkpoint_path(
    path::AbstractString;
    run_digest::Union{Nothing,AbstractString}=nothing,
    resolution_digest::Union{Nothing,AbstractString}=nothing,
    provenance_digest::Union{Nothing,AbstractString}=nothing,
    strategy_key=nothing,
)
    basename(path) == _evolution_checkpoint_name(
        parse(Int, chopprefix(basename(path), "generation-")),
    ) || throw(ArgumentError("checkpoint directory has an invalid name"))
    isfile(joinpath(path, "DONE")) || throw(ArgumentError("checkpoint is incomplete"))
    _evolution_reject_symlink_components(path, "checkpoint path")
    Set(readdir(path)) == Set(("checkpoint.toml", "runner.toml", "DONE")) ||
        throw(ArgumentError("checkpoint contains unexpected or missing files"))
    any(islink(joinpath(path, name)) for name in readdir(path)) &&
        throw(ArgumentError("checkpoint files must not be symbolic links"))
    manifest_path = joinpath(path, "checkpoint.toml")
    strip(read(joinpath(path, "DONE"), String)) == _evolution_sha256(manifest_path) ||
        throw(ArgumentError("checkpoint manifest checksum failed"))
    manifest = TOML.parsefile(manifest_path)
    get(manifest, "format", nothing) == _EVOLUTION_CHECKPOINT_FORMAT ||
        throw(ArgumentError("checkpoint format is invalid"))
    get(manifest, "format_version", nothing) == _EVOLUTION_CHECKPOINT_FORMAT_VERSION ||
        throw(ArgumentError("checkpoint format version is invalid"))
    get(manifest, "completion_marker", nothing) == "DONE" ||
        throw(ArgumentError("checkpoint completion marker is invalid"))
    completed_iteration = get(manifest, "completed_iteration", -1)
    basename(path) == _evolution_checkpoint_name(completed_iteration) ||
        throw(ArgumentError("checkpoint iteration does not match its directory"))
    get(manifest, "committed_candidate_count", -1) >= 0 ||
        throw(ArgumentError("checkpoint candidate count is invalid"))
    for (expected, key, context) in (
        (run_digest, "run_digest", "run"),
        (resolution_digest, "resolution_digest", "resolution"),
        (provenance_digest, "provenance_digest", "provenance"),
    )
        stored = _evolution_digest(manifest[key], "$(context) digest")
        expected === nothing ||
            stored == _evolution_digest(expected, "expected $(context) digest") ||
            throw(ArgumentError("checkpoint $(context) digest mismatch"))
    end
    stored_strategy = _evolution_stable_id(manifest["strategy_key"], "strategy key")
    strategy_key === nothing ||
        stored_strategy == _evolution_stable_id(strategy_key, "expected strategy key") ||
        throw(ArgumentError("checkpoint strategy key mismatch"))
    get(manifest, "runner_document", nothing) == "runner.toml" ||
        throw(ArgumentError("checkpoint runner document path is invalid"))
    state_path = joinpath(path, "runner.toml")
    _evolution_digest(
        manifest["runner_document_sha256"],
        "runner document digest",
    ) == _evolution_sha256(state_path) || throw(ArgumentError(
        "checkpoint runner document checksum failed",
    ))
    state = TOML.parsefile(state_path)
    get(state, "format", nothing) == "brainlesslab-portable-runner-snapshot" ||
        throw(ArgumentError("runner snapshot format is invalid"))
    get(state, "format_version", nothing) == 1 ||
        throw(ArgumentError("runner snapshot format version is invalid"))
    runner = _evolution_from_portable(state["runner"])
    runner isa AbstractDict || throw(ArgumentError(
        "runner snapshot root must decode to a dictionary",
    ))
    haskey(runner, "strategy") || throw(ArgumentError(
        "runner snapshot requires a strategy entry",
    ))
    return (
        path=String(path),
        completed_iteration=Int(completed_iteration),
        run_digest=String(manifest["run_digest"]),
        resolution_digest=String(manifest["resolution_digest"]),
        provenance_digest=String(manifest["provenance_digest"]),
        strategy_key=Symbol(stored_strategy),
        runner_document=runner,
        strategy_snapshot=runner["strategy"],
        committed_candidate_count=Int(manifest["committed_candidate_count"]),
    )
end

function Evolution.read_checkpoint(
    record_directory::AbstractString,
    generation::Integer;
    kwargs...,
)
    _evolution_reject_symlink_components(
        record_directory,
        "checkpoint record directory",
    )
    path = joinpath(
        record_directory,
        "checkpoints",
        _evolution_checkpoint_name(generation),
    )
    islink(dirname(path)) && throw(ArgumentError(
        "record checkpoints/ must not be a symbolic link",
    ))
    return _evolution_read_checkpoint_path(path; kwargs...)
end

function Evolution.latest_checkpoint(record_directory::AbstractString; kwargs...)
    _evolution_reject_symlink_components(
        record_directory,
        "checkpoint record directory",
    )
    root = joinpath(record_directory, "checkpoints")
    isdir(root) || return nothing
    islink(root) && throw(ArgumentError(
        "record checkpoints/ must not be a symbolic link",
    ))
    candidates = String[]
    for name in readdir(root)
        startswith(name, "generation-") || continue
        path = joinpath(root, name)
        isdir(path) && isfile(joinpath(path, "DONE")) && push!(candidates, path)
    end
    isempty(candidates) && return nothing
    sort!(candidates)
    return _evolution_read_checkpoint_path(last(candidates); kwargs...)
end
