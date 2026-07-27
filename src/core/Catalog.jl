_seed_to_int(seed::Integer) = Int(mod(UInt64(seed), UInt64(typemax(Int))))

function _context_seed(context::NodeBuildContext, name::Symbol)
    hasproperty(context.seeds, name) || throw(KeyError(
        "node build context has no :$(name) seed",
    ))
    return _seed_to_int(getproperty(context.seeds, name))
end

function _generic_node_builder(
    id::Symbol,
    constructor;
    model_keyword::Union{Nothing,Symbol}=nothing,
    require_model::Bool=false,
)
    profile_keyword = node_receptor_profile_keyword(id)
    return function (context::NodeBuildContext, values)
        options = Dict{Symbol,Any}(values)
        _normalize_node_options!(id, options)
        if context.model === nothing
            require_model && throw(ArgumentError(
                "node :$(id) requires an explicit node model",
            ))
        else
            model_keyword === nothing && throw(ArgumentError(
                "node :$(id) does not declare how to receive a node model",
            ))
            options[model_keyword] = context.model
        end
        if context.receptor_profile !== nothing
            profile_keyword === nothing && throw(ArgumentError(
                "body requires a receptor profile but node :$(id) does not declare that capability",
            ))
            options[profile_keyword] = context.receptor_profile
        end
        options[:seed] = _context_seed(context, :topology)
        keywords = (; (key => value for (key, value) in options)...)
        reservoir = constructor(
            context.n_nodes,
            n_receptors(context.ports),
            n_effectors(context.ports);
            keywords...,
        )
        reservoir isa Reservoir || throw(ArgumentError(
            "node :$(id) builder returned $(typeof(reservoir)), not Reservoir",
        ))
        return reservoir
    end
end

_node_design_spec(::Any) = nothing

function _generic_registered_node_parameters(id::Symbol, genome)
    if genome === FalandaysParams
        defaults = FalandaysParams()
        return (
            ParameterSpec(
                :lrate_targ,
                defaults.lrate_targ;
                validator=value -> value isa Float64 && isfinite(value) && value >= 0.0,
                description="target-activity adaptation rate",
            ),
            ParameterSpec(
                :learn_on,
                defaults.learn_on;
                validator=value -> value isa Bool,
                description="enable online plasticity",
            ),
        )
    elseif id in (:sorn, :homeostatic_flow_v2)
        return (
            ParameterSpec(
                :learn_on,
                true;
                validator=value -> value isa Bool,
                description="enable online plasticity",
            ),
        )
    end
    return ()
end

function _generic_registered_node_capabilities(id::Symbol, genome, design)
    capabilities = Symbol[]
    if genome === FalandaysParams
        append!(
            capabilities,
            (:spiking, :online_plasticity, :recurrent_weights, :homeostatic_target),
        )
        variant = if id === :falandays_noisy
            (:sensory_noise,)
        elseif id === :falandays_extended
            (:sensory_noise, :small_world_topology, :signed_weights)
        elseif id === :falandays_ablated
            (:clamped_homeostatic_target,)
        elseif id === :falandays_hemispheric
            (:hemispheric_topology,)
        elseif id === :falandays_oosawa
            (:endogenous_drive,)
        elseif id === :falandays_dendritic
            (:dendritic_eligibility,)
        elseif id === :falandays_spatial
            (:spatial_topology,)
        elseif id === :falandays_delayed
            (:spatial_topology, :conduction_delays)
        else
            ()
        end
        append!(capabilities, variant)
    elseif id === :sorn
        append!(
            capabilities,
            (:spiking, :online_plasticity, :recurrent_weights, :intrinsic_plasticity),
        )
    elseif id in (:compartmental_dense, :compartmental_structured)
        append!(capabilities, (:spiking, :recurrent_weights, :compartmental_dynamics))
    elseif id === :null_random
        append!(capabilities, (:spiking, :input_independent_control))
    elseif id === :homeostatic_flow_v2
        append!(
            capabilities,
            (
                :continuous_state,
                :online_plasticity,
                :recurrent_weights,
                :intrinsic_homeostasis,
                :flow_control,
            ),
        )
    end
    design === nothing || push!(capabilities, :model_design)
    node_receptor_profile_keyword(id) === nothing ||
        push!(capabilities, :receptor_profile)
    return Tuple(capabilities)
end

function _falandays_parameters()
    defaults = FalandaysParams()
    nonnegative = value -> value isa Float64 && isfinite(value) && value >= 0.0
    positive = value -> value isa Float64 && isfinite(value) && value > 0.0
    return (
        ParameterSpec(
            :leak,
            defaults.leak;
            validator=value -> value isa Float64 && isfinite(value) && 0.0 <= value <= 1.0,
            sweep=(0.1, 0.25, 0.5, 0.75),
            description="activation retained between updates",
        ),
        ParameterSpec(
            :lrate_wmat,
            defaults.lrate_wmat;
            validator=nonnegative,
            sweep=(0.05, 0.1, 0.35, 1.0),
            description="local recurrent-weight homeostasis rate",
        ),
        ParameterSpec(
            :lrate_targ,
            defaults.lrate_targ;
            validator=nonnegative,
            sweep=(0.001, 0.01, 0.1),
            description="target-activity adaptation rate",
        ),
        ParameterSpec(
            :threshold_mult,
            defaults.threshold_mult;
            validator=positive,
            sweep=(1.5, 2.0, 2.5),
            description="target-to-spike-threshold multiplier",
        ),
        ParameterSpec(
            :targ_min,
            defaults.targ_min;
            validator=positive,
            sweep=(0.5, 1.0, 1.5),
            description="minimum homeostatic target activity",
        ),
        ParameterSpec(
            :input_weight,
            defaults.input_weight;
            validator=nonnegative,
            sweep=(0.75, 1.875, 2.75, 4.0),
            description="sensory input amplitude",
        ),
        ParameterSpec(
            :weight_init_std,
            defaults.weight_init_std;
            validator=nonnegative,
            sweep=(0.25, 0.5, 1.0, 2.0),
            description="initial recurrent-weight scale",
        ),
        ParameterSpec(
            :learn_on,
            defaults.learn_on;
            validator=value -> value isa Bool,
            description="enable online homeostatic plasticity",
        ),
        ParameterSpec(
            :link_p,
            0.1;
            owner=:reservoir,
            validator=value -> value isa Float64 && isfinite(value) && 0.0 <= value <= 1.0,
            sweep=(0.05, 0.1, 0.2, 0.4),
            description="recurrent connection probability",
        ),
        ParameterSpec(
            :weight_init_mode,
            :legacy_normal;
            owner=:reservoir,
            validator=value -> value in (:legacy_normal, :excitatory, :pong_mixed),
            description="initial recurrent-weight sign regime",
        ),
        ParameterSpec(
            :rectify,
            true;
            owner=:reservoir,
            validator=value -> value isa Bool,
            description="rectify activation before thresholding",
        ),
        ParameterSpec(
            :topology,
            :bernoulli;
            owner=:reservoir,
            validator=value -> value in (:bernoulli, :watts_strogatz),
            description="recurrent connectivity family",
        ),
        ParameterSpec(
            :repair_masks,
            true;
            owner=:reservoir,
            validator=value -> value isa Bool,
            description="repair empty input or output masks",
        ),
    )
end

function _falandays_equations()
    return (
        EquationSpec(
            :activation,
            raw"a_n(t)=\lambda a_n(t-1)+\sum_r U_{rn}x_r(t)+\sum_j W_{jn}(t)s_j(t-1)";
            title="Locally driven activation",
            description="Sensory and previous-step recurrent currents update each node locally.",
            variables=(
                :a => "node activation",
                :lambda => "leak coefficient",
                :x => "sensory input",
                :U => "input weight",
                :W => "recurrent weight",
                :s => "previous-step spike",
            ),
        ),
        EquationSpec(
            :weight_homeostasis,
            raw"W_{jn}\leftarrow W_{jn}-\eta_W\,s_j(t-1)\,\frac{a_n(t)-T_n(t)}{k_n}";
            title="Local weight homeostasis",
            variables=(
                :eta_W => "weight-learning rate",
                :T => "target activity",
                :k => "active incoming connections",
            ),
        ),
        EquationSpec(
            :target_homeostasis,
            raw"T_n\leftarrow\max\left(T_n+\eta_T(a_n-T_n),T_{\min}\right)";
            title="Local target adaptation",
            variables=(
                :eta_T => "target-learning rate",
                :T_min => "minimum target activity",
            ),
        ),
    )
end

function _falandays_builder(context::NodeBuildContext, values)
    params = FalandaysParams(
        leak=values[:leak],
        lrate_wmat=values[:lrate_wmat],
        lrate_targ=values[:lrate_targ],
        threshold_mult=values[:threshold_mult],
        targ_min=values[:targ_min],
        input_weight=values[:input_weight],
        weight_init_std=values[:weight_init_std],
        learn_on=values[:learn_on],
    )
    options = Dict{Symbol,Any}(
        :params => params,
        :link_p => values[:link_p],
        :weight_init_mode => values[:weight_init_mode],
        :rectify => values[:rectify],
        :topology => values[:topology],
        :repair_masks => values[:repair_masks],
    )
    context.receptor_profile === nothing ||
        (options[:input_link_p] = context.receptor_profile)
    keywords = (; (key => value for (key, value) in options)...)
    return _falandays_native(
        context.n_nodes,
        n_receptors(context.ports),
        n_effectors(context.ports);
        seed=_context_seed(context, :topology),
        keywords...,
    )
end

function falandays_node_spec()
    return NodeSpec(
        :falandays,
        _falandays_builder;
        genome_type=FalandaysParams,
        stability=:reference,
        tags=(:reference,),
        capabilities=(
            :spiking,
            :online_plasticity,
            :recurrent_weights,
            :homeostatic_target,
            :receptor_profile,
        ),
        parameters=_falandays_parameters(),
        parameter_sets=Dict(
            :sweep => (:leak, :lrate_wmat),
            :connectivity => (:link_p,),
        ),
        equations=_falandays_equations(),
        default_analyses=(
            :branching_ratio_mr,
            :node_target_error,
            :spectral_radius,
            :fano_factor,
            :participation_ratio,
        ),
        metadata=(
            source="Independent Julia reimplementation of Falandays et al. 2024, " *
                   "Cognitive Neurodynamics 18(4) 1811-1834, doi:10.1007/s11571-023-09988-2",
        ),
    )
end

function _generic_registered_node_spec(id::Symbol, constructor)
    genome = try
        genome_type(id)
    catch
        nothing
    end
    design = genome === nothing ? nothing : _node_design_spec(genome)
    capabilities = _generic_registered_node_capabilities(id, genome, design)
    return NodeSpec(
        id,
        _generic_node_builder(
            id,
            constructor;
            model_keyword=design === nothing ? nothing : :genome,
            require_model=design !== nothing,
        );
        genome_type=genome,
        design=design,
        stability=id === :null_random ? :control : :experimental,
        tags=id === :null_random ? (:control,) : (:experimental,),
        capabilities=capabilities,
        parameters=_generic_registered_node_parameters(id, genome),
        metadata=(adapter=:registered_constructor,),
    )
end

function _falandays_reference_composition(task::Symbol)
    config = falandays_paper_config(task)
    return CompositionSpec(
        Symbol("falandays_", task),
        :falandays,
        task;
        n_nodes=config.nnodes,
        parameters=Dict{Symbol,Any}(
            :lrate_wmat => config.lrate_wmat,
            :lrate_targ => config.lrate_targ,
            :input_weight => config.input_amp,
            :weight_init_mode => config.weight_init_mode,
            :rectify => false,
            :topology => :bernoulli,
            :repair_masks => false,
        ),
    )
end

function _with_composition_parameters(
    source::CompositionSpec,
    suffix::Symbol,
    overrides::Pair...,
)
    parameters = copy(source.parameters)
    foreach(override -> (parameters[Symbol(first(override))] = last(override)), overrides)
    return CompositionSpec(
        Symbol(source.id, :__, suffix),
        source.node,
        source.task;
        body=source.body,
        n_agents=source.n_agents,
        n_nodes=source.n_nodes,
        parameters=parameters,
        task_options=copy(source.task_options),
        body_options=copy(source.body_options),
        interaction_cycle=source.interaction_cycle,
    )
end


function _typed_builtin_ablation(id::Symbol)
    id === :freeze_plasticity && return AblationSpec(
        id,
        composition -> _with_composition_parameters(
            composition,
            :freeze_plasticity,
            :learn_on => false,
        );
        required_capabilities=(:online_plasticity,),
        description="Disable online plasticity while preserving the composition.",
    )
    id === :clamp_target && return AblationSpec(
        id,
        composition -> _with_composition_parameters(
            composition,
            :clamp_target,
            :lrate_targ => 0.0,
        );
        required_capabilities=(:homeostatic_target,),
        description="Clamp the homeostatic target by setting its adaptation rate to zero.",
    )
    return nothing
end

function register_builtins!(registry::RegistrySet)
    register!(registry, falandays_node_spec())
    for (id, constructor) in sort!(collect(NODES); by=pair -> string(first(pair)))
        id === :falandays && continue
        register!(registry, _generic_registered_node_spec(id, constructor))
    end

    for (id, task) in sort!(collect(TASKS); by=pair -> string(first(pair)))
        id === :pong_hitrate && continue
        task isa TaskSpec || continue
        register!(registry, task)
    end

    for (id, implementation) in sort!(collect(BODIES); by=pair -> string(first(pair)))
        register!(
            registry,
            :bodies,
            ImplementationSpec(
                id,
                implementation;
                options=body_option_defaults(id),
            ),
        )
    end
    for (id, implementation) in sort!(collect(DRIVES); by=pair -> string(first(pair)))
        register!(registry, :drives, ImplementationSpec(id, implementation))
    end
    for (id, implementation) in sort!(collect(MOTORS); by=pair -> string(first(pair)))
        register!(registry, :motors, ImplementationSpec(id, implementation))
    end
    for (id, implementation) in sort!(collect(SENSORS); by=pair -> string(first(pair)))
        register!(registry, :sensors, ImplementationSpec(id, implementation))
    end
    for (id, implementation) in sort!(collect(METRICS); by=pair -> string(first(pair)))
        register!(registry, :metrics, ImplementationSpec(id, implementation))
    end
    for (id, entry) in sort!(collect(ANALYSES); by=pair -> string(first(pair)))
        register!(
            registry,
            :analyses,
            ImplementationSpec(
                id,
                entry.f;
                label=entry.label,
                metadata=(task=entry.task,),
            ),
        )
    end
    for (id, implementation) in sort!(collect(VIEWS); by=pair -> string(first(pair)))
        register!(registry, :views, ImplementationSpec(id, implementation))
    end
    for spec in Evolution.builtin_strategy_specs()
        register!(registry, spec)
    end
    for (id, implementation) in sort!(collect(ABLATIONS); by=pair -> string(first(pair)))
        typed = _typed_builtin_ablation(id)
        register!(
            registry,
            :ablations,
            ImplementationSpec(id, typed === nothing ? implementation : typed),
        )
    end

    for task in (:wall, :tracking, :pong)
        register_default!(registry, _falandays_reference_composition(task))
    end
    return registry
end

const DEFAULT_REGISTRY = RegistrySet()

Evolution.search_strategy(id::Union{Symbol,AbstractString}) =
    Evolution.search_strategy(DEFAULT_REGISTRY, id)

Evolution.search_strategies() =
    Evolution.search_strategies(DEFAULT_REGISTRY)
