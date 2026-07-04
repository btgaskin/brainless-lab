import TOML

const _SWEEP_MODES = Set{String}(("one_at_a_time", "factorial"))
const _SWEEP_DEFAULT_MEASURES = ("sigma_mr", "spectral_radius", "liveness")
# Recording :spectral_radius costs a dense eigendecomposition per agent per
# tick; sweeps only consume windowed means (window >= 60) and end-of-run
# values, so recompute rho(W) every K ticks and hold the last value between
# (see Recorder compute_every). Weights drift on learning-rate timescales,
# so a stride of 10 is far inside every window sweeps aggregate over.
const _SWEEP_SPECTRAL_EVERY = 10
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

Base.@kwdef struct SweepCaptureOptions
    group::String = "none"
    groups::Dict{String,Vector{Dict{String,Any}}} = Dict{String,Vector{Dict{String,Any}}}()
    gif::Bool = false
    gif_framerate::Int = 20
    gif_maxframes::Int = 120
    timeseries::Bool = false
    window::Int = 60
    stride::Int = 30
    n_shifts::Int = 20
    seed::Int = 0
end

Base.@kwdef struct SweepColumnSchema
    metric_header::Vector{String}
    float_columns::Set{String}
    int_columns::Set{String}
    bool_columns::Set{String}
    aggregate_columns::Vector{String}
    measure_columns::Dict{String,Vector{String}}
    ensemble_specs::Vector{NamedTuple}
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
    node = _validate_sweep_node(base.node)
    task = _validate_sweep_task(base.task)
    task_obj = resolve_task(task)
    is_swarm = task in _SWEEP_SWARM_TASKS || base.n_agents !== nothing

    if task_obj isa TaskSpec
        ticks = base.ticks === nothing ? task_obj.default_ticks : base.ticks
        window = base.window === nothing ? min(ticks, task_obj.default_window) : base.window
        N = base.N === nothing ? _default_node_count(node) : base.N
        return SweepBaseline(
            node=node,
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

    is_swarm || throw(ArgumentError("task :$(task) is not a TaskSpec and is not a known swarm task"))
    ticks = base.ticks === nothing ? 1000 : base.ticks
    window = base.window === nothing ? ticks : base.window
    N = base.N === nothing ? _default_node_count(node) : base.N
    n_agents = base.n_agents === nothing ? 8 : base.n_agents
    return SweepBaseline(
        node=node,
        task=task,
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

function _sweep_max_rollouts(data)
    sweep = _sweep_section(data)
    return Int(get(sweep, "max_rollouts", get(sweep, "max_cells", 200)))
end

function _sweep_force(data, force)
    force && return true
    value = get(_sweep_section(data), "force", false)
    return Bool(value)
end

_sweep_threaded(data) = Bool(get(_sweep_section(data), "threaded", true))

function _sweep_seeds(data)
    raw = get(_sweep_section(data), "seeds", [0])
    return Int.(collect(raw))
end

function _analytics_measures(data)
    analytics = haskey(data, "analytics") && data["analytics"] isa AbstractDict ? data["analytics"] : Dict{String,Any}()
    raw = get(analytics, "measures", collect(_SWEEP_DEFAULT_MEASURES))
    out = String[]
    for measure in string.(collect(raw))
        canonical = _canonical_measure_name(measure)
        canonical in out || push!(out, canonical)
    end
    return out
end

function _canonical_measure_name(measure::AbstractString)
    m = String(measure)
    m in ("clusters", "cluster_stats", "contact_graph_clusters") && return "contact_clusters"
    return m
end

function _default_ensemble_specs()
    q85 = DEFAULT_ENSEMBLE_THRESHOLD
    return [
        (kind=:turn, threshold=q85, neighbor_radius=nothing, id=_analysis_observable_id(:turn, q85)),
        (kind=:align, threshold=q85, neighbor_radius="vision_range", id=_analysis_observable_id(:align, q85)),
        (kind=:speed, threshold=q85, neighbor_radius=nothing, id=_analysis_observable_id(:speed, q85)),
        (kind=:graded, threshold=nothing, neighbor_radius=nothing, id=_analysis_observable_id(:graded, nothing)),
    ]
end

function _ensemble_threshold(raw, kind::Symbol)
    kind === :graded && raw === nothing && return nothing
    raw === nothing && return DEFAULT_ENSEMBLE_THRESHOLD
    raw isa AbstractDict && return _analysis_threshold_from_table(raw, :ensemble)
    raw isa AbstractString && lowercase(String(raw)) in ("median", "adaptive") && return Symbol(lowercase(String(raw)))
    raw isa Number && return Float64(raw)
    return raw
end

function _ensemble_specs(data)
    haskey(data, "ensemble") || return _default_ensemble_specs()
    raw = data["ensemble"]
    entries = raw isa AbstractVector ? raw : Any[raw]
    specs = NamedTuple[]
    for entry in entries
        entry isa AbstractDict || throw(ArgumentError("[[ensemble]] entries must be TOML tables"))
        kind = Symbol(get(entry, "kind", get(entry, :kind, "turn")))
        kind in _ENSEMBLE_OBSERVABLE_KINDS ||
            throw(ArgumentError("ensemble kind must be one of $(join(string.(_ENSEMBLE_OBSERVABLE_KINDS), ", "))"))
        threshold = _ensemble_threshold(get(entry, "threshold", get(entry, :threshold, nothing)), kind)
        radius = get(entry, "neighbor_radius", get(entry, :neighbor_radius, kind === :align ? "vision_range" : nothing))
        id = string(get(entry, "id", get(entry, :id, _analysis_observable_id(kind, threshold))))
        push!(specs, (kind=kind, threshold=threshold, neighbor_radius=radius, id=id))
    end
    return specs
end

function _group_entry_list(raw)
    raw isa AbstractVector || return [Dict{String,Any}(string(k) => v for (k, v) in raw)]
    out = Dict{String,Any}[]
    for entry in raw
        entry isa AbstractDict || throw(ArgumentError("capture group entries must be TOML tables"))
        push!(out, Dict{String,Any}(string(k) => v for (k, v) in entry))
    end
    return out
end

function _capture_groups(raw)
    raw isa AbstractDict || return Dict{String,Vector{Dict{String,Any}}}()
    out = Dict{String,Vector{Dict{String,Any}}}()
    for (name, spec) in raw
        spec isa AbstractDict || spec isa AbstractVector ||
            throw(ArgumentError("capture group '$(name)' must be a table or array of tables"))
        out[lowercase(string(name))] = _group_entry_list(spec)
    end
    return out
end

function _capture_options(data, base::SweepBaseline)
    table = haskey(data, "capture") && data["capture"] isa AbstractDict ? data["capture"] : Dict{String,Any}()
    group = lowercase(string(get(table, "group", get(table, :group, "none"))))
    capture_enabled = group != "none"
    window_default = base.window === nothing ? max(Int(base.ticks), 1) : Int(base.window)
    window = Int(get(table, "window", get(table, :window, window_default)))
    stride = Int(get(table, "stride", get(table, :stride, max(1, fld(window, 2)))))
    return SweepCaptureOptions(
        group=group,
        groups=_capture_groups(get(table, "groups", get(table, :groups, Dict{String,Any}()))),
        gif=Bool(get(table, "gif", get(table, :gif, capture_enabled))),
        gif_framerate=Int(get(table, "gif_framerate", get(table, :gif_framerate, 20))),
        gif_maxframes=Int(get(table, "gif_maxframes", get(table, :gif_maxframes, 120))),
        timeseries=Bool(get(table, "timeseries", get(table, :timeseries, capture_enabled))),
        window=window,
        stride=stride,
        n_shifts=Int(get(table, "n_shifts", get(table, :n_shifts, capture_enabled ? 20 : 0))),
        seed=Int(get(table, "seed", get(table, :seed, 0))),
    )
end

function _measure_columns(measure::AbstractString, ensemble_specs)
    measure == "sigma_mr" && return ["sigma_mr"]
    measure == "sigma_mr_node" && return ["sigma_mr_node"]
    measure == "sigma_mr_agent" && return ["sigma_mr_agent__$(spec.id)" for spec in ensemble_specs]
    measure == "dist_to_source" && return ["dist_to_source"]
    measure == "forage_score" && return ["forage_score"]
    measure == "spectral_radius" && return ["spectral_radius"]
    measure == "susceptibility_node" && return ["susceptibility_node"]
    measure == "susceptibility_agent" && return ["susceptibility_agent"]
    measure == "correlation_length" && return ["correlation_length"]
    measure == "contact_clusters" && return ["cluster_n_components", "cluster_largest_component_frac", "cluster_mean_component_size"]
    measure == "liveness" && return String[]
    measure == "regime" && return ["regime", "regime_polarization", "regime_milling", "regime_speed"]
    throw(ArgumentError("unknown analytics measure '$(measure)'"))
end

function _descriptor_columns(base::SweepBaseline)
    task = resolve_task(base.task)
    task isa TaskSpec || return String[]
    return string.(task.descriptor_keys)
end

function _build_column_schema(measures, ensemble_specs, baseline::SweepBaseline)
    base_columns = ["seed", "score", "raw_score", "score_key", "alive", "liveness", "rate_mean", "rate_var"]
    descriptor_columns = _descriptor_columns(baseline)
    measure_columns = Dict{String,Vector{String}}()
    dynamic = String[]
    for measure in measures
        cols = _measure_columns(measure, ensemble_specs)
        measure_columns[measure] = cols
        append!(dynamic, cols)
    end
    append!(dynamic, descriptor_columns)
    dynamic = unique(dynamic)
    tail = ["warnings", "error", "notes"]
    metric_header = vcat(base_columns, dynamic, tail)

    float_columns = Set{String}(["score", "raw_score", "liveness", "rate_mean", "rate_var"])
    for measure in measures, col in get(measure_columns, measure, String[])
        col == "regime" || push!(float_columns, col)
    end
    for col in descriptor_columns
        push!(float_columns, col)
    end
    int_columns = Set{String}(["seed"])
    bool_columns = Set{String}(["alive"])
    aggregate_columns = ["score", "raw_score", "liveness", "rate_mean", "rate_var"]
    for measure in measures, col in get(measure_columns, measure, String[])
        (col == "regime" || startswith(col, "regime_")) && continue
        col in aggregate_columns || push!(aggregate_columns, col)
    end
    for col in descriptor_columns
        col in aggregate_columns || push!(aggregate_columns, col)
    end

    return SweepColumnSchema(
        metric_header=metric_header,
        float_columns=float_columns,
        int_columns=int_columns,
        bool_columns=bool_columns,
        aggregate_columns=aggregate_columns,
        measure_columns=measure_columns,
        ensemble_specs=ensemble_specs,
    )
end

function _is_swarm_sweep(base::SweepBaseline)
    return base.task in (:torus, :swarm, :forage) || base.n_agents !== nothing
end

function _registry_name_error(kind::AbstractString, name::Symbol, known)
    known_strings = sort!(string.(collect(known)))
    suggestion = _suggest_name(string(name), known_strings)
    known_msg = isempty(known_strings) ? "none registered" : join(known_strings, ", ")
    if suggestion === nothing
        return ArgumentError("unknown $(kind) ':$(name)' (known: $(known_msg))")
    end
    return ArgumentError("unknown $(kind) ':$(name)' -- did you mean ':$(suggestion)'? (known: $(known_msg))")
end

function _validate_sweep_node(node)
    node_sym = _canonical_model_sym(Symbol(node))
    haskey(NODES, node_sym) || throw(_registry_name_error("node", node_sym, keys(NODES)))
    return node_sym
end

function _validate_sweep_task(task)
    task_sym = Symbol(task)
    task_sym === :swarm && return :torus
    haskey(TASKS, task_sym) || throw(_registry_name_error("task", task_sym, keys(TASKS)))
    return task_sym
end

function sweepable_axes(node=:falandays_base, task=:wall)
    node_sym = _validate_sweep_node(node)
    task_sym = _validate_sweep_task(task)
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
        push!(out, SweepAxisInfo(path="drive.noise_gain", default=0.0, range=">= 0", description="Oosawa target-deficit membrane noise gain"))
        push!(out, SweepAxisInfo(path="drive.membrane_noise", default=0.0, range=">= 0", description="Oosawa constant membrane noise floor"))
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
        push!(out, SweepAxisInfo(path="node.learn_on", default=nothing, range="true|false", description="online plasticity switch when the node supports it"))
    end

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
        task_obj = resolve_task(task_sym)
        if task_obj isa TaskSpec && task_obj.env_type === WallEnv
            push!(out, SweepAxisInfo(path="env.lam", default=1.0, range="> 0", description="wall-task collision penalty"))
        end
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

function _capture_artifacts_complete(cell_dir::AbstractString, captured::Bool, capture::SweepCaptureOptions)
    captured || return true
    capture.timeseries && !isfile(joinpath(cell_dir, "criticality_timeseries.csv")) && return false
    capture.gif && !isfile(joinpath(cell_dir, "representative.gif")) && return false
    capture.n_shifts > 0 && !isfile(joinpath(cell_dir, "null_test.csv")) && return false
    return true
end

function _sweep_cell_complete(cell_dir::AbstractString, captured::Bool, capture::SweepCaptureOptions)
    return isfile(_sweep_done_path(cell_dir)) &&
        isfile(joinpath(cell_dir, "metrics.csv")) &&
        _capture_artifacts_complete(cell_dir, captured, capture)
end

function _values_match(actual, expected)
    if expected isa AbstractVector || expected isa Tuple
        return any(value -> _values_match(actual, value), expected)
    elseif actual isa Number && expected isa Number
        return Float64(actual) == Float64(expected)
    end
    return string(actual) == string(expected)
end

function _params_match(params, selector::AbstractDict)
    for (key, expected) in selector
        key_s = string(key)
        haskey(params, key_s) || return false
        _values_match(params[key_s], expected) || return false
    end
    return true
end

function _cell_captured(cell, capture::SweepCaptureOptions)
    capture.group == "none" && return false
    capture.group == "all" && return true
    selectors = get(capture.groups, capture.group, Dict{String,Any}[])
    isempty(selectors) && return false
    return any(selector -> _params_match(cell["params"], selector), selectors)
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

function _threshold_toml(value)
    value === nothing && return nothing
    value === :median && return Dict{String,Any}("median" => true)
    value === :adaptive && return Dict{String,Any}("median" => true)
    if value isa Tuple && length(value) == 2 && value[1] === :quantile
        return Dict{String,Any}("quantile" => Float64(value[2]))
    elseif value isa Number
        return Dict{String,Any}("fixed" => Float64(value))
    end
    return string(value)
end

function _ensemble_toml(specs)
    out = Dict{String,Any}[]
    for spec in specs
        entry = Dict{String,Any}("kind" => string(spec.kind), "id" => spec.id)
        threshold = _threshold_toml(spec.threshold)
        threshold === nothing || (entry["threshold"] = threshold)
        spec.neighbor_radius === nothing || (entry["neighbor_radius"] = spec.neighbor_radius)
        push!(out, entry)
    end
    return out
end

function _capture_toml(capture::SweepCaptureOptions)
    return Dict{String,Any}(
        "group" => capture.group,
        "groups" => capture.groups,
        "gif" => capture.gif,
        "gif_framerate" => capture.gif_framerate,
        "gif_maxframes" => capture.gif_maxframes,
        "timeseries" => capture.timeseries,
        "window" => capture.window,
        "stride" => capture.stride,
        "n_shifts" => capture.n_shifts,
        "seed" => capture.seed,
    )
end

function _write_manifest(path::AbstractString, id::AbstractString, base::SweepBaseline, seeds, measures, preview, ensemble_specs, capture::SweepCaptureOptions)
    manifest = _manifest_header(:sweep)
    merge!(
        manifest,
        Dict{String,Any}(
            "id" => id,
            "seeds" => Dict{String,Any}(
                "seed_base" => base.seed_base,
                "offsets" => collect(seeds),
                "resolved" => [base.seed_base + seed for seed in seeds],
            ),
            "analytics" => Dict{String,Any}("measures" => collect(measures)),
            "ensemble" => _ensemble_toml(ensemble_specs),
            "capture" => _capture_toml(capture),
            "cost_preview" => preview,
            "baseline" => _baseline_toml(base),
        ),
    )
    open(path, "w") do io
        TOML.print(io, manifest)
    end
    return path
end

function _write_resolved_config(path::AbstractString, id::AbstractString, mode::AbstractString, base::SweepBaseline, axes, seeds, measures, max_cells, max_rollouts, ensemble_specs, capture::SweepCaptureOptions)
    data = Dict{String,Any}(
        "sweep" => Dict{String,Any}(
            "id" => id,
            "mode" => mode,
            "seeds" => collect(seeds),
            "max_cells" => max_cells,
            "max_rollouts" => max_rollouts,
        ),
        "baseline" => _baseline_toml(base),
        "axes" => Dict{String,Any}(string(k) => v for (k, v) in axes),
        "analytics" => Dict{String,Any}("measures" => collect(measures)),
        "ensemble" => _ensemble_toml(ensemble_specs),
        "capture" => _capture_toml(capture),
    )
    open(path, "w") do io
        TOML.print(io, data)
    end
    return path
end

function _record_channels_for_measures(measures; capture::Bool=false)
    channels = Set{Symbol}((:spikes, :rate))
    ("spectral_radius" in measures || capture) && push!(channels, :spectral_radius)
    "regime" in measures && union!(channels, (:poses, :polarization, :milling))
    if capture || any(measure -> measure in ("sigma_mr_agent", "dist_to_source", "susceptibility_agent", "correlation_length", "contact_clusters"), measures)
        push!(channels, :poses)
    end
    return Tuple(sort!(collect(channels); by=string))
end

function _simulation_kwargs(base::SweepBaseline, seed::Integer, measures; capture::Bool=false)
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
        :record => _record_channels_for_measures(measures; capture=capture),
        :every => 1,
        :spectral_every => _SWEEP_SPECTRAL_EVERY,
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

_has_metric(metrics_nt, key::Symbol) = key in propertynames(metrics_nt)

function _swarm_objective_key(metrics_nt)
    _has_metric(metrics_nt, :score) && return :score
    _has_metric(metrics_nt, :forage_score) && return :forage_score
    return nothing
end

function _sim_score(sim::SimResult)
    task_obj = resolve_task(sim.task)
    if task_obj isa TaskSpec
        raw = _metric_value(sim.metrics, task_obj.score_key)
        return normalized_score(task_obj, raw), Float64(raw), string(task_obj.score_key)
    end

    objective_key = _swarm_objective_key(sim.metrics)
    if objective_key !== nothing
        raw = Float64(getproperty(sim.metrics, objective_key))
        return normalized_forage_score(raw), raw, string(objective_key)
    elseif _has_metric(sim.metrics, :polarization) || _has_metric(sim.metrics, :milling)
        @warn "swarm polarization and milling are descriptors, not competence scores; request the regime measure or descriptor columns instead" task = sim.task maxlog = 1
        return NaN, NaN, "none"
    end
    throw(ArgumentError("task :$(sim.task) has no normalized_score or forage objective metric"))
end

function _copy_descriptor_metrics!(row::Dict{String,Any}, sim::SimResult, warnings::Vector{String})
    task_obj = resolve_task(sim.task)
    task_obj isa TaskSpec || return row
    for key in task_obj.descriptor_keys
        name = string(key)
        if _has_metric(sim.metrics, key)
            row[name] = _finite_or_nan(getproperty(sim.metrics, key))
        else
            row[name] = NaN
            push!(warnings, "descriptor :$(key) unavailable")
        end
    end
    return row
end

function _sigma_mr_params(sim::SimResult)
    ticks = Int(sim.config.ticks)
    window = hasproperty(sim.config, :window) ? min(Int(sim.config.window), ticks) : ticks
    # Match the sweep score/liveness window discipline: drop the pre-window
    # warmup so online-learning switch-on transients do not enter sigma_mr.
    transient = max(ticks - window, 0)
    kmax = max(2, min(20, Int(floor(max(window, 1) / 3))))
    return kmax, transient
end

function _measure_sigma_mr(sim::SimResult)
    kmax, transient = _sigma_mr_params(sim)
    res = branching_ratio_mr(sim; kmax=kmax, transient=transient)
    return _finite_or_nan(res.m_mr)
end

function _measure_sigma_mr_node(sim::SimResult)
    kmax, transient = _sigma_mr_params(sim)
    res = branching_ratio_mr(sim; kmax=kmax, transient=transient, level=:node)
    return _finite_or_nan(res.m_mr)
end

function _measure_sigma_mr_agent(sim::SimResult, spec)
    kmax, transient = _sigma_mr_params(sim)
    res = branching_ratio_mr(sim; kmax=kmax, transient=transient, level=:agent, observable=spec)
    return _finite_or_nan(res.m_mr)
end

function _measure_dist_to_source(sim::SimResult)
    sim.task == :forage || return NaN
    hasproperty(sim.metrics, :mean_distance_to_source) || return NaN
    return _finite_or_nan(sim.metrics.mean_distance_to_source)
end

function _measure_forage_score(sim::SimResult)
    hasproperty(sim.metrics, :forage_score) || return NaN
    return _finite_or_nan(sim.metrics.forage_score)
end

function _measure_susceptibility(sim::SimResult, level::Symbol)
    res = susceptibility(sim; level=level)
    return _finite_or_nan(res.susceptibility)
end

function _measure_correlation_length(sim::SimResult)
    return _finite_or_nan(correlation_length(sim))
end

function _measure_contact_clusters(sim::SimResult)
    res = contact_graph_clusters(sim)
    return (
        n_components=_finite_or_nan(res.n_components_mean),
        largest_component_frac=_finite_or_nan(res.largest_component_frac_mean),
        mean_component_size=_finite_or_nan(res.mean_component_size_mean),
    )
end

function _measure_spectral_radius(sim::SimResult)
    res = spectral_radius(sim)
    return _finite_or_nan(res.mean)
end

function _default_seed_row(seed::Integer, schema::SweepColumnSchema)
    row = Dict{String,Any}()
    for key in schema.metric_header
        if key in schema.float_columns
            row[key] = NaN
        elseif key in schema.int_columns
            row[key] = key == "seed" ? Int(seed) : missing
        elseif key in schema.bool_columns
            row[key] = false
        else
            row[key] = ""
        end
    end
    row["seed"] = Int(seed)
    row["liveness"] = 0.0
    return row
end

function _failed_seed_row(seed::Integer, err, schema::SweepColumnSchema)
    message = sprint(showerror, err)
    row = _default_seed_row(seed, schema)
    row["warnings"] = "cell failed: $(message)"
    row["error"] = message
    return row
end

function _run_seed_metrics(base::SweepBaseline, seed::Integer, measures, schema::SweepColumnSchema; captured::Bool=false)
    kwargs = _simulation_kwargs(base, seed, measures; capture=captured)
    sim = try
        simulate(base.task; _kwargs_tuple(kwargs)...)
    catch err
        return _failed_seed_row(seed, err, schema), nothing
    end

    score, raw_score, score_key = try
        _sim_score(sim)
    catch err
        return _failed_seed_row(seed, err, schema), nothing
    end
    warnings = String[]
    notes = String.(getproperty(sim.config, :ablation_notes))

    alive = hasproperty(sim.metrics, :alive) ? Bool(sim.metrics.alive) : false
    alive || push!(warnings, "dead reservoir/liveness failed")
    if _is_compartmental_node(base.node) && !haskey(base.node_kwargs, :genome) && !haskey(base.node_kwargs, :raw)
        push!(warnings, "trained-required-but-untrained compartmental cell")
    end

    row = _default_seed_row(seed, schema)
    row["score"] = _finite_or_nan(score)
    row["raw_score"] = _finite_or_nan(raw_score)
    row["score_key"] = score_key
    row["alive"] = alive
    row["liveness"] = alive ? 1.0 : 0.0
    row["rate_mean"] = hasproperty(sim.metrics, :rate_mean) ? _finite_or_nan(sim.metrics.rate_mean) : NaN
    row["rate_var"] = hasproperty(sim.metrics, :rate_var) ? _finite_or_nan(sim.metrics.rate_var) : NaN
    row["warnings"] = ""
    row["error"] = ""
    row["notes"] = join(notes, " | ")
    _copy_descriptor_metrics!(row, sim, warnings)

    for measure in measures
        if measure == "sigma_mr"
            try
                row["sigma_mr"] = _measure_sigma_mr(sim)
                isfinite(row["sigma_mr"]) || push!(warnings, "sigma_mr unavailable/non-finite")
            catch err
                row["sigma_mr"] = NaN
                push!(warnings, "sigma_mr failed: $(sprint(showerror, err))")
            end
        elseif measure == "sigma_mr_node"
            try
                row["sigma_mr_node"] = _measure_sigma_mr_node(sim)
                isfinite(row["sigma_mr_node"]) || push!(warnings, "sigma_mr_node unavailable/non-finite")
            catch err
                row["sigma_mr_node"] = NaN
                push!(warnings, "sigma_mr_node failed: $(sprint(showerror, err))")
            end
        elseif measure == "sigma_mr_agent"
            for spec in schema.ensemble_specs
                key = "sigma_mr_agent__$(spec.id)"
                try
                    row[key] = _measure_sigma_mr_agent(sim, spec)
                    isfinite(row[key]) || push!(warnings, "$(key) unavailable/non-finite")
                catch err
                    row[key] = NaN
                    push!(warnings, "$(key) failed: $(sprint(showerror, err))")
                end
            end
        elseif measure == "dist_to_source"
            row["dist_to_source"] = _measure_dist_to_source(sim)
        elseif measure == "forage_score"
            row["forage_score"] = _measure_forage_score(sim)
        elseif measure == "spectral_radius"
            try
                row["spectral_radius"] = _measure_spectral_radius(sim)
                isfinite(row["spectral_radius"]) || push!(warnings, "spectral_radius unavailable/non-finite")
            catch err
                row["spectral_radius"] = NaN
                push!(warnings, "spectral_radius failed: $(sprint(showerror, err))")
            end
        elseif measure == "susceptibility_node"
            try
                row["susceptibility_node"] = _measure_susceptibility(sim, :node)
            catch err
                row["susceptibility_node"] = NaN
                push!(warnings, "susceptibility_node failed: $(sprint(showerror, err))")
            end
        elseif measure == "susceptibility_agent"
            try
                row["susceptibility_agent"] = _measure_susceptibility(sim, :agent)
            catch err
                row["susceptibility_agent"] = NaN
                push!(warnings, "susceptibility_agent failed: $(sprint(showerror, err))")
            end
        elseif measure == "correlation_length"
            try
                row["correlation_length"] = _measure_correlation_length(sim)
            catch err
                row["correlation_length"] = NaN
                push!(warnings, "correlation_length failed: $(sprint(showerror, err))")
            end
        elseif measure == "contact_clusters"
            try
                clusters = _measure_contact_clusters(sim)
                row["cluster_n_components"] = clusters.n_components
                row["cluster_largest_component_frac"] = clusters.largest_component_frac
                row["cluster_mean_component_size"] = clusters.mean_component_size
            catch err
                row["cluster_n_components"] = NaN
                row["cluster_largest_component_frac"] = NaN
                row["cluster_mean_component_size"] = NaN
                push!(warnings, "contact_clusters failed: $(sprint(showerror, err))")
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

function _csv_header(rows, schema=nothing)
    schema === nothing || return schema.metric_header
    fixed = ["seed", "score", "raw_score", "score_key", "alive", "liveness", "rate_mean", "rate_var", "sigma_mr", "spectral_radius", "regime", "regime_polarization", "regime_milling", "regime_speed", "warnings", "error", "notes"]
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

function _parse_csv_record(line::AbstractString)
    fields = String[]
    buf = IOBuffer()
    in_quotes = false
    i = firstindex(line)
    while i <= lastindex(line)
        c = line[i]
        if in_quotes
            if c == '"'
                j = nextind(line, i)
                if j <= lastindex(line) && line[j] == '"'
                    write(buf, UInt8('"'))
                    i = j
                else
                    in_quotes = false
                end
            else
                print(buf, c)
            end
        elseif c == '"'
            in_quotes = true
        elseif c == ','
            push!(fields, String(take!(buf)))
        else
            print(buf, c)
        end
        i = nextind(line, i)
    end
    in_quotes && throw(ArgumentError("unterminated quoted CSV field"))
    push!(fields, String(take!(buf)))
    return fields
end

function _read_simple_csv(path::AbstractString, schema=nothing)
    lines = readlines(path)
    isempty(lines) && return Dict{String,Any}[]
    header = _parse_csv_record(lines[1])
    float_columns = schema === nothing ?
        Set{String}(("score", "raw_score", "liveness", "rate_mean", "rate_var", "sigma_mr", "spectral_radius", "regime_polarization", "regime_milling", "regime_speed")) :
        schema.float_columns
    int_columns = schema === nothing ? Set{String}(("seed",)) : schema.int_columns
    bool_columns = schema === nothing ? Set{String}(("alive",)) : schema.bool_columns
    rows = Dict{String,Any}[]
    for line in lines[2:end]
        isempty(strip(line)) && continue
        values = _parse_csv_record(line)
        row = Dict{String,Any}()
        for (key, value) in zip(header, values)
            if key in int_columns
                row[key] = isempty(value) ? missing : parse(Int, value)
            elseif key in bool_columns
                row[key] = lowercase(value) == "true"
            elseif key in float_columns
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

function _aggregate_cell(cell_id, cell, rows, schema::SweepColumnSchema)
    out = Dict{String,Any}(
        "cell" => cell_id,
        "axis" => cell["axis"],
        "value" => cell["value"],
        "n_seeds" => length(rows),
        "warnings" => join(unique(filter(!isempty, string.(get.(rows, "warnings", "")))), " | "),
        "errors" => join(unique(filter(!isempty, string.(get.(rows, "error", "")))), " | "),
    )

    for key in schema.aggregate_columns
        vals = _finite_values(rows, key)
        mean, std = _mean_std(vals)
        out["$(key)_mean"] = mean
        out["$(key)_std"] = std
    end
    out["regime_mode"] = _mode_string(get.(rows, "regime", ""))
    out["params"] = join(["$(key)=$(value)" for (key, value) in sort!(collect(cell["params"]), by=first)], ";")
    return out
end

function _capture_kmax(window::Integer)
    return max(2, min(20, fld(max(Int(window), 12), 6)))
end

function _series_value(series, idx::Integer)
    idx <= length(series) || return NaN
    return _finite_or_nan(series[idx])
end

function _window_mean_for_centers(series::AbstractVector{<:Real}, centers::AbstractVector{<:Real}, window::Integer)
    out = Vector{Float64}(undef, length(centers))
    n = length(series)
    @inbounds for idx in eachindex(centers)
        start = max(1, round(Int, centers[idx] - 0.5 * (window - 1)))
        stop = min(n, start + window - 1)
        out[idx] = start <= n && stop >= start ? _analysis_finite_mean(@view series[start:stop]) : NaN
    end
    return out
end

function _spectral_radius_timeseries(sim::SimResult, centers, window::Integer)
    try
        sr = spectral_radius(sim)
        series = sr.series isa AbstractMatrix ? _analysis_row_means(sr.series) : Float64.(sr.series)
        return _window_mean_for_centers(series, centers, window)
    catch
        return fill(NaN, length(centers))
    end
end

function _safe_windowed_branching(sim::SimResult; level::Symbol, window::Integer, stride::Integer, kmax::Integer, observable=nothing)
    try
        return branching_ratio_mr_windowed(sim; level=level, window=window, stride=stride, kmax=kmax, observable=observable)
    catch
        return Float64[], Float64[], Float64[], Int[]
    end
end

function _safe_windowed_susceptibility(sim::SimResult, level::Symbol, window::Integer, stride::Integer)
    try
        return susceptibility_windowed(sim; level=level, window=window, stride=stride).susceptibility
    catch
        return Float64[]
    end
end

function _safe_windowed_correlation(sim::SimResult, window::Integer, stride::Integer)
    try
        return correlation_length_windowed(sim; window=window, stride=stride).correlation_length
    catch
        return Float64[]
    end
end

function _safe_windowed_clusters(sim::SimResult, window::Integer, stride::Integer)
    try
        return contact_graph_clusters_windowed(sim; window=window, stride=stride)
    catch
        return (n_components=Float64[], largest_component_frac=Float64[], mean_component_size=Float64[])
    end
end

function _write_criticality_timeseries(path::AbstractString, sim::SimResult, schema::SweepColumnSchema, capture::SweepCaptureOptions)
    window = capture.window
    stride = capture.stride
    kmax = _capture_kmax(window)
    centers, m_node, r2_node, n_node =
        _safe_windowed_branching(sim; level=:node, window=window, stride=stride, kmax=kmax)

    agent_series = Dict{String,Any}()
    for spec in schema.ensemble_specs
        agent_series[spec.id] = _safe_windowed_branching(
            sim;
            level=:agent,
            window=window,
            stride=stride,
            kmax=kmax,
            observable=spec,
        )
    end

    susc_node = _safe_windowed_susceptibility(sim, :node, window, stride)
    susc_agent = _safe_windowed_susceptibility(sim, :agent, window, stride)
    corr_len = _safe_windowed_correlation(sim, window, stride)
    clusters = _safe_windowed_clusters(sim, window, stride)
    dist = try
        _window_mean_for_centers(distance_to_source(sim), centers, window)
    catch
        fill(NaN, length(centers))
    end
    rho = _spectral_radius_timeseries(sim, centers, window)

    header = ["t_center", "m_node", "r2_node", "n_node"]
    for spec in schema.ensemble_specs
        push!(header, "m_agent__$(spec.id)")
        push!(header, "r2_agent__$(spec.id)")
        push!(header, "n_agent__$(spec.id)")
    end
    append!(header, ["susc_node", "susc_agent", "corr_len", "cluster_n_components", "cluster_largest_component_frac", "cluster_mean_component_size", "dist_to_source", "spectral_radius"])

    rows = Dict{String,Any}[]
    for idx in eachindex(centers)
        row = Dict{String,Any}(
            "t_center" => centers[idx],
            "m_node" => _series_value(m_node, idx),
            "r2_node" => _series_value(r2_node, idx),
            "n_node" => idx <= length(n_node) ? n_node[idx] : 0,
            "susc_node" => _series_value(susc_node, idx),
            "susc_agent" => _series_value(susc_agent, idx),
            "corr_len" => _series_value(corr_len, idx),
            "cluster_n_components" => _series_value(clusters.n_components, idx),
            "cluster_largest_component_frac" => _series_value(clusters.largest_component_frac, idx),
            "cluster_mean_component_size" => _series_value(clusters.mean_component_size, idx),
            "dist_to_source" => _series_value(dist, idx),
            "spectral_radius" => _series_value(rho, idx),
        )
        for spec in schema.ensemble_specs
            _, m_agent, r2_agent, n_agent = agent_series[spec.id]
            row["m_agent__$(spec.id)"] = _series_value(m_agent, idx)
            row["r2_agent__$(spec.id)"] = _series_value(r2_agent, idx)
            row["n_agent__$(spec.id)"] = idx <= length(n_agent) ? n_agent[idx] : 0
        end
        push!(rows, row)
    end
    return _write_rows_csv(path, rows; header=header)
end

function _write_empty_csv(path::AbstractString, header)
    open(path, "w") do io
        println(io, join(header, ","))
    end
    return path
end

function _null_result_row(measure::AbstractString, result, n_shifts::Integer)
    return Dict{String,Any}(
        "measure" => measure,
        "real" => _finite_or_nan(result.real),
        "null_mean" => _finite_or_nan(result.null_mean),
        "null_std" => _finite_or_nan(result.null_std),
        "ratio" => _finite_or_nan(result.ratio),
        "n_shifts" => Int(n_shifts),
    )
end

function _write_null_test(path::AbstractString, sim::SimResult, schema::SweepColumnSchema, capture::SweepCaptureOptions, cell_index::Integer)
    header = ["measure", "real", "null_mean", "null_std", "ratio", "n_shifts"]
    capture.n_shifts <= 0 && return _write_empty_csv(path, header)

    rows = Dict{String,Any}[]
    seed = capture.seed + 1009 * Int(cell_index)
    kmax = _capture_kmax(capture.window)
    for spec in schema.ensemble_specs
        rng = MersenneTwister(seed + length(rows))
        measure_name = "sigma_mr_agent__$(spec.id)"
        result = try
            crossshift_null(
                sim,
                s -> branching_ratio_mr(s; level=:agent, kmax=kmax, observable=spec).m_mr;
                n_shifts=capture.n_shifts,
                rng=rng,
            )
        catch
            (real=NaN, null_mean=NaN, null_std=NaN, ratio=NaN)
        end
        push!(rows, _null_result_row(measure_name, result, capture.n_shifts))
    end

    null_measures = (
        "susceptibility_agent" => (s -> susceptibility(s; level=:agent).susceptibility),
        "correlation_length" => (s -> correlation_length(s)),
        "cluster_largest_component_frac" => (s -> contact_graph_clusters(s).largest_component_frac_mean),
        "cluster_mean_component_size" => (s -> contact_graph_clusters(s).mean_component_size_mean),
    )
    for (name, fn) in null_measures
        rng = MersenneTwister(seed + length(rows))
        result = try
            crossshift_null(sim, fn; n_shifts=capture.n_shifts, rng=rng)
        catch
            (real=NaN, null_mean=NaN, null_std=NaN, ratio=NaN)
        end
        push!(rows, _null_result_row(name, result, capture.n_shifts))
    end

    return _write_rows_csv(path, rows; header=header)
end

function _write_placeholder_gif(path::AbstractString)
    open(path, "w") do io
        write(io, _SWEEP_GIF_1X1)
    end
    return path
end

function _try_write_representative_gif(path::AbstractString, sim::SimResult; framerate::Integer=20, maxframes::Integer=120)
    try
        return animate(sim; path=path, maxframes=min(Int(maxframes), sim.config.ticks), framerate=Int(framerate), branching=false)
    catch
        return _write_placeholder_gif(path)
    end
end

function _write_cell_manifest(path::AbstractString, cell_id, cell, base::SweepBaseline, seeds; captured::Bool=false)
    info = Dict{String,Any}(
        "cell" => cell_id,
        "axis" => string(cell["axis"]),
        "value" => string(cell["value"]),
        "params" => Dict{String,Any}(string(k) => v for (k, v) in cell["params"]),
        "baseline" => _baseline_toml(base),
        "seeds" => collect(seeds),
        "captured" => captured,
    )
    open(path, "w") do io
        TOML.print(io, info)
    end
    return path
end

function _run_cell(cell_id, cell, seeds, measures, schema::SweepColumnSchema, cell_dir; captured::Bool=false, capture::SweepCaptureOptions=SweepCaptureOptions(), cell_index::Integer=1, threaded::Bool=true)
    mkpath(cell_dir)
    base = cell["baseline"]
    seed_values = [base.seed_base + seed for seed in seeds]
    # Seeds are independent rollouts: fan out across threads, keeping row order
    # by seed. Only captured cells need a live SimResult afterwards (for the
    # timeseries/null/GIF artifacts); every other rollout is dropped as soon as
    # its metric row exists so peak memory stays one row per seed, not one
    # full recorder per cell.
    results = parallel_map(seed_values; threaded=threaded) do seed
        row, sim = _run_seed_metrics(base, seed, measures, schema; captured=captured)
        (row=row, sim=captured ? sim : nothing)
    end
    rows = [result.row for result in results]
    representative = nothing
    for result in results
        if result.sim !== nothing
            representative = result.sim
            break
        end
    end
    _write_rows_csv(joinpath(cell_dir, "metrics.csv"), rows; header=schema.metric_header)
    _write_cell_manifest(joinpath(cell_dir, "manifest.toml"), cell_id, cell, base, seed_values; captured=captured)
    if captured
        if capture.timeseries
            if representative === nothing
                _write_empty_csv(joinpath(cell_dir, "criticality_timeseries.csv"), ["t_center"])
            else
                _write_criticality_timeseries(joinpath(cell_dir, "criticality_timeseries.csv"), representative, schema, capture)
            end
        end
        if capture.n_shifts > 0
            if representative === nothing
                _write_empty_csv(joinpath(cell_dir, "null_test.csv"), ["measure", "real", "null_mean", "null_std", "ratio", "n_shifts"])
            else
                _write_null_test(joinpath(cell_dir, "null_test.csv"), representative, schema, capture, cell_index)
            end
        end
        if capture.gif
            representative === nothing ?
                _write_placeholder_gif(joinpath(cell_dir, "representative.gif")) :
                _try_write_representative_gif(
                    joinpath(cell_dir, "representative.gif"),
                    representative;
                    framerate=capture.gif_framerate,
                    maxframes=capture.gif_maxframes,
                )
        end
    end
    _write_sweep_done(cell_dir, cell_id)
    return rows
end

function _results_header(schema::SweepColumnSchema)
    header = ["cell", "axis", "value", "params", "n_seeds", "score_mean", "score_std", "raw_score_mean", "raw_score_std"]
    reported = [col for col in schema.aggregate_columns if !(col in ("score", "raw_score"))]
    for measure in reported
        push!(header, "$(measure)_mean")
        push!(header, "$(measure)_std")
    end
    append!(header, ["regime_mode", "warnings", "errors", "result_path"])
    return header
end

function _write_results_csv(path::AbstractString, rows, schema::SweepColumnSchema)
    return _write_rows_csv(path, rows; header=_results_header(schema))
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
        failed = count(row -> !isempty(string(get(row, "errors", ""))), rows)
        println(io)
        println(io, "Dead/liveness-failed cells flagged: $(dead) / $(length(rows)).")
        println(io, "Cells with recorded errors: $(failed) / $(length(rows)).")
        if failed > 0
            println(io)
            println(io, "## Errors")
            for row in rows
                err = string(get(row, "errors", ""))
                isempty(err) && continue
                println(io, "- `$(row["cell"])` `$(row["axis"])=$(row["value"])`: $(err)")
            end
        end
        println(io)
        println(io, "Captured-cell GIFs use the first completed seed. If no Makie backend is loaded, a placeholder GIF is written and the numeric metrics remain authoritative.")
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
    ensemble_specs = _ensemble_specs(data)
    capture = _capture_options(data, base)
    schema = _build_column_schema(measures, ensemble_specs, base)
    cells, axis_names, axis_values = _build_sweep_cells(base, axes, mode)
    max_cells = _sweep_max_cells(data)
    max_rollouts = _sweep_max_rollouts(data)
    rollout_count = length(cells) * length(seeds)
    preview = _cost_preview(mode, axis_values, seeds, base.ticks)
    println("Sweep cost preview: ", preview)

    if rollout_count > max_rollouts && !_sweep_force(data, force)
        throw(ArgumentError("sweep has $(length(cells)) cells x $(length(seeds)) seeds = $(rollout_count) rollouts above max_rollouts=$(max_rollouts); pass force=true or use --force. If this is factorial, consider mode = \"one_at_a_time\"."))
    end

    id = _sweep_id(source_path, data)
    sweep_root = root === nothing ? joinpath(_repo_root(), "sweeps", id) : joinpath(String(root), id)
    mkpath(sweep_root)
    mkpath(joinpath(sweep_root, "cells"))

    _write_manifest(joinpath(sweep_root, "manifest.toml"), id, base, seeds, measures, preview, ensemble_specs, capture)
    _write_resolved_config(joinpath(sweep_root, resolved_config_filename()), id, mode, base, axes, seeds, measures, max_cells, max_rollouts, ensemble_specs, capture)

    threaded = _sweep_threaded(data)
    infos = [
        begin
            cell_id = "cell_" * lpad(string(idx), 3, "0")
            (
                idx=idx,
                cell=cell,
                cell_id=cell_id,
                cell_dir=joinpath(sweep_root, "cells", cell_id),
                captured=_cell_captured(cell, capture),
            )
        end for (idx, cell) in enumerate(cells)
    ]

    _cell_metric_rows(info) =
        _sweep_cell_complete(info.cell_dir, info.captured, capture) ?
        _read_simple_csv(joinpath(info.cell_dir, "metrics.csv"), schema) :
        _run_cell(info.cell_id, info.cell, seeds, measures, schema, info.cell_dir;
            captured=info.captured, capture=capture, cell_index=info.idx, threaded=threaded)

    # Two phases: non-captured cells are pure numeric work and fan out across
    # threads (their seeds fan out too, composing with the outer level).
    # Captured cells render Makie GIFs, which must stay off worker threads, so
    # they run on this task afterwards -- their seed rollouts and null-test
    # surrogates still parallelise internally.
    rows_by_cell = Vector{Vector{Dict{String,Any}}}(undef, length(infos))
    plain_infos = [info for info in infos if !info.captured]
    for (info, rows) in zip(plain_infos, parallel_map(_cell_metric_rows, plain_infos; threaded=threaded))
        rows_by_cell[info.idx] = rows
    end
    for info in infos
        info.captured || continue
        rows_by_cell[info.idx] = _cell_metric_rows(info)
    end

    aggregate_rows = Dict{String,Any}[]
    cell_rows = Dict{String,Any}[]
    for info in infos
        aggregate = _aggregate_cell(info.cell_id, info.cell, rows_by_cell[info.idx], schema)
        aggregate["result_path"] = info.cell_dir
        push!(aggregate_rows, aggregate)
        push!(cell_rows, Dict{String,Any}(
            "cell" => info.cell_id,
            "params" => info.cell["params"],
            "result_path" => info.cell_dir,
            "best_fitness" => aggregate["score_mean"],
            "captured" => info.captured,
        ))
    end

    results_path = joinpath(sweep_root, "results.csv")
    _write_results_csv(results_path, aggregate_rows, schema)
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
