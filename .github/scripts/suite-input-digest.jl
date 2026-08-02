using SHA

const REPOSITORY_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
include(joinpath(REPOSITORY_ROOT, "test", "suites.jl"))

const COMMON_INPUTS = (
    ".github/workflows/ci.yml",
    ".github/scripts/suite-input-digest.jl",
    "Project.toml",
    "Manifest.toml",
    "src",
    "ext",
    "test/runtests.jl",
    "test/suites.jl",
    "test/testutils.jl",
)

const EXTERNAL_INPUTS = (
    core=(
        "README.md",
        "CONTRIBUTING.md",
        "AGENTS.md",
        "docs",
        "site/src",
        "examples",
        "experiments/README.md",
        "skills",
        "research",
    ),
    runtime=(
        "examples/embodiments",
        "examples/templates/new_project",
        "examples/shoal_forage_quickstart.jl",
    ),
    operations=("bin", "plans", "experiments", "research"),
    oracle=(
        "test/fixtures",
        "test/oracle",
        "tools/calibration",
        "tools/configs",
    ),
    legacy=(),
)

function input_files(roots)
    paths = String[]
    for relative_root in roots
        root = joinpath(REPOSITORY_ROOT, relative_root)
        if isfile(root)
            push!(paths, normpath(root))
        elseif isdir(root)
            for (directory, _, files) in walkdir(root), file in files
                path = joinpath(directory, file)
                isfile(path) && push!(paths, normpath(path))
            end
        else
            throw(ArgumentError(
                "declared suite input does not exist: $(repr(relative_root))",
            ))
        end
    end
    return sort!(unique(paths))
end

function suite_input_digest(suite::Symbol; include_manifest::Bool=true)
    suite in keys(EXTERNAL_INPUTS) ||
        throw(ArgumentError("suite input digest does not support $(repr(suite))"))

    common = include_manifest ?
        COMMON_INPUTS :
        filter(!=("Manifest.toml"), COMMON_INPUTS)
    roots = String[common...]
    append!(roots, joinpath.("test", test_files_for(suite)))
    append!(roots, getproperty(EXTERNAL_INPUTS, suite))

    parts = map(input_files(roots)) do path
        relative = replace(relpath(path, REPOSITORY_ROOT), '\\' => '/')
        string(relative, '\0', bytes2hex(SHA.sha256(read(path))))
    end
    return bytes2hex(SHA.sha256(join(parts, '\n')))
end

function main(args)
    isempty(args) && throw(ArgumentError(
        "usage: suite-input-digest.jl SUITE [--without-manifest]",
    ))
    length(args) <= 2 || throw(ArgumentError("too many arguments"))
    suite = parse_test_suite(args[1])
    include_manifest = true
    if length(args) == 2
        args[2] == "--without-manifest" ||
            throw(ArgumentError("unknown option $(repr(args[2]))"))
        include_manifest = false
    end

    digest = suite_input_digest(suite; include_manifest)
    if haskey(ENV, "GITHUB_OUTPUT")
        open(ENV["GITHUB_OUTPUT"], "a") do io
            println(io, "digest=", digest)
        end
    end
    println(digest)
    return nothing
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
