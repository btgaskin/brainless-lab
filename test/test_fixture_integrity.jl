using SHA

const FIXTURE_MANIFEST = "SCIENTIFIC_FIXTURES.sha256"

function _safe_fixture_path(path::AbstractString)
    isempty(path) && return false
    occursin('\\', path) && return false
    occursin('\0', path) && return false
    isabspath(path) && return false
    occursin(r"^[A-Za-z]:", path) && return false
    parts = split(path, '/'; keepempty=true)
    any(part -> part in ("", ".", ".."), parts) && return false
    return true
end

function _integrity_fixture_path(
    root::AbstractString,
    relative::AbstractString,
)
    return joinpath(root, split(relative, '/')...)
end

function _fixture_integrity_errors(
    fixture_dir::AbstractString;
    manifest_name::AbstractString=FIXTURE_MANIFEST,
)
    errors = String[]
    if islink(fixture_dir)
        push!(errors, "symlink fixture root")
        return errors
    end
    manifest_path = joinpath(fixture_dir, manifest_name)
    if !isfile(manifest_path)
        push!(errors, "missing fixture manifest: $manifest_name")
        return errors
    end
    if islink(manifest_path)
        push!(errors, "symlink fixture manifest: $manifest_name")
        return errors
    end

    entries = Dict{String,String}()
    for (line_number, raw_line) in enumerate(eachline(manifest_path))
        line = strip(raw_line)
        (isempty(line) || startswith(line, '#')) && continue
        fields = split(line; limit=2)
        if length(fields) != 2
            push!(errors, "malformed manifest line $line_number")
            continue
        end
        digest, relative = fields
        relative = strip(relative)
        if !occursin(r"^[0-9a-f]{64}$", digest)
            push!(errors, "invalid SHA-256 on manifest line $line_number")
            continue
        end
        if !_safe_fixture_path(relative) || relative == manifest_name
            push!(errors, "unsafe fixture path on manifest line $line_number: $relative")
            continue
        end
        if haskey(entries, relative)
            push!(errors, "duplicate fixture path on manifest line $line_number: $relative")
            continue
        end
        entries[relative] = digest
    end

    fixture_files = String[]
    for (directory, directories, files) in walkdir(fixture_dir; follow_symlinks=false)
        for name in directories
            path = joinpath(directory, name)
            islink(path) || continue
            relative = replace(relpath(path, fixture_dir), '\\' => '/')
            push!(errors, "symlink fixture: $relative")
        end
        for name in files
            path = joinpath(directory, name)
            relative = replace(relpath(path, fixture_dir), '\\' => '/')
            if islink(path)
                push!(errors, "symlink fixture: $relative")
            elseif relative != manifest_name
                push!(fixture_files, relative)
            end
        end
    end

    sealed = Set(keys(entries))
    present = Set(fixture_files)
    for relative in sort!(collect(setdiff(sealed, present)))
        push!(errors, "missing fixture: $relative")
    end
    for relative in sort!(collect(setdiff(present, sealed)))
        push!(errors, "unlisted fixture: $relative")
    end
    for relative in sort!(collect(intersect(sealed, present)))
        path = _integrity_fixture_path(fixture_dir, relative)
        actual = bytes2hex(SHA.sha256(read(path)))
        actual == entries[relative] ||
            push!(errors, "fixture digest mismatch: $relative")
    end

    return sort!(unique(errors))
end

function _write_fixture_manifest(
    fixture_dir::AbstractString,
    relative_paths::AbstractVector{<:AbstractString},
)
    open(joinpath(fixture_dir, FIXTURE_MANIFEST), "w") do io
        for relative in relative_paths
            digest = bytes2hex(SHA.sha256(
                read(_integrity_fixture_path(fixture_dir, relative)),
            ))
            println(io, digest, "  ", relative)
        end
    end
end

@testset "Scientific fixture integrity" begin
    fixture_dir = joinpath(@__DIR__, "fixtures")
    @test isempty(_fixture_integrity_errors(fixture_dir))
end

@testset "Fixture seal rejects an open or unsafe tree" begin
    mktempdir() do fixture_dir
        write(joinpath(fixture_dir, "root.bin"), "root")
        mkpath(joinpath(fixture_dir, "nested"))
        write(joinpath(fixture_dir, "nested", "child.bin"), "child")
        _write_fixture_manifest(fixture_dir, ["root.bin", "nested/child.bin"])
        @test isempty(_fixture_integrity_errors(fixture_dir))

        write(joinpath(fixture_dir, "nested", "unlisted.bin"), "unlisted")
        @test "unlisted fixture: nested/unlisted.bin" in
              _fixture_integrity_errors(fixture_dir)

        write(joinpath(fixture_dir, "nested", "child.bin"), "changed")
        @test "fixture digest mismatch: nested/child.bin" in
              _fixture_integrity_errors(fixture_dir)
    end

    mktempdir() do fixture_dir
        write(joinpath(fixture_dir, "present.bin"), "present")
        open(joinpath(fixture_dir, FIXTURE_MANIFEST), "w") do io
            digest = bytes2hex(SHA.sha256("missing"))
            println(io, digest, "  missing.bin")
        end
        @test "missing fixture: missing.bin" in _fixture_integrity_errors(fixture_dir)
        @test "unlisted fixture: present.bin" in _fixture_integrity_errors(fixture_dir)
    end

    mktempdir() do fixture_dir
        write(joinpath(fixture_dir, "present.bin"), "present")
        digest = bytes2hex(SHA.sha256(read(joinpath(fixture_dir, "present.bin"))))
        open(joinpath(fixture_dir, FIXTURE_MANIFEST), "w") do io
            println(io, digest, "  present.bin")
            println(io, digest, "  present.bin")
            println(io, digest, "  ../escape.bin")
            println(io, digest, "  nested/../present.bin")
            println(io, digest, "  nested\\present.bin")
            println(io, digest, "  /absolute.bin")
        end
        errors = _fixture_integrity_errors(fixture_dir)
        @test any(error -> startswith(error, "duplicate fixture path"), errors)
        @test count(error -> startswith(error, "unsafe fixture path"), errors) == 4
    end

    if Sys.isunix()
        mktempdir() do fixture_dir
            write(joinpath(fixture_dir, "target.bin"), "target")
            mkpath(joinpath(fixture_dir, "target-dir"))
            write(joinpath(fixture_dir, "target-dir", "nested.bin"), "nested")
            symlink("target.bin", joinpath(fixture_dir, "alias.bin"))
            symlink("target-dir", joinpath(fixture_dir, "alias-dir"))
            _write_fixture_manifest(
                fixture_dir,
                ["target.bin", "target-dir/nested.bin"],
            )
            @test "symlink fixture: alias.bin" in
                  _fixture_integrity_errors(fixture_dir)
            @test "symlink fixture: alias-dir" in
                  _fixture_integrity_errors(fixture_dir)
        end

        mktempdir() do root
            fixture_dir = joinpath(root, "fixtures")
            mkpath(fixture_dir)
            outside_manifest = joinpath(root, "outside.sha256")
            write(outside_manifest, "")
            symlink(outside_manifest, joinpath(fixture_dir, FIXTURE_MANIFEST))
            @test _fixture_integrity_errors(fixture_dir) ==
                  ["symlink fixture manifest: $FIXTURE_MANIFEST"]
        end

        mktempdir() do root
            fixture_target = joinpath(root, "fixture-target")
            mkpath(fixture_target)
            write(joinpath(fixture_target, "sealed.bin"), "sealed")
            _write_fixture_manifest(fixture_target, ["sealed.bin"])
            fixture_link = joinpath(root, "fixtures")
            symlink(fixture_target, fixture_link)
            @test _fixture_integrity_errors(fixture_link) ==
                  ["symlink fixture root"]
        end
    end
end
