using TOML

const EXPERIMENT_FORMAT = "brainlesslab-experiment"
const EXPERIMENT_FORMAT_VERSION = 1

_experiment_toml_value(value::Symbol) = String(value)
_experiment_toml_value(value::VersionNumber) = string(value)
_experiment_toml_value(value::Tuple) = [_experiment_toml_value(item) for item in value]
_experiment_toml_value(value::AbstractVector) = [_experiment_toml_value(item) for item in value]
_experiment_toml_value(value::NamedTuple) = Dict{String,Any}(
    String(name) => _experiment_toml_value(getproperty(value, name))
    for name in propertynames(value)
)
_experiment_toml_value(value::AbstractDict) = Dict{String,Any}(
    string(key) => _experiment_toml_value(item) for (key, item) in pairs(value)
)
_experiment_toml_value(::Nothing) = throw(ArgumentError(
    "experiment metadata cannot contain nothing because TOML has no null value",
))
_experiment_toml_value(value) = value

function _experiment_plan_filename(index::Integer, plan::AbstractOperationPlan)
    id = String(plan.id)
    occursin(r"^[A-Za-z0-9_.-]+$", id) || throw(ArgumentError(
        "experiment operation id :$(plan.id) is not safe for an artifact filename",
    ))
    return string(lpad(Int(index), 2, '0'), "-", id, ".toml")
end

function experiment_document(experiment::ExperimentSpec)
    operations = [Dict{String,Any}(
        "id" => String(plan.id),
        "plan" => _experiment_plan_filename(index, plan),
    ) for (index, plan) in enumerate(experiment.operations)]
    document = Dict{String,Any}(
        "format" => EXPERIMENT_FORMAT,
        "format_version" => EXPERIMENT_FORMAT_VERSION,
        "id" => String(experiment.id),
        "version" => string(experiment.version),
        "title" => experiment.title,
        "question" => experiment.question,
        "evidence_state" => String(experiment.evidence_state),
        "limitations" => collect(experiment.limitations),
        "conditions" => [String(condition.id) for condition in experiment.conditions],
        "operations" => operations,
    )
    isempty(propertynames(experiment.metadata)) ||
        (document["metadata"] = _experiment_toml_value(experiment.metadata))
    return document
end

function write_experiment(
    directory::AbstractString,
    experiment::ExperimentSpec;
    registry::RegistrySet=DEFAULT_REGISTRY,
)
    validate(experiment, registry)
    ispath(directory) && throw(ArgumentError(
        "experiment directory already exists: $(directory)",
    ))
    plans_directory = joinpath(directory, "plans")
    mkpath(plans_directory)
    for (index, plan) in enumerate(experiment.operations)
        write_plan(
            joinpath(plans_directory, _experiment_plan_filename(index, plan)),
            plan,
        )
    end
    open(joinpath(directory, "experiment.toml"), "w") do io
        TOML.print(io, experiment_document(experiment); sorted=true)
    end
    return String(directory)
end

function _experiment_namedtuple(document)
    names = Tuple(sort!(Symbol.(collect(keys(document))); by=string))
    return NamedTuple{names}(Tuple(document[String(name)] for name in names))
end

function _experiment_plan_path(directory::AbstractString, filename)
    name = String(filename)
    basename(name) == name || throw(ArgumentError(
        "experiment plan path must be one filename",
    ))
    endswith(name, ".toml") || throw(ArgumentError(
        "experiment plan path must end in .toml",
    ))
    return joinpath(directory, "plans", name)
end

function read_experiment(
    directory::AbstractString;
    registry::RegistrySet=DEFAULT_REGISTRY,
)
    manifest = TOML.parsefile(joinpath(directory, "experiment.toml"))
    _require_document_keys(
        manifest,
        (
            "format", "format_version", "id", "version", "title", "question",
            "evidence_state", "limitations", "conditions", "operations", "metadata",
        ),
        "experiment",
    )
    get(manifest, "format", nothing) == EXPERIMENT_FORMAT || throw(ArgumentError(
        "experiment format must be $(repr(EXPERIMENT_FORMAT))",
    ))
    get(manifest, "format_version", nothing) == EXPERIMENT_FORMAT_VERSION ||
        throw(ArgumentError(
            "experiment format_version must be $(EXPERIMENT_FORMAT_VERSION)",
        ))
    for key in ("id", "version", "title", "question", "evidence_state", "conditions", "operations")
        haskey(manifest, key) || throw(ArgumentError("experiment requires $(key)"))
    end

    plans = AbstractOperationPlan[]
    operation_ids = Set{Symbol}()
    for entry in manifest["operations"]
        _require_document_keys(entry, ("id", "plan"), "experiment operation")
        plan = read_plan(
            _experiment_plan_path(directory, entry["plan"]);
            registry=registry,
        )
        id = Symbol(entry["id"])
        plan.id === id || throw(ArgumentError(
            "experiment operation id :$(id) does not match plan id :$(plan.id)",
        ))
        id in operation_ids && throw(ArgumentError("duplicate experiment operation :$(id)"))
        push!(operation_ids, id)
        push!(plans, plan)
    end

    targets = Dict{Symbol,EvaluationTarget}()
    for plan in plans, target in operation_targets(plan)
        if haskey(targets, target.id)
            _experiment_target_signature(targets[target.id]) ==
                _experiment_target_signature(target) || throw(ArgumentError(
                "experiment plans disagree on condition :$(target.id)",
            ))
        else
            targets[target.id] = target
        end
    end
    condition_ids = Symbol.(manifest["conditions"])
    length(unique(condition_ids)) == length(condition_ids) || throw(ArgumentError(
        "experiment condition ids must be unique",
    ))
    all(id -> haskey(targets, id), condition_ids) || throw(ArgumentError(
        "experiment manifest references a condition absent from its plans",
    ))
    Set(keys(targets)) == Set(condition_ids) || throw(ArgumentError(
        "experiment plans contain conditions absent from the manifest",
    ))

    metadata = _experiment_namedtuple(get(manifest, "metadata", Dict{String,Any}()))
    experiment = ExperimentSpec(
        Symbol(manifest["id"]),
        VersionNumber(manifest["version"]);
        title=manifest["title"],
        question=manifest["question"],
        conditions=Tuple(targets[id] for id in condition_ids),
        operations=Tuple(plans),
        evidence_state=Symbol(manifest["evidence_state"]),
        limitations=Tuple(get(manifest, "limitations", String[])),
        metadata=metadata,
    )
    return validate(experiment, registry)
end
