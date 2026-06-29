import TOML

function _axis_table(data)
    if haskey(data, "axes")
        return data["axes"]
    end
    if haskey(data, "sweep") && data["sweep"] isa AbstractDict && haskey(data["sweep"], "axes")
        return data["sweep"]["axes"]
    end
    return Dict{String,Any}()
end

function _sweep_id(path::AbstractString, data)
    if haskey(data, "sweep") && data["sweep"] isa AbstractDict && haskey(data["sweep"], "id")
        return _sanitize_path_part(data["sweep"]["id"])
    end
    return _sanitize_path_part(splitext(basename(path))[1])
end

function _base_config_for_sweep(path::AbstractString, data)
    if haskey(data, "sweep") && data["sweep"] isa AbstractDict && haskey(data["sweep"], "base_config")
        base = string(data["sweep"]["base_config"])
        base_path = isabspath(base) ? base : joinpath(dirname(path), base)
        return read_config(base_path)
    end
    return _config_from_dict(data)
end

function _axis_values(value)
    if value isa AbstractVector || value isa Tuple
        return collect(value)
    end
    return Any[value]
end

function _axis_products(axis_names, axis_values)
    rows = [Dict{String,Any}()]
    for (name, values) in zip(axis_names, axis_values)
        next_rows = Dict{String,Any}[]
        for row in rows, value in values
            updated = copy(row)
            updated[string(name)] = value
            push!(next_rows, updated)
        end
        rows = next_rows
    end
    return rows
end

function _coerce_section_field(::Type{RunSection}, field::Symbol, value)
    field === :name && return string(value)
    field in (:driver, :profile) && return Symbol(value)
    field in (:seed_base, :suite_seed_base) && return Int(value)
    throw(KeyError(field))
end

function _coerce_section_field(::Type{ModelSection}, field::Symbol, value)
    field in (:family, :node) && return Symbol(value)
    throw(KeyError(field))
end

function _coerce_section_field(::Type{TaskSection}, field::Symbol, value)
    field in (:train, :suite) && return _symbols_tuple(value)
    field === :aggregator && return Symbol(value)
    field in (:R, :E, :N, :ticks, :window) && return value === nothing ? nothing : Int(value)
    field in (:link_p, :rho, :lam) && return Float64(value)
    throw(KeyError(field))
end

function _coerce_section_field(::Type{EvolveSection}, field::Symbol, value)
    field in (:generations, :popsize, :k_trials, :suite_every, :k_suite, :cma_seed) && return Int(value)
    field === :sigma0 && return Float64(value)
    field === :threaded && return Bool(value)
    throw(KeyError(field))
end

function _replace_section(section, field::Symbol, value)
    T = typeof(section)
    field in fieldnames(T) || throw(KeyError(field))
    names = fieldnames(T)
    values = map(names) do name
        name === field ? _coerce_section_field(T, field, value) : getfield(section, name)
    end
    return T(values...)
end

function _with_section(cfg::RunConfig, section::Symbol, field::Symbol, value)
    section === :run && return RunConfig(
        run=_replace_section(cfg.run, field, value),
        model=cfg.model,
        task=cfg.task,
        evolve=cfg.evolve,
    )
    section === :model && return RunConfig(
        run=cfg.run,
        model=_replace_section(cfg.model, field, value),
        task=cfg.task,
        evolve=cfg.evolve,
    )
    section === :task && return RunConfig(
        run=cfg.run,
        model=cfg.model,
        task=_replace_section(cfg.task, field, value),
        evolve=cfg.evolve,
    )
    section === :evolve && return RunConfig(
        run=cfg.run,
        model=cfg.model,
        task=cfg.task,
        evolve=_replace_section(cfg.evolve, field, value),
    )
    throw(KeyError(section))
end

function _set_config_param(cfg::RunConfig, key::AbstractString, value)
    if key == "seed"
        seeded = _with_section(cfg, :run, :seed_base, value)
        seeded = _with_section(seeded, :run, :suite_seed_base, Int(value) + 100_000)
        return _with_section(seeded, :evolve, :cma_seed, value)
    end

    parts = split(key, ".")
    if length(parts) == 2
        return _with_section(cfg, Symbol(parts[1]), Symbol(parts[2]), value)
    end

    field = Symbol(key)
    field in fieldnames(RunSection) && return _with_section(cfg, :run, field, value)
    field in fieldnames(ModelSection) && return _with_section(cfg, :model, field, value)
    field in fieldnames(TaskSection) && return _with_section(cfg, :task, field, value)
    field in fieldnames(EvolveSection) && return _with_section(cfg, :evolve, field, value)

    throw(ArgumentError("unknown sweep axis '$key'"))
end

function _apply_sweep_params(cfg::RunConfig, params::AbstractDict)
    out = cfg
    for key in sort(collect(keys(params)); by=string)
        out = _set_config_param(out, string(key), params[key])
    end
    return resolve(out)
end

function _write_sweep_index(path::AbstractString, rows, axis_names)
    open(path, "w") do io
        println(io, join(vcat(["cell"], string.(axis_names), ["result_path", "best_fitness"]), ","))
        for row in rows
            fields = Any[row["cell"]]
            append!(fields, [row["params"][string(name)] for name in axis_names])
            push!(fields, row["result_path"])
            push!(fields, row["best_fitness"])
            println(io, join((_csv_cell(field) for field in fields), ","))
        end
    end
    return path
end

function run_sweep(sweep_toml::AbstractString; root=nothing)
    data = TOML.parsefile(sweep_toml)
    axes = _axis_table(data)
    isempty(axes) && throw(ArgumentError("sweep TOML must define [axes] or [sweep.axes]"))

    axis_names = sort(collect(keys(axes)); by=string)
    axis_values = [_axis_values(axes[name]) for name in axis_names]
    cells = _axis_products(axis_names, axis_values)

    id = _sweep_id(sweep_toml, data)
    sweep_root = root === nothing ? joinpath(_repo_root(), "sweeps", id) : joinpath(String(root), id)
    mkpath(sweep_root)

    base_cfg = _base_config_for_sweep(sweep_toml, data)
    rows = Dict{String,Any}[]

    for (idx, params) in enumerate(cells)
        cell_id = "cell_" * lpad(string(idx), 3, "0")
        cell_dir = joinpath(sweep_root, cell_id)
        cfg = _apply_sweep_params(base_cfg, params)
        run = run_experiment(cfg; dir=cell_dir)
        push!(
            rows,
            Dict{String,Any}(
                "cell" => cell_id,
                "params" => params,
                "result_path" => run.dir,
                "best_fitness" => _getprop(run.result, :best_fitness, missing),
            ),
        )
    end

    index_path = joinpath(sweep_root, "index.csv")
    _write_sweep_index(index_path, rows, axis_names)
    return (id=id, dir=sweep_root, index=index_path, cells=rows)
end
