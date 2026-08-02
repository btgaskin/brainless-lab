#!/usr/bin/env julia

const REPOSITORY = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_OUTPUT = joinpath(
    REPOSITORY,
    "site",
    "src",
    "fixtures",
    "example-record",
)
const PLANS = (
    profile=joinpath(@__DIR__, "example_profile.toml"),
    benchmark=joinpath(@__DIR__, "example_benchmark.toml"),
)

function _output_directory(args)
    isempty(args) && return DEFAULT_OUTPUT
    length(args) == 2 && args[1] == "--output" && return abspath(args[2])
    throw(ArgumentError(
        "usage: julia --project=. tools/docs/generate_example_records.jl " *
        "[--output DIRECTORY]",
    ))
end

function _record_directory(output::AbstractString)
    lines = filter(!isempty, strip.(split(output, '\n')))
    length(lines) == 1 && startswith(only(lines), "record: ") || error(
        "record CLI returned unexpected output: $(repr(output))",
    )
    return only(lines)[length("record: ") + 1:end]
end

function _normalise_record!(directory::AbstractString, stable_id::AbstractString)
    # write_record deliberately records the execution environment. The documentation
    # fixture instead uses stable placeholders for the timestamp, generated directory
    # id, source revision, Git state, and Julia version. Every artifact and checksum
    # remains byte-strict in the drift test.
    replacements = (
        "created_utc" => "1970-01-01T00:00:00.000",
        "git_sha" => "0000000000000000000000000000000000000000",
        "git_state" => "normalised",
        "id" => stable_id,
        "julia_version" => "0.0.0",
    )
    path = joinpath(directory, "record.toml")
    source = read(path, String)
    for (field, value) in replacements
        pattern = Regex("(?m)^" * field * " = \"[^\"]*\"\$")
        length(collect(eachmatch(pattern, source))) == 1 || error(
            "record.toml does not contain exactly one $(field) field",
        )
        source = replace(source, pattern => "$(field) = \"$(value)\"")
    end
    write(path, source)
    return directory
end

function _generate_fixture!(operation::Symbol, plan::AbstractString, output::AbstractString)
    record_root = mktempdir()
    julia = Base.julia_cmd()
    cli = joinpath(REPOSITORY, "bin", "brainlesslab.jl")
    command = `$(julia) --threads=1 --project=$(REPOSITORY) $(cli) run $(plan) --root $(record_root)`
    record = _record_directory(read(command, String))
    destination = joinpath(output, String(operation))
    ispath(destination) && rm(destination; recursive=true, force=true)
    mkpath(dirname(destination))
    cp(record, destination; force=true)
    _normalise_record!(destination, "documentation_example_$(operation)")
    println("generated $(operation) fixture: $(relpath(destination, REPOSITORY))")
    return destination
end

function main(args=ARGS)
    output = _output_directory(args)
    for operation in propertynames(PLANS)
        _generate_fixture!(operation, getproperty(PLANS, operation), output)
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
