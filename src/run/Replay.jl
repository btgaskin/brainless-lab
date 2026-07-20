import JLD2
import TOML

const _RECORDER_REPLAY_FILE = "recorder.jld2"

function _replay_file(dir::AbstractString)
    path = String(dir)
    return endswith(path, ".jld2") ? path : joinpath(path, _RECORDER_REPLAY_FILE)
end

function _replay_dir(path::AbstractString)
    s = String(path)
    return endswith(s, ".jld2") ? dirname(s) : s
end

function _recorder_channels_for_save(rec::Recorder)
    channels = Dict{Symbol,Vector{Any}}()
    for (channel, samples) in rec.channels
        channels[Symbol(channel)] = Any[sample for sample in samples]
    end
    return channels
end

function _restore_channel_dict(channels)
    restored = Dict{Symbol,Vector{Any}}()
    for (channel, samples) in channels
        restored[Symbol(channel)] = Any[sample for sample in samples]
    end
    return restored
end

function _restore_enabled(enabled)
    return Set{Symbol}(Symbol(channel) for channel in enabled)
end

function _restore_recorder(channels, enabled, every, tick)
    rec = Recorder(enabled=collect(_restore_enabled(enabled)), every=Int(every))
    rec.channels = _restore_channel_dict(channels)
    rec.tick = Int(tick)
    return rec
end

function _jld_has(data, key::AbstractString)
    return haskey(data, key)
end

function _jld_get(data, key::AbstractString)
    return data[key]
end

function _symbolize_toml(value)
    if value isa AbstractDict
        pairs_ = sort!([(Symbol(k), _symbolize_toml(v)) for (k, v) in value], by=first)
        keys_ = Tuple(first(pair) for pair in pairs_)
        values_ = Tuple(last(pair) for pair in pairs_)
        return NamedTuple{keys_}(values_)
    elseif value isa AbstractVector
        return [_symbolize_toml(item) for item in value]
    end
    return value
end

function _maybe_parse_toml(path::AbstractString)
    isfile(path) || return nothing
    return _symbolize_toml(TOML.parsefile(path))
end

function _run_provenance(dir::AbstractString)
    return (
        config=_maybe_parse_toml(joinpath(dir, resolved_config_filename())),
        manifest=_maybe_parse_toml(joinpath(dir, "manifest.toml")),
    )
end

function _fallback_task(provenance)
    cfg = provenance.config
    cfg === nothing && return :unknown
    hasproperty(cfg, :task) || return :unknown
    task_cfg = cfg.task
    hasproperty(task_cfg, :train) || return :unknown
    train = task_cfg.train
    isempty(train) && return :unknown
    return Symbol(first(train))
end

function _fallback_node(provenance)
    cfg = provenance.config
    cfg === nothing && return :unknown
    hasproperty(cfg, :model) || return :unknown
    model_cfg = cfg.model
    hasproperty(model_cfg, :node) || return :unknown
    return Symbol(model_cfg.node)
end

function _fallback_config(provenance)
    return (
        ticks=nothing,
        seed=nothing,
        record=Tuple(Symbol[]),
        every=1,
        window=nothing,
        n_agents=nothing,
        n_nodes=nothing,
        environment=(kind=:unknown, bounds=nothing, size=nothing),
        agents=(),
        entity_ids=(),
        bodies=(),
        networks=(),
        provenance=provenance,
    )
end

function _fallback_metrics(dir::AbstractString)
    metrics_path = joinpath(dir, "metrics.toml")
    parsed = _maybe_parse_toml(metrics_path)
    parsed === nothing && return NamedTuple()
    return parsed
end

"""
    save_recorder(dir, sim::SimResult)

Persist the recorder and visualization inputs for a high-level simulation to
`recorder.jld2` inside `dir`. Returns the written file path.
"""
function save_recorder(dir::AbstractString, sim::SimResult)
    mkpath(dir)
    path = joinpath(dir, _RECORDER_REPLAY_FILE)
    JLD2.jldsave(
        path;
        format_version=1,
        channels=_recorder_channels_for_save(sim.recorder),
        enabled=collect(sim.recorder.enabled),
        every=sim.recorder.every,
        tick=sim.recorder.tick,
        task=sim.task,
        node=sim.node,
        metrics=sim.metrics,
        config=sim.config,
    )
    return path
end

"""
    replay(rundir::AbstractString)::SimResult

Load a saved run directory containing `recorder.jld2` and reconstruct the
`SimResult` needed by `visualize` and `animate`.
"""
function replay(rundir::AbstractString)::SimResult
    replay_path = _replay_file(rundir)
    isfile(replay_path) ||
        throw(ArgumentError("replay: missing $(basename(replay_path)); saved runs without recorder data cannot be replayed"))

    data = JLD2.load(replay_path)
    dir = _replay_dir(rundir)
    provenance = _run_provenance(dir)

    channels = _jld_has(data, "channels") ? _jld_get(data, "channels") : Dict{Symbol,Vector{Any}}()
    enabled = _jld_has(data, "enabled") ? _jld_get(data, "enabled") : collect(keys(channels))
    every = _jld_has(data, "every") ? _jld_get(data, "every") : 1
    tick = _jld_has(data, "tick") ? _jld_get(data, "tick") : 0
    rec = _restore_recorder(channels, enabled, every, tick)

    task = _jld_has(data, "task") ? Symbol(_jld_get(data, "task")) : _fallback_task(provenance)
    node = _jld_has(data, "node") ? Symbol(_jld_get(data, "node")) : _fallback_node(provenance)
    metrics = _jld_has(data, "metrics") ? _jld_get(data, "metrics") : _fallback_metrics(dir)
    config = _jld_has(data, "config") ? _jld_get(data, "config") : _fallback_config(provenance)

    return SimResult(rec, metrics, task, node, config)
end
