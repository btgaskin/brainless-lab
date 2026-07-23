using Test

@testset "maintained documentation has one current route set" begin
    repository = normpath(joinpath(@__DIR__, ".."))
    docs = joinpath(repository, "site", "src", "content", "docs")

    @test isfile(joinpath(docs, "core", "operations-records.mdx"))
    @test isfile(joinpath(docs, "node-mechanisms.mdx"))
    @test !isdir(joinpath(docs, "notes"))
    @test !isdir(joinpath(docs, "experiments"))

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
        joinpath(repository, "skills", "brainless-lab"),
    )
    retired_links = (
        r"\]\(/notes/",
        r"\]\(/experiments/",
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
