using SHA

@testset "Scientific fixture integrity" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")
    manifest_path = joinpath(fixture_dir, "SCIENTIFIC_FIXTURES.sha256")
    entries = Dict{String,String}()

    for raw_line in eachline(manifest_path)
        line = strip(raw_line)
        (isempty(line) || startswith(line, '#')) && continue
        fields = split(line)
        @test length(fields) == 2
        length(fields) == 2 || continue
        digest, file = fields
        @test !haskey(entries, file)
        entries[file] = digest
    end

    fixture_files = sort!(
        filter(file -> file != basename(manifest_path), readdir(fixture_dir)),
    )
    @test sort!(collect(keys(entries))) == fixture_files

    for file in fixture_files
        path = joinpath(fixture_dir, file)
        actual = bytes2hex(SHA.sha256(read(path)))
        @test actual == entries[file]
    end
end
