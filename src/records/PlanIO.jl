using TOML

const PLAN_FORMAT = "brainlesslab-plan"
const PLAN_FORMAT_VERSION = 1

_plan_toml_value(value::Symbol) = String(value)
_plan_toml_value(value::Tuple) = [_plan_toml_value(item) for item in value]
_plan_toml_value(value::AbstractVector) = [_plan_toml_value(item) for item in value]
_plan_toml_value(value::UInt64) = value <= UInt64(typemax(Int64)) ? Int64(value) : string(value)
_plan_toml_value(value) = value

function _interaction_cycle_document(cycle::FixedRateCycle)
    return Dict{String,Any}(
        "kind" => "fixed_rate",
        "neural_frames" => neural_frames(cycle),
    )
end

function _parse_interaction_cycle(document)
    _require_document_keys(document, ("kind", "neural_frames"), "interaction_cycle")
    get(document, "kind", nothing) == "fixed_rate" || throw(ArgumentError(
        "interaction_cycle kind must be fixed_rate",
    ))
    haskey(document, "neural_frames") || throw(ArgumentError(
        "fixed_rate interaction_cycle requires neural_frames",
    ))
    return FixedRateCycle(document["neural_frames"])
end

function _string_dict(values)
    return Dict{String,Any}(string(key) => _plan_toml_value(value) for (key, value) in pairs(values))
end

function _require_document_keys(document, allowed, context)
    unknown = sort!(collect(setdiff(Set(keys(document)), Set(allowed))))
    isempty(unknown) || throw(ArgumentError(
        "unknown $(context) keys: $(join(unknown, ", "))",
    ))
    return document
end

function _composition_document(composition::CompositionSpec)
    document = Dict{String,Any}(
        "id" => String(composition.id),
        "node" => String(composition.node),
        "task" => String(composition.task),
        "n_nodes" => composition.n_nodes,
    )
    composition.body === nothing || (document["body"] = String(composition.body))
    composition.n_agents === nothing || (document["n_agents"] = composition.n_agents)
    isempty(composition.parameters) ||
        (document["parameters"] = _string_dict(composition.parameters))
    isempty(composition.task_options) ||
        (document["task_options"] = _string_dict(composition.task_options))
    isempty(composition.body_options) ||
        (document["body_options"] = _string_dict(composition.body_options))
    composition.interaction_cycle === nothing ||
        (document["interaction_cycle"] = _interaction_cycle_document(
            composition.interaction_cycle,
        ))
    return document
end

function _evaluation_document(evaluation::EvaluationSpec)
    return Dict{String,Any}(
        "blocks" => evaluation.blocks,
        "trials_per_block" => evaluation.trials_per_block,
        "horizon" => evaluation.horizon,
        "warmup" => evaluation.warmup,
        "construction_scope" => String(evaluation.construction_scope),
        "reset" => String(evaluation.reset),
        "root_seed" => evaluation.root_seed,
        "streams" => collect(String.(seed_stream_names(evaluation))),
        "aggregate" => String(evaluation.aggregate),
    )
end

function _target_document(target::EvaluationTarget)
    return Dict{String,Any}(
        "id" => String(target.id),
        "composition" => _composition_document(target.composition),
        "evaluation" => _evaluation_document(target.evaluation),
    )
end

function _base_plan_document(plan, operation::Symbol, targets)
    return Dict{String,Any}(
        "format" => PLAN_FORMAT,
        "format_version" => PLAN_FORMAT_VERSION,
        "operation" => String(operation),
        "id" => String(plan.id),
        "targets" => [_target_document(target) for target in targets],
    )
end

function plan_document(plan::ProfilePlan)
    document = _base_plan_document(plan, :profile, (plan.target,))
    document["profile"] = Dict{String,Any}(
        "target" => String(plan.target.id),
        "analyses" => collect(String.(plan.analyses)),
        "record_every" => plan.record_every,
    )
    return document
end

function plan_document(plan::SweepPlan)
    document = _base_plan_document(plan, :sweep, (plan.target,))
    document["sweep"] = Dict{String,Any}(
        "target" => String(plan.target.id),
        "mode" => String(plan.mode),
        "max_rollouts" => plan.max_rollouts,
        "axes" => [
            Dict{String,Any}(
                "parameter" => String(axis.parameter),
                "values" => collect(axis.values),
            )
            for axis in plan.axes
        ],
    )
    return document
end

function plan_document(plan::AblationPlan)
    document = _base_plan_document(plan, :ablate, (plan.target,))
    document["ablate"] = Dict{String,Any}(
        "target" => String(plan.target.id),
        "ablations" => collect(String.(plan.ablations)),
    )
    return document
end

function plan_document(plan::EvolutionPlan)
    targets = (plan.training, plan.heldout_targets...)
    document = _base_plan_document(plan, :evolve, targets)
    document["evolve"] = Dict{String,Any}(
        "training" => String(plan.training.id),
        "heldout" => String[String(target.id) for target in plan.heldout_targets],
        "optimizer" => String(plan.optimizer),
        "parameter_set" => String(plan.parameter_set),
        "objective" => String(plan.objective),
        "generations" => plan.generations,
        "popsize" => plan.popsize,
        "sigma0" => plan.sigma0,
    )
    return document
end

function plan_document(plan::BenchmarkPlan)
    targets = EvaluationTarget[]
    seen = Set{Symbol}()
    for case in plan.cases, target in case.conditions
        target.id in seen && continue
        push!(targets, target)
        push!(seen, target.id)
    end
    document = _base_plan_document(plan, :benchmark, Tuple(targets))
    document["benchmark"] = Dict{String,Any}(
        "cases" => [
            Dict{String,Any}(
                "id" => String(case.id),
                "conditions" => String[String(target.id) for target in case.conditions],
                "baseline" => String(case.baseline),
            )
            for case in plan.cases
        ],
    )
    return document
end

function write_plan(path::AbstractString, plan::AbstractOperationPlan)
    open(path, "w") do io
        TOML.print(io, plan_document(plan); sorted=true)
    end
    return String(path)
end

function _parse_composition(document, registry::RegistrySet)
    _require_document_keys(
        document,
        ("id", "preset", "node", "task", "body", "n_agents", "n_nodes", "parameters", "task_options", "body_options", "interaction_cycle"),
        "composition",
    )
    parameters = Dict{Symbol,Any}(
        Symbol(key) => value
        for (key, value) in get(document, "parameters", Dict{String,Any}())
    )
    task_options = Dict{Symbol,Any}(
        Symbol(key) => value
        for (key, value) in get(document, "task_options", Dict{String,Any}())
    )
    body_options = Dict{Symbol,Any}(
        Symbol(key) => value
        for (key, value) in get(document, "body_options", Dict{String,Any}())
    )
    node_id = haskey(document, "preset") ?
        composition_spec(registry, Symbol(document["preset"])).node :
        (haskey(document, "node") ? Symbol(document["node"]) : nothing)
    if node_id !== nothing
        spec = node_spec(registry, node_id)
        for parameter in spec.parameters
            haskey(parameters, parameter.name) || continue
            if parameter.datatype === Symbol && parameters[parameter.name] isa AbstractString
                parameters[parameter.name] = Symbol(parameters[parameter.name])
            end
        end
    end
    if haskey(document, "preset")
        allowed_inline = intersect(Set(keys(document)), Set(("node", "task", "n_nodes", "body", "n_agents")))
        isempty(allowed_inline) || throw(ArgumentError(
            "composition preset cannot be combined with structural keys $(sort!(collect(allowed_inline)))",
        ))
        base = composition_spec(registry, Symbol(document["preset"]))
        return CompositionSpec(
            Symbol(get(document, "id", base.id)),
            base.node,
            base.task;
            body=base.body,
            n_agents=base.n_agents,
            n_nodes=base.n_nodes,
            parameters=merge(copy(base.parameters), parameters),
            task_options=merge(copy(base.task_options), task_options),
            body_options=merge(copy(base.body_options), body_options),
            interaction_cycle=haskey(document, "interaction_cycle") ?
                _parse_interaction_cycle(document["interaction_cycle"]) :
                base.interaction_cycle,
        )
    end
    for key in ("id", "node", "task", "n_nodes")
        haskey(document, key) || throw(ArgumentError("inline composition requires $(key)"))
    end
    return CompositionSpec(
        Symbol(document["id"]),
        Symbol(document["node"]),
        Symbol(document["task"]);
        body=haskey(document, "body") ? Symbol(document["body"]) : nothing,
        n_agents=get(document, "n_agents", nothing),
        n_nodes=document["n_nodes"],
        parameters=parameters,
        task_options=task_options,
        body_options=body_options,
        interaction_cycle=haskey(document, "interaction_cycle") ?
            _parse_interaction_cycle(document["interaction_cycle"]) : nothing,
    )
end

function _parse_evaluation(document)
    _require_document_keys(
        document,
        ("blocks", "trials_per_block", "horizon", "warmup", "construction_scope", "reset", "root_seed", "streams", "aggregate"),
        "evaluation",
    )
    haskey(document, "horizon") || throw(ArgumentError("evaluation requires horizon"))
    root_seed_value = get(document, "root_seed", 0)
    root_seed = root_seed_value isa AbstractString ? parse(UInt64, root_seed_value) : root_seed_value
    return EvaluationSpec(
        blocks=get(document, "blocks", 1),
        trials_per_block=get(document, "trials_per_block", 1),
        horizon=document["horizon"],
        warmup=get(document, "warmup", 0),
        construction_scope=Symbol(get(document, "construction_scope", "trial")),
        reset=Symbol(get(document, "reset", "full")),
        root_seed=root_seed,
        streams=Tuple(Symbol(stream) for stream in get(document, "streams", String.(getfield.(DEFAULT_SEED_STREAMS, :name)))),
        aggregate=Symbol(get(document, "aggregate", "mean")),
    )
end

function _parse_targets(document, registry::RegistrySet)
    targets = Dict{Symbol,EvaluationTarget}()
    for entry in document
        _require_document_keys(entry, ("id", "composition", "evaluation"), "target")
        for key in ("id", "composition", "evaluation")
            haskey(entry, key) || throw(ArgumentError("target requires $(key)"))
        end
        id = Symbol(entry["id"])
        haskey(targets, id) && throw(ArgumentError("duplicate target :$(id)"))
        targets[id] = EvaluationTarget(
            id,
            _parse_composition(entry["composition"], registry),
            _parse_evaluation(entry["evaluation"]),
        )
    end
    isempty(targets) && throw(ArgumentError("plan requires at least one target"))
    return targets
end

function _target(targets, name)
    id = Symbol(name)
    haskey(targets, id) || throw(KeyError("unknown plan target :$(id)"))
    return targets[id]
end

function read_plan(path::AbstractString; registry::RegistrySet=DEFAULT_REGISTRY)
    document = TOML.parsefile(path)
    get(document, "format", nothing) == PLAN_FORMAT || throw(ArgumentError(
        "plan format must be $(repr(PLAN_FORMAT))",
    ))
    get(document, "format_version", nothing) == PLAN_FORMAT_VERSION || throw(ArgumentError(
        "plan format_version must be $(PLAN_FORMAT_VERSION)",
    ))
    haskey(document, "operation") || throw(ArgumentError("plan requires operation"))
    haskey(document, "id") || throw(ArgumentError("plan requires id"))
    haskey(document, "targets") || throw(ArgumentError("plan requires targets"))
    operation = Symbol(document["operation"])
    section_name = String(operation)
    allowed = ("format", "format_version", "operation", "id", "targets", section_name)
    _require_document_keys(document, allowed, "plan")
    haskey(document, section_name) || throw(ArgumentError(
        "plan operation :$(operation) requires [$(section_name)]",
    ))
    id = Symbol(document["id"])
    targets = _parse_targets(document["targets"], registry)
    section = document[section_name]

    if operation === :profile
        _require_document_keys(section, ("target", "analyses", "record_every"), "profile")
        return ProfilePlan(
            id,
            _target(targets, section["target"]);
            analyses=Symbol.(get(section, "analyses", String[])),
            record_every=get(section, "record_every", 1),
        )
    elseif operation === :sweep
        _require_document_keys(section, ("target", "axes", "mode", "max_rollouts"), "sweep")
        axes = Tuple(
            SweepAxis(Symbol(axis["parameter"]), Tuple(axis["values"]))
            for axis in get(section, "axes", Any[])
        )
        return SweepPlan(
            id,
            _target(targets, section["target"]);
            axes=axes,
            mode=Symbol(get(section, "mode", "factorial")),
            max_rollouts=get(section, "max_rollouts", 10_000),
        )
    elseif operation === :ablate
        _require_document_keys(section, ("target", "ablations"), "ablate")
        return AblationPlan(
            id,
            _target(targets, section["target"]);
            ablations=Symbol.(section["ablations"]),
        )
    elseif operation === :evolve
        _require_document_keys(
            section,
            ("training", "heldout", "optimizer", "parameter_set", "objective", "generations", "popsize", "sigma0"),
            "evolve",
        )
        return EvolutionPlan(
            id,
            _target(targets, section["training"]);
            heldout_targets=Tuple(_target(targets, name) for name in get(section, "heldout", String[])),
            optimizer=Symbol(get(section, "optimizer", "sepcma")),
            parameter_set=Symbol(get(section, "parameter_set", "evolve")),
            objective=Symbol(get(section, "objective", "normalized_score")),
            generations=get(section, "generations", 50),
            popsize=get(section, "popsize", 64),
            sigma0=get(section, "sigma0", 0.5),
        )
    elseif operation === :benchmark
        _require_document_keys(section, ("cases",), "benchmark")
        cases = Tuple(begin
            _require_document_keys(case, ("id", "conditions", "baseline"), "benchmark case")
            BenchmarkCasePlan(
                Symbol(case["id"]),
                Tuple(_target(targets, name) for name in case["conditions"]);
                baseline=Symbol(case["baseline"]),
            )
        end for case in section["cases"])
        return BenchmarkPlan(id, cases)
    end
    throw(ArgumentError("unsupported plan operation :$(operation)"))
end
