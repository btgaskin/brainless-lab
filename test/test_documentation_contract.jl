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
