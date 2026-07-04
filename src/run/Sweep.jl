import TOML

const _SWEEP_MODES = Set{String}(("one_at_a_time", "factorial"))
const _SWEEP_DEFAULT_MEASURES = ("sigma_mr", "spectral_radius", "liveness")
const _SWEEP_NUMERIC_MEASURES = Set{String}(("score", "raw_score", "sigma_mr", "spectral_radius", "liveness"))
const _SWEEP_SWARM_TASKS = Set{Symbol}((:torus, :swarm, :forage))
const _SWEEP_GIF_1X1 = UInt8[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00,
    0x00, 0xfb, 0xfa, 0xf7, 0x2f, 0x6f, 0x5e, 0x21, 0xf9, 0x04, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
    0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
]
const _SWEEP_PNG_1X1 = UInt8[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02, 0x00, 0x00, 0x00,
    0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
    0x03, 0x03, 0x02, 0x00, 0xef, 0xbf, 0xa7, 0xdb, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]

Base.@kwdef struct SweepBaseline
    node::Symbol = :falandays_base
    task::Symbol = :wall
    N::Union{Nothing,Int} = nothing
    ticks::Union{Nothing,Int} = nothing
    window::Union{Nothing,Int} = nothing
    seed_base::Int = 0
    n_agents::Union{Nothing,Int} = nothing
    body::Union{Nothing,Symbol} = nothing
    drive::Union{Nothing,Symbol} = nothing
    ablation::Symbol = :none
    node_kwargs::Dict{Symbol,Any} = Dict{Symbol,Any}()
    env_kwargs::Dict{Symbol,Any} = Dict{Symbol,Any}()
    drive_kwargs::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

Base.@kwdef struct SweepAxisInfo
    path::String
    default::Any = nothing
    range::String = ""
    description::String = ""
end

function _axis_table(data)
    if haskey(data, "axes")
        return data["axes"]
    end
    if haskey(data, "sweep") && data["sweep"] isa AbstractDict && haskey(data["sweep"], "axes")
        return data["sweep"]["axes"]
    end
    return Dict{String,Any}()
end

function _sweep_section(data)
    return haskey(data, "sweep") && data["sweep"] isa AbstractDict ? data["sweep"] : Dict{String,Any}()
end

function _sweep_id(path::AbstractString, data)
    sweep = _sweep_section(data)
    if haskey(sweep, "id")
        return _sanitize_path_part(sweep["id"])
    end
    return _sanitize_path_part(splitext(basename(path))[1])
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

function _as_optional_sweep_int(value)
    value === nothing && return nothing
    return Int(value)
end

_as_sweep_symbol(value) = Symbol(value)

function _copy_sweep_baseline(base::SweepBaseline)
    return SweepBaseline(
        node=base.node,
        task=base.task,
        N=base.N,
        ticks=base.ticks,
        window=base.window,
        seed_base=base.seed_base,
        n_agents=base.n_agents,
        body=base.body,
        drive=base.drive,
        ablation=base.ablation,
        node_kwargs=copy(base.node_kwargs),
        env_kwargs=copy(base.env_kwargs),
        drive_kwargs=copy(base.drive_kwargs),
    )
end

function _baseline_from_run_config(cfg::RunConfig)
    resolved = resolve(cfg)
    node_kwargs = Dict{Symbol,Any}(:link_p => resolved.task.link_p)
    _is_compartmental_node(resolved.model.node) && (node_kwargs[:rho] = resolved.task.rho)
    return SweepBaseline(
        node=resolved.model.node,
        task=first(resolved.task.train),
        N=resolved.task.N,
        ticks=resolved.task.ticks,
        window=resolved.task.window,
        seed_base=resolved.run.seed_base,
        node_kwargs=node_kwargs,
        env_kwargs=Dict{Symbol,Any}(:lam => resolved.task.lam),
    )
end

function _base_config_for_sweep(path::AbstractString, data)
    sweep = _sweep_section(data)
    if haskey(sweep, "base_config")
        base = string(sweep["base_config"])
        base_path = isabspath(base) ? base : joinpath(dirname(path), base)
        return read_config(base_path)
    end
    return _config_from_dict(data)
end

function _baseline_from_dict(path::AbstractString, data)
    if !haskey(data, "baseline")
        return _resolve_sweep_baseline(_baseline_from_run_config(_base_config_for_sweep(path, data)))
    end

    table = data["baseline"]
    table isa AbstractDict || throw(ArgumentError("[baseline] must be a TOML table"))
    node = _as_sweep_symbol(_get(table, "node", "falandays_base"))
    task = _as_sweep_symbol(_get(table, "task", "wall"))
    base = SweepBaseline(
        node=_canonical_model_sym(node),
        task=task,
        N=_as_optional_sweep_int(_get(table, "N", _get(table, "n_nodes", nothing))),
        ticks=_as_optional_sweep_int(_get(table, "ticks", nothing)),
        window=_as_optional_sweep_int(_get(table, "window", nothing)),
        seed_base=Int(_get(table, "seed_base", _get(table, "seed", 0))),
        n_agents=_as_optional_sweep_int(_get(table, "n_agents", nothing)),
        body=_get(table, "body", nothing) === nothing ? nothing : _as_sweep_symbol(_get(table, "body", nothing)),
        drive=_get(table, "drive", nothing) === nothing ? nothing : _as_sweep_symbol(_get(table, "drive", nothing)),
    )

    for (key, value) in table
        key_s = string(key)
        if occursin(".", key_s) || key_s == "ablation"
            base = _apply_axis_value(base, key_s, value)
        end
    end

    return _resolve_sweep_baseline(base)
end

function _resolve_sweep_baseline(base::SweepBaseline)
    resolve_node(base.node)
    task_obj = resolve_task(base.task)
    is_swarm = base.task in _SWEEP_SWARM_TASKS || base.n_agents !== nothing

    if task_obj isa TaskSpec
        ticks = base.ticks === nothing ? task_obj.default_ticks : base.ticks
        window = base.window === nothing ? min(ticks, task_obj.default_window) : base.window
        N = base.N === nothing ? _default_node_count(base.node) : base.N
        return SweepBaseline(
            node=base.node,
            task=task_obj.name,
            N=N,
            ticks=ticks,
            window=window,
            seed_base=base.seed_base,
            n_agents=base.n_agents,
            body=base.body,
            drive=base.drive,
            ablation=base.ablation,
            node_kwargs=copy(base.node_kwargs),
            env_kwargs=copy(base.env_kwargs),
            drive_kwargs=copy(base.drive_kwargs),
        )
    end

    is_swarm || throw(ArgumentError("task :$(base.task) is not a TaskSpec and is not a known swarm task"))
    ticks = base.ticks === nothing ? 1000 : base.ticks
    window = base.window === nothing ? ticks : base.window
    N = base.N === nothing ? _default_node_count(base.node) : base.N
    n_agents = base.n_agents === nothing ? 8 : base.n_agents
    return SweepBaseline(
        node=base.node,
        task=base.task == :swarm ? :torus : base.task,
        N=N,
        ticks=ticks,
        window=window,
        seed_base=base.seed_base,
        n_agents=n_agents,
        body=base.body,
        drive=base.drive,
        ablation=base.ablation,
        node_kwargs=copy(base.node_kwargs),
        env_kwargs=copy(base.env_kwargs),
        drive_kwargs=copy(base.drive_kwargs),
    )
end

function _sweep_mode(data)
    mode = string(get(_sweep_section(data), "mode", "one_at_a_time"))
    mode in _SWEEP_MODES ||
        throw(ArgumentError("sweep.mode must be one_at_a_time or factorial, got $(repr(mode))"))
    return mode
end

function _sweep_max_cells(data)
    return Int(get(_sweep_section(data), "max_cells", 200))
end

function _sweep_force(data, force)
    force && return true
    value = get(_sweep_section(data), "force", false)
    return Bool(value)
end

function _sweep_seeds(data)
    raw = get(_sweep_section(data), "seeds", [0])
    return Int.(collect(raw))
end

function _analytics_measures(data)
    analytics = haskey(data, "analytics") && data["analytics"] isa AbstractDict ? data["analytics"] : Dict{String,Any}()
    raw = get(analytics, "measures", collect(_SWEEP_DEFAULT_MEASURES))
    return string.(collect(raw))
end

function _is_swarm_sweep(base::SweepBaseline)
    return base.task in (:torus, :swarm, :forage) || base.n_agents !== nothing
end

function _try_param_default(node::Symbol, key::Symbol)
    if _is_falandays_node(node) && key in fieldnames(FalandaysParams)
        return getfield(FalandaysParams(), key)
    end
    return nothing
end

function sweepable_axes(node=:falandays_base, task=:wall)
    node_sym = _canonical_model_sym(Symbol(node))
    task_sym = Symbol(task)
    out = SweepAxisInfo[]

    if _is_falandays_node(node_sym)
        params = FalandaysParams()
        push!(out, SweepAxisInfo(path="node.leak", default=params.leak, range="0.0..1.0", description="Falandays activation leak"))
        push!(out, SweepAxisInfo(path="node.lrate_wmat", default=params.lrate_wmat, range=">= 0", description="Falandays recurrent weight learning rate"))
        push!(out, SweepAxisInfo(path="node.lrate_targ", default=params.lrate_targ, range=">= 0", description="Falandays target-homeostasis learning rate"))
        push!(out, SweepAxisInfo(path="node.threshold_mult", default=params.threshold_mult, range="> 0", description="Falandays target-to-threshold multiplier"))
        push!(out, SweepAxisInfo(path="node.targ_min", default=params.targ_min, range="> 0", description="Falandays minimum target set-point"))
        push!(out, SweepAxisInfo(path="node.input_weight", default=params.input_weight, range=">= 0", description="Falandays input synapse scale"))
        push!(out, SweepAxisInfo(path="node.weight_init_std", default=params.weight_init_std, range=">= 0", description="Falandays recurrent initialization scale"))
        push!(out, SweepAxisInfo(path="node.learn_on", default=params.learn_on, range="true|false", description="Falandays online plasticity switch"))
        push!(out, SweepAxisInfo(path="node.link_p", default=0.1, range="0.0..1.0", description="random recurrent/input/output graph density"))
    elseif _is_compartmental_node(node_sym)
        push!(out, SweepAxisInfo(path="node.raw_scale", default=0.25, range=">= 0", description="random compartmental genome scale"))
        push!(out, SweepAxisInfo(path="node.link_p", default=0.1, range="0.0..1.0", description="compartmental recurrent graph density"))
        push!(out, SweepAxisInfo(path="node.rho", default=0.2, range="0.0..1.0", description="compartmental input/recurrent balance"))
        push!(out, SweepAxisInfo(path="node.k_rec", default=nothing, range="integer", description="explicit compartmental recurrent in-degree"))
        push!(out, SweepAxisInfo(path="node.k_in", default=nothing, range="integer", description="explicit compartmental input in-degree"))
        push!(out, SweepAxisInfo(path="node.state_scale", default=0.05, range=">= 0", description="random initial compartmental state scale"))
        push!(out, SweepAxisInfo(path="node.dt", default=1.0, range="> 0", description="compartmental integration step"))
        push!(out, SweepAxisInfo(path="node.hill_tau", default=HILL_TAU, range="> 0", description="hillock recovery time constant"))
        push!(out, SweepAxisInfo(path="node.hill_reset", default=HILL_RESET, range="real", description="post-spike hillock reset"))
    else
        push!(out, SweepAxisInfo(path="node.n_nodes", default=_default_node_count(node_sym), range="integer", description="reservoir size alias"))
        push!(out, SweepAxisInfo(path="node.learn_on", default=nothing, range="true|false", description="online plasticity switch when the node supports it"))
    end

    push!(out, SweepAxisInfo(path="drive.noise_gain", default=0.0, range=">= 0", description="Oosawa target-deficit membrane noise gain"))
    push!(out, SweepAxisInfo(path="drive.membrane_noise", default=0.0, range=">= 0", description="Oosawa constant membrane noise floor"))

    push!(out, SweepAxisInfo(path="task.N", default=_default_node_count(node_sym), range="integer", description="reservoir node count"))
    push!(out, SweepAxisInfo(path="task.ticks", default=nothing, range="integer", description="rollout duration"))
    push!(out, SweepAxisInfo(path="task.window", default=nothing, range="integer", description="metric/liveness window"))
    push!(out, SweepAxisInfo(path="seed", default=0, range="integer", description="seed base added to sweep.seeds offsets"))

    if task_sym in _SWEEP_SWARM_TASKS
        cfg = SwarmConfig(n_agents=8)
        push!(out, SweepAxisInfo(path="env.n_agents", default=cfg.n_agents, range="integer", description="swarm population size"))
        push!(out, SweepAxisInfo(path="env.space_size", default=cfg.space_size, range="> 0", description="torus side length"))
        push!(out, SweepAxisInfo(path="env.vision_range", default=cfg.vision_range, range="nothing or > 0", description="maximum conspecific/source vision distance"))
        push!(out, SweepAxisInfo(path="env.sensory_noise", default=cfg.sensory_noise, range=">= 0", description="bearing sensor noise"))
        push!(out, SweepAxisInfo(path="env.source_gain", default=cfg.source_gain, range=">= 0", description="forage source bank gain"))
        push!(out, SweepAxisInfo(path="env.capture_radius", default=cfg.capture_radius, range=">= 0", description="forage capture radius"))
        push!(out, SweepAxisInfo(path="env.conspecific_vision", default=cfg.conspecific_vision, range="true|false", description="whether agents see each other"))
    else
        push!(out, SweepAxisInfo(path="env.lam", default=1.0, range="> 0", description="wall/task environment parameter when supported"))
    end

    values = join(vcat(["none"], string.(ablations())), " | ")
    push!(out, SweepAxisInfo(path="ablation", default="none", range=values, description="registered perturbation symbol"))
    return out
end

function _known_axis_paths(node::Symbol, task::Symbol)
    return sort!([axis.path for axis in sweepable_axes(node, task)])
end

function _edit_distance(a::AbstractString, b::AbstractString)
    m = lastindex(a)
    n = lastindex(b)
    prev = collect(0:n)
    curr = zeros(Int, n + 1)
    for i in 1:m
        curr[1] = i
        for j in 1:n
            cost = a[i] == b[j] ? 0 : 1
            curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost)
        end
        prev, curr = curr, prev
    end
    return prev[n + 1]
end

function _suggest_name(name::AbstractString, known)
    isempty(known) && return nothing
    scored = sort([(String(k), _edit_distance(String(name), String(k))) for k in known], by=last)
    best = first(scored)
    return best[2] <= max(3, ceil(Int, length(name) / 3)) ? best[1] : nothing
end

function _unknown_axis_error(axis::AbstractString, base::SweepBaseline)
    known = _known_axis_paths(base.node, base.task)
    suggestion = _suggest_name(axis, known)
    known_msg = join(known, ", ")
    if suggestion === nothing
        return ArgumentError("unknown axis '$(axis)' (known: $(known_msg))")
    end
    return ArgumentError("unknown axis '$(axis)' -- did you mean '$(suggestion)'? (known: $(known_msg))")
end

function _validate_ablation_value(value)
    sym = Symbol(value)
    sym === :none && return :none
    if !(sym in ablations())
        known = vcat([:none], ablations())
        suggestion = _suggest_name(string(sym), string.(known))
        msg = suggestion === nothing ?
            "unknown ablation '$(sym)' (known: $(join(string.(known), ", ")))" :
            "unknown ablation '$(sym)' -- did you mean '$(suggestion)'? (known: $(join(string.(known), ", ")))"
        throw(ArgumentError(msg))
    end
    return sym
end

function _validate_axis!(base::SweepBaseline, axis::AbstractString, values)
    axis in _known_axis_paths(base.node, base.task) || throw(_unknown_axis_error(axis, base))
    if axis == "ablation"
        for value in values
            _validate_ablation_value(value)
        end
    end
    return nothing
end

function _coerce_axis_value(path::AbstractString, value)
    value isa AbstractString && lowercase(String(value)) == "nothing" && return nothing
    value isa AbstractString && lowercase(String(value)) == "none" && path != "ablation" && return nothing
    return value
end

function _apply_axis_value(base::SweepBaseline, path::AbstractString, value)
    out = _copy_sweep_baseline(base)
    value = _coerce_axis_value(path, value)

    if path == "ablation"
        return SweepBaseline(
            node=out.node,
            task=out.task,
            N=out.N,
            ticks=out.ticks,
            window=out.window,
            seed_base=out.seed_base,
            n_agents=out.n_agents,
            body=out.body,
            drive=out.drive,
            ablation=_validate_ablation_value(value),
            node_kwargs=out.node_kwargs,
            env_kwargs=out.env_kwargs,
            drive_kwargs=out.drive_kwargs,
        )
    elseif path == "seed"
        return SweepBaseline(
            node=out.node,
            task=out.task,
            N=out.N,
            ticks=out.ticks,
            window=out.window,
            seed_base=Int(value),
            n_agents=out.n_agents,
            body=out.body,
            drive=out.drive,
            ablation=out.ablation,
            node_kwargs=out.node_kwargs,
            env_kwargs=out.env_kwargs,
            drive_kwargs=out.drive_kwargs,
        )
    end

    parts = split(path, ".")
    length(parts) == 2 || throw(ArgumentError("unknown sweep axis '$path'"))
    ns, field = parts
    key = Symbol(field)
    if ns == "node"
        out.node_kwargs[key] = value
    elseif ns == "env"
        if key === :n_agents
            out = SweepBaseline(
                node=out.node,
                task=out.task,
                N=out.N,
                ticks=out.ticks,
                window=out.window,
                seed_base=out.seed_base,
                n_agents=Int(value),
                body=out.body,
                drive=out.drive,
                ablation=out.ablation,
                node_kwargs=out.node_kwargs,
                env_kwargs=out.env_kwargs,
                drive_kwargs=out.drive_kwargs,
            )
        else
            out.env_kwargs[key] = value
        end
    elseif ns == "drive"
        out.drive_kwargs[key] = value
        out = SweepBaseline(
            node=out.node,
            task=out.task,
            N=out.N,
            ticks=out.ticks,
            window=out.window,
            seed_base=out.seed_base,
            n_agents=out.n_agents,
            body=out.body,
            drive=out.drive === nothing ? :oosawa : out.drive,
            ablation=out.ablation,
            node_kwargs=out.node_kwargs,
            env_kwargs=out.env_kwargs,
            drive_kwargs=out.drive_kwargs,
        )
    elseif ns == "task"
        if key === :N || key === :n_nodes
            out = SweepBaseline(node=out.node, task=out.task, N=Int(value), ticks=out.ticks, window=out.window,
                seed_base=out.seed_base, n_agents=out.n_agents, body=out.body, drive=out.drive,
                ablation=out.ablation, node_kwargs=out.node_kwargs, env_kwargs=out.env_kwargs, drive_kwargs=out.drive_kwargs)
        elseif key === :ticks
            out = SweepBaseline(node=out.node, task=out.task, N=out.N, ticks=Int(value), window=out.window,
                seed_base=out.seed_base, n_agents=out.n_agents, body=out.body, drive=out.drive,
                ablation=out.ablation, node_kwargs=out.node_kwargs, env_kwargs=out.env_kwargs, drive_kwargs=out.drive_kwargs)
        elseif key === :window
            out = SweepBaseline(node=out.node, task=out.task, N=out.N, ticks=out.ticks, window=Int(value),
                seed_base=out.seed_base, n_agents=out.n_agents, body=out.body, drive=out.drive,
                ablation=out.ablation, node_kwargs=out.node_kwargs, env_kwargs=out.env_kwargs, drive_kwargs=out.drive_kwargs)
        else
            throw(ArgumentError("unknown task axis '$path'"))
        end
    else
        throw(ArgumentError("unknown sweep axis '$path'"))
    end

    return out
end

function _build_sweep_cells(base::SweepBaseline, axes::AbstractDict, mode::AbstractString)
    axis_names = sort(collect(string.(keys(axes))))
    axis_values = [_axis_values(axes[name]) for name in axis_names]
    for (axis, values) in zip(axis_names, axis_values)
        _validate_axis!(base, axis, values)
    end

    cells = Dict{String,Any}[]
    if mode == "one_at_a_time"
        for (axis, values) in zip(axis_names, axis_values)
            for value in values
                push!(cells, Dict{String,Any}(
                    "axis" => axis,
                    "value" => value,
                    "params" => Dict{String,Any}(axis => value),
                    "baseline" => _resolve_sweep_baseline(_apply_axis_value(base, axis, value)),
                ))
            end
        end
    else
        for params in _axis_products(axis_names, axis_values)
            varied = _copy_sweep_baseline(base)
            for axis in axis_names
                varied = _apply_axis_value(varied, axis, params[axis])
            end
            push!(cells, Dict{String,Any}(
                "axis" => join(axis_names, "+"),
                "value" => join(["$(axis)=$(params[axis])" for axis in axis_names], ";"),
                "params" => params,
                "baseline" => _resolve_sweep_baseline(varied),
            ))
        end
    end
    return cells, axis_names, axis_values
end

function _cost_math(mode::AbstractString, axis_values)
    lengths = [length(values) for values in axis_values]
    if mode == "one_at_a_time"
        return join(string.(lengths), "+"), sum(lengths)
    end
    return join(string.(lengths), "x"), prod(lengths)
end

function _estimate_minutes(rollouts::Integer, ticks::Integer)
    minutes = rollouts * max(ticks, 1) / 120_000
    return minutes < 1 ? "<1m" : string(ceil(Int, minutes), "m")
end

function _cost_preview(mode, axis_values, seeds, ticks)
    math, cells = _cost_math(mode, axis_values)
    rollouts = cells * length(seeds)
    return "$(mode): $(math) = $(cells) cells x $(length(seeds)) seeds = $(rollouts) rollouts of ~$(ticks) ticks ~= est $(_estimate_minutes(rollouts, ticks))"
end

_sweep_done_path(cell_dir::AbstractString) = joinpath(cell_dir, "DONE")

function _sweep_cell_complete(cell_dir::AbstractString)
    return isfile(_sweep_done_path(cell_dir)) && isfile(joinpath(cell_dir, "metrics.csv"))
end

function _write_sweep_done(cell_dir::AbstractString, cell_id::AbstractString)
    open(_sweep_done_path(cell_dir), "w") do io
        println(io, "status = \"done\"")
        println(io, "cell = \"", _sanitize_path_part(cell_id), "\"")
        println(io, "completed_utc = \"", _utc_timestamp(), "\"")
    end
    return _sweep_done_path(cell_dir)
end

function _dict_to_tomlable(d::Dict{Symbol,Any})
    return Dict{String,Any}(string(k) => (v isa Symbol ? string(v) : v) for (k, v) in d)
end

function _baseline_toml(base::SweepBaseline)
    out = Dict{String,Any}(
        "node" => string(base.node),
        "task" => string(base.task),
        "seed_base" => base.seed_base,
        "ablation" => string(base.ablation),
    )
    base.N === nothing || (out["N"] = base.N)
    base.ticks === nothing || (out["ticks"] = base.ticks)
    base.window === nothing || (out["window"] = base.window)
    base.n_agents === nothing || (out["n_agents"] = base.n_agents)
    base.body === nothing || (out["body"] = string(base.body))
    base.drive === nothing || (out["drive"] = string(base.drive))
    isempty(base.node_kwargs) || (out["node_kwargs"] = _dict_to_tomlable(base.node_kwargs))
    isempty(base.env_kwargs) || (out["env_kwargs"] = _dict_to_tomlable(base.env_kwargs))
    isempty(base.drive_kwargs) || (out["drive_kwargs"] = _dict_to_tomlable(base.drive_kwargs))
    return out
end

function _write_manifest(path::AbstractString, id::AbstractString, base::SweepBaseline, seeds, measures, preview)
    manifest = Dict{String,Any}(
        "manifest_version" => "sweep-v1",
        "id" => id,
        "timestamp_utc" => _utc_timestamp(),
        "repo_path" => _repo_root(),
        "git_sha" => _git_sha(_repo_root()),
        "git_dirty" => _git_dirty(_repo_root()),
        "julia_version" => string(VERSION),
        "hostname" => _hostname(),
        "packages" => _direct_package_versions(),
        "seeds" => Dict{String,Any}(
            "seed_base" => base.seed_base,
            "offsets" => collect(seeds),
            "resolved" => [base.seed_base + seed for seed in seeds],
        ),
        "analytics" => Dict{String,Any}("measures" => collect(measures)),
        "cost_preview" => preview,
        "baseline" => _baseline_toml(base),
    )
    open(path, "w") do io
        TOML.print(io, manifest)
    end
    return path
end

function _write_resolved_config(path::AbstractString, id::AbstractString, mode::AbstractString, base::SweepBaseline, axes, seeds, measures, max_cells)
    data = Dict{String,Any}(
        "sweep" => Dict{String,Any}(
            "id" => id,
            "mode" => mode,
            "seeds" => collect(seeds),
            "max_cells" => max_cells,
        ),
        "baseline" => _baseline_toml(base),
        "axes" => Dict{String,Any}(string(k) => v for (k, v) in axes),
        "analytics" => Dict{String,Any}("measures" => collect(measures)),
    )
    open(path, "w") do io
        TOML.print(io, data)
    end
    return path
end

function _record_channels_for_measures(measures)
    channels = Set{Symbol}((:spikes, :rate))
    "spectral_radius" in measures && push!(channels, :spectral_radius)
    "regime" in measures && union!(channels, (:poses, :polarization, :milling))
    return Tuple(sort!(collect(channels); by=string))
end

function _simulation_kwargs(base::SweepBaseline, seed::Integer, measures)
    node_kwargs = copy(base.node_kwargs)
    for (key, value) in base.drive_kwargs
        node_kwargs[key] = value
    end
    base.drive === nothing || (node_kwargs[:drive] = base.drive)

    kwargs = Dict{Symbol,Any}(
        :node => base.node,
        :ticks => base.ticks,
        :window => base.window,
        :seed => Int(seed),
        :N => base.N,
        :record => _record_channels_for_measures(measures),
        :every => 1,
        :node_kwargs => _kwargs_tuple(node_kwargs),
        :ablation => base.ablation,
    )
    base.body === nothing || (kwargs[:body] = base.body)
    if _is_swarm_sweep(base)
        kwargs[:n_agents] = base.n_agents
        for (key, value) in base.env_kwargs
            kwargs[key] = value
        end
    else
        kwargs[:env_kwargs] = _kwargs_tuple(copy(base.env_kwargs))
    end
    return kwargs
end

function _finite_or_nan(value)
    (value === nothing || value === missing) && return NaN
    value isa Number || return NaN
    x = Float64(value)
    return isfinite(x) ? x : NaN
end

function _sim_score(sim::SimResult)
    task_obj = resolve_task(sim.task)
    if task_obj isa TaskSpec
        raw = _metric_value(sim.metrics, task_obj.score_key)
        return normalized_score(task_obj, raw), Float64(raw), string(task_obj.score_key)
    end

    if hasproperty(sim.metrics, :forage_score)
        return Float64(sim.metrics.forage_score), Float64(sim.metrics.forage_score), "forage_score"
    elseif hasproperty(sim.metrics, :polarization)
        return Float64(sim.metrics.polarization), Float64(sim.metrics.polarization), "polarization"
    end
    throw(ArgumentError("task :$(sim.task) has no normalized_score; use a swarm metric such as forage_score or polarization"))
end

function _measure_sigma_mr(sim::SimResult)
    kmax = max(2, min(20, Int(floor(sim.config.ticks / 3))))
    res = branching_ratio_mr(sim; kmax=kmax, transient=0)
    return _finite_or_nan(res.m_mr)
end

function _measure_spectral_radius(sim::SimResult)
    res = spectral_radius(sim)
    return _finite_or_nan(res.mean)
end

function _run_seed_metrics(base::SweepBaseline, seed::Integer, measures)
    kwargs = _simulation_kwargs(base, seed, measures)
    sim = simulate(base.task; _kwargs_tuple(kwargs)...)
    score, raw_score, score_key = _sim_score(sim)
    warnings = String[]
    notes = String.(getproperty(sim.config, :ablation_notes))

    alive = hasproperty(sim.metrics, :alive) ? Bool(sim.metrics.alive) : false
    alive || push!(warnings, "dead reservoir/liveness failed")
    if _is_compartmental_node(base.node) && !haskey(base.node_kwargs, :genome) && !haskey(base.node_kwargs, :raw)
        push!(warnings, "trained-required-but-untrained compartmental cell")
    end

    row = Dict{String,Any}(
        "seed" => Int(seed),
        "score" => _finite_or_nan(score),
        "raw_score" => _finite_or_nan(raw_score),
        "score_key" => score_key,
        "alive" => alive,
        "liveness" => alive ? 1.0 : 0.0,
        "rate_mean" => hasproperty(sim.metrics, :rate_mean) ? _finite_or_nan(sim.metrics.rate_mean) : NaN,
        "rate_var" => hasproperty(sim.metrics, :rate_var) ? _finite_or_nan(sim.metrics.rate_var) : NaN,
        "warnings" => "",
        "notes" => join(notes, " | "),
        "regime" => "",
    )

    for measure in measures
        if measure == "sigma_mr"
            try
                row["sigma_mr"] = _measure_sigma_mr(sim)
                isfinite(row["sigma_mr"]) || push!(warnings, "sigma_mr unavailable/non-finite")
            catch err
                row["sigma_mr"] = NaN
                push!(warnings, "sigma_mr failed: $(sprint(showerror, err))")
            end
        elseif measure == "spectral_radius"
            try
                row["spectral_radius"] = _measure_spectral_radius(sim)
                isfinite(row["spectral_radius"]) || push!(warnings, "spectral_radius unavailable/non-finite")
            catch err
                row["spectral_radius"] = NaN
                push!(warnings, "spectral_radius failed: $(sprint(showerror, err))")
            end
        elseif measure == "liveness"
            row["liveness"] = alive ? 1.0 : 0.0
        elseif measure == "regime"
            if sim.task in (:torus, :forage)
                try
                    regime = swarm_regime(sim)
                    row["regime"] = string(regime.label)
                    row["regime_polarization"] = _finite_or_nan(regime.polarization)
                    row["regime_milling"] = _finite_or_nan(regime.milling)
                    row["regime_speed"] = _finite_or_nan(regime.speed)
                catch err
                    push!(warnings, "regime failed: $(sprint(showerror, err))")
                end
            else
                push!(warnings, "regime unavailable for non-swarm task")
            end
        else
            throw(ArgumentError("unknown analytics measure '$(measure)'"))
        end
    end

    row["warnings"] = join(warnings, " | ")
    return row, sim
end

function _csv_header(rows)
    fixed = ["seed", "score", "raw_score", "score_key", "alive", "liveness", "rate_mean", "rate_var", "sigma_mr", "spectral_radius", "regime", "regime_polarization", "regime_milling", "regime_speed", "warnings", "notes"]
    extras = sort!(setdiff(unique(vcat([collect(keys(row)) for row in rows]...)), fixed))
    return vcat(fixed, extras)
end

function _write_rows_csv(path::AbstractString, rows; header=nothing)
    header === nothing && (header = _csv_header(rows))
    open(path, "w") do io
        println(io, join(header, ","))
        for row in rows
            println(io, join((_csv_cell(get(row, key, "")) for key in header), ","))
        end
    end
    return path
end

function _read_simple_csv(path::AbstractString)
    lines = readlines(path)
    isempty(lines) && return Dict{String,Any}[]
    header = split(lines[1], ",")
    rows = Dict{String,Any}[]
    for line in lines[2:end]
        isempty(strip(line)) && continue
        values = split(line, ","; keepempty=true)
        row = Dict{String,Any}()
        for (key, value) in zip(header, values)
            if key in ("seed",)
                row[key] = isempty(value) ? missing : parse(Int, value)
            elseif key in ("alive",)
                row[key] = lowercase(value) == "true"
            elseif key in ("score", "raw_score", "liveness", "rate_mean", "rate_var", "sigma_mr", "spectral_radius", "regime_polarization", "regime_milling", "regime_speed")
                row[key] = isempty(value) ? NaN : parse(Float64, value)
            else
                row[key] = value
            end
        end
        push!(rows, row)
    end
    return rows
end

function _finite_values(rows, key)
    vals = Float64[]
    for row in rows
        value = get(row, key, NaN)
        value isa Number || continue
        x = Float64(value)
        isfinite(x) && push!(vals, x)
    end
    return vals
end

function _mean_std(vals::Vector{Float64})
    isempty(vals) && return (NaN, NaN)
    mean = sum(vals) / length(vals)
    if length(vals) == 1
        return (mean, 0.0)
    end
    var = sum((x - mean)^2 for x in vals) / (length(vals) - 1)
    return (mean, sqrt(var))
end

function _mode_string(vals)
    counts = Dict{String,Int}()
    for value in vals
        s = string(value)
        isempty(s) && continue
        counts[s] = get(counts, s, 0) + 1
    end
    isempty(counts) && return ""
    return first(sort!(collect(counts), by=x -> (-x[2], x[1])))[1]
end

function _aggregate_cell(cell_id, cell, rows, measures)
    out = Dict{String,Any}(
        "cell" => cell_id,
        "axis" => cell["axis"],
        "value" => cell["value"],
        "n_seeds" => length(rows),
        "warnings" => join(unique(filter(!isempty, string.(get.(rows, "warnings", "")))), " | "),
    )

    for key in ("score", "raw_score", "liveness", "sigma_mr", "spectral_radius", "rate_mean", "rate_var")
        vals = _finite_values(rows, key)
        mean, std = _mean_std(vals)
        out["$(key)_mean"] = mean
        out["$(key)_std"] = std
    end
    out["regime_mode"] = _mode_string(get.(rows, "regime", ""))
    out["params"] = join(["$(key)=$(value)" for (key, value) in sort!(collect(cell["params"]), by=first)], ";")
    return out
end

function _write_placeholder_gif(path::AbstractString)
    open(path, "w") do io
        write(io, _SWEEP_GIF_1X1)
    end
    return path
end

function _try_write_representative_gif(path::AbstractString, sim::SimResult)
    try
        return animate(sim; path=path, maxframes=min(120, sim.config.ticks), framerate=20)
    catch
        return _write_placeholder_gif(path)
    end
end

function _write_cell_manifest(path::AbstractString, cell_id, cell, base::SweepBaseline, seeds)
    info = Dict{String,Any}(
        "cell" => cell_id,
        "axis" => string(cell["axis"]),
        "value" => string(cell["value"]),
        "params" => Dict{String,Any}(string(k) => v for (k, v) in cell["params"]),
        "baseline" => _baseline_toml(base),
        "seeds" => collect(seeds),
    )
    open(path, "w") do io
        TOML.print(io, info)
    end
    return path
end

function _run_cell(cell_id, cell, seeds, measures, cell_dir)
    mkpath(cell_dir)
    base = cell["baseline"]
    seed_values = [base.seed_base + seed for seed in seeds]
    representative = nothing
    rows = Dict{String,Any}[]
    for seed in seed_values
        row, sim = _run_seed_metrics(base, seed, measures)
        push!(rows, row)
        representative === nothing && (representative = sim)
    end
    _write_rows_csv(joinpath(cell_dir, "metrics.csv"), rows)
    _write_cell_manifest(joinpath(cell_dir, "manifest.toml"), cell_id, cell, base, seed_values)
    representative === nothing || _try_write_representative_gif(joinpath(cell_dir, "representative.gif"), representative)
    _write_sweep_done(cell_dir, cell_id)
    return rows
end

function _results_header(measures)
    header = ["cell", "axis", "value", "params", "n_seeds", "score_mean", "score_std", "raw_score_mean", "raw_score_std"]
    reported = String["liveness", "rate_mean", "rate_var"]
    "sigma_mr" in measures && push!(reported, "sigma_mr")
    "spectral_radius" in measures && push!(reported, "spectral_radius")
    for measure in reported
        push!(header, "$(measure)_mean")
        push!(header, "$(measure)_std")
    end
    append!(header, ["regime_mode", "warnings", "result_path"])
    return header
end

function _write_results_csv(path::AbstractString, rows, measures)
    return _write_rows_csv(path, rows; header=_results_header(measures))
end

function _figure_payload(rows, axis)
    selected = [row for row in rows if row["axis"] == axis]
    return "axis,value,score_mean,sigma_mr_mean,spectral_radius_mean,liveness_mean\n" *
        join((
            join((_csv_cell(get(row, key, "")) for key in ("axis", "value", "score_mean", "sigma_mr_mean", "spectral_radius_mean", "liveness_mean")), ",")
            for row in selected
        ), "\n")
end

function _write_axis_figure_placeholder(path::AbstractString, rows, axis)
    # The core package stays Makie-free. When a backend is loaded, users can
    # render richer plots from results.csv; this placeholder keeps the run-dir
    # contract explicit instead of silently omitting the figure.
    open(path, "w") do io
        write(io, _SWEEP_PNG_1X1)
    end
    open(path * ".csv", "w") do io
        write(io, _figure_payload(rows, axis))
    end
    return path
end

function _save_sweep_axis_figure end

function _write_axis_figures(dir::AbstractString, rows, axis_names)
    mkpath(dir)
    paths = String[]
    for axis in axis_names
        path = joinpath(dir, _sanitize_path_part(axis) * ".png")
        try
            push!(paths, _save_sweep_axis_figure(path, rows, axis))
        catch err
            if err isa MethodError
                push!(paths, _write_axis_figure_placeholder(path, rows, axis))
            else
                @warn "failed to render sweep figure; writing placeholder" axis path exception=(err, catch_backtrace())
                push!(paths, _write_axis_figure_placeholder(path, rows, axis))
            end
        end
    end
    return paths
end

function _best_rows_by_axis(rows)
    out = Dict{String,Any}()
    for row in rows
        axis = string(row["axis"])
        old = get(out, axis, nothing)
        if old === nothing || _finite_or_nan(row["score_mean"]) > _finite_or_nan(old["score_mean"])
            out[axis] = row
        end
    end
    return out
end

function _breakdown_for_axis(rows, axis)
    selected = [row for row in rows if row["axis"] == axis]
    isempty(selected) && return "not observed"
    scores = _finite_values(selected, "score_mean")
    best = isempty(scores) ? NaN : maximum(scores)
    for row in selected
        live = _finite_or_nan(row["liveness_mean"])
        score = _finite_or_nan(row["score_mean"])
        if isfinite(live) && live < 0.5
            return "liveness failed at $(row["value"])"
        elseif isfinite(best) && best > 0.0 && isfinite(score) && score < 0.5 * best
            return "score collapsed at $(row["value"])"
        end
    end
    return "no breakdown flagged"
end

function _regime_flip_for_axis(rows, axis)
    regimes = unique(filter(!isempty, string.(get.([row for row in rows if row["axis"] == axis], "regime_mode", ""))))
    length(regimes) > 1 || return "no regime flip"
    return "regime flip: " * join(regimes, " -> ")
end

function _write_readme(path::AbstractString, id, base::SweepBaseline, rows, axis_names, preview, measures)
    best = _best_rows_by_axis(rows)
    open(path, "w") do io
        println(io, "# Sweep `$(id)`")
        println(io)
        println(io, "> Cost preview: $(preview)")
        println(io)
        println(io, "Baseline: node `:$(base.node)`, task `:$(base.task)`, N=$(base.N), ticks=$(base.ticks), window=$(base.window).")
        println(io)
        println(io, "Measures: ", join(measures, ", "))
        println(io)
        println(io, "Note: `sigma_mr` and `spectral_radius` should be read together. Falandays' sigma can be partly homeostatically rate-pinned, so rho(W) is the complementary read.")
        println(io)
        println(io, "## Callouts")
        for axis in axis_names
            row = get(best, axis, nothing)
            if row === nothing
                println(io, "- `$(axis)`: no completed cells")
            else
                println(
                    io,
                    "- `$(axis)`: best `$(row["value"])` (score=$(round(_finite_or_nan(row["score_mean"]); digits=4))); ",
                    _breakdown_for_axis(rows, axis),
                    "; ",
                    _regime_flip_for_axis(rows, axis),
                )
            end
        end
        dead = count(row -> _finite_or_nan(row["liveness_mean"]) < 0.5, rows)
        println(io)
        println(io, "Dead/liveness-failed cells flagged: $(dead) / $(length(rows)).")
        println(io)
        println(io, "Representative GIFs use the first completed seed for each cell; if no Makie backend is loaded, a placeholder GIF is written and the numeric metrics remain authoritative.")
    end
    return path
end

function _run_sweep_data(data, source_path::AbstractString; root=nothing, force=false)
    axes = _axis_table(data)
    isempty(axes) && throw(ArgumentError("sweep TOML must define [axes] or [sweep.axes]"))

    base = _baseline_from_dict(source_path, data)
    mode = _sweep_mode(data)
    seeds = _sweep_seeds(data)
    measures = _analytics_measures(data)
    cells, axis_names, axis_values = _build_sweep_cells(base, axes, mode)
    max_cells = _sweep_max_cells(data)
    preview = _cost_preview(mode, axis_values, seeds, base.ticks)
    println("Sweep cost preview: ", preview)

    if length(cells) > max_cells && !_sweep_force(data, force)
        throw(ArgumentError("sweep has $(length(cells)) cells above max_cells=$(max_cells); pass force=true or use --force. If this is factorial, consider mode = \"one_at_a_time\"."))
    end

    id = _sweep_id(source_path, data)
    sweep_root = root === nothing ? joinpath(_repo_root(), "sweeps", id) : joinpath(String(root), id)
    mkpath(sweep_root)
    mkpath(joinpath(sweep_root, "cells"))

    _write_manifest(joinpath(sweep_root, "manifest.toml"), id, base, seeds, measures, preview)
    _write_resolved_config(joinpath(sweep_root, "sweep.resolved.toml"), id, mode, base, axes, seeds, measures, max_cells)

    aggregate_rows = Dict{String,Any}[]
    cell_rows = Dict{String,Any}[]
    for (idx, cell) in enumerate(cells)
        cell_id = "cell_" * lpad(string(idx), 3, "0")
        cell_dir = joinpath(sweep_root, "cells", cell_id)
        rows =
            _sweep_cell_complete(cell_dir) ?
            _read_simple_csv(joinpath(cell_dir, "metrics.csv")) :
            _run_cell(cell_id, cell, seeds, measures, cell_dir)
        aggregate = _aggregate_cell(cell_id, cell, rows, measures)
        aggregate["result_path"] = cell_dir
        push!(aggregate_rows, aggregate)
        push!(cell_rows, Dict{String,Any}(
            "cell" => cell_id,
            "params" => cell["params"],
            "result_path" => cell_dir,
            "best_fitness" => aggregate["score_mean"],
        ))
    end

    results_path = joinpath(sweep_root, "results.csv")
    _write_results_csv(results_path, aggregate_rows, measures)
    _write_axis_figures(joinpath(sweep_root, "figures"), aggregate_rows, axis_names)
    _write_readme(joinpath(sweep_root, "README.md"), id, base, aggregate_rows, axis_names, preview, measures)

    return (id=id, dir=sweep_root, index=results_path, results=results_path, cells=cell_rows, preview=preview)
end

function run_sweep(sweep_toml::AbstractString; root=nothing, force::Bool=false)
    data = TOML.parsefile(sweep_toml)
    return _run_sweep_data(data, sweep_toml; root=root, force=force)
end

function ablate(node, task; seeds=(0,), root=nothing, id=nothing, force::Bool=true, kwargs...)
    baseline = Dict{String,Any}(
        "node" => string(Symbol(node)),
        "task" => string(Symbol(task)),
    )
    for (key, value) in pairs(kwargs)
        baseline[string(key)] = value
    end
    sweep_id = id === nothing ? "ablate_$(Symbol(node))_$(Symbol(task))" : string(id)
    data = Dict{String,Any}(
        "sweep" => Dict{String,Any}(
            "id" => sweep_id,
            "mode" => "one_at_a_time",
            "seeds" => collect(seeds),
            "max_cells" => max(200, length(ablations()) + 1),
        ),
        "baseline" => baseline,
        "axes" => Dict{String,Any}(
            "ablation" => vcat(["none"], string.(ablations())),
        ),
        "analytics" => Dict{String,Any}(
            "measures" => collect(_SWEEP_DEFAULT_MEASURES),
        ),
    )
    return _run_sweep_data(data, "<ablate>"; root=root, force=force)
end
