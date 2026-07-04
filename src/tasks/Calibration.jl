using Dates

function _git_short_sha()
    try
        sha = strip(readchomp(`git rev-parse --short HEAD`))
        return isempty(sha) ? "unknown" : sha
    catch
        return "unknown"
    end
end

function _seed_vector(seeds)
    values = Int.(collect(seeds))
    isempty(values) && throw(ArgumentError("calibration seeds must not be empty"))
    return values
end

function _seed_summary(values::Vector{Int})
    if length(values) == 1
        return string(values[1])
    elseif values == collect(first(values):last(values))
        return string(first(values), ":", last(values))
    end
    return join(values, ",")
end

_mean_float64(values::Vector{Float64}) = sum(values) / length(values)

function _calibration_sim_kwargs(
    task_obj;
    node,
    seed,
    ticks,
    window,
    N,
    n_agents,
    record,
    node_kwargs,
    env_kwargs,
    kwargs,
)
    options = Dict{Symbol,Any}(
        :node => node,
        :seed => Int(seed),
        :record => record,
    )
    ticks === nothing || (options[:ticks] = Int(ticks))
    window === nothing || (options[:window] = Int(window))
    N === nothing || (options[:N] = Int(N))
    isempty(node_kwargs) || (options[:node_kwargs] = _kwargs_tuple(_merge_kwdicts(node_kwargs)))

    if task_obj isa TaskSpec
        isempty(env_kwargs) || (options[:env_kwargs] = _kwargs_tuple(_merge_kwdicts(env_kwargs)))
    else
        n_agents === nothing || (options[:n_agents] = Int(n_agents))
        isempty(env_kwargs) || (options[:swarm_kwargs] = _kwargs_tuple(_merge_kwdicts(env_kwargs)))
    end

    for (key, value) in pairs(kwargs)
        options[Symbol(key)] = value
    end
    return _kwargs_tuple(options)
end

function _calibration_task_symbol(task_obj)
    task_obj isa TaskSpec && return task_obj.name
    return Symbol(task_obj)
end

function _calibration_score_key(metrics_nt, preferred::Symbol)
    preferred in propertynames(metrics_nt) && return preferred
    preferred == :score && :forage_score in propertynames(metrics_nt) && return :forage_score
    throw(KeyError("metric :$(preferred) is absent from calibration metrics"))
end

function _calibration_raw_score(sim::SimResult, preferred::Symbol)
    key = _calibration_score_key(sim.metrics, preferred)
    return _metric_value(sim.metrics, key), key
end

function _measure_null_anchor(
    task_obj,
    preferred_key::Symbol,
    seed_values::Vector{Int};
    null,
    ticks,
    window,
    N,
    n_agents,
    record,
    node_kwargs,
    env_kwargs,
    kwargs,
)
    raw = Float64[]
    used_key = preferred_key
    task_sym = _calibration_task_symbol(task_obj)
    for seed in seed_values
        sim = simulate(
            task_sym;
            _calibration_sim_kwargs(
                task_obj;
                node=null,
                seed=seed,
                ticks=ticks,
                window=window,
                N=N,
                n_agents=n_agents,
                record=record,
                node_kwargs=node_kwargs,
                env_kwargs=env_kwargs,
                kwargs=kwargs,
            )...,
        )
        value, key = _calibration_raw_score(sim, preferred_key)
        used_key = key
        push!(raw, value)
    end
    provenance = "null=$(null), score_key=$(used_key), seeds $(_seed_summary(seed_values)), git $(_git_short_sha()), $(Dates.today())"
    return null_anchor(_mean_float64(raw), provenance)
end

function _reference_from_namedtuple(reference, default_model)
    model = hasproperty(reference, :model) ? reference.model : reference
    model_sym = hasproperty(reference, :model_sym) ? reference.model_sym : default_model
    return model, model_sym
end

function _measure_reference_anchor(
    task_spec::TaskSpec,
    reference,
    seed_values::Vector{Int};
    reference_model,
    ticks,
    window,
    N,
    node_kwargs,
    env_kwargs,
    kwargs,
)
    model, model_sym =
        reference isa NamedTuple ? _reference_from_namedtuple(reference, reference_model) :
        (reference, reference_model)
    raw = Float64[]
    for seed in seed_values
        out = rollout(
            task_spec,
            model,
            seed;
            model_sym=model_sym,
            ticks=ticks,
            window=window,
            N=N,
            node_kwargs=node_kwargs,
            env_kwargs=env_kwargs,
            kwargs...,
        )
        push!(raw, Float64(out.score))
    end
    provenance = "reference=$(model_sym), score_key=$(task_spec.score_key), seeds $(_seed_summary(seed_values)), git $(_git_short_sha()), $(Dates.today())"
    return reference_anchor(_mean_float64(raw), provenance)
end

function _calibrated_ceiling(
    task_spec::TaskSpec,
    reference,
    seed_values::Vector{Int};
    reference_model,
    ticks,
    window,
    N,
    node_kwargs,
    env_kwargs,
    kwargs,
)
    task_spec.ceiling.kind == ANALYTIC && return task_spec.ceiling
    if reference !== nothing
        return _measure_reference_anchor(
            task_spec,
            reference,
            seed_values;
            reference_model=reference_model,
            ticks=ticks,
            window=window,
            N=N,
            node_kwargs=node_kwargs,
            env_kwargs=env_kwargs,
            kwargs=kwargs,
        )
    end
    return reference_anchor(
        task_spec.ceiling.value,
        "legacy observed best, pending reference-genome calibration",
    )
end

"""
    calibrate_task(task; null=:null_random, reference=nothing, seeds=0:7, kw...)

Measure the null floor for a task using the model-agnostic random-output policy
and return `(floor, ceiling)` anchors. Reference ceilings are measured only when
`reference` is supplied; otherwise existing non-analytic ceilings are retagged as
legacy observed bests pending reference-genome calibration.
"""
function calibrate_task(
    task;
    null=:null_random,
    reference=nothing,
    reference_model=:falandays,
    seeds=0:7,
    ticks=nothing,
    window=nothing,
    N=nothing,
    n_agents=nothing,
    record=Symbol[],
    node_kwargs=NamedTuple(),
    env_kwargs=NamedTuple(),
    kwargs...,
)
    task_obj = resolve_task(task)
    seed_values = _seed_vector(seeds)

    if task_obj isa TaskSpec
        floor = _measure_null_anchor(
            task_obj,
            task_obj.score_key,
            seed_values;
            null=Symbol(null),
            ticks=ticks,
            window=window,
            N=N,
            n_agents=n_agents,
            record=record,
            node_kwargs=node_kwargs,
            env_kwargs=env_kwargs,
            kwargs=kwargs,
        )
        ceiling = _calibrated_ceiling(
            task_obj,
            reference,
            seed_values;
            reference_model=reference_model,
            ticks=ticks,
            window=window,
            N=N,
            node_kwargs=node_kwargs,
            env_kwargs=env_kwargs,
            kwargs=kwargs,
        )
        return (floor=floor, ceiling=ceiling)
    elseif Symbol(task_obj) == :forage
        floor = _measure_null_anchor(
            task_obj,
            :score,
            seed_values;
            null=Symbol(null),
            ticks=ticks,
            window=window,
            N=N,
            n_agents=n_agents,
            record=record,
            node_kwargs=node_kwargs,
            env_kwargs=env_kwargs,
            kwargs=kwargs,
        )
        return (floor=floor, ceiling=FORAGE_CEILING_ANCHOR)
    end

    throw(ArgumentError("calibrate_task has no scoring anchor policy for task :$(task_obj)"))
end

function write_calibration_report(
    io::IO=stdout;
    task_names=(:wall, :pong, :pong_hitrate, :cartpole_swingup, :forage),
    references=Dict{Symbol,Any}(:wall => (model=FalandaysParams(), model_sym=:falandays_oosawa)),
    kwargs...,
)
    for task_name in task_names
        reference = get(references, Symbol(task_name), nothing)
        anchors = calibrate_task(task_name; reference=reference, kwargs...)
        println(io, task_name)
        println(io, "  floor = ", anchors.floor.value, " [", anchors.floor.kind, "] ", anchors.floor.provenance)
        println(io, "  ceiling = ", anchors.ceiling.value, " [", anchors.ceiling.kind, "] ", anchors.ceiling.provenance)
    end
    return nothing
end
