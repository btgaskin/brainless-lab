using Test

@testset "public documentation uses current vocabulary and canonical paths" begin
    root = normpath(joinpath(@__DIR__, ".."))
    surfaces = (
        joinpath(root, "README.md"),
        joinpath(root, "docs"),
        joinpath(root, "site", "src", "content"),
        joinpath(root, "examples"),
        joinpath(root, "experiments", "README.md"),
        joinpath(root, "skills", "brainless-lab"),
    )
    forbidden = (
        r"VEN[A-Za-z_]*|:ven(?:_|\b)|\"ven(?:_|\")|SensorimotorBody|HomeostaticBody|PassthroughBody|NeedSpec|NeedDelta|Morphology\.jl|encode_receptors|decode_effectors|update_body!",
        r"""docs_path\s*=\s*"docs/""",
        r"authors-faithful|authors faithful",
        r"\brun_sweep\b|whole compute surface",
        r":falandays_base\b",
    )
    offenders = String[]
    for surface in surfaces
        files = if isfile(surface)
            (surface,)
        else
            Tuple(
                joinpath(directory, file)
                for (directory, _, names) in walkdir(surface)
                for file in names
                if any(extension -> endswith(file, extension), (".md", ".mdx", ".jl", ".toml", ".mjs"))
            )
        end
        for file in files
            text = read(file, String)
            any(pattern -> occursin(pattern, text), forbidden) &&
                push!(offenders, relpath(file, root))
        end
    end
    @test isempty(offenders)
end
