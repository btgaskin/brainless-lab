import TOML

Base.@kwdef struct RunSection
    name::String = "experiment"
    driver::Symbol = :evolve
    seed_base::Int = 0
    suite_seed_base::Int = 100_000
    profile::Symbol = :teaching
end

Base.@kwdef struct ModelSection
    family::Symbol = :falandays
    node::Symbol = :falandays
end

Base.@kwdef struct TaskSection
    train::Tuple{Vararg{Symbol}} = (:wall,)
    suite::Tuple{Vararg{Symbol}} = ()
    aggregator::Symbol = :min
    R::Union{Nothing,Int} = nothing
    E::Union{Nothing,Int} = nothing
    N::Union{Nothing,Int} = nothing
    ticks::Union{Nothing,Int} = nothing
    window::Union{Nothing,Int} = nothing
    link_p::Float64 = 0.1
    rho::Float64 = 0.2
    lam::Float64 = 1.0
end

Base.@kwdef struct EvolveSection
    generations::Int = 30
    popsize::Int = 16
    sigma0::Float64 = 2.5
    k_trials::Int = 8
    suite_every::Int = 0
    k_suite::Int = 0
    cma_seed::Int = 0
    threaded::Bool = true
end

Base.@kwdef struct RunConfig
    run::RunSection = RunSection()
    model::ModelSection = ModelSection()
    task::TaskSection = TaskSection()
    evolve::EvolveSection = EvolveSection()
end

const _RUN_CONFIG_DRIVERS = Set((:evolve, :fixed, :plastic))
const _RUN_CONFIG_AGGREGATORS = Set((:min, :mean))
const _RUN_CONFIG_PROFILES = Set((:none, :teaching, :oracle, :evolution))

function _section(data, key::AbstractString)
    data isa AbstractDict || return Dict{String,Any}()
    haskey(data, key) && return data[key]
    sym = Symbol(key)
    haskey(data, sym) && return data[sym]
    return Dict{String,Any}()
end

function _get(table, key::AbstractString, default)
    table isa AbstractDict || return default
    haskey(table, key) && return table[key]
    sym = Symbol(key)
    haskey(table, sym) && return table[sym]
    return default
end

_as_string(value, default) = value === nothing ? default : string(value)
_as_symbol(value, default) = value === nothing ? default : Symbol(value)
_as_int(value, default) = value === nothing ? default : Int(value)
_as_float(value, default) = value === nothing ? default : Float64(value)

function _as_bool(value, default)
    value === nothing && return default
    value isa AbstractString && return lowercase(String(value)) == "true"
    return Bool(value)
end

_as_optional_int(value, default) = value === nothing ? default : Int(value)

function _symbols_tuple(value, default=())
    value === nothing && return default
    value isa Tuple && return Tuple(Symbol(v) for v in value)
    value isa AbstractVector && return Tuple(Symbol(v) for v in value)
    return (Symbol(value),)
end

function _config_from_dict(data)
    run = _section(data, "run")
    model = _section(data, "model")
    task = _section(data, "task")
    evolve = _section(data, "evolve")

    model_node = _get(model, "node", _get(model, "family", "falandays"))
    model_family = _get(model, "family", model_node)

    return RunConfig(
        run=RunSection(
            name=_as_string(_get(run, "name", nothing), "experiment"),
            driver=_as_symbol(_get(run, "driver", nothing), :evolve),
            seed_base=_as_int(_get(run, "seed_base", nothing), 0),
            suite_seed_base=_as_int(_get(run, "suite_seed_base", nothing), 100_000),
            profile=_as_symbol(_get(run, "profile", nothing), :teaching),
        ),
        model=ModelSection(
            family=_as_symbol(model_family, :falandays),
            node=_as_symbol(model_node, :falandays),
        ),
        task=TaskSection(
            train=_symbols_tuple(_get(task, "train", nothing), (:wall,)),
            suite=_symbols_tuple(_get(task, "suite", nothing), ()),
            aggregator=_as_symbol(_get(task, "aggregator", nothing), :min),
            R=_as_optional_int(_get(task, "R", nothing), nothing),
            E=_as_optional_int(_get(task, "E", nothing), nothing),
            N=_as_optional_int(_get(task, "N", nothing), nothing),
            ticks=_as_optional_int(_get(task, "ticks", nothing), nothing),
            window=_as_optional_int(_get(task, "window", nothing), nothing),
            link_p=_as_float(_get(task, "link_p", nothing), 0.1),
            rho=_as_float(_get(task, "rho", nothing), 0.2),
            lam=_as_float(_get(task, "lam", nothing), 1.0),
        ),
        evolve=EvolveSection(
            generations=_as_int(_get(evolve, "generations", nothing), 30),
            popsize=_as_int(_get(evolve, "popsize", nothing), 16),
            sigma0=_as_float(_get(evolve, "sigma0", nothing), 2.5),
            k_trials=_as_int(_get(evolve, "k_trials", nothing), 8),
            suite_every=_as_int(_get(evolve, "suite_every", nothing), 0),
            k_suite=_as_int(_get(evolve, "k_suite", nothing), 0),
            cma_seed=_as_int(_get(evolve, "cma_seed", nothing), 0),
            threaded=_as_bool(_get(evolve, "threaded", nothing), true),
        ),
    )
end

function read_config(path::AbstractString)::RunConfig
    return _config_from_dict(TOML.parsefile(path))
end

function _toml_string(s::AbstractString)
    escaped = replace(String(s), "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t")
    return "\"" * escaped * "\""
end

_toml_value(value::AbstractString) = _toml_string(value)
_toml_value(value::Symbol) = _toml_string(string(value))
_toml_value(value::Bool) = value ? "true" : "false"
_toml_value(value::Integer) = string(value)

function _toml_value(value::AbstractFloat)
    isfinite(value) || throw(ArgumentError("TOML config cannot encode non-finite float $value"))
    return repr(Float64(value))
end

function _toml_value(value::Union{Tuple,AbstractVector})
    return "[" * join((_toml_value(v) for v in value), ", ") * "]"
end

function _write_toml_field(io, key::AbstractString, value)
    value === nothing && return nothing
    println(io, key, " = ", _toml_value(value))
    return nothing
end

function write_config(cfg::RunConfig, path::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "[run]")
        _write_toml_field(io, "name", cfg.run.name)
        _write_toml_field(io, "driver", cfg.run.driver)
        _write_toml_field(io, "seed_base", cfg.run.seed_base)
        _write_toml_field(io, "suite_seed_base", cfg.run.suite_seed_base)
        _write_toml_field(io, "profile", cfg.run.profile)
        println(io)

        println(io, "[model]")
        _write_toml_field(io, "family", cfg.model.family)
        _write_toml_field(io, "node", cfg.model.node)
        println(io)

        println(io, "[task]")
        _write_toml_field(io, "train", cfg.task.train)
        _write_toml_field(io, "suite", cfg.task.suite)
        _write_toml_field(io, "aggregator", cfg.task.aggregator)
        _write_toml_field(io, "R", cfg.task.R)
        _write_toml_field(io, "E", cfg.task.E)
        _write_toml_field(io, "N", cfg.task.N)
        _write_toml_field(io, "ticks", cfg.task.ticks)
        _write_toml_field(io, "window", cfg.task.window)
        _write_toml_field(io, "link_p", cfg.task.link_p)
        _write_toml_field(io, "rho", cfg.task.rho)
        _write_toml_field(io, "lam", cfg.task.lam)
        println(io)

        println(io, "[evolve]")
        _write_toml_field(io, "generations", cfg.evolve.generations)
        _write_toml_field(io, "popsize", cfg.evolve.popsize)
        _write_toml_field(io, "sigma0", cfg.evolve.sigma0)
        _write_toml_field(io, "k_trials", cfg.evolve.k_trials)
        _write_toml_field(io, "suite_every", cfg.evolve.suite_every)
        _write_toml_field(io, "k_suite", cfg.evolve.k_suite)
        _write_toml_field(io, "cma_seed", cfg.evolve.cma_seed)
        _write_toml_field(io, "threaded", cfg.evolve.threaded)
    end
    return path
end

function _task_specs_for_config(tasks_)
    specs = TaskSpec[]
    for task in tasks_
        spec = resolve_task(task)
        spec isa TaskSpec ||
            throw(ArgumentError("run configs support single-agent TaskSpec tasks, got :$(task)"))
        push!(specs, spec)
    end
    return specs
end

function _validate_resolved_config(cfg::RunConfig)
    cfg.run.driver in _RUN_CONFIG_DRIVERS ||
        throw(ArgumentError("run.driver must be one of evolve, fixed, plastic"))
    cfg.run.profile in _RUN_CONFIG_PROFILES ||
        throw(ArgumentError("run.profile must be one of none, teaching, oracle, evolution"))
    cfg.run.seed_base >= 0 || throw(ArgumentError("run.seed_base must be non-negative"))
    cfg.run.suite_seed_base >= 0 || throw(ArgumentError("run.suite_seed_base must be non-negative"))

    isempty(cfg.task.train) && throw(ArgumentError("task.train must contain at least one task"))
    cfg.task.aggregator in _RUN_CONFIG_AGGREGATORS ||
        throw(ArgumentError("task.aggregator must be :min or :mean"))
    cfg.task.R === nothing || cfg.task.R >= 1 || throw(ArgumentError("task.R must be positive"))
    cfg.task.E === nothing || cfg.task.E >= 1 || throw(ArgumentError("task.E must be positive"))
    cfg.task.N === nothing || cfg.task.N >= 1 || throw(ArgumentError("task.N must be positive"))
    cfg.task.ticks === nothing || cfg.task.ticks >= 1 || throw(ArgumentError("task.ticks must be positive"))
    cfg.task.window === nothing || cfg.task.window >= 1 || throw(ArgumentError("task.window must be positive"))
    0.0 <= cfg.task.link_p <= 1.0 || throw(ArgumentError("task.link_p must be in [0, 1]"))
    0.0 <= cfg.task.rho <= 1.0 || throw(ArgumentError("task.rho must be in [0, 1]"))
    cfg.task.lam > 0.0 || throw(ArgumentError("task.lam must be positive"))

    cfg.evolve.generations >= 1 || throw(ArgumentError("evolve.generations must be at least 1"))
    cfg.evolve.popsize >= 2 || throw(ArgumentError("evolve.popsize must be at least 2"))
    cfg.evolve.sigma0 > 0.0 || throw(ArgumentError("evolve.sigma0 must be positive"))
    cfg.evolve.k_trials >= 1 || throw(ArgumentError("evolve.k_trials must be at least 1"))
    cfg.evolve.suite_every >= 0 || throw(ArgumentError("evolve.suite_every must be non-negative"))
    cfg.evolve.k_suite >= 0 || throw(ArgumentError("evolve.k_suite must be non-negative"))
    cfg.evolve.cma_seed >= 0 || throw(ArgumentError("evolve.cma_seed must be non-negative"))
    return cfg
end

function resolve(cfg::RunConfig)::RunConfig
    profiled = apply_profile(cfg)

    driver = Symbol(profiled.run.driver)
    profile = Symbol(profiled.run.profile)
    seed_base = Int(profiled.run.seed_base)
    suite_seed_base = Int(profiled.run.suite_seed_base)
    if suite_seed_base == 100_000 && seed_base != 0
        suite_seed_base = seed_base + 100_000
    end

    node = _canonical_model_sym(profiled.model.node)
    resolve_node(node)

    train = Tuple(Symbol(t) for t in profiled.task.train)
    suite = isempty(profiled.task.suite) ? train : Tuple(Symbol(t) for t in profiled.task.suite)
    train_specs = _task_specs_for_config(train)
    _task_specs_for_config(suite)

    tick_default = maximum(spec.default_ticks for spec in train_specs)
    window_default = min(tick_default, minimum(spec.default_window for spec in train_specs))
    ticks = profiled.task.ticks === nothing ? tick_default : Int(profiled.task.ticks)
    window = profiled.task.window === nothing ? min(ticks, window_default) : Int(profiled.task.window)
    n_nodes = profiled.task.N === nothing ? _default_node_count(node) : Int(profiled.task.N)
    receptors = profiled.task.R === nothing ? train_specs[1].n_receptors : Int(profiled.task.R)
    effectors = profiled.task.E === nothing ? train_specs[1].n_effectors : Int(profiled.task.E)

    cma_seed = Int(profiled.evolve.cma_seed)
    if cma_seed == 0 && seed_base != 0
        cma_seed = seed_base
    end
    k_suite = profiled.evolve.k_suite == 0 && profiled.evolve.suite_every > 0 ?
        profiled.evolve.k_trials :
        profiled.evolve.k_suite

    resolved = RunConfig(
        run=RunSection(
            name=profiled.run.name,
            driver=driver,
            seed_base=seed_base,
            suite_seed_base=suite_seed_base,
            profile=profile,
        ),
        model=ModelSection(
            family=Symbol(profiled.model.family),
            node=node,
        ),
        task=TaskSection(
            train=train,
            suite=suite,
            aggregator=Symbol(profiled.task.aggregator),
            R=receptors,
            E=effectors,
            N=n_nodes,
            ticks=ticks,
            window=window,
            link_p=Float64(profiled.task.link_p),
            rho=Float64(profiled.task.rho),
            lam=Float64(profiled.task.lam),
        ),
        evolve=EvolveSection(
            generations=Int(profiled.evolve.generations),
            popsize=Int(profiled.evolve.popsize),
            sigma0=Float64(profiled.evolve.sigma0),
            k_trials=Int(profiled.evolve.k_trials),
            suite_every=Int(profiled.evolve.suite_every),
            k_suite=Int(k_suite),
            cma_seed=cma_seed,
            threaded=Bool(profiled.evolve.threaded),
        ),
    )
    return _validate_resolved_config(resolved)
end
