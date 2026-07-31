module BrainlessLabTestUtils

using BrainlessLab

function diagnostic_simulate(args...; ticks, window=nothing, kwargs...)
    effective_window = window === nothing ? Int(ticks) : Int(window)
    return simulate(
        args...;
        ticks=Int(ticks),
        window=effective_window,
        kwargs...,
    )
end

function diagnostic_build_ensemble(args...; ticks, window=nothing, kwargs...)
    effective_window = window === nothing ? Int(ticks) : Int(window)
    return BrainlessLab._build_ensemble(
        args...;
        ticks=Int(ticks),
        window=effective_window,
        kwargs...,
    )
end

function task_with_minimum(task_name::Symbol, minimum_scored_ticks::Integer)
    task = BrainlessLab.task_spec(DEFAULT_REGISTRY, task_name)
    return TaskSpec(
        task.name,
        task.setup;
        env_type=task.env_type,
        n_receptors=task.n_receptors,
        n_effectors=task.n_effectors,
        default_ticks=task.default_ticks,
        default_window=task.default_window,
        minimum_scored_ticks=minimum_scored_ticks,
        interaction_cycle=task.interaction_cycle,
        status=task.status,
        tags=task.tags,
        protocol=task.protocol,
        options=task.options,
        floor=task.floor,
        ceiling=task.ceiling,
        score_key=task.score_key,
        descriptor_keys=task.descriptor_keys,
    )
end

function diagnostic_registry(task_names=(:tracking, :pong))
    registry = deepcopy(DEFAULT_REGISTRY)
    for task_name in task_names
        registry.tasks.entries[task_name] = task_with_minimum(task_name, 1)
    end
    return registry
end

function scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function int_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Int(value) : Int(only(value))
end

function _operation_node_builder(context::NodeBuildContext, parameters)
    seed = Int(mod(context.seeds.topology, UInt64(typemax(Int))))
    return BrainlessLab.NullRandomReservoir(
        context.n_nodes,
        n_receptors(context.ports),
        n_effectors(context.ports);
        seed=seed,
    )
end

"""
    operation_registry()

Return a fresh registry for tests of orchestration, serialisation, and seed
pairing. The node is deliberately cheap: these tests do not establish
Falandays behaviour, which belongs to the oracle suite.
"""
function operation_registry()
    registry = RegistrySet()
    node = NodeSpec(
        :test_node,
        _operation_node_builder;
        stability=:control,
        tags=(:test_fixture,),
        capabilities=(:online_plasticity, :homeostatic_target),
        parameters=(
            ParameterSpec(
                :gain,
                1.0;
                validator=value -> 0.0 <= value <= 2.0,
                sweep=(0.5, 1.0),
                description="test-only gain coordinate",
            ),
            ParameterSpec(
                :bias,
                0.0;
                validator=value -> -1.0 <= value <= 1.0,
                sweep=(-0.25, 0.25),
                description="test-only bias coordinate",
            ),
        ),
        parameter_sets=Dict(
            :sweep => (:gain, :bias),
        ),
        equations=(
            BrainlessLab.EquationSpec(
                :test_output,
                raw"y_t = g x_t + b";
                title="Deterministic test coordinate",
                variables=(
                    :g => "test gain",
                    :b => "test bias",
                ),
            ),
        ),
    )
    register!(registry, node)
    for task_name in (:tracking, :pong)
        register!(registry, task_with_minimum(task_name, 1))
    end
    register!(
        registry,
        :analyses,
        resolve(DEFAULT_REGISTRY.analyses, :heading_error),
    )
    return registry
end

function operation_target(
    id::Symbol,
    task::Symbol;
    parameters=Dict{Symbol,Any}(),
    blocks::Integer=1,
    trials::Integer=1,
    horizon::Integer=2,
    root_seed::Integer=101,
    aggregate::Symbol=:mean,
)
    values = Dict{Symbol,Any}(:gain => 1.0, :bias => 0.0)
    merge!(values, Dict{Symbol,Any}(parameters))
    composition = CompositionSpec(
        Symbol(id, :_composition),
        :test_node,
        task;
        n_nodes=2,
        parameters=values,
    )
    evaluation = EvaluationSpec(
        blocks=blocks,
        trials_per_block=trials,
        horizon=horizon,
        root_seed=root_seed,
        aggregate=aggregate,
    )
    return EvaluationTarget(id, composition, evaluation)
end

end
