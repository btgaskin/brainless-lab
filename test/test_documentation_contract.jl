using Test

@testset "maintained documentation has one current route set" begin
    repository = normpath(joinpath(@__DIR__, ".."))
    docs = joinpath(repository, "site", "src", "content", "docs")

    @test isfile(joinpath(docs, "tutorials", "first-simulation.mdx"))
    @test isfile(joinpath(docs, "handbook", "operations.mdx"))
    @test isfile(joinpath(docs, "reference", "interfaces.mdx"))
    @test isfile(joinpath(docs, "research", "index.mdx"))
    @test isfile(joinpath(docs, "benchmarks", "index.mdx"))
    @test isfile(joinpath(docs, "experiments", "index.mdx"))
    @test isfile(joinpath(docs, "experimental", "index.mdx"))
    @test isfile(joinpath(docs, "research", "catalogue.mdx"))
    @test !isdir(joinpath(docs, "notes"))
    @test !any(isfile, (
        joinpath(docs, "core", "operations-records.mdx"),
        joinpath(docs, "core", "architecture.mdx"),
        joinpath(docs, "node-mechanisms.mdx"),
    ))

    retired_files = (
        "collective.mdx",
        "concepts.mdx",
        "environments-tasks.mdx",
        "extending.mdx",
        "getting-started.mdx",
        "introduction.mdx",
        "receptors-effectors.mdx",
        "research-workflow.mdx",
        "task-reference.mdx",
        "tooling.mdx",
        joinpath("nodes", "falandays.mdx"),
        joinpath("nodes", "overview.mdx"),
        joinpath("outputs", "overview.mdx"),
    )
    @test all(path -> !isfile(joinpath(docs, path)), retired_files)

    maintained_surfaces = (
        joinpath(repository, "README.md"),
        joinpath(repository, "CONTRIBUTING.md"),
        joinpath(repository, "AGENTS.md"),
        joinpath(repository, "docs"),
        joinpath(repository, "site", "src"),
        joinpath(repository, "examples"),
        joinpath(repository, "experiments", "README.md"),
        joinpath(repository, "research"),
        joinpath(repository, "skills", "brainless-lab"),
    )
    retired_links = (
        r"\]\(/notes/",
        r"\]\(/collective/",
        r"\]\(/concepts/",
        r"\]\(/environments-tasks/",
        r"\]\(/extending/",
        r"\]\(/getting-started/",
        r"\]\(/introduction/",
        r"\]\(/nodes/",
        r"\]\(/outputs/",
        r"\]\(/receptors-effectors/",
        r"\]\(/research-workflow/",
        r"\]\(/task-reference/",
        r"\]\(/tooling/",
        r"\]\(/core/",
        r"\]\(/analysis/",
        r"\]\(/contracts/",
        r"\]\(/evolution/",
        r"\]\(/node-mechanisms/",
        r"\]\(/scoring/",
        r"\]\(/agentic-workflow/",
        r"/core/tools-artifacts/",
    )
    offenders = String[]
    for surface in maintained_surfaces
        files = isfile(surface) ? (surface,) : Tuple(
            joinpath(directory, file)
            for (directory, _, names) in walkdir(surface)
            for file in names
            if any(
                extension -> endswith(file, extension),
                (".md", ".mdx", ".jl", ".toml", ".mjs", ".ts", ".tsx"),
            )
        )
        for file in files
            source = read(file, String)
            any(pattern -> occursin(pattern, source), retired_links) &&
                push!(offenders, relpath(file, repository))
        end
    end
    @test isempty(unique(offenders))
end

@testset "CLI reports concise errors and record paths" begin
    repository = normpath(joinpath(@__DIR__, ".."))
    cli = Module(:BrainlessLabCLITest)
    Base.include(cli, joinpath(repository, "bin", "brainlesslab.jl"))

    mktemp() do path, io
        write(io, """
format = "brainlesslab-plan"
format_version = 1
operation = "profile"
id = "bad_cli_plan"
unknown = true
targets = []

[profile]
target = "missing"
""")
        flush(io)
        errors = IOBuffer()
        code = Base.invokelatest(
            cli.cli_main,
            ["check", path];
            error_io=errors,
        )
        message = String(take!(errors))
        @test code == 1
        @test startswith(message, "error: ")
        @test !occursin("Stacktrace", message)
        @test !occursin("_require_document_keys", message)
    end

    mktemp() do path, io
        write(io, """
format = "brainlesslab-plan"
format_version = 2
operation = "profile"
id = "unsupported_reset"

[[targets]]
id = "wall"

[targets.composition]
id = "null_wall"
node = "null_random"
task = "wall"
n_nodes = 5

[targets.evaluation]
horizon = 200
reset = "none"

[profile]
target = "wall"
analyses = []
""")
        flush(io)
        errors = IOBuffer()
        code = Base.invokelatest(
            cli.cli_main,
            ["check", path];
            error_io=errors,
        )
        message = String(take!(errors))
        @test code == 1
        @test message ==
              "error: ArgumentError: operation plan target :wall must use " *
              "reset=:full; generic evaluation does not support reset=:none\n"
    end

    mktemp() do plan_path, plan_io
        write(plan_io, """
format = "brainlesslab-plan"
format_version = 1
operation = "profile"
id = "cli_path_smoke"

[[targets]]
id = "tracking"

[targets.composition]
id = "cli_tracking"
node = "null_random"
task = "tracking"
n_nodes = 5

[targets.evaluation]
blocks = 1
trials_per_block = 1
horizon = 2000
warmup = 0
construction_scope = "trial"
reset = "full"
root_seed = 7
aggregate = "mean"

[profile]
target = "tracking"
analyses = []
record_every = 1
""")
        flush(plan_io)
        mktempdir() do records
            mktemp() do _, output
                code = redirect_stdout(output) do
                    Base.invokelatest(
                        cli.main,
                        ["run", plan_path, "--root", records],
                    )
                end
                flush(output)
                seekstart(output)
                lines = filter(!isempty, split(read(output, String), '\n'))
                @test code == 0
                @test length(lines) == 1
                @test startswith(only(lines), "record: ")
                @test !occursin("summary:", only(lines))
            end
        end
    end
end
