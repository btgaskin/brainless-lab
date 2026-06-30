module Store

using Dates
using JLD2
using TOML

export bench_dir,
    repo_root,
    genome_key,
    genome_dir,
    genome_tag,
    text_tag,
    save_genome_entry,
    load_genome_entry,
    copy_entry_to_cell,
    write_toml,
    git_sha,
    short_git,
    hostname,
    timestamp_utc

bench_dir() = normpath(joinpath(@__DIR__, ".."))
repo_root(bench::AbstractString=bench_dir()) = normpath(joinpath(bench, ".."))

genome_key(neuron::Symbol, task::Symbol) = "$(String(neuron))__$(String(task))"
genome_dir(bench::AbstractString, neuron::Symbol, task::Symbol) =
    joinpath(bench, "genomes", genome_key(neuron, task))

function _pad2(x)
    return lpad(string(Int(x)), 2, '0')
end

function timestamp_utc()
    t = Dates.now(Dates.UTC)
    return string(
        Dates.year(t),
        _pad2(Dates.month(t)),
        _pad2(Dates.day(t)),
        "T",
        _pad2(Dates.hour(t)),
        _pad2(Dates.minute(t)),
        _pad2(Dates.second(t)),
        "Z",
    )
end

function _fnv1a_bytes(bytes; n::Integer=12)
    h = UInt64(0xcbf29ce484222325)
    prime = UInt64(0x100000001b3)
    for b in bytes
        h = xor(h, UInt64(b))
        h *= prime
    end
    hex = string(h, base=16, pad=16)
    return hex[1:min(Int(n), lastindex(hex))]
end

function genome_tag(genome; n::Integer=12)
    vector = Vector{Float64}(Float64.(genome))
    return _fnv1a_bytes(reinterpret(UInt8, vector); n=n)
end

function text_tag(text::AbstractString; n::Integer=8)
    return _fnv1a_bytes(codeunits(text); n=n)
end

function write_toml(path::AbstractString, data::AbstractDict)
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, data)
    end
    return path
end

function save_genome_entry(bench::AbstractString, neuron::Symbol, task::Symbol, genome, manifest::AbstractDict)
    dir = genome_dir(bench, neuron, task)
    mkpath(dir)

    genome_vector = Vector{Float64}(Float64.(genome))
    genome_path = joinpath(dir, "genome.jld2")
    manifest_path = joinpath(dir, "train_manifest.toml")

    JLD2.jldsave(genome_path; genome=genome_vector)
    write_toml(manifest_path, manifest)

    return (
        dir=dir,
        genome_path=genome_path,
        manifest_path=manifest_path,
        genome=genome_vector,
        manifest=manifest,
        tag=String(get(manifest, "tag", genome_tag(genome_vector))),
    )
end

function load_genome_entry(bench::AbstractString, neuron::Symbol, task::Symbol)
    dir = genome_dir(bench, neuron, task)
    genome_path = joinpath(dir, "genome.jld2")
    manifest_path = joinpath(dir, "train_manifest.toml")
    isfile(genome_path) || return nothing

    genome = Vector{Float64}(Float64.(JLD2.load(genome_path, "genome")))
    manifest = isfile(manifest_path) ? TOML.parsefile(manifest_path) : Dict{String,Any}()
    tag = String(get(manifest, "tag", genome_tag(genome)))

    return (
        dir=dir,
        genome_path=genome_path,
        manifest_path=manifest_path,
        genome=genome,
        manifest=manifest,
        tag=tag,
    )
end

function copy_entry_to_cell(entry, cell_dir::AbstractString)
    entry === nothing && return nothing
    mkpath(cell_dir)
    cp(entry.genome_path, joinpath(cell_dir, "genome.jld2"); force=true)
    if isfile(entry.manifest_path)
        cp(entry.manifest_path, joinpath(cell_dir, "provenance.toml"); force=true)
    end
    return cell_dir
end

function git_sha(repo::AbstractString=repo_root())
    try
        return readchomp(`git -C $repo rev-parse HEAD`)
    catch
        return "unknown"
    end
end

function short_git(sha::AbstractString)
    sha == "unknown" && return "nogit"
    return sha[1:min(8, lastindex(sha))]
end

function hostname()
    try
        return readchomp(`hostname`)
    catch
        return get(ENV, "HOSTNAME", get(ENV, "COMPUTERNAME", "unknown"))
    end
end

end
