const BENCHMARK_SPEC_STATES = (:planned, :frozen)

"""One fixed, task-independent model assembly admitted to a benchmark."""
struct ModelProfileSpec{M<:NamedTuple}
    id::Symbol
    node::Symbol
    label::String
    n_nodes::Int
    parameters::Dict{Symbol,Any}
    mechanism::String
    provenance::Tuple{Vararg{String}}
    limitations::Tuple{Vararg{String}}
    metadata::M
    model::Union{Nothing,Evolution.ModelReference}
end

function ModelProfileSpec(
    id::Union{Symbol,AbstractString},
    node::Union{Symbol,AbstractString};
    label::AbstractString=string(id),
    n_nodes::Integer,
    parameters,
    mechanism::AbstractString,
    provenance=(),
    limitations=(),
    metadata::NamedTuple=NamedTuple(),
    model::Union{Nothing,Evolution.ModelReference}=nothing,
)
    id_ = _nonempty_symbol(id, "model profile id")
    node_ = _nonempty_symbol(node, "model profile node")
    count = Int(n_nodes)
    count > 0 || throw(ArgumentError("model profile :$(id_) requires positive n_nodes"))
    isempty(strip(label)) && throw(ArgumentError("model profile label must not be empty"))
    isempty(strip(mechanism)) && throw(ArgumentError(
        "model profile :$(id_) requires a mechanism description",
    ))
    return ModelProfileSpec{typeof(metadata)}(
        id_,
        node_,
        String(label),
        count,
        Dict{Symbol,Any}(Symbol(key) => deepcopy(value) for (key, value) in pairs(parameters)),
        String(mechanism),
        Tuple(String(value) for value in provenance),
        Tuple(String(value) for value in limitations),
        metadata,
        model,
    )
end

"""Development and untouched confirmation protocols for one benchmark task."""
struct BenchmarkTaskProtocol
    task::Symbol
    development::EvaluationSpec
    confirmation::EvaluationSpec
    task_options::Dict{Symbol,Any}
end

BenchmarkTaskProtocol(task::Symbol, development::EvaluationSpec, confirmation::EvaluationSpec) =
    BenchmarkTaskProtocol(task; development, confirmation)

function BenchmarkTaskProtocol(
    task::Union{Symbol,AbstractString};
    development::EvaluationSpec,
    confirmation::EvaluationSpec,
    task_options=Dict{Symbol,Any}(),
)
    task_ = _nonempty_symbol(task, "benchmark task")
    for (stage, evaluation) in (
        (:development, development),
        (:confirmation, confirmation),
    )
        evaluation.trials_per_block == 1 || throw(ArgumentError(
            "benchmark $(stage) protocol for :$(task_) must use one trial per independent block",
        ))
        evaluation.construction_scope === :trial || throw(ArgumentError(
            "benchmark $(stage) protocol for :$(task_) must construct one fresh reservoir per block",
        ))
        evaluation.reset === :full || throw(ArgumentError(
            "benchmark $(stage) protocol for :$(task_) must use reset=:full",
        ))
        evaluation.aggregate === :mean || throw(ArgumentError(
            "benchmark $(stage) protocol for :$(task_) must use aggregate=:mean",
        ))
    end
    development.root_seed != confirmation.root_seed || throw(ArgumentError(
        "benchmark task :$(task_) must keep development and confirmation seeds disjoint",
    ))
    return BenchmarkTaskProtocol(task_, development, confirmation,
        Dict{Symbol,Any}(Symbol(k) => deepcopy(v) for (k, v) in pairs(task_options)))
end

"""One model-task cell, with only the generic input gain left task-specific."""
struct BenchmarkEntrySpec
    profile::Symbol
    task::Symbol
    input_gain::Union{Nothing,Float64}
end

function BenchmarkEntrySpec(
    profile::Union{Symbol,AbstractString},
    task::Union{Symbol,AbstractString};
    input_gain=nothing,
)
    gain = input_gain === nothing ? nothing : InterfaceSpec(input_gain=input_gain).input_gain
    return BenchmarkEntrySpec(
        _nonempty_symbol(profile, "benchmark entry profile"),
        _nonempty_symbol(task, "benchmark entry task"),
        gain,
    )
end

"""
Versioned direct-control benchmark definition.

The task harness and model profiles are fixed. Development may select only
`InterfaceSpec.input_gain`; confirmation requires every entry to have one
selected value.
"""
struct BenchmarkSpec{P<:Tuple,T<:Tuple,E<:Tuple,G<:Tuple}
    id::Symbol
    version::VersionNumber
    title::String
    n_nodes::Int
    profiles::P
    task_protocols::T
    entries::E
    gain_grid::G
    baseline_profile::Symbol
    state::Symbol
    limitations::Tuple{Vararg{String}}
end

function BenchmarkSpec(
    id::Union{Symbol,AbstractString},
    version::VersionNumber;
    title::AbstractString,
    n_nodes::Integer,
    profiles,
    task_protocols,
    entries,
    gain_grid,
    baseline_profile::Union{Symbol,AbstractString},
    state::Symbol=:planned,
    limitations=(),
)
    id_ = _nonempty_symbol(id, "benchmark spec id")
    count = Int(n_nodes)
    count > 0 || throw(ArgumentError("benchmark spec requires positive n_nodes"))
    state in BENCHMARK_SPEC_STATES || throw(ArgumentError(
        "benchmark state must be :planned or :frozen",
    ))
    profiles_ = Tuple(profiles)
    protocols_ = Tuple(task_protocols)
    entries_ = Tuple(entries)
    gains = Tuple(InterfaceSpec(input_gain=value).input_gain for value in gain_grid)
    isempty(profiles_) && throw(ArgumentError("benchmark spec requires model profiles"))
    isempty(protocols_) && throw(ArgumentError("benchmark spec requires task protocols"))
    isempty(entries_) && throw(ArgumentError("benchmark spec requires entries"))
    isempty(gains) && throw(ArgumentError("benchmark gain grid must not be empty"))
    length(unique(gains)) == length(gains) || throw(ArgumentError(
        "benchmark gain grid values must be unique",
    ))
    profile_ids = Tuple(profile.id for profile in profiles_)
    task_ids = Tuple(protocol.task for protocol in protocols_)
    length(unique(profile_ids)) == length(profile_ids) || throw(ArgumentError(
        "benchmark model profile ids must be unique",
    ))
    length(unique(task_ids)) == length(task_ids) || throw(ArgumentError(
        "benchmark task ids must be unique",
    ))
    all(profile -> profile.n_nodes == count, profiles_) || throw(ArgumentError(
        "every benchmark model profile must use exactly $(count) dynamic nodes",
    ))
    baseline = Symbol(baseline_profile)
    baseline in profile_ids || throw(ArgumentError(
        "benchmark baseline profile :$(baseline) is not declared",
    ))
    cells = Tuple((entry.profile, entry.task) for entry in entries_)
    length(unique(cells)) == length(cells) || throw(ArgumentError(
        "benchmark profile-task entries must be unique",
    ))
    expected = Set((profile, task) for profile in profile_ids for task in task_ids)
    Set(cells) == expected || throw(ArgumentError(
        "benchmark entries must cover every declared profile-task cell exactly once",
    ))
    all(entry -> entry.profile in profile_ids && entry.task in task_ids, entries_) ||
        throw(ArgumentError("benchmark entry references an undeclared profile or task"))
    state === :frozen && any(entry -> entry.input_gain === nothing, entries_) &&
        throw(ArgumentError("frozen benchmark entries require selected input gains"))
    return BenchmarkSpec{
        typeof(profiles_),
        typeof(protocols_),
        typeof(entries_),
        typeof(gains),
    }(
        id_,
        version,
        String(title),
        count,
        profiles_,
        protocols_,
        entries_,
        gains,
        baseline,
        state,
        Tuple(String(value) for value in limitations),
    )
end

const ModelProfileRegistry = Registry{Symbol,ModelProfileSpec}
const DEFAULT_MODEL_PROFILES = ModelProfileRegistry(:model_profiles)

register_model_profile!(
    profile::ModelProfileSpec;
    registry::ModelProfileRegistry=DEFAULT_MODEL_PROFILES,
) = register!(registry, profile.id, profile)

model_profile(
    id::Union{Symbol,AbstractString};
    registry::ModelProfileRegistry=DEFAULT_MODEL_PROFILES,
) = resolve(registry, Symbol(id))

model_profiles(registry::ModelProfileRegistry=DEFAULT_MODEL_PROFILES) =
    sort!(collect(keys(registry)); by=string)

_benchmark_profile(spec::BenchmarkSpec, id::Symbol) =
    only(profile for profile in spec.profiles if profile.id === id)

_benchmark_protocol(spec::BenchmarkSpec, task::Symbol) =
    only(protocol for protocol in spec.task_protocols if protocol.task === task)

function _benchmark_composition(profile::ModelProfileSpec, task::Symbol, input_gain::Real;
    task_options=Dict{Symbol,Any}())
    return CompositionSpec(
        Symbol(task, :__, profile.id),
        profile.node,
        task;
        n_nodes=profile.n_nodes,
        parameters=copy(profile.parameters),
        interface=InterfaceSpec(input_gain=input_gain),
        task_options=deepcopy(task_options),
    )
end

"""Generate ordinary development sweeps for every benchmark cell."""
function calibration_plans(spec::BenchmarkSpec)
    plans = SweepPlan[]
    for entry in spec.entries
        profile = _benchmark_profile(spec, entry.profile)
        protocol = _benchmark_protocol(spec, entry.task)
        composition = _benchmark_composition(profile, entry.task, 1.0; task_options=protocol.task_options)
        target = EvaluationTarget(
            Symbol(entry.task, :__, entry.profile, :__development),
            composition,
            protocol.development;
            topology_key=profile.id,
            model=profile.model,
        )
        push!(plans, SweepPlan(
            Symbol(spec.id, :__, entry.task, :__, entry.profile, :__input_gain),
            target;
            axes=(SweepAxis(:input_gain, spec.gain_grid; scope=:interface),),
            mode=:factorial,
            max_rollouts=length(spec.gain_grid) * protocol.development.blocks,
        ))
    end
    return Tuple(plans)
end

"""Freeze selected gains without changing any model-profile coordinate."""
function freeze_benchmark(spec::BenchmarkSpec, selections)
    spec.state === :planned || throw(ArgumentError(
        "benchmark :$(spec.id) is already frozen; create a new version to change selections",
    ))
    selected = Dict{Tuple{Symbol,Symbol},Float64}(
        (Symbol(first(key)), Symbol(last(key))) => InterfaceSpec(input_gain=value).input_gain
        for (key, value) in pairs(selections)
    )
    expected = Set((entry.profile, entry.task) for entry in spec.entries)
    Set(keys(selected)) == expected || throw(ArgumentError(
        "benchmark gain selections must cover every profile-task entry",
    ))
    all(gain -> gain in spec.gain_grid, values(selected)) || throw(ArgumentError(
        "benchmark gain selections must come from the declared development grid",
    ))
    entries = Tuple(BenchmarkEntrySpec(
        entry.profile,
        entry.task;
        input_gain=selected[(entry.profile, entry.task)],
    ) for entry in spec.entries)
    return BenchmarkSpec(
        spec.id,
        spec.version;
        title=spec.title,
        n_nodes=spec.n_nodes,
        profiles=spec.profiles,
        task_protocols=spec.task_protocols,
        entries,
        gain_grid=spec.gain_grid,
        baseline_profile=spec.baseline_profile,
        state=:frozen,
        limitations=spec.limitations,
    )
end

function _select_profile_candidate(candidates)
    isempty(candidates) && throw(ArgumentError("input-gain sweep has no cells"))
    directions = unique([value.profile_direction for value in candidates])
    length(directions) == 1 || throw(ArgumentError(
        "input-gain sweep mixes benchmark-profile directions",
    ))
    direction = only(directions)
    order(value) = direction === :lower ?
        (value.profile_value, value.gain) :
        (-value.profile_value, value.gain)
    return first(sort(collect(candidates); by=order))
end

"""Select the best declared benchmark-profile coordinate; exact ties use the smaller gain."""
function select_input_gain(result::SweepResult)
    axes = result.plan.axes
    length(axes) == 1 || throw(ArgumentError(
        "input-gain selection requires exactly one sweep axis",
    ))
    axis = only(axes)
    axis.scope === :interface && axis.parameter === :input_gain || throw(ArgumentError(
        "input-gain selection requires an interface :input_gain axis",
    ))
    candidates = Tuple(begin
        values = Dict(row.parameters)
        score = row.profile_value
        ismissing(score) && throw(ArgumentError(
            "input-gain selection requires a declared benchmark-profile value",
        ))
        profile_value = Float64(score)
        isfinite(profile_value) || throw(ArgumentError(
            "input-gain selection cannot use a non-finite benchmark-profile value",
        ))
        direction = row.profile_direction
        direction in (:lower, :higher) || throw(ArgumentError(
            "input-gain selection requires profile direction :lower or :higher",
        ))
        (
            gain=Float64(values[:input_gain]),
            profile_metric=row.profile_metric,
            profile_value,
            profile_label=row.profile_label,
            profile_unit=row.profile_unit,
            profile_direction=direction,
            raw_score=ismissing(row.raw_score) ? missing : Float64(row.raw_score),
            cell=row.cell,
        )
    end for row in result.cell_summaries)
    return _select_profile_candidate(candidates)
end

"""Generate the ordinary paired confirmation `BenchmarkPlan`."""
function benchmark_plan(spec::BenchmarkSpec)
    spec.state === :frozen || throw(ArgumentError(
        "benchmark :$(spec.id) must be frozen after development before confirmation",
    ))
    cases = BenchmarkCasePlan[]
    for protocol in spec.task_protocols
        entries = Tuple(entry for entry in spec.entries if entry.task === protocol.task)
        conditions = Tuple(begin
            profile = _benchmark_profile(spec, entry.profile)
            composition = _benchmark_composition(profile, entry.task, something(entry.input_gain);
                task_options=protocol.task_options)
            EvaluationTarget(
                Symbol(entry.task, :__, entry.profile),
                composition,
                protocol.confirmation;
                topology_key=profile.id,
                model=profile.model,
            )
        end for entry in entries)
        baseline = Symbol(protocol.task, :__, spec.baseline_profile)
        push!(cases, BenchmarkCasePlan(protocol.task, conditions; baseline))
    end
    return BenchmarkPlan(Symbol(spec.id, :__v, spec.version.major), Tuple(cases))
end

const DIRECT_CONTROL_GAIN_GRID = (0.125, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0)

const DIRECT_CONTROL_FALANDAYS_PROFILE = ModelProfileSpec(
    :falandays_direct_v1,
    :falandays;
    label="Falandays",
    n_nodes=200,
    parameters=Dict(
        :leak => 0.25,
        :lrate_wmat => 1.0,
        :lrate_targ => 0.01,
        :threshold_mult => 2.0,
        :targ_min => 1.0,
        :input_weight => 1.875,
        :weight_init_std => 1.0,
        :learn_on => true,
        :link_p => 0.1,
        :weight_init_mode => :excitatory,
        :rectify => false,
        :topology => :bernoulli,
        :repair_masks => false,
    ),
    mechanism="Canonical local Falandays dynamics with one fixed cross-task random-network policy.",
    provenance=("Falandays et al. 2024; BrainlessLab reference-trajectory fixtures",),
    limitations=("Benchmark membership does not extend the reference-trajectory validation boundary.",),
    metadata=(output_adapter=:seeded_direct_mask,),
)

const DIRECT_CONTROL_SORN_PROFILE = ModelProfileSpec(
    :sorn_direct_v1,
    :sorn;
    label="SORN",
    n_nodes=200,
    parameters=Dict(
        :inhibitory_fraction => 0.2,
        :p_ee => 10.0 / 166.0,
        :p_ei => 1.0,
        :p_ie => 1.0,
        :p_input => 0.05,
        :p_output => 0.05,
        :ee_row_sum => 1.0,
        :ei_row_sum => 1.0,
        :ie_row_sum => 1.0,
        :input_row_sum => 1.0,
        :T_E_max => 0.5,
        :T_I_max => 1.0,
        :eta_stdp => 0.001,
        :eta_ip => 0.001,
        :H_ip => 0.1,
        :learn_on => true,
    ),
    mechanism="Binary excitatory/inhibitory SORN with causal STDP, synaptic normalisation, and intrinsic plasticity.",
    provenance=(
        "Lazar, Pipa, and Triesch 2009, doi:10.3389/neuro.10.023.2009",
        "heychristoph/SORN commit 1d0ea64108a38ece3eaa5b192a6c5f916f8ed2d6",
        "delpapa/SORN_V2 commit 40b42c3810345460636fe14785a4d74aa0c12f87",
    ),
    limitations=(
        "No original authors' Matlab oracle was recovered.",
        "Continuous task receptors use seeded 5% excitatory input pools rather than the paper's disjoint symbol groups.",
        "The seeded direct-action output mask is a BrainlessLab adapter, not the paper's fitted linear readout.",
    ),
    metadata=(population=(excitatory=167, inhibitory=33), output_adapter=:seeded_excitatory_mean),
)

function _direct_control_protocol(task::Symbol, development_seed::Int, confirmation_seed::Int)
    horizon, warmup = task === :cartpole_plank_easy ? (15_000, 0) : (7_200, 1_200)
    return BenchmarkTaskProtocol(
        task;
        development=EvaluationSpec(
            blocks=16,
            trials_per_block=1,
            horizon=horizon,
            warmup=warmup,
            construction_scope=:trial,
            reset=:full,
            root_seed=development_seed,
            aggregate=:mean,
        ),
        confirmation=EvaluationSpec(
            blocks=32,
            trials_per_block=1,
            horizon=horizon,
            warmup=warmup,
            construction_scope=:trial,
            reset=:full,
            root_seed=confirmation_seed,
            aggregate=:mean,
        ),
    )
end

const _DIRECT_CONTROL_BENCHMARK_DEVELOPMENT = BenchmarkSpec(
    :direct_control,
    v"1.0.0";
    title="Falandays and SORN direct-control benchmark",
    n_nodes=200,
    profiles=(DIRECT_CONTROL_FALANDAYS_PROFILE, DIRECT_CONTROL_SORN_PROFILE),
    task_protocols=(
        _direct_control_protocol(:tracking, 71_001, 81_001),
        _direct_control_protocol(:pong, 72_001, 82_001),
        _direct_control_protocol(:cartpole_plank_easy, 73_001, 83_001),
    ),
    entries=Tuple(
        BenchmarkEntrySpec(profile.id, task)
        for task in (:tracking, :pong, :cartpole_plank_easy)
        for profile in (DIRECT_CONTROL_FALANDAYS_PROFILE, DIRECT_CONTROL_SORN_PROFILE)
    ),
    gain_grid=DIRECT_CONTROL_GAIN_GRID,
    baseline_profile=:falandays_direct_v1,
    state=:planned,
    limitations=(
        "Tasks remain separate; there is no cross-task aggregate.",
        "Only input gain is selected per model-task cell.",
        "The profiles include different fixed input and output pool policies; contrasts do not isolate the neuronal update rule.",
        "The benchmark measures untrained random-assembly direct control, not a fitted or reward-trained controller.",
        "CartPole uses 32 one-episode confirmation blocks, not the source repository's 1,000-episode protocol.",
    ),
)

"""The six development-selected interface gains frozen for direct-control v1."""
const DIRECT_CONTROL_INPUT_GAINS = (
    (profile=:falandays_direct_v1, task=:tracking, input_gain=1.0),
    (profile=:sorn_direct_v1, task=:tracking, input_gain=4.0),
    (profile=:falandays_direct_v1, task=:pong, input_gain=1.0),
    (profile=:sorn_direct_v1, task=:pong, input_gain=32.0),
    (profile=:falandays_direct_v1, task=:cartpole_plank_easy, input_gain=8.0),
    (profile=:sorn_direct_v1, task=:cartpole_plank_easy, input_gain=8.0),
)

const DIRECT_CONTROL_BENCHMARK = freeze_benchmark(
    _DIRECT_CONTROL_BENCHMARK_DEVELOPMENT,
    Dict(
        (selection.profile, selection.task) => selection.input_gain
        for selection in DIRECT_CONTROL_INPUT_GAINS
    ),
)

function _direct_control_experiment(spec::BenchmarkSpec)
    plan = benchmark_plan(spec)
    conditions = Tuple(
        condition
        for case in plan.cases
        for condition in case.conditions
    )
    return ExperimentSpec(
        spec.id,
        spec.version;
        title=spec.title,
        question="How do the frozen Falandays and SORN profiles compare on each declared direct-control task?",
        conditions,
        operations=(plan,),
        evidence_state=:frozen,
        limitations=spec.limitations,
        metadata=(
            programme=:core_benchmark,
            selection=:development_input_gain_only,
            n_nodes=spec.n_nodes,
        ),
    )
end

"""The frozen, untouched-confirmation experiment for direct-control v1."""
const DIRECT_CONTROL_EXPERIMENT = _direct_control_experiment(DIRECT_CONTROL_BENCHMARK)

"""Four-task v2 protocol. Gains are frozen; v2 confirmation has not been collected."""
const DIRECT_CONTROL_BENCHMARK_V2 = BenchmarkSpec(
    :direct_control, v"2.0.0";
    title="Four-task direct-control benchmark",
    n_nodes=200,
    profiles=DIRECT_CONTROL_BENCHMARK.profiles,
    task_protocols=(
        _direct_control_protocol(:tracking, 71_001, 951_001),
        _direct_control_protocol(:pong, 72_001, 952_001),
        _direct_control_protocol(:cartpole_plank_easy, 73_001, 953_001),
        BenchmarkTaskProtocol(:delayed_cue;
            development=EvaluationSpec(blocks=64, horizon=144, root_seed=942_001),
            confirmation=EvaluationSpec(blocks=512, horizon=144, root_seed=954_001)),
    ),
    entries=(DIRECT_CONTROL_BENCHMARK.entries...,
        BenchmarkEntrySpec(:falandays_direct_v1, :delayed_cue; input_gain=0.125),
        BenchmarkEntrySpec(:sorn_direct_v1, :delayed_cue; input_gain=1.0)),
    gain_grid=DIRECT_CONTROL_GAIN_GRID,
    baseline_profile=DIRECT_CONTROL_BENCHMARK.baseline_profile,
    state=:frozen,
    limitations=(DIRECT_CONTROL_BENCHMARK.limitations...,
        "Delayed-cue development pilots are near chance; admission establishes task utility, not model success.",
        "All v2 confirmation blocks remain pending; v1 results are not v2 observations."),
)

const DIRECT_CONTROL_EXPERIMENT_V2 = _direct_control_experiment(DIRECT_CONTROL_BENCHMARK_V2)

"""Build one shared-design target per versioned task, without task-specific model parameters."""
function benchmark_evolution_targets(spec::BenchmarkSpec, node::Symbol;
    root_seed::Integer, blocks::Integer=2, parameters=Dict{Symbol,Any}(), input_gain::Real=1.0)
    return Tuple(EvaluationTarget(Symbol(protocol.task, :__shared_design),
        CompositionSpec(Symbol(protocol.task, :__shared_design), node, protocol.task;
            n_nodes=spec.n_nodes, parameters=copy(parameters), interface=InterfaceSpec(; input_gain),
            task_options=deepcopy(protocol.task_options)),
        EvaluationSpec(; blocks, horizon=protocol.development.horizon,
            warmup=protocol.development.warmup, root_seed=root_seed + 1000 * index);
        topology_key=node)
        for (index, protocol) in enumerate(spec.task_protocols))
end

function register_builtin_model_profiles!()
    isempty(DEFAULT_MODEL_PROFILES) || return DEFAULT_MODEL_PROFILES
    register_model_profile!(DIRECT_CONTROL_FALANDAYS_PROFILE)
    register_model_profile!(DIRECT_CONTROL_SORN_PROFILE)
    return DEFAULT_MODEL_PROFILES
end
