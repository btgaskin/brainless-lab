import Dates
import TOML

const MANIFEST_VERSION = "brainlesslab-v1"
const RESOLVED_CONFIG_FILENAME = "config.resolved.toml"

_repo_root() = abspath(joinpath(@__DIR__, "..", ".."))
resolved_config_filename() = RESOLVED_CONFIG_FILENAME

function _utc_timestamp()
    return Dates.format(Dates.now(Dates.UTC), "yyyy-mm-ddTHH:MM:SS.sss") * "Z"
end

function _git_sha(repo::AbstractString=_repo_root())
    try
        return readchomp(`git -C $repo rev-parse HEAD`)
    catch
        return "unknown"
    end
end

function _git_dirty(repo::AbstractString=_repo_root())
    _git_sha(repo) == "unknown" && return "unknown"
    try
        return !isempty(readchomp(`git -C $repo status --porcelain`))
    catch
        return "unknown"
    end
end

function _hostname()
    try
        return string(gethostname())
    catch
        return get(ENV, "HOSTNAME", get(ENV, "COMPUTERNAME", "unknown"))
    end
end

function _direct_package_versions()
    # Read versions from the project's Manifest.toml via TOML (avoids depending
    # on Pkg, which would break Pkg.test's sandbox).
    out = Dict{String,String}()
    try
        root = pkgdir(@__MODULE__)
        root === nothing && return out
        proj = TOML.parsefile(joinpath(root, "Project.toml"))
        direct = Set(keys(get(proj, "deps", Dict{String,Any}())))
        man_path = joinpath(root, "Manifest.toml")
        if isfile(man_path)
            man = TOML.parsefile(man_path)
            deps = get(man, "deps", Dict{String,Any}())
            for (name, entries) in deps
                name in direct || continue
                e = entries isa AbstractVector ? first(entries) : entries
                v = get(e, "version", nothing)
                out[name] = v === nothing ? "stdlib" : string(v)
            end
        end
    catch err
        out["error"] = sprint(showerror, err)
    end
    return out
end

function _fnv1a64_hex(bytes::Vector{UInt8})
    h = UInt64(0xcbf29ce484222325)
    prime = UInt64(0x00000100000001b3)
    for byte in bytes
        h = xor(h, UInt64(byte)) * prime
    end
    return string(h; base=16, pad=16)
end

function _manifest_toml_fnv1a()
    try
        root = pkgdir(@__MODULE__)
        root === nothing && return "unknown"
        man_path = joinpath(root, "Manifest.toml")
        isfile(man_path) || return "unknown"
        return _fnv1a64_hex(read(man_path))
    catch
        return "unknown"
    end
end

function _seed_scheme(cfg::RunConfig)
    resolved = resolve(cfg)
    train_preview = [
        resolved.run.seed_base + i
        for i in 0:(resolved.evolve.k_trials - 1)
    ]
    suite_preview = resolved.evolve.k_suite == 0 ? Int[] : [
        resolved.run.suite_seed_base + i
        for i in 0:(resolved.evolve.k_suite - 1)
    ]

    return Dict{String,Any}(
        "seed_base" => resolved.run.seed_base,
        "suite_seed_base" => resolved.run.suite_seed_base,
        "cma_seed" => resolved.evolve.cma_seed,
        "scheme" => "train_seed = seed_base + generation * 10007 + trial_index; suite_seed = suite_seed_base + trial_index; cma_seed seeds SepCMA",
        "train_preview_generation0" => train_preview,
        "suite_preview" => suite_preview,
    )
end

function _manifest_config(cfg::RunConfig)
    return Dict{String,Any}(
        "run" => Dict{String,Any}(
            "name" => cfg.run.name,
            "runner" => string(cfg.run.runner),
            "seed_base" => cfg.run.seed_base,
            "suite_seed_base" => cfg.run.suite_seed_base,
            "profile" => string(cfg.run.profile),
        ),
        "model" => Dict{String,Any}(
            "family" => string(cfg.model.family),
            "node" => string(cfg.model.node),
        ),
        "task" => Dict{String,Any}(
            "train" => [string(t) for t in cfg.task.train],
            "suite" => [string(t) for t in cfg.task.suite],
            "aggregator" => string(cfg.task.aggregator),
            "R" => cfg.task.R,
            "E" => cfg.task.E,
            "N" => cfg.task.N,
            "ticks" => cfg.task.ticks,
            "window" => cfg.task.window,
            "link_p" => cfg.task.link_p,
            "rho" => cfg.task.rho,
            "lam" => cfg.task.lam,
        ),
        "evolve" => Dict{String,Any}(
            "generations" => cfg.evolve.generations,
            "popsize" => cfg.evolve.popsize,
            "sigma0" => cfg.evolve.sigma0,
            "k_trials" => cfg.evolve.k_trials,
            "suite_every" => cfg.evolve.suite_every,
            "k_suite" => cfg.evolve.k_suite,
            "cma_seed" => cfg.evolve.cma_seed,
            "threaded" => cfg.evolve.threaded,
        ),
    )
end

function _manifest_header(tool; timestamp_utc=_utc_timestamp(), repo::AbstractString=_repo_root())
    return Dict{String,Any}(
        "manifest_version" => MANIFEST_VERSION,
        "tool" => string(Symbol(tool)),
        "timestamp_utc" => timestamp_utc,
        "repo_path" => repo,
        "git_sha" => _git_sha(repo),
        "git_dirty" => _git_dirty(repo),
        "julia_version" => string(VERSION),
        "hostname" => _hostname(),
        "threads" => Threads.nthreads(),
        "packages" => _direct_package_versions(),
    )
end

function capture_manifest(cfg::RunConfig; seeds=nothing, tool=:run)
    resolved = resolve(cfg)
    repo = _repo_root()
    seed_info = seeds === nothing ? _seed_scheme(resolved) : seeds
    manifest_sha = _manifest_toml_fnv1a()

    manifest = _manifest_header(tool; repo=repo)
    manifest["manifest_sha"] = manifest_sha
    manifest["manifest_toml_fnv1a"] = manifest_sha
    manifest["seeds"] = seed_info
    manifest["config"] = _manifest_config(resolved)
    return manifest
end
