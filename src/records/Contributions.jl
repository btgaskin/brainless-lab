using TOML
import SHA

const CONTRIBUTION_FORMAT = "brainlesslab-contribution"
const CONTRIBUTION_FORMAT_VERSION = 1
const RESEARCH_CATALOGUE_FORMAT = "brainlesslab-research-catalogue"
const RESEARCH_CATALOGUE_FORMAT_VERSION = 1
const CONTRIBUTION_TARGET_BYTES = 1024^2
const CONTRIBUTION_MAX_BYTES = 5 * 1024^2
const CONTRIBUTION_TEXT_EXTENSIONS = Set((".toml", ".csv", ".json", ".md", ".html"))
const CONTRIBUTION_REQUIRED_RECORD_ARTIFACTS = Set((
    "request.toml",
    "resolved.toml",
    "seeds.csv",
    "data/trials.csv",
    "data/task_metrics.csv",
    "summary/statistics.csv",
    "summary/contrasts.csv",
    "summary/summary.json",
    "report/index.html",
))

function _contribution_require_keys(document, allowed, required, context)
    _require_document_keys(document, allowed, context)
    for key in required
        haskey(document, key) || throw(ArgumentError("$(context) requires $(key)"))
    end
    return document
end

function _contribution_relative_path(value, context)
    path = replace(String(value), '\\' => '/')
    isempty(path) && throw(ArgumentError("$(context) must not be empty"))
    startswith(path, "/") && throw(ArgumentError("$(context) must be relative"))
    occursin(r"^[A-Za-z]:", path) && throw(ArgumentError("$(context) must be relative"))
    parts = split(path, '/')
    any(part -> isempty(part) || part in (".", ".."), parts) && throw(ArgumentError(
        "$(context) must not contain empty, . or .. path components",
    ))
    return join(parts, '/')
end

function _contribution_child(root::AbstractString, relative, context)
    path = _contribution_relative_path(relative, context)
    candidate = normpath(joinpath(root, split(path, '/')...))
    root_path = normpath(abspath(root))
    candidate_path = normpath(abspath(candidate))
    (candidate_path == root_path ||
        startswith(candidate_path, root_path * string(Base.Filesystem.path_separator))) ||
        throw(ArgumentError("$(context) escapes its contribution directory"))
    return candidate
end

function _contribution_files(root::AbstractString)
    isdir(root) || throw(ArgumentError("contribution bundle directory does not exist: $(root)"))
    islink(root) && throw(ArgumentError(
        "contribution bundle directory must not be a symbolic link: $(root)",
    ))
    files = String[]
    for (directory, directories, names) in walkdir(root; follow_symlinks=false)
        for name in directories
            path = joinpath(directory, name)
            islink(path) && throw(ArgumentError(
                "contribution bundles must not contain symbolic links: $(relpath(path, root))",
            ))
        end
        for name in names
            path = joinpath(directory, name)
            islink(path) && throw(ArgumentError(
                "contribution bundles must not contain symbolic links: $(relpath(path, root))",
            ))
            push!(files, replace(relpath(path, root), '\\' => '/'))
        end
    end
    return sort!(files)
end

function _validate_contribution_text(path::AbstractString, relative::AbstractString)
    filename = basename(relative)
    extension = lowercase(splitext(filename)[2])
    (filename == "DONE" || extension in CONTRIBUTION_TEXT_EXTENSIONS) ||
        throw(ArgumentError(
            "contribution artifact $(relative) is not an allowed text file",
        ))
    parts = lowercase.(split(relative, '/'))
    ("figures" in parts || "raw" in parts || occursin(r"(^|[-_.])raw([-_.]|$)", lowercase(filename))) &&
        throw(ArgumentError(
            "contribution artifact $(relative) is a figure or raw trace",
        ))
    bytes = read(path)
    (isvalid(String, bytes) && !any(==(0x00), bytes)) || throw(ArgumentError(
        "contribution artifact $(relative) is not valid UTF-8 text",
    ))
    return length(bytes)
end

function _validate_record_bundle(directory::AbstractString; source_sha=nothing)
    isfile(joinpath(directory, "record.toml")) || throw(ArgumentError(
        "operation record is missing record.toml: $(directory)",
    ))
    manifest = TOML.parsefile(joinpath(directory, "record.toml"))
    get(manifest, "format", nothing) == RECORD_FORMAT || throw(ArgumentError(
        "operation record format must be $(repr(RECORD_FORMAT))",
    ))
    get(manifest, "format_version", nothing) == RECORD_FORMAT_VERSION ||
        throw(ArgumentError(
            "operation record format_version must be $(RECORD_FORMAT_VERSION)",
        ))
    get(manifest, "completion_marker", nothing) == "DONE" || throw(ArgumentError(
        "operation record completion marker must be DONE",
    ))
    isfile(joinpath(directory, "DONE")) || throw(ArgumentError(
        "operation record is incomplete: $(directory)",
    ))
    !isfile(joinpath(directory, "FAILED")) || throw(ArgumentError(
        "operation record contains FAILED: $(directory)",
    ))
    get(manifest, "git_state", nothing) == "clean" || throw(ArgumentError(
        "contributed operation records must have git_state = clean",
    ))
    if source_sha !== nothing
        get(manifest, "git_sha", nothing) == source_sha || throw(ArgumentError(
            "operation record git_sha does not match contribution source_sha",
        ))
    end

    haskey(manifest, "artifacts") || throw(ArgumentError("record requires artifacts"))
    artifacts = String.(manifest["artifacts"])
    length(unique(artifacts)) == length(artifacts) || throw(ArgumentError(
        "record artifact paths must be unique",
    ))
    haskey(manifest, "artifact_sha256") ||
        throw(ArgumentError("record requires artifact_sha256"))
    checksums = manifest["artifact_sha256"]
    Set(artifacts) == Set(keys(checksums)) || throw(ArgumentError(
        "record artifacts and artifact_sha256 keys must match",
    ))
    issubset(CONTRIBUTION_REQUIRED_RECORD_ARTIFACTS, Set(artifacts)) ||
        throw(ArgumentError(
            "operation record is missing one or more required standard artifacts",
        ))
    expected = Set(vcat(["record.toml", "DONE"], artifacts))
    actual = Set(_contribution_files(directory))
    expected == actual || throw(ArgumentError(
        "operation record file inventory does not match record.toml",
    ))
    for relative in artifacts
        path = _contribution_child(directory, relative, "record artifact path")
        digest = open(path, "r") do io
            bytes2hex(SHA.sha256(io))
        end
        digest == checksums[relative] || throw(ArgumentError(
            "record artifact checksum failed for $(relative)",
        ))
    end
    return manifest
end

function _validate_experiment_run(directory::AbstractString; source_sha=nothing)
    manifest_path = joinpath(directory, "experiment-run.toml")
    isfile(manifest_path) || throw(ArgumentError(
        "experiment run is missing experiment-run.toml: $(directory)",
    ))
    manifest = TOML.parsefile(manifest_path)
    _contribution_require_keys(
        manifest,
        (
            "format", "format_version", "id", "experiment", "experiment_version",
            "evidence_state", "protocol", "operation_records",
        ),
        ("format", "format_version", "id", "experiment", "experiment_version", "protocol",
            "operation_records"),
        "experiment run",
    )
    get(manifest, "format", nothing) == "brainlesslab-experiment-run" ||
        throw(ArgumentError("experiment run format must be \"brainlesslab-experiment-run\""))
    get(manifest, "format_version", nothing) == 1 ||
        throw(ArgumentError("experiment run format_version must be 1"))
    isfile(joinpath(directory, "DONE")) || throw(ArgumentError("experiment run is incomplete"))
    !isfile(joinpath(directory, "FAILED")) ||
        throw(ArgumentError("experiment run contains FAILED"))

    protocol_path = _contribution_relative_path(manifest["protocol"], "experiment protocol path")
    protocol_path == "protocol/experiment.toml" || throw(ArgumentError(
        "experiment run protocol must be protocol/experiment.toml",
    ))
    experiment = read_experiment(joinpath(directory, "protocol"))
    String(experiment.id) == manifest["experiment"] || throw(ArgumentError(
        "experiment run id does not match its ExperimentSpec",
    ))
    string(experiment.version) == manifest["experiment_version"] || throw(ArgumentError(
        "experiment run version does not match its ExperimentSpec",
    ))

    record_paths = String.(manifest["operation_records"])
    length(record_paths) == length(experiment.operations) || throw(ArgumentError(
        "experiment run operation count does not match its ExperimentSpec",
    ))
    length(unique(record_paths)) == length(record_paths) || throw(ArgumentError(
        "experiment run operation record paths must be unique",
    ))
    records = Dict{String,Any}[]
    for (index, (relative, plan)) in enumerate(zip(record_paths, experiment.operations))
        safe = _contribution_relative_path(relative, "operation record path")
        startswith(safe, "operations/") || throw(ArgumentError(
            "operation record path must be under operations/",
        ))
        record_path = _contribution_child(directory, safe, "operation record path")
        record = _validate_record_bundle(record_path; source_sha)
        record["kind"] == String(operation_kind(plan)) || throw(ArgumentError(
            "operation record $(index) kind does not match its ExperimentSpec",
        ))
        request = read_plan(joinpath(record_path, "request.toml"))
        plan_document(request) == plan_document(plan) || throw(ArgumentError(
            "operation record $(index) request does not match its ExperimentSpec",
        ))
        push!(records, Dict{String,Any}(
            "path" => safe,
            "manifest" => record,
        ))
    end
    return (manifest=manifest, experiment=experiment, records=records)
end

function _validate_bundle_inventory(
    contribution_directory::AbstractString,
    bundle_name::AbstractString,
    manifest,
)
    artifact_key = bundle_name * "_artifacts"
    checksum_key = bundle_name * "_sha256"
    artifacts = String.(manifest[artifact_key])
    length(unique(artifacts)) == length(artifacts) || throw(ArgumentError(
        "$(artifact_key) paths must be unique",
    ))
    checksums = manifest[checksum_key]
    Set(artifacts) == Set(keys(checksums)) || throw(ArgumentError(
        "$(artifact_key) and $(checksum_key) keys must match",
    ))
    bundle = _contribution_child(
        contribution_directory,
        manifest[bundle_name],
        "$(bundle_name) path",
    )
    actual = _contribution_files(bundle)
    Set(actual) == Set(artifacts) || throw(ArgumentError(
        "$(bundle_name) file inventory does not match contribution.toml",
    ))
    total = 0
    for relative in artifacts
        path = _contribution_child(bundle, relative, "$(bundle_name) artifact path")
        total += _validate_contribution_text(path, relative)
        digest = open(path, "r") do io
            bytes2hex(SHA.sha256(io))
        end
        digest == checksums[relative] || throw(ArgumentError(
            "$(bundle_name) checksum failed for $(relative)",
        ))
    end
    total <= CONTRIBUTION_MAX_BYTES || throw(ArgumentError(
        "$(bundle_name) is $(total) bytes; the hard limit is $(CONTRIBUTION_MAX_BYTES)",
    ))
    return (path=bundle, bytes=total, target_exceeded=total > CONTRIBUTION_TARGET_BYTES)
end

function _git_object_exists(repository::AbstractString, revision::AbstractString)
    command = Cmd(`git cat-file -e $revision`; dir=repository)
    return success(pipeline(command; stdout=devnull, stderr=devnull))
end

function _verify_source_revision(repository::AbstractString, source_sha::AbstractString, main_ref)
    occursin(r"^[0-9a-f]{40}$", source_sha) || throw(ArgumentError(
        "contribution source_sha must be a full lower-case Git SHA",
    ))
    revision = string(source_sha, "^{commit}")
    _git_object_exists(repository, revision) ||
        throw(ArgumentError("contribution source_sha is not a reachable commit"))
    if main_ref !== nothing
        command = Cmd(`git merge-base --is-ancestor $source_sha $main_ref`; dir=repository)
        success(command) || throw(ArgumentError(
            "contribution source_sha is not reachable from $(main_ref)",
        ))
    end
    return source_sha
end

function _read_source_experiment(
    repository::AbstractString,
    source_sha::AbstractString,
    experiment_path::AbstractString,
)
    tree = read(
        Cmd(
            `git ls-tree -r --name-only -z $source_sha -- $experiment_path`;
            dir=repository,
        ),
        String,
    )
    paths = filter(path -> !isempty(path), split(tree, '\0'))
    isempty(paths) && throw(ArgumentError(
        "experiment_path does not exist at contribution source_sha",
    ))
    prefix = experiment_path * "/"
    mktempdir() do temporary
        for repository_path in paths
            startswith(repository_path, prefix) || throw(ArgumentError(
                "source experiment contains a path outside experiment_path",
            ))
            relative = _contribution_relative_path(
                chopprefix(repository_path, prefix),
                "source experiment artifact",
            )
            (relative == "experiment.toml" ||
                (startswith(relative, "plans/") && endswith(relative, ".toml"))) ||
                throw(ArgumentError(
                    "source experiment contains an unexpected artifact: $(relative)",
                ))
            output = _contribution_child(temporary, relative, "source experiment artifact")
            mkpath(dirname(output))
            revision = string(source_sha, ":", repository_path)
            contents = read(Cmd(`git show $revision`; dir=repository))
            open(output, "w") do io
                write(io, contents)
            end
        end
        isfile(joinpath(temporary, "experiment.toml")) || throw(ArgumentError(
            "experiment_path has no experiment.toml at contribution source_sha",
        ))
        return read_experiment(temporary)
    end
end

function _comparison_document(submission, replay)
    submission.experiment.id == replay.experiment.id || throw(ArgumentError(
        "submission and replay use different experiment ids",
    ))
    submission.experiment.version == replay.experiment.version || throw(ArgumentError(
        "submission and replay use different experiment versions",
    ))
    operations = Dict{String,Any}[]
    for (index, (left, right)) in enumerate(zip(submission.records, replay.records))
        left_dir = left["directory"]
        right_dir = right["directory"]
        request_equal = TOML.parsefile(joinpath(left_dir, "request.toml")) ==
            TOML.parsefile(joinpath(right_dir, "request.toml"))
        resolved_equal = TOML.parsefile(joinpath(left_dir, "resolved.toml")) ==
            TOML.parsefile(joinpath(right_dir, "resolved.toml"))
        seeds_equal = read(joinpath(left_dir, "seeds.csv")) ==
            read(joinpath(right_dir, "seeds.csv"))
        request_equal || throw(ArgumentError(
            "operation $(index) request differs between submission and replay",
        ))
        resolved_equal || throw(ArgumentError(
            "operation $(index) resolved configuration differs between submission and replay",
        ))
        seeds_equal || throw(ArgumentError(
            "operation $(index) seeds differ between submission and replay",
        ))
        left_manifest = left["manifest"]
        right_manifest = right["manifest"]
        data_paths = sort!(collect(union(
            filter(path -> startswith(path, "data/") || startswith(path, "summary/"),
                String.(left_manifest["artifacts"])),
            filter(path -> startswith(path, "data/") || startswith(path, "summary/"),
                String.(right_manifest["artifacts"])),
        )))
        data_equal = all(data_paths) do path
            isfile(joinpath(left_dir, path)) && isfile(joinpath(right_dir, path)) &&
                read(joinpath(left_dir, path)) == read(joinpath(right_dir, path))
        end
        push!(operations, Dict{String,Any}(
            "index" => index,
            "kind" => left_manifest["kind"],
            "request_equal" => true,
            "resolved_equal" => true,
            "seeds_equal" => true,
            "data_equal" => data_equal,
            "compared_data_paths" => data_paths,
        ))
    end
    return Dict{String,Any}(
        "format" => "brainlesslab-contribution-comparison",
        "format_version" => 1,
        "experiment" => String(submission.experiment.id),
        "experiment_version" => string(submission.experiment.version),
        "protocol_equal" => true,
        "configuration_equal" => true,
        "seeds_equal" => true,
        "replay_is_independent_evidence" => false,
        "operations" => operations,
    )
end

function _prepare_run_for_comparison(run, directory)
    records = Dict{String,Any}[]
    for entry in run.records
        copied = copy(entry)
        copied["directory"] = _contribution_child(directory, entry["path"], "operation path")
        push!(records, copied)
    end
    return (manifest=run.manifest, experiment=run.experiment, records=records)
end

function _experiment_protocol_signature(experiment::ExperimentSpec)
    return (
        experiment=experiment_document(experiment),
        operations=[plan_document(plan) for plan in experiment.operations],
    )
end

function compare_contribution(directory::AbstractString; write=false)
    manifest = TOML.parsefile(joinpath(directory, "contribution.toml"))
    submission_directory = _contribution_child(directory, manifest["submission"], "submission path")
    replay_directory = _contribution_child(directory, manifest["replay"], "replay path")
    submission = _prepare_run_for_comparison(
        _validate_experiment_run(submission_directory; source_sha=manifest["source_sha"]),
        submission_directory,
    )
    replay = _prepare_run_for_comparison(
        _validate_experiment_run(replay_directory; source_sha=manifest["source_sha"]),
        replay_directory,
    )
    protocol_files = filter(
        path -> startswith(path, "protocol/"),
        _contribution_files(submission_directory),
    )
    replay_protocol_files = filter(
        path -> startswith(path, "protocol/"),
        _contribution_files(replay_directory),
    )
    protocol_files == replay_protocol_files || throw(ArgumentError(
        "submission and replay protocol inventories differ",
    ))
    all(protocol_files) do relative
        read(joinpath(submission_directory, relative)) ==
            read(joinpath(replay_directory, relative))
    end || throw(ArgumentError("submission and replay protocols differ"))
    document = _comparison_document(submission, replay)
    if write
        open(joinpath(directory, "comparison.json"), "w") do io
            Base.write(io, _json(document), '\n')
        end
    end
    return document
end

function _check_contribution_append_only(
    directory::AbstractString,
    repository::AbstractString,
    base_ref::AbstractString,
)
    root = normpath(abspath(repository))
    relative = replace(relpath(directory, root), '\\' => '/')
    startswith(relative, "research/contributions/") || throw(ArgumentError(
        "accepted contribution must be under research/contributions/",
    ))
    prior_manifest = string(base_ref, ":", relative, "/contribution.toml")
    output = readchomp(Cmd(`git diff --name-status $base_ref...HEAD`; dir=root))
    if _git_object_exists(root, prior_manifest)
        isempty(output) && return nothing
        changed = filter(split(output, '\n')) do line
            columns = split(line, '\t')
            any(path -> path == relative || startswith(path, relative * "/"), columns[2:end])
        end
        isempty(changed) && return nothing
        throw(ArgumentError(
            "accepted contribution records are append-only; found $(join(changed, "; "))",
        ))
    end
    isempty(output) && return nothing
    for line in split(output, '\n')
        columns = split(line, '\t')
        status = first(columns)
        changed_path = last(columns)
        if changed_path == "research/catalogue.json"
            status in ("A", "M") || throw(ArgumentError(
                "research catalogue may only be added or regenerated; found $(line)",
            ))
            continue
        end
        startswith(status, "A") || throw(ArgumentError(
            "run-only contribution pull requests may only add files; found $(line)",
        ))
        startswith(changed_path, relative * "/") || throw(ArgumentError(
            "run-only contribution pull request changed a file outside $(relative): $(changed_path)",
        ))
        prior_path = string(base_ref, ":", changed_path)
        if _git_object_exists(root, prior_path)
            throw(ArgumentError(
                "accepted contribution records are append-only; $(changed_path) exists at $(base_ref)",
            ))
        end
    end
    return nothing
end

function validate_contribution(
    directory::AbstractString;
    repository::Union{Nothing,AbstractString},
    main_ref::Union{Nothing,AbstractString}=nothing,
    base_ref::Union{Nothing,AbstractString}=nothing,
)
    isdir(directory) || throw(ArgumentError("contribution directory does not exist: $(directory)"))
    islink(directory) && throw(ArgumentError(
        "contribution directory must not be a symbolic link",
    ))
    manifest_path = joinpath(directory, "contribution.toml")
    isfile(manifest_path) || throw(ArgumentError("contribution is missing contribution.toml"))
    manifest = TOML.parsefile(manifest_path)
    allowed = (
        "format", "format_version", "id", "experiment_id", "experiment_version",
        "experiment_path", "contributor", "reviewer", "source_sha", "submission",
        "replay", "review_url", "accepted_utc", "reproduction_state",
        "submission_artifacts", "submission_sha256", "replay_artifacts", "replay_sha256",
    )
    required = allowed
    _contribution_require_keys(manifest, allowed, required, "contribution")
    manifest["format"] == CONTRIBUTION_FORMAT || throw(ArgumentError(
        "contribution format must be $(repr(CONTRIBUTION_FORMAT))",
    ))
    manifest["format_version"] == CONTRIBUTION_FORMAT_VERSION || throw(ArgumentError(
        "contribution format_version must be $(CONTRIBUTION_FORMAT_VERSION)",
    ))
    manifest["reproduction_state"] == "accepted" || throw(ArgumentError(
        "committed contributions must have reproduction_state = \"accepted\"",
    ))
    manifest["contributor"] != manifest["reviewer"] || throw(ArgumentError(
        "contributor and reviewer must be different people",
    ))
    for key in ("contributor", "reviewer", "review_url")
        isempty(strip(String(manifest[key]))) && throw(ArgumentError(
            "contribution $(key) must not be empty",
        ))
    end
    occursin(r"^https://[^/\s]+(?:/.*)?$", String(manifest["review_url"])) ||
        throw(ArgumentError(
        "contribution review_url must be an absolute HTTPS URL",
        ))
    experiment_path = _contribution_relative_path(
        manifest["experiment_path"],
        "experiment_path",
    )
    startswith(experiment_path, "experiments/") || throw(ArgumentError(
        "experiment_path must be under experiments/",
    ))
    for key in ("id", "experiment_id")
        occursin(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$", manifest[key]) || throw(ArgumentError(
            "$(key) must be a stable lower-case identifier",
        ))
    end
    version = VersionNumber(manifest["experiment_version"])
    expected_parent = joinpath(
        manifest["experiment_id"],
        "v" * string(version),
        manifest["id"],
    )
    replace(normpath(relpath(directory, joinpath(directory, "..", "..", ".."))), '\\' => '/') ==
        expected_parent || throw(ArgumentError(
            "contribution path must be <experiment-id>/v<version>/<contribution-id>",
        ))
    manifest["submission"] == "submission" || throw(ArgumentError(
        "contribution submission path must be submission",
    ))
    manifest["replay"] == "replay" || throw(ArgumentError(
        "contribution replay path must be replay",
    ))
    submission = _validate_bundle_inventory(directory, "submission", manifest)
    replay = _validate_bundle_inventory(directory, "replay", manifest)
    source_sha = String(manifest["source_sha"])
    occursin(r"^[0-9a-f]{40}$", source_sha) || throw(ArgumentError(
        "contribution source_sha must be a full lower-case Git SHA",
    ))
    repository === nothing || _verify_source_revision(repository, source_sha, main_ref)
    (repository === nothing || base_ref === nothing) ||
        _check_contribution_append_only(directory, repository, base_ref)

    submission_run = _validate_experiment_run(submission.path; source_sha)
    replay_run = _validate_experiment_run(replay.path; source_sha)
    if repository !== nothing
        repository_experiment = _read_source_experiment(
            repository,
            source_sha,
            experiment_path,
        )
        _experiment_protocol_signature(repository_experiment) ==
            _experiment_protocol_signature(submission_run.experiment) || throw(ArgumentError(
                "experiment_path does not match the submitted ExperimentSpec",
            ))
    end
    String(submission_run.experiment.id) == manifest["experiment_id"] ||
        throw(ArgumentError("submission ExperimentSpec id does not match contribution"))
    submission_run.experiment.version == version || throw(ArgumentError(
        "submission ExperimentSpec version does not match contribution",
    ))
    replay_run.experiment.id == submission_run.experiment.id &&
        replay_run.experiment.version == submission_run.experiment.version ||
        throw(ArgumentError("replay ExperimentSpec does not match submission"))
    comparison = compare_contribution(directory)
    for operation in comparison["operations"]
        operation["data_equal"] || throw(ArgumentError(
            "operation $(operation["index"]) replay data and summary artifacts differ",
        ))
    end
    comparison_path = joinpath(directory, "comparison.json")
    isfile(comparison_path) || throw(ArgumentError("contribution is missing comparison.json"))
    read(comparison_path, String) == _json(comparison) * "\n" || throw(ArgumentError(
        "comparison.json is stale; run compare-contribution with --write",
    ))
    expected_top = Set(vcat(
        ["contribution.toml", "comparison.json"],
        [manifest["submission"] * "/" * path for path in manifest["submission_artifacts"]],
        [manifest["replay"] * "/" * path for path in manifest["replay_artifacts"]],
    ))
    Set(_contribution_files(directory)) == expected_top || throw(ArgumentError(
        "contribution contains files outside its exact inventories",
    ))
    total_bytes = sum(filesize(joinpath(directory, split(path, '/')...)) for path in expected_top)
    total_bytes <= CONTRIBUTION_MAX_BYTES || throw(ArgumentError(
        "contribution is $(total_bytes) bytes; the hard limit is $(CONTRIBUTION_MAX_BYTES)",
    ))
    return (
        manifest=manifest,
        experiment=submission_run.experiment,
        submission=submission_run,
        replay=replay_run,
        submission_bytes=submission.bytes,
        replay_bytes=replay.bytes,
        total_bytes=total_bytes,
        target_exceeded=total_bytes > CONTRIBUTION_TARGET_BYTES,
    )
end

function _catalogue_run(role, run, contribution_path, run_relative; independent_evidence)
    operations = Dict{String,Any}[]
    for record in run.records
        record_root = joinpath(contribution_path, run_relative, record["path"])
        resolved = TOML.parsefile(joinpath(record_root, "resolved.toml"))
        push!(operations, Dict{String,Any}(
            "id" => splitext(basename(record["path"]))[1],
            "kind" => record["manifest"]["kind"],
            "targets" => get(resolved, "targets", Any[]),
            "settings" => get(resolved, "operation_settings", Dict{String,Any}()),
            "paths" => Dict{String,Any}(
                "record" => replace(relpath(record_root, _record_repo_root()), '\\' => '/'),
                "request" => replace(relpath(joinpath(record_root, "request.toml"), _record_repo_root()), '\\' => '/'),
                "resolved" => replace(relpath(joinpath(record_root, "resolved.toml"), _record_repo_root()), '\\' => '/'),
                "seeds" => replace(relpath(joinpath(record_root, "seeds.csv"), _record_repo_root()), '\\' => '/'),
                "trials" => replace(relpath(joinpath(record_root, "data", "trials.csv"), _record_repo_root()), '\\' => '/'),
                "task_metrics" => replace(relpath(joinpath(record_root, "data", "task_metrics.csv"), _record_repo_root()), '\\' => '/'),
                "summary" => replace(relpath(joinpath(record_root, "summary", "summary.json"), _record_repo_root()), '\\' => '/'),
                "report" => replace(relpath(joinpath(record_root, "report", "index.html"), _record_repo_root()), '\\' => '/'),
            ),
        ))
    end
    return Dict{String,Any}(
        "role" => role,
        "independent_evidence" => independent_evidence,
        "run_id" => run.manifest["id"],
        "operations" => operations,
    )
end

function _accepted_catalogue_entry(
    directory::AbstractString;
    repository::Union{Nothing,AbstractString},
    main_ref::Union{Nothing,AbstractString},
)
    contribution = validate_contribution(directory; repository, main_ref)
    manifest = contribution.manifest
    relative = replace(relpath(directory, _record_repo_root()), '\\' => '/')
    return Dict{String,Any}(
        "id" => manifest["id"],
        "admission" => "accepted",
        "experiment_id" => manifest["experiment_id"],
        "experiment_version" => manifest["experiment_version"],
        "evidence_state" => String(contribution.experiment.evidence_state),
        "title" => contribution.experiment.title,
        "question" => contribution.experiment.question,
        "limitations" => collect(contribution.experiment.limitations),
        "source_sha" => manifest["source_sha"],
        "contributor" => manifest["contributor"],
        "reviewer" => manifest["reviewer"],
        "review_url" => manifest["review_url"],
        "accepted_utc" => manifest["accepted_utc"],
        "paths" => Dict{String,Any}(
            "contribution" => relative,
            "experiment" => manifest["experiment_path"],
            "comparison" => relative * "/comparison.json",
        ),
        "runs" => [
            _catalogue_run(
                "submission",
                contribution.submission,
                directory,
                manifest["submission"];
                independent_evidence=true,
            ),
            _catalogue_run(
                "maintainer_replay",
                contribution.replay,
                directory,
                manifest["replay"];
                independent_evidence=false,
            ),
        ],
    )
end

function _pre_pipeline_entries(
    path::AbstractString;
    repository_root::AbstractString=_record_repo_root(),
)
    isfile(path) || return Dict{String,Any}[]
    document = TOML.parsefile(path)
    _require_document_keys(document, ("record",), "pre-pipeline registry")
    records = get(document, "record", Any[])
    entries = Dict{String,Any}[]
    for entry in records
        _contribution_require_keys(
            entry,
            (
                "id", "experiment_id", "experiment_version", "title", "evidence_state",
                "protocol_path", "record_path", "note",
            ),
            (
                "id", "experiment_id", "experiment_version", "title", "evidence_state",
                "protocol_path", "record_path", "note",
            ),
            "pre-pipeline record",
        )
        for key in (
            "id", "experiment_id", "experiment_version", "title", "evidence_state", "note",
        )
            value = entry[key]
            value isa AbstractString && !isempty(value) || throw(ArgumentError(
                "pre-pipeline record $(key) must be a non-empty string",
            ))
        end
        protocol_path = _contribution_relative_path(
            entry["protocol_path"],
            "pre-pipeline protocol path",
        )
        record_path = _contribution_relative_path(
            entry["record_path"],
            "pre-pipeline record path",
        )
        protocol = _contribution_child(
            repository_root,
            protocol_path,
            "pre-pipeline protocol path",
        )
        isfile(protocol) || throw(ArgumentError(
            "pre-pipeline protocol does not exist: $(protocol_path)",
        ))
        record_root = _contribution_child(
            repository_root,
            record_path,
            "pre-pipeline record path",
        )
        record = _validate_record_bundle(record_root)
        resolved = TOML.parsefile(joinpath(record_root, "resolved.toml"))
        operation = Dict{String,Any}(
            "id" => record["id"],
            "kind" => record["kind"],
            "targets" => get(resolved, "targets", Any[]),
            "settings" => get(resolved, "operation_settings", Dict{String,Any}()),
            "paths" => Dict{String,Any}(
                "record" => record_path,
                "request" => record_path * "/request.toml",
                "resolved" => record_path * "/resolved.toml",
                "seeds" => record_path * "/seeds.csv",
                "trials" => record_path * "/data/trials.csv",
                "task_metrics" => record_path * "/data/task_metrics.csv",
                "summary" => record_path * "/summary/summary.json",
                "report" => record_path * "/report/index.html",
            ),
        )
        push!(entries, Dict{String,Any}(
            "id" => entry["id"],
            "admission" => "pre-pipeline",
            "experiment_id" => entry["experiment_id"],
            "experiment_version" => entry["experiment_version"],
            "evidence_state" => entry["evidence_state"],
            "title" => entry["title"],
            "note" => entry["note"],
            "source_sha" => record["git_sha"],
            "paths" => Dict{String,Any}(
                "protocol" => protocol_path,
                "record" => record_path,
            ),
            "runs" => [Dict{String,Any}(
                "role" => "historical_record",
                "independent_evidence" => false,
                "run_id" => record["id"],
                "operations" => [operation],
            )],
        ))
    end
    return entries
end

function research_catalogue(;
    root::AbstractString=joinpath(_record_repo_root(), "research"),
    repository::Union{Nothing,AbstractString},
    main_ref::Union{Nothing,AbstractString}=nothing,
)
    repository_root = repository === nothing ? _record_repo_root() : repository
    contributions = _pre_pipeline_entries(
        joinpath(root, "pre-pipeline.toml");
        repository_root,
    )
    accepted_root = joinpath(root, "contributions")
    if isdir(accepted_root)
        for (experiment_root, versions, _) in walkdir(accepted_root)
            rel_parts = split(replace(relpath(experiment_root, accepted_root), '\\' => '/'), '/')
            length(rel_parts) == 2 || continue
            for contribution_id in sort!(filter(
                name -> isdir(joinpath(experiment_root, name)),
                readdir(experiment_root),
            ))
                push!(
                    contributions,
                    _accepted_catalogue_entry(
                        joinpath(experiment_root, contribution_id);
                        repository,
                        main_ref,
                    ),
                )
            end
            empty!(versions)
        end
    end
    sort!(contributions; by=entry -> (
        entry["experiment_id"],
        entry["experiment_version"],
        entry["id"],
    ))
    return Dict{String,Any}(
        "format" => RESEARCH_CATALOGUE_FORMAT,
        "format_version" => RESEARCH_CATALOGUE_FORMAT_VERSION,
        "contributions" => contributions,
    )
end

function write_research_catalogue(
    output::AbstractString=joinpath(_record_repo_root(), "research", "catalogue.json");
    root::AbstractString=joinpath(_record_repo_root(), "research"),
    repository::Union{Nothing,AbstractString},
    main_ref::Union{Nothing,AbstractString}=nothing,
)
    document = research_catalogue(; root, repository, main_ref)
    mkpath(dirname(output))
    open(output, "w") do io
        write(io, _json(document), '\n')
    end
    return String(output)
end
