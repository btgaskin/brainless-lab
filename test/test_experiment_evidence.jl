using Test

function _frontmatter_field(source::AbstractString, field::AbstractString)
    matched = match(Regex("(?m)^\\s+" * field * ":\\s+(.+?)\\s*\$"), source)
    return isnothing(matched) ? nothing : strip(only(matched.captures))
end

@testset "experiment pages declare evidence metadata" begin
    directory = joinpath(
        @__DIR__,
        "..",
        "site",
        "src",
        "content",
        "docs",
        "experiments",
    )
    pages = filter(
        path -> endswith(path, ".mdx") && basename(path) != "overview.mdx",
        readdir(directory; join=true),
    )
    @test !isempty(pages)
    repository_root = normpath(joinpath(@__DIR__, ".."))

    for path in pages
        source = read(path, String)
        @test occursin(r"(?m)^evidence:\s*$", source)
        @test occursin(
            r"(?m)^\s+status:\s+(exploratory|tuned|frozen|confirmed|promoted|retired)\s*$",
            source,
        )
        @test occursin(r"(?m)^\s+randomization_unit:\s+\S", source)
        @test occursin(r"(?m)^\s+n_independent_blocks:\s+\d+\s*$", source)
        @test occursin(r"(?m)^\s+block_summary:\s+\S", source)
        @test occursin(r"(?m)^\s+primary_endpoint:\s+\S", source)
        @test occursin(r"(?m)^\s+artifact_path:\s+\S", source)
        @test occursin(r"(?m)^\s+limitations:\s+\S", source)

        status = _frontmatter_field(source, "status")
        if status in ("confirmed", "promoted")
            block_count = tryparse(
                Int,
                something(_frontmatter_field(source, "n_independent_blocks"), ""),
            )
            @test !isnothing(block_count)
            @test block_count > 0

            artifact_path = something(_frontmatter_field(source, "artifact_path"), "")
            artifact = normpath(joinpath(repository_root, artifact_path))
            @test startswith(artifact, repository_root * Base.Filesystem.path_separator)
            @test ispath(artifact)
        end
    end
end

@testset "published documentation does not link to draft experiments" begin
    docs_directory = joinpath(@__DIR__, "..", "site", "src", "content", "docs")
    pages = String[]
    for (root, _, files) in walkdir(docs_directory), file in files
        endswith(file, ".mdx") && push!(pages, joinpath(root, file))
    end

    draft_routes = String[]
    for path in pages
        source = read(path, String)
        occursin(r"(?m)^draft:\s+true\s*$", source) || continue
        relative = relpath(path, docs_directory)
        route = "/" * replace(splitext(relative)[1], Base.Filesystem.path_separator => "/") * "/"
        push!(draft_routes, route)
    end
    @test !isempty(draft_routes)

    for path in pages
        source = read(path, String)
        occursin(r"(?m)^draft:\s+true\s*$", source) && continue
        for route in draft_routes
            @test !occursin(route, source)
        end
    end
end
