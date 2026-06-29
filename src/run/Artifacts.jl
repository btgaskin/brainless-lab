import Dates
import JLD2
import Random
import TOML

function _path_timestamp()
    return Dates.format(Dates.now(Dates.UTC), "yyyymmddTHHMMSSsss") * "Z"
end

function _sanitize_path_part(value)
    s = string(value)
    return replace(s, r"[^A-Za-z0-9_.+-]" => "_")
end

function _short_git()
    sha = _git_sha(_repo_root())
    sha == "unknown" && return "nogit"
    return sha[1:min(lastindex(sha), 7)]
end

function run_dir(cfg::RunConfig; root::AbstractString=joinpath(_repo_root(), "runs"))
    resolved = resolve(cfg)
    task_id = _sanitize_path_part(join((string(t) for t in resolved.task.train), "+"))
    driver_id = _sanitize_path_part(resolved.run.driver)
    runid = string(Random.rand(UInt32), base=16, pad=8)
    dir = joinpath(
        root,
        task_id,
        driver_id,
        "$(_path_timestamp())_$(_short_git())_$runid",
    )
    mkpath(dir)
    return dir
end

_hasprop(x, name::Symbol) = name in propertynames(x)
_getprop(x, name::Symbol, default=nothing) = _hasprop(x, name) ? getproperty(x, name) : default

function _json_escape(s::AbstractString)
    return replace(
        String(s),
        "\\" => "\\\\",
        "\"" => "\\\"",
        "\n" => "\\n",
        "\r" => "\\r",
        "\t" => "\\t",
    )
end

function _json_write(io, value)
    if value === nothing || value === missing
        print(io, "null")
    elseif value isa Bool
        print(io, value ? "true" : "false")
    elseif value isa Integer
        print(io, value)
    elseif value isa AbstractFloat
        isfinite(value) ? print(io, repr(Float64(value))) : print(io, "null")
    elseif value isa Symbol
        print(io, "\"", _json_escape(string(value)), "\"")
    elseif value isa AbstractString
        print(io, "\"", _json_escape(value), "\"")
    elseif value isa NamedTuple
        _json_write_object(io, [(string(k), getproperty(value, k)) for k in propertynames(value)])
    elseif value isa AbstractDict
        entries = sort([(string(k), v) for (k, v) in value], by=first)
        _json_write_object(io, entries)
    elseif value isa Tuple || value isa AbstractVector
        print(io, "[")
        first_item = true
        for item in value
            first_item || print(io, ",")
            _json_write(io, item)
            first_item = false
        end
        print(io, "]")
    elseif value isa AbstractArray
        _json_write(io, collect(value))
    else
        print(io, "\"", _json_escape(string(value)), "\"")
    end
    return nothing
end

function _json_write_object(io, entries)
    print(io, "{")
    first_item = true
    for (key, value) in entries
        first_item || print(io, ",")
        print(io, "\"", _json_escape(key), "\":")
        _json_write(io, value)
        first_item = false
    end
    print(io, "}")
    return nothing
end

function _write_json_file(path::AbstractString, value)
    open(path, "w") do io
        _json_write(io, value)
        println(io)
    end
    return path
end

function _csv_cell(value)
    value === nothing && return ""
    s = value isa AbstractFloat ? repr(Float64(value)) : string(value)
    if occursin(",", s) || occursin("\"", s) || occursin("\n", s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

function _write_evolve_log(path::AbstractString, result)
    open(path, "w") do io
        println(io, "generation,fitness_best,fitness_median,fitness_mean")
        _hasprop(result, :history) || return nothing
        h = result.history
        for i in eachindex(h.generation)
            println(
                io,
                join(
                    (
                        _csv_cell(h.generation[i]),
                        _csv_cell(h.fitness_best[i]),
                        _csv_cell(h.fitness_median[i]),
                        _csv_cell(h.fitness_mean[i]),
                    ),
                    ",",
                ),
            )
        end
    end
    return path
end

function _suite_seed_tuple(cfg::RunConfig)
    count = cfg.evolve.k_suite > 0 ? cfg.evolve.k_suite : cfg.evolve.k_trials
    return Tuple(cfg.run.suite_seed_base + i for i in 0:(count - 1))
end

function _last_generation(result)
    _hasprop(result, :history) || return missing
    generations = result.history.generation
    isempty(generations) && return missing
    return generations[end]
end

function _write_suite_log(path::AbstractString, result, cfg::RunConfig)
    open(path, "w") do io
        cfg.evolve.suite_every > 0 || return nothing
        _hasprop(result, :best) || return nothing
        generation = _last_generation(result)
        for task in cfg.task.suite, seed in _suite_seed_tuple(cfg)
            out = rollout(
                task,
                result.best,
                seed;
                model_sym=cfg.model.node,
                N=cfg.task.N,
                ticks=cfg.task.ticks,
                link_p=cfg.task.link_p,
                rho=cfg.task.rho,
                window=cfg.task.window,
                lam=cfg.task.lam,
            )
            row = Dict{String,Any}(
                "generation" => generation,
                "task" => string(out.task),
                "seed" => Int(seed),
                "score" => out.score,
                "norm_score" => out.norm_score,
                "alive" => out.alive,
            )
            _json_write(io, row)
            println(io)
        end
    end
    return path
end

function _save_best_jld2(path::AbstractString, result, cfg::RunConfig)
    best = _getprop(result, :best, nothing)
    best_raw = _getprop(result, :best_raw, best)
    best_fitness = _getprop(result, :best_fitness, nothing)
    result_config = _getprop(result, :config, nothing)
    JLD2.jldsave(
        path;
        best=best,
        best_raw=best_raw,
        best_fitness=best_fitness,
        result_config=result_config,
        model_sym=cfg.model.node,
        train_tasks=cfg.task.train,
    )
    return path
end

function _final_metrics(result, cfg::RunConfig)
    out = Dict{String,Any}(
        "run_name" => cfg.run.name,
        "driver" => string(cfg.run.driver),
    )

    if _hasprop(result, :best_fitness)
        out["best_fitness"] = result.best_fitness
        out["best_score"] = _getprop(result, :best_score, result.best_fitness)
        out["last_fitness_best"] = _getprop(result, :last_fitness_best, nothing)
        if _hasprop(result, :history)
            out["generations"] = length(result.history.generation)
        end
    elseif _hasprop(result, :summary)
        out["summary"] = result.summary
    else
        out["result_type"] = string(typeof(result))
    end

    return out
end

function save_run(result, cfg::RunConfig, dir::AbstractString; manifest=nothing, seeds=nothing)
    resolved = resolve(cfg)
    seed_info = seeds === nothing ? _seed_scheme(resolved) : seeds
    manifest_info = manifest === nothing ? capture_manifest(resolved; seeds=seed_info) : manifest

    mkpath(dir)
    mkpath(joinpath(dir, "logs"))
    mkpath(joinpath(dir, "genomes"))
    mkpath(joinpath(dir, "metrics"))

    write_config(resolved, joinpath(dir, "config.resolved.toml"))
    open(joinpath(dir, "manifest.toml"), "w") do io
        TOML.print(io, manifest_info)
    end
    _write_json_file(joinpath(dir, "seeds.json"), seed_info)
    _write_evolve_log(joinpath(dir, "logs", "evolve_log.csv"), result)
    _write_suite_log(joinpath(dir, "logs", "suite_log.jsonl"), result, resolved)
    _save_best_jld2(joinpath(dir, "genomes", "best.jld2"), result, resolved)
    _write_json_file(joinpath(dir, "metrics", "final.json"), _final_metrics(result, resolved))
    return dir
end

function _default_model_for_run(cfg::RunConfig)
    return _default_x0(
        cfg.model.node,
        cfg.task.N;
        ticks=cfg.task.ticks,
        link_p=cfg.task.link_p,
        rho=cfg.task.rho,
        window=cfg.task.window,
    )
end

function _run_evolve_config(cfg::RunConfig)
    return evolve(
        model_sym=cfg.model.node,
        train_tasks=cfg.task.train,
        generations=cfg.evolve.generations,
        popsize=cfg.evolve.popsize,
        k_trials=cfg.evolve.k_trials,
        aggregator=cfg.task.aggregator,
        N=cfg.task.N,
        ticks=cfg.task.ticks,
        sigma0=cfg.evolve.sigma0,
        seed=cfg.evolve.cma_seed,
        wiring_seed_base=cfg.run.seed_base,
        link_p=cfg.task.link_p,
        rho=cfg.task.rho,
        window=cfg.task.window,
        lam=cfg.task.lam,
        threaded=cfg.evolve.threaded,
    )
end

function _run_fixed_config(cfg::RunConfig)
    driver = FixedDriver(
        model_sym=cfg.model.node,
        model=_default_model_for_run(cfg),
        tasks=cfg.task.suite,
        seeds=_suite_seed_tuple(cfg),
        N=cfg.task.N,
        ticks=cfg.task.ticks,
        link_p=cfg.task.link_p,
        rho=cfg.task.rho,
        window=cfg.task.window,
        lam=cfg.task.lam,
    )
    return evaluate(driver)
end

function _run_plastic_config(cfg::RunConfig)
    driver = PlasticDriver(
        model_sym=cfg.model.node,
        model=_default_model_for_run(cfg),
        tasks=cfg.task.suite,
        seeds=_suite_seed_tuple(cfg),
        N=cfg.task.N,
        ticks=cfg.task.ticks,
        link_p=cfg.task.link_p,
        window=cfg.task.window,
        lam=cfg.task.lam,
    )
    return evaluate(driver)
end

function run_experiment(cfg::RunConfig; dir=nothing)
    resolved = resolve(cfg)
    seed_info = _seed_scheme(resolved)
    manifest_info = capture_manifest(resolved; seeds=seed_info)

    result =
        resolved.run.driver == :evolve ? _run_evolve_config(resolved) :
        resolved.run.driver == :fixed ? _run_fixed_config(resolved) :
        resolved.run.driver == :plastic ? _run_plastic_config(resolved) :
        throw(ArgumentError("unsupported run driver :$(resolved.run.driver)"))

    out_dir = dir === nothing ? run_dir(resolved) : String(dir)
    mkpath(out_dir)
    save_run(result, resolved, out_dir; manifest=manifest_info, seeds=seed_info)
    return (result=result, dir=out_dir, config=resolved, manifest=manifest_info, seeds=seed_info)
end

run_from_config(path::AbstractString; kwargs...) = run_experiment(read_config(path); kwargs...)
