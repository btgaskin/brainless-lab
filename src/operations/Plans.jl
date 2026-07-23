abstract type AbstractOperationPlan end
abstract type AbstractResolvedOperationPlan end
abstract type AbstractOperationResult end

"""One named composition plus its complete outer evaluation protocol."""
struct EvaluationTarget{C<:CompositionSpec,E<:EvaluationSpec}
    id::Symbol
    composition::C
    evaluation::E

    function EvaluationTarget(
        id::Union{Symbol,AbstractString},
        composition::C,
        evaluation::E,
    ) where {C<:CompositionSpec,E<:EvaluationSpec}
        id_ = _nonempty_symbol(id, "evaluation target id")
        return new{C,E}(id_, composition, evaluation)
    end
end

struct ProfilePlan{T<:EvaluationTarget} <: AbstractOperationPlan
    id::Symbol
    target::T
    analyses::Tuple{Vararg{Symbol}}
    record_every::Int
end

function ProfilePlan(
    id::Union{Symbol,AbstractString},
    target::EvaluationTarget;
    analyses=(),
    record_every::Integer=1,
)
    id_ = _nonempty_symbol(id, "profile plan id")
    analyses_ = _symbol_tuple(analyses, "profile analyses")
    every = Int(record_every)
    every > 0 || throw(ArgumentError("profile record_every must be positive"))
    return ProfilePlan(id_, target, analyses_, every)
end

struct SweepAxis{V<:Tuple}
    parameter::Symbol
    values::V

    function SweepAxis{V}(parameter::Symbol, values::V) where {V<:Tuple}
        isempty(values) && throw(ArgumentError("sweep axis :$(parameter) must not be empty"))
        length(unique(values)) == length(values) || throw(ArgumentError(
            "sweep axis :$(parameter) values must be unique",
        ))
        return new{V}(parameter, values)
    end
end

function SweepAxis(parameter::Union{Symbol,AbstractString}, values)
    parameter_ = _nonempty_symbol(parameter, "sweep parameter")
    values_ = Tuple(values)
    isempty(values_) && throw(ArgumentError("sweep axis :$(parameter_) must not be empty"))
    length(unique(values_)) == length(values_) || throw(ArgumentError(
        "sweep axis :$(parameter_) values must be unique",
    ))
    return SweepAxis{typeof(values_)}(parameter_, values_)
end

struct SweepPlan{T<:EvaluationTarget,A<:Tuple} <: AbstractOperationPlan
    id::Symbol
    target::T
    axes::A
    mode::Symbol
    max_rollouts::Int
end

function SweepPlan(
    id::Union{Symbol,AbstractString},
    target::EvaluationTarget;
    axes=(),
    mode::Symbol=:factorial,
    max_rollouts::Integer=10_000,
)
    id_ = _nonempty_symbol(id, "sweep plan id")
    axes_ = Tuple(axes)
    all(axis -> axis isa SweepAxis, axes_) || throw(ArgumentError(
        "sweep axes must all be SweepAxis values",
    ))
    names = Tuple(axis.parameter for axis in axes_)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "sweep axis parameters must be unique",
    ))
    mode in (:factorial, :one_at_a_time) || throw(ArgumentError(
        "sweep mode must be :factorial or :one_at_a_time",
    ))
    limit = Int(max_rollouts)
    limit > 0 || throw(ArgumentError("sweep max_rollouts must be positive"))
    return SweepPlan(id_, target, axes_, mode, limit)
end

"""A registered causal intervention, with explicit applicability metadata."""
struct AblationSpec{A,M}
    id::Symbol
    apply::A
    stage::Symbol
    required_capabilities::Tuple{Vararg{Symbol}}
    description::String
    metadata::M
end

function AblationSpec(
    id::Union{Symbol,AbstractString},
    apply;
    stage::Symbol=:composition,
    required_capabilities=(),
    description::AbstractString="",
    metadata::NamedTuple=NamedTuple(),
)
    id_ = _nonempty_symbol(id, "ablation id")
    stage in (:composition, :reservoir, :task) || throw(ArgumentError(
        "ablation :$(id_) stage must be :composition, :reservoir, or :task",
    ))
    capabilities = _symbol_tuple(required_capabilities, "ablation capabilities")
    return AblationSpec{typeof(apply),typeof(metadata)}(
        id_,
        apply,
        stage,
        capabilities,
        String(description),
        metadata,
    )
end

struct AblationPlan{T<:EvaluationTarget,A<:Tuple} <: AbstractOperationPlan
    id::Symbol
    target::T
    ablations::A
end


function AblationPlan(
    id::Union{Symbol,AbstractString},
    target::EvaluationTarget;
    ablations,
)
    id_ = _nonempty_symbol(id, "ablation plan id")
    ablations_ = _symbol_tuple(ablations, "ablation cases")
    isempty(ablations_) && throw(ArgumentError("ablation plan requires at least one case"))
    return AblationPlan(id_, target, ablations_)
end

struct EvolutionPlan{T<:EvaluationTarget,H<:Tuple} <: AbstractOperationPlan
    id::Symbol
    training::T
    heldout_targets::H
    optimizer::Symbol
    parameter_set::Symbol
    objective::Symbol
    generations::Int
    popsize::Int
    sigma0::Float64
end

function EvolutionPlan(
    id::Union{Symbol,AbstractString},
    training::EvaluationTarget;
    heldout_targets=(),
    optimizer::Union{Symbol,AbstractString}=:sepcma,
    parameter_set::Union{Symbol,AbstractString}=:evolve,
    objective::Union{Symbol,AbstractString}=:normalized_score,
    generations::Integer=50,
    popsize::Integer=64,
    sigma0::Real=0.5,
)
    id_ = _nonempty_symbol(id, "evolution plan id")
    heldout = Tuple(heldout_targets)
    all(target -> target isa EvaluationTarget, heldout) || throw(ArgumentError(
        "heldout_targets must all be EvaluationTarget values",
    ))
    generations_ = Int(generations)
    popsize_ = Int(popsize)
    sigma = Float64(sigma0)
    generations_ > 0 || throw(ArgumentError("evolution generations must be positive"))
    popsize_ >= 2 || throw(ArgumentError("evolution popsize must be at least 2"))
    isfinite(sigma) && sigma > 0 || throw(ArgumentError(
        "evolution sigma0 must be finite and positive",
    ))
    return EvolutionPlan(
        id_,
        training,
        heldout,
        _nonempty_symbol(optimizer, "evolution optimizer"),
        _nonempty_symbol(parameter_set, "evolution parameter set"),
        _nonempty_symbol(objective, "evolution objective"),
        generations_,
        popsize_,
        sigma,
    )
end

struct BenchmarkCasePlan{C<:Tuple}
    id::Symbol
    conditions::C
    baseline::Symbol
end

function BenchmarkCasePlan(
    id::Union{Symbol,AbstractString},
    conditions;
    baseline::Union{Symbol,AbstractString},
)
    id_ = _nonempty_symbol(id, "benchmark case id")
    conditions_ = Tuple(conditions)
    isempty(conditions_) && throw(ArgumentError("benchmark case requires conditions"))
    all(condition -> condition isa EvaluationTarget, conditions_) || throw(ArgumentError(
        "benchmark conditions must all be EvaluationTarget values",
    ))
    names = Tuple(condition.id for condition in conditions_)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "benchmark condition ids must be unique within a case",
    ))
    baseline_ = Symbol(baseline)
    baseline_ in names || throw(ArgumentError(
        "benchmark baseline :$(baseline_) is not a condition in case :$(id_)",
    ))
    return BenchmarkCasePlan(id_, conditions_, baseline_)
end

struct BenchmarkPlan{C<:Tuple} <: AbstractOperationPlan
    id::Symbol
    cases::C
end

function BenchmarkPlan(id::Union{Symbol,AbstractString}, cases)
    id_ = _nonempty_symbol(id, "benchmark plan id")
    cases_ = Tuple(cases)
    isempty(cases_) && throw(ArgumentError("benchmark plan requires at least one case"))
    all(case -> case isa BenchmarkCasePlan, cases_) || throw(ArgumentError(
        "benchmark cases must all be BenchmarkCasePlan values",
    ))
    names = Tuple(case.id for case in cases_)
    length(unique(names)) == length(names) || throw(ArgumentError(
        "benchmark case ids must be unique",
    ))
    return BenchmarkPlan(id_, cases_)
end

const EXPERIMENT_EVIDENCE_STATES = (
    :exploratory,
    :tuned,
    :frozen,
    :confirmed,
    :promoted,
    :retired,
)

"""A citable scientific protocol composed from named conditions and operations."""
struct ExperimentSpec{C<:Tuple,O<:Tuple,M}
    id::Symbol
    version::VersionNumber
    title::String
    question::String
    conditions::C
    operations::O
    evidence_state::Symbol
    limitations::Tuple{Vararg{String}}
    metadata::M
end

function ExperimentSpec(
    id::Union{Symbol,AbstractString},
    version::VersionNumber;
    title::AbstractString,
    question::AbstractString,
    conditions,
    operations,
    evidence_state::Symbol=:exploratory,
    limitations=(),
    metadata::NamedTuple=NamedTuple(),
)
    id_ = _nonempty_symbol(id, "experiment id")
    isempty(strip(title)) && throw(ArgumentError("experiment title must not be empty"))
    isempty(strip(question)) && throw(ArgumentError("experiment question must not be empty"))
    conditions_ = Tuple(conditions)
    operations_ = Tuple(operations)
    isempty(conditions_) && throw(ArgumentError("experiment requires named conditions"))
    isempty(operations_) && throw(ArgumentError("experiment requires operations"))
    all(condition -> condition isa EvaluationTarget, conditions_) || throw(ArgumentError(
        "experiment conditions must all be EvaluationTarget values",
    ))
    all(operation -> operation isa AbstractOperationPlan, operations_) || throw(ArgumentError(
        "experiment operations must all be operation plans",
    ))
    condition_ids = Tuple(condition.id for condition in conditions_)
    length(unique(condition_ids)) == length(condition_ids) || throw(ArgumentError(
        "experiment condition ids must be unique",
    ))
    evidence_state in EXPERIMENT_EVIDENCE_STATES || throw(ArgumentError(
        "invalid experiment evidence_state :$(evidence_state)",
    ))
    limitations_ = Tuple(String(limitation) for limitation in limitations)
    return ExperimentSpec{
        typeof(conditions_),
        typeof(operations_),
        typeof(metadata),
    }(
        id_,
        version,
        String(title),
        String(question),
        conditions_,
        operations_,
        evidence_state,
        limitations_,
        metadata,
    )
end

"""Validate a cold operation plan against one explicit registry set."""
validate(plan::AbstractOperationPlan, registry::RegistrySet) = plan

"""Resolve registry names and defaults without executing simulations."""
resolve(plan::AbstractOperationPlan, registry::RegistrySet) = throw(MethodError(resolve, (plan, registry)))

"""Execute an already-resolved operation plan."""
execute(plan::AbstractResolvedOperationPlan) = throw(MethodError(execute, (plan,)))

"""Return authoritative named tables for a typed operation result."""
tables(result::AbstractOperationResult) = throw(MethodError(tables, (result,)))

"""Return the compact derived summary for a typed operation result."""
summary(result::AbstractOperationResult) = throw(MethodError(summary, (result,)))
