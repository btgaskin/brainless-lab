const _PROFILE_DEFAULTS = Dict{Symbol,NamedTuple}(
    :teaching => (N=40, ticks=80, window=80),
    :oracle => (N=100, ticks=1000, window=200),
    :evolution => (N=1000, ticks=1000, window=300),
)

function _profile_default(profile::Symbol)
    profile in (:none, :default) && return nothing
    haskey(_PROFILE_DEFAULTS, profile) ||
        throw(ArgumentError("unknown run profile :$(profile)"))
    return _PROFILE_DEFAULTS[profile]
end

_profile_value(defaults, key::Symbol, fallback) =
    defaults === nothing || !haskey(defaults, key) ? fallback : getproperty(defaults, key)

function apply_profile(cfg::RunConfig)
    profile = Symbol(cfg.run.profile)
    defaults = _profile_default(profile)
    defaults === nothing && return cfg

    task = TaskSection(
        train=cfg.task.train,
        suite=cfg.task.suite,
        aggregator=cfg.task.aggregator,
        R=cfg.task.R,
        E=cfg.task.E,
        N=cfg.task.N === nothing ? _profile_value(defaults, :N, nothing) : cfg.task.N,
        ticks=cfg.task.ticks === nothing ? _profile_value(defaults, :ticks, nothing) : cfg.task.ticks,
        window=cfg.task.window === nothing ? _profile_value(defaults, :window, nothing) : cfg.task.window,
        link_p=cfg.task.link_p,
        rho=cfg.task.rho,
        lam=cfg.task.lam,
    )

    return RunConfig(
        run=cfg.run,
        model=cfg.model,
        task=task,
        evolve=cfg.evolve,
    )
end
