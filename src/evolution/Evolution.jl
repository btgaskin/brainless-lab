module Evolution

using Random
using ..BrainlessLab: NodeModel

export DesignBlock,
    NodeDesignSpec,
    ModelReference,
    NormalInitialisation,
    RunConfig,
    SearchStrategySpec,
    CandidateProposal,
    Observation,
    AbstractSearchState,
    encode,
    decode,
    search_strategy,
    search_strategies,
    builtin_strategy_specs,
    sepcma_spec,
    nsga2_spec,
    cmame_spec,
    validate_strategy,
    model_reference_document,
    parse_model_reference,
    run_config_document,
    parse_run_config,
    initialise,
    propose!,
    observe!,
    outcome,
    snapshot,
    restore

const EXPERIMENTAL = :experimental
const DIRECTIONS = (:maximise, :minimise)
const REDUCERS = (:mean, :minimum, :maximum, :sum)

struct DesignBlock
    name::Symbol
    shape::Tuple{Vararg{Int}}
    range::UnitRange{Int}

    function DesignBlock(
        name::Symbol,
        shape::Tuple{Vararg{Int}},
        range::UnitRange{Int},
    )
        isempty(String(name)) &&
            throw(ArgumentError("design block name must not be empty"))
        isempty(shape) &&
            throw(ArgumentError("design block :$(name) shape must not be empty"))
        all(>(0), shape) ||
            throw(ArgumentError("design block :$(name) shape must be positive"))
        isempty(range) &&
            throw(ArgumentError("design block :$(name) range must not be empty"))
        prod(shape) == length(range) || throw(DimensionMismatch(
            "design block :$(name) shape has $(prod(shape)) coordinates, " *
            "but its range has $(length(range))",
        ))
        return new(name, shape, range)
    end
end

struct NodeDesignSpec{T<:NodeModel,B,E,D}
    model_type::Type{T}
    blocks::B
    dimension::Int
    encode::E
    decode::D
    stability::Symbol
end

function NodeDesignSpec(
    model_type::Type{T},
    blocks,
    encode_,
    decode_;
    stability::Symbol=EXPERIMENTAL,
) where {T<:NodeModel}
    stability === EXPERIMENTAL || throw(ArgumentError(
        "node design specifications are experimental",
    ))
    blocks_ = Tuple(blocks)
    isempty(blocks_) &&
        throw(ArgumentError("node design specification requires at least one block"))
    all(block -> block isa DesignBlock, blocks_) || throw(ArgumentError(
        "node design blocks must be DesignBlock values",
    ))
    names = getfield.(blocks_, :name)
    length(unique(names)) == length(names) ||
        throw(ArgumentError("node design block names must be unique"))
    expected = 1
    for block in blocks_
        first(block.range) == expected || throw(ArgumentError(
            "node design block ranges must form a contiguous schema starting at 1",
        ))
        expected = last(block.range) + 1
    end
    dimension = expected - 1
    return NodeDesignSpec{
        T,
        typeof(blocks_),
        typeof(encode_),
        typeof(decode_),
    }(
        model_type,
        blocks_,
        dimension,
        encode_,
        decode_,
        stability,
    )
end

function encode(spec::NodeDesignSpec{T}, model::T) where {T<:NodeModel}
    applicable(spec.encode, model) || throw(ArgumentError(
        "node design encoder is not callable with $(T)",
    ))
    coordinates = Vector{Float64}(Float64.(spec.encode(model)))
    length(coordinates) == spec.dimension || throw(DimensionMismatch(
        "node design encoder returned $(length(coordinates)) coordinates; " *
        "expected $(spec.dimension)",
    ))
    all(isfinite, coordinates) ||
        throw(ArgumentError("node design encoder returned non-finite coordinates"))
    return coordinates
end

function encode(spec::NodeDesignSpec, model::NodeModel)
    throw(ArgumentError(
        "node design expects $(spec.model_type), got $(typeof(model))",
    ))
end

function decode(spec::NodeDesignSpec{T}, coordinates) where {T<:NodeModel}
    values = Vector{Float64}(Float64.(coordinates))
    length(values) == spec.dimension || throw(DimensionMismatch(
        "node design requires $(spec.dimension) coordinates, got $(length(values))",
    ))
    all(isfinite, values) ||
        throw(ArgumentError("node design coordinates must be finite"))
    applicable(spec.decode, values) || throw(ArgumentError(
        "node design decoder is not callable with Vector{Float64}",
    ))
    model = spec.decode(values)
    model isa T || throw(ArgumentError(
        "node design decoder returned $(typeof(model)); expected $(T)",
    ))
    return model
end

struct ModelReference
    path::String
    model_id::String
    node::Symbol
    schema_sha256::String
    coordinates_sha256::String

    function ModelReference(
        path::AbstractString,
        model_id::AbstractString,
        node::Symbol,
        schema_sha256::AbstractString,
        coordinates_sha256::AbstractString,
    )
        path_ = String(path)
        model_id_ = String(model_id)
        schema_ = String(schema_sha256)
        coordinates_ = String(coordinates_sha256)
        isempty(strip(path_)) &&
            throw(ArgumentError("model reference path must not be empty"))
        isabspath(path_) &&
            throw(ArgumentError("model reference path must be relative"))
        occursin(r"^[A-Za-z]:", path_) &&
            throw(ArgumentError("model reference path must be relative"))
        parts = split(replace(path_, '\\' => '/'), '/'; keepempty=true)
        ".." in parts &&
            throw(ArgumentError("model reference path must not contain .."))
        isempty(strip(model_id_)) &&
            throw(ArgumentError("model reference id must not be empty"))
        isempty(String(node)) &&
            throw(ArgumentError("model reference node must not be empty"))
        occursin(r"^[0-9a-f]{64}$", schema_) || throw(ArgumentError(
            "model reference schema_sha256 must be a lowercase SHA-256 digest",
        ))
        occursin(r"^[0-9a-f]{64}$", coordinates_) || throw(ArgumentError(
            "model reference coordinates_sha256 must be a lowercase SHA-256 digest",
        ))
        return new(path_, model_id_, node, schema_, coordinates_)
    end
end

struct NormalInitialisation
    centre::Symbol
    scale::Float64
    reference::Union{Nothing,ModelReference}
    coordinates::Union{Nothing,Vector{Float64}}
end

function NormalInitialisation(
    ;
    centre::Symbol=:zero,
    scale::Real,
    reference::Union{Nothing,ModelReference}=nothing,
    coordinates=nothing,
)
    centre in (:zero, :model) || throw(ArgumentError(
        "normal initialisation centre must be :zero or :model",
    ))
    scale_ = Float64(scale)
    isfinite(scale_) && scale_ > 0.0 || throw(ArgumentError(
        "normal initialisation scale must be finite and positive",
    ))
    if centre === :zero
        reference === nothing && coordinates === nothing || throw(ArgumentError(
            "zero-centred initialisation must not contain a model reference",
        ))
        return NormalInitialisation(:zero, scale_, nothing, nothing)
    end
    reference === nothing && throw(ArgumentError(
        "model-centred initialisation requires a ModelReference",
    ))
    coordinates_ = coordinates === nothing ?
        nothing :
        Vector{Float64}(Float64.(coordinates))
    coordinates_ === nothing || begin
        isempty(coordinates_) && throw(ArgumentError(
            "model-centred initialisation coordinates must not be empty",
        ))
        all(isfinite, coordinates_) || throw(ArgumentError(
            "model-centred initialisation coordinates must be finite",
        ))
    end
    return NormalInitialisation(:model, scale_, reference, coordinates_)
end

NormalInitialisation(
    reference::ModelReference,
    coordinates;
    scale::Real,
) = NormalInitialisation(
    ;
    centre=:model,
    scale,
    reference,
    coordinates,
)

struct SearchStrategySpec{C<:Tuple,A<:Tuple,R<:Tuple}
    key::Symbol
    label::String
    capabilities::C
    allowed_options::A
    required_options::R
    stability::Symbol
end

function SearchStrategySpec(
    key::Symbol,
    label::AbstractString;
    capabilities=(),
    allowed_options=(),
    required_options=(),
    stability::Symbol=EXPERIMENTAL,
)
    isempty(String(key)) &&
        throw(ArgumentError("search strategy key must not be empty"))
    isempty(strip(label)) &&
        throw(ArgumentError("search strategy label must not be empty"))
    stability === EXPERIMENTAL || throw(ArgumentError(
        "search strategies are experimental",
    ))
    capabilities_ = Tuple(Symbol.(capabilities))
    allowed_ = Tuple(Symbol.(allowed_options))
    required_ = Tuple(Symbol.(required_options))
    length(unique(capabilities_)) == length(capabilities_) ||
        throw(ArgumentError("search strategy capabilities must be unique"))
    length(unique(allowed_)) == length(allowed_) ||
        throw(ArgumentError("search strategy options must be unique"))
    all(in(allowed_), required_) || throw(ArgumentError(
        "required search strategy options must also be allowed",
    ))
    return SearchStrategySpec{
        typeof(capabilities_),
        typeof(allowed_),
        typeof(required_),
    }(
        key,
        String(label),
        capabilities_,
        allowed_,
        required_,
        stability,
    )
end

sepcma_spec() = SearchStrategySpec(
    :sepcma,
    "Separable CMA-ES";
    capabilities=(:scalar_selection,),
    allowed_options=(:population, :reducer),
    required_options=(:reducer,),
)

nsga2_spec() = SearchStrategySpec(
    :nsga2,
    "NSGA-II";
    capabilities=(:multiobjective, :pareto),
    allowed_options=(
        :population,
        :bound_scale,
        :pc,
        :eta_c,
        :pm,
        :eta_m,
    ),
)

cmame_spec() = SearchStrategySpec(
    :cmame,
    "CMA-ME";
    capabilities=(:quality_diversity, :archive),
    allowed_options=(
        :bins,
        :emitters,
        :emitter_population,
        :patience,
        :quality_reducer,
    ),
    required_options=(:quality_reducer,),
)

const _BUILTIN_STRATEGY_SPECS = (
    sepcma_spec(),
    nsga2_spec(),
    cmame_spec(),
)

function _builtin_strategy_spec(key::Symbol)
    index = findfirst(spec -> spec.key === key, _BUILTIN_STRATEGY_SPECS)
    index === nothing && throw(KeyError(
        "unknown search strategy :$(key); known strategies: " *
        join(
            ":" .* string.(
                sort!(collect(getfield.(_BUILTIN_STRATEGY_SPECS, :key))),
            ),
            ", ",
        ),
    ))
    return _BUILTIN_STRATEGY_SPECS[index]
end

function search_strategy end
function search_strategies end
builtin_strategy_specs() = _BUILTIN_STRATEGY_SPECS

function _positive_integer(value, label::AbstractString; minimum::Int=1)
    value isa Integer ||
        throw(ArgumentError("$(label) must be an integer"))
    result = Int(value)
    result >= minimum ||
        throw(ArgumentError("$(label) must be at least $(minimum)"))
    return result
end

function _finite_float(value, label::AbstractString)
    value isa Real || throw(ArgumentError("$(label) must be numeric"))
    result = Float64(value)
    isfinite(result) || throw(ArgumentError("$(label) must be finite"))
    return result
end

function _reducer(value, label::AbstractString)
    reducer = Symbol(value)
    reducer in REDUCERS || throw(ArgumentError(
        "$(label) must be one of " * join(":" .* string.(REDUCERS), ", "),
    ))
    return reducer
end

function _validate_options(spec::SearchStrategySpec, options::NamedTuple)
    names = propertynames(options)
    unknown = setdiff(names, spec.allowed_options)
    isempty(unknown) || throw(ArgumentError(
        "unknown :$(spec.key) options: " * join(":" .* string.(unknown), ", "),
    ))
    missing = setdiff(spec.required_options, names)
    isempty(missing) || throw(ArgumentError(
        "missing :$(spec.key) options: " * join(":" .* string.(missing), ", "),
    ))

    if spec.key === :sepcma
        hasproperty(options, :population) &&
            _positive_integer(
                options.population,
                "sepcma population";
                minimum=2,
            )
        _reducer(options.reducer, "sepcma reducer")
    elseif spec.key === :nsga2
        hasproperty(options, :population) &&
            _positive_integer(
                options.population,
                "nsga2 population";
                minimum=4,
            )
        if hasproperty(options, :bound_scale)
            _finite_float(options.bound_scale, "nsga2 bound_scale") > 0.0 ||
                throw(ArgumentError("nsga2 bound_scale must be positive"))
        end
        for name in (:pc, :pm)
            hasproperty(options, name) || continue
            value = _finite_float(getproperty(options, name), "nsga2 $(name)")
            0.0 <= value <= 1.0 || throw(ArgumentError(
                "nsga2 $(name) must lie in [0, 1]",
            ))
        end
        for name in (:eta_c, :eta_m)
            hasproperty(options, name) || continue
            _finite_float(getproperty(options, name), "nsga2 $(name)") > 0.0 ||
                throw(ArgumentError("nsga2 $(name) must be positive"))
        end
    elseif spec.key === :cmame
        _reducer(options.quality_reducer, "cmame quality_reducer")
        hasproperty(options, :bins) &&
            _positive_integer(options.bins, "cmame bins"; minimum=2)
        hasproperty(options, :emitters) &&
            _positive_integer(options.emitters, "cmame emitters")
        hasproperty(options, :emitter_population) &&
            _positive_integer(
                options.emitter_population,
                "cmame emitter_population";
                minimum=2,
            )
        hasproperty(options, :patience) &&
            _positive_integer(options.patience, "cmame patience")
    end
    return options
end

function _canonical_options(
    spec::SearchStrategySpec,
    options::NamedTuple,
)
    return (; (
        name => getproperty(options, name)
        for name in spec.allowed_options
        if hasproperty(options, name)
    )...)
end

struct RunConfig{I,O<:NamedTuple}
    strategy::Symbol
    iterations::Int
    search_seed::UInt64
    measure::Symbol
    direction::Symbol
    initialisation::I
    options::O
end

function validate_strategy(
    spec::SearchStrategySpec,
    config::RunConfig,
    n_scores::Integer,
)
    spec.key === config.strategy || throw(ArgumentError(
        "strategy specification :$(spec.key) does not match RunConfig " *
        ":$(config.strategy)",
    ))
    count_ = Int(n_scores)
    count_ >= 1 ||
        throw(ArgumentError("search requires at least one target score"))
    if spec.key === :nsga2
        count_ >= 2 ||
            throw(ArgumentError("nsga2 requires at least two target scores"))
    elseif spec.key === :cmame
        config.measure === :normalized_score || throw(ArgumentError(
            "cmame requires measure=:normalized_score",
        ))
    end
    return count_
end

function RunConfig(
    strategy::Symbol,
    iterations::Integer,
    search_seed::Integer,
    measure::Symbol,
    direction::Symbol,
    initialisation,
    options::NamedTuple,
)
    spec = _builtin_strategy_spec(strategy)
    iterations_ = Int(iterations)
    iterations_ >= 1 ||
        throw(ArgumentError("search iterations must be at least 1"))
    search_seed >= 0 ||
        throw(ArgumentError("search seed must be non-negative"))
    isempty(String(measure)) &&
        throw(ArgumentError("search measure must not be empty"))
    direction in DIRECTIONS || throw(ArgumentError(
        "search direction must be :maximise or :minimise",
    ))
    initialisation isa NormalInitialisation || throw(ArgumentError(
        "search initialisation must be a NormalInitialisation",
    ))
    _validate_options(spec, options)
    options_ = _canonical_options(spec, options)
    return RunConfig{
        typeof(initialisation),
        typeof(options_),
    }(
        strategy,
        iterations_,
        UInt64(search_seed),
        measure,
        direction,
        initialisation,
        options_,
    )
end

function RunConfig(;
    strategy,
    iterations,
    search_seed,
    measure=:normalized_score,
    direction=:maximise,
    initialisation,
    options=NamedTuple(),
)
    return RunConfig(
        Symbol(strategy),
        iterations,
        search_seed,
        Symbol(measure),
        Symbol(direction),
        initialisation,
        options,
    )
end

struct CandidateProposal
    id::Int
    iteration::Int
    coordinates::Vector{Float64}

    function CandidateProposal(id::Integer, iteration::Integer, coordinates)
        id_ = Int(id)
        iteration_ = Int(iteration)
        id_ >= 1 || throw(ArgumentError("candidate id must be positive"))
        iteration_ >= 1 ||
            throw(ArgumentError("candidate iteration must be positive"))
        coordinates_ = Vector{Float64}(Float64.(coordinates))
        isempty(coordinates_) &&
            throw(ArgumentError("candidate coordinates must not be empty"))
        all(isfinite, coordinates_) ||
            throw(ArgumentError("candidate coordinates must be finite"))
        return new(id_, iteration_, coordinates_)
    end
end

struct Observation
    id::Int
    scores::Vector{Float64}
    valid::Bool

    function Observation(id::Integer, scores; valid::Bool=true)
        id_ = Int(id)
        id_ >= 1 || throw(ArgumentError("observation id must be positive"))
        scores_ = scores isa Real ?
            Float64[Float64(scores)] :
            Vector{Float64}(Float64.(scores))
        isempty(scores_) &&
            throw(ArgumentError("observation requires at least one target score"))
        all(isfinite, scores_) ||
            throw(ArgumentError("observation scores must be finite"))
        return new(id_, scores_, valid)
    end
end

Observation(
    proposal::CandidateProposal,
    scores;
    valid::Bool=true,
) = Observation(proposal.id, scores; valid)

abstract type AbstractSearchState end

function initialise end
function propose! end
function observe! end
function outcome end
function snapshot end
function restore end

function _initial_centre(
    design::NodeDesignSpec,
    initialisation::NormalInitialisation,
)
    if initialisation.centre === :zero
        return zeros(Float64, design.dimension)
    end
    coordinates = something(initialisation.coordinates)
    length(coordinates) == design.dimension || throw(DimensionMismatch(
        "model reference has $(length(coordinates)) coordinates; " *
        "design requires $(design.dimension)",
    ))
    return copy(coordinates)
end

function _score_reduction(reducer::Symbol, scores::Vector{Float64})
    reducer === :mean && return sum(scores) / length(scores)
    reducer === :minimum && return minimum(scores)
    reducer === :maximum && return maximum(scores)
    reducer === :sum && return sum(scores)
    throw(ArgumentError("unknown reducer :$(reducer)"))
end

_oriented(value::Real, direction::Symbol) =
    direction === :maximise ? Float64(value) : -Float64(value)

function _ordered_observations(pending, observations)
    isempty(pending) && throw(ArgumentError("search state has no pending proposals"))
    source = observations isa Observation ? (observations,) : Tuple(observations)
    length(source) == length(pending) || throw(DimensionMismatch(
        "received $(length(source)) observations for $(length(pending)) proposals",
    ))
    all(observation -> observation isa Observation, source) ||
        throw(ArgumentError("observe! requires Observation values"))
    by_id = Dict{Int,Observation}()
    for observation in source
        haskey(by_id, observation.id) && throw(ArgumentError(
            "duplicate observation id $(observation.id)",
        ))
        by_id[observation.id] = observation
    end
    expected = Set(proposal.id for proposal in pending)
    Set(keys(by_id)) == expected || throw(ArgumentError(
        "observation ids do not match the pending proposal ids",
    ))
    return [by_id[proposal.id] for proposal in pending]
end

function _proposals(
    candidates::Vector{Vector{Float64}},
    iteration::Int,
    next_id::Int,
)
    proposals = CandidateProposal[
        CandidateProposal(next_id + index - 1, iteration, candidate)
        for (index, candidate) in enumerate(candidates)
    ]
    return proposals, next_id + length(candidates)
end

# Separable CMA-ES core. Random sampling is deliberately outside this state.

mutable struct SepCore
    n_dim::Int
    lambda::Int
    mu::Int
    weights::Vector{Float64}
    positive_weights::Vector{Float64}
    mu_eff::Float64
    c_sigma::Float64
    d_sigma::Float64
    c_c::Float64
    c1::Float64
    c_mu::Float64
    chi_n::Float64
    x_mean::Vector{Float64}
    sigma::Float64
    C_diag::Vector{Float64}
    p_c::Vector{Float64}
    p_sigma::Vector{Float64}
    countiter::Int
    countevals::Int
end

function _chi_n(n::Int)
    value = isodd(n) ? sqrt(2.0 / pi) : sqrt(pi / 2.0)
    k = isodd(n) ? 1 : 2
    while k < n
        value *= (k + 1) / k
        k += 2
    end
    return Float64(value)
end

function _recombination_weights(lambda::Int)
    raw = [log((lambda + 1) / 2) - log(i) for i in 1:lambda]
    mu = count(>(0.0), raw)
    weights = raw ./ sum(@view raw[1:mu])
    if mu < lambda
        negative_sum = sum(@view weights[(mu + 1):lambda])
        if negative_sum != 0.0
            @views weights[(mu + 1):lambda] ./= -negative_sum
        end
    end
    mu_eff = 1.0 / sum(abs2, @view weights[1:mu])
    return weights, mu, Float64(mu_eff)
end

function _negative_weight_sum!(weights, mu, target; limit::Bool=false)
    mu >= length(weights) && return weights
    negative = @view weights[(mu + 1):length(weights)]
    current = sum(negative)
    current == 0.0 && return weights
    target_ = abs(Float64(target))
    limit && current >= -target_ && return weights
    negative .*= abs(target_ / current)
    return weights
end

function _new_sep_core(
    centre::Vector{Float64},
    sigma::Float64,
    lambda::Int,
)
    n = length(centre)
    weights, mu, mu_eff = _recombination_weights(lambda)
    n_ = Float64(n)
    c1 = 1.0 / (n_ + 2.0 * sqrt(n_) + mu_eff / n_)
    c_mu = min(
        1.0 - c1,
        (0.25 + mu_eff + inv(mu_eff) - 2.0) /
        (n_ + 4.0 * sqrt(n_) + mu_eff / 2.0),
    )
    if weights[end] < 0.0 && c_mu > 0.0
        _negative_weight_sum!(weights, mu, 1.0 + c1 / c_mu)
        negative = @view weights[(mu + 1):length(weights)]
        mu_eff_minus = sum(negative)^2 / sum(abs2, negative)
        _negative_weight_sum!(
            weights,
            mu,
            1.0 + 2.0 * mu_eff_minus / (mu_eff + 2.0);
            limit=true,
        )
    end
    c_sigma = (mu_eff + 2.0) / (n_ + mu_eff + 3.0)
    damp_in_eff = max(1.0, 3.0 * (1.0 - 0.5^(n_ / 10.0)))
    d_sigma = 1.0 +
        2.0 * max(
            0.0,
            damp_in_eff * sqrt((mu_eff - 1.0) / (n_ + 1.0)) - 1.0,
        ) +
        c_sigma
    c_c = (1.0 + inv(n_) + mu_eff / n_) /
        (sqrt(n_) + inv(n_) + 2.0 * mu_eff / n_)
    return SepCore(
        n,
        lambda,
        mu,
        weights,
        copy(weights[1:mu]),
        mu_eff,
        c_sigma,
        d_sigma,
        c_c,
        c1,
        c_mu,
        _chi_n(n),
        copy(centre),
        sigma,
        ones(Float64, n),
        zeros(Float64, n),
        zeros(Float64, n),
        0,
        0,
    )
end

function _sep_propose(core::SepCore, rng::Random.AbstractRNG)
    scale = sqrt.(core.C_diag)
    return [
        core.x_mean .+ core.sigma .* scale .* randn(rng, core.n_dim)
        for _ in 1:core.lambda
    ]
end

function _weighted_mean(population, weights, dimension)
    result = zeros(Float64, dimension)
    for index in eachindex(weights)
        result .+= weights[index] .* population[index]
    end
    return result
end

function _sep_observe!(
    core::SepCore,
    candidates::Vector{Vector{Float64}},
    losses::Vector{Float64},
)
    length(candidates) == length(losses) ||
        throw(DimensionMismatch("candidate and loss counts must match"))
    length(candidates) >= core.mu ||
        throw(ArgumentError("not enough candidates for separable CMA-ES"))
    all(candidate -> length(candidate) == core.n_dim, candidates) ||
        throw(DimensionMismatch("candidate dimension does not match CMA state"))
    all(isfinite, losses) ||
        throw(ArgumentError("CMA losses must be finite"))

    order = sortperm(losses)
    population = [candidates[index] for index in order]
    old_mean = copy(core.x_mean)
    core.countiter += 1
    core.countevals += length(population)
    core.x_mean = _weighted_mean(
        population,
        core.positive_weights,
        core.n_dim,
    )

    old_scale = sqrt.(core.C_diag)
    delta = core.x_mean .- old_mean
    z = delta ./ old_scale
    z .*= sqrt(core.mu_eff) / core.sigma
    core.p_sigma .*= 1.0 - core.c_sigma
    core.p_sigma .+=
        sqrt(core.c_sigma * (2.0 - core.c_sigma)) .* z

    denominator =
        1.0 - (1.0 - core.c_sigma)^(2 * core.countiter)
    squared_sum = sum(abs2, core.p_sigma) / denominator
    hsig =
        squared_sum / core.n_dim - 1.0 <
        1.0 + 4.0 / (core.n_dim + 1.0)
    h = hsig ? 1.0 : 0.0
    c1a =
        core.c1 *
        (1.0 - (1.0 - h * h) * core.c_c * (2.0 - core.c_c))

    core.p_c .*= 1.0 - core.c_c
    core.p_c .+=
        h * sqrt(core.c_c * (2.0 - core.c_c) * core.mu_eff) .*
        delta ./ core.sigma

    weights = Vector{Float64}(undef, length(population) + 1)
    weights[1] = log(2.0) * c1a
    for index in eachindex(population)
        weights[index + 1] = log(2.0) * core.c_mu * core.weights[index]
    end
    weight_sum = sum(weights)
    for coordinate in 1:core.n_dim
        average = weights[1] * core.p_c[coordinate]^2
        denominator_ = core.sigma * old_scale[coordinate]
        for index in eachindex(population)
            normalised =
                (population[index][coordinate] - old_mean[coordinate]) /
                denominator_
            average += weights[index + 1] * normalised^2
        end
        factor = exp((average - weight_sum) / 2.0)
        core.C_diag[coordinate] *= factor^2
        if !isfinite(core.C_diag[coordinate]) ||
           core.C_diag[coordinate] <= 0.0
            core.C_diag[coordinate] = eps(Float64)
        end
    end

    core.sigma *= exp(
        min(
            1.0,
            (core.c_sigma / core.d_sigma) *
            (sqrt(squared_sum) / core.chi_n - 1.0),
        ),
    )
    return core
end

mutable struct SepCMAState{C<:RunConfig} <: AbstractSearchState
    config::C
    dimension::Int
    core::SepCore
    iteration::Int
    next_id::Int
    pending::Vector{CandidateProposal}
    selected_coordinates::Union{Nothing,Vector{Float64}}
    selected_scores::Union{Nothing,Vector{Float64}}
    selected_value::Float64
    selected_id::Int
    n_evaluated::Int
end

function _option(options::NamedTuple, name::Symbol, default)
    return hasproperty(options, name) ? getproperty(options, name) : default
end

function _initialise_sepcma(
    design::NodeDesignSpec,
    config::RunConfig,
)
    centre = _initial_centre(design, config.initialisation)
    default_population = 4 + floor(Int, 3 * log(design.dimension))
    population = Int(
        _option(config.options, :population, default_population),
    )
    core = _new_sep_core(
        centre,
        config.initialisation.scale,
        population,
    )
    return SepCMAState(
        config,
        design.dimension,
        core,
        0,
        1,
        CandidateProposal[],
        nothing,
        nothing,
        -Inf,
        0,
        0,
    )
end

function propose!(
    state::SepCMAState,
    rng::Random.AbstractRNG,
)
    isempty(state.pending) ||
        throw(ArgumentError("observe pending proposals before proposing again"))
    state.iteration < state.config.iterations ||
        throw(ArgumentError("search has completed its configured iterations"))
    candidates = _sep_propose(state.core, rng)
    proposals, state.next_id = _proposals(
        candidates,
        state.iteration + 1,
        state.next_id,
    )
    state.pending = proposals
    return copy(proposals)
end

function observe!(state::SepCMAState, observations)
    ordered = _ordered_observations(state.pending, observations)
    reducer = Symbol(state.config.options.reducer)
    values = Float64[
        _score_reduction(reducer, observation.scores)
        for observation in ordered
    ]
    all(isfinite, values) ||
        throw(ArgumentError("sepcma reducer returned a non-finite value"))
    oriented = _oriented.(values, Ref(state.config.direction))
    valid_oriented = [
        oriented[index]
        for index in eachindex(oriented)
        if ordered[index].valid
    ]
    invalid_value = isempty(valid_oriented) ?
        -1.0 :
        minimum(valid_oriented) -
        max(1.0, maximum(abs, valid_oriented))
    ranked = [
        ordered[index].valid ? oriented[index] : invalid_value
        for index in eachindex(oriented)
    ]
    losses = .-ranked
    candidates = [copy(proposal.coordinates) for proposal in state.pending]
    _sep_observe!(state.core, candidates, losses)

    for index in eachindex(values)
        if ordered[index].valid &&
           oriented[index] > state.selected_value
            state.selected_value = oriented[index]
            state.selected_coordinates = copy(candidates[index])
            state.selected_scores = copy(ordered[index].scores)
            state.selected_id = state.pending[index].id
        end
    end
    state.n_evaluated += length(ordered)
    state.iteration += 1
    empty!(state.pending)
    return state
end

function outcome(state::SepCMAState)
    state.selected_coordinates === nothing &&
        throw(ArgumentError("sepcma has no evaluated candidate"))
    reducer = Symbol(state.config.options.reducer)
    value = _score_reduction(reducer, something(state.selected_scores))
    return (
        kind=:selected,
        selected=(
            id=state.selected_id,
            coordinates=copy(something(state.selected_coordinates)),
            scores=copy(something(state.selected_scores)),
            value=value,
        ),
        n_evaluated=state.n_evaluated,
    )
end

# NSGA-II preserves the separate target scores throughout selection.

function _dominates(a::Vector{Float64}, b::Vector{Float64})
    all_ge = true
    any_gt = false
    for index in eachindex(a)
        if a[index] < b[index]
            all_ge = false
            break
        elseif a[index] > b[index]
            any_gt = true
        end
    end
    return all_ge && any_gt
end

function _nondominated_fronts(
    objectives::Vector{Vector{Float64}},
    validity::Vector{Bool}=fill(true, length(objectives)),
)
    length(validity) == length(objectives) ||
        throw(DimensionMismatch("objective and validity counts must match"))
    count_ = length(objectives)
    dominates = [Int[] for _ in 1:count_]
    domination_count = zeros(Int, count_)
    first_front = Int[]
    for left in 1:count_
        for right in 1:count_
            left == right && continue
            left_dominates = validity[left] != validity[right] ?
                validity[left] :
                _dominates(objectives[left], objectives[right])
            right_dominates = validity[left] != validity[right] ?
                validity[right] :
                _dominates(objectives[right], objectives[left])
            if left_dominates
                push!(dominates[left], right)
            elseif right_dominates
                domination_count[left] += 1
            end
        end
        domination_count[left] == 0 && push!(first_front, left)
    end
    fronts = Vector{Vector{Int}}()
    isempty(first_front) && return fronts
    push!(fronts, first_front)
    index = 1
    while index <= length(fronts)
        next_front = Int[]
        for candidate in fronts[index]
            for dominated in dominates[candidate]
                domination_count[dominated] -= 1
                domination_count[dominated] == 0 &&
                    push!(next_front, dominated)
            end
        end
        isempty(next_front) || push!(fronts, next_front)
        index += 1
    end
    return fronts
end

function _crowding_distance(
    front::Vector{Int},
    objectives::Vector{Vector{Float64}},
)
    distances = zeros(Float64, length(front))
    isempty(front) && return distances
    for target in eachindex(objectives[first(front)])
        values = [objectives[index][target] for index in front]
        order = sortperm(values)
        distances[first(order)] = Inf
        distances[last(order)] = Inf
        span = values[last(order)] - values[first(order)]
        if span > 0.0 && length(front) > 2
            for index in 2:(length(front) - 1)
                distances[order[index]] +=
                    (
                        values[order[index + 1]] -
                        values[order[index - 1]]
                    ) / span
            end
        end
    end
    return distances
end

function _tournament(
    rng::Random.AbstractRNG,
    population,
    rank,
    crowding,
)
    left = rand(rng, eachindex(population))
    right = rand(rng, eachindex(population))
    if rank[left] != rank[right]
        return population[rank[left] < rank[right] ? left : right]
    end
    return population[
        crowding[left] >= crowding[right] ? left : right
    ]
end

function _sbx(
    rng::Random.AbstractRNG,
    first_parent::Vector{Float64},
    second_parent::Vector{Float64},
    lower::Vector{Float64},
    upper::Vector{Float64},
    probability::Float64,
    eta::Float64,
)
    first_child = copy(first_parent)
    second_child = copy(second_parent)
    rand(rng) > probability &&
        return first_child, second_child
    for coordinate in eachindex(first_parent)
        rand(rng) > 0.5 && continue
        first_value = first_parent[coordinate]
        second_value = second_parent[coordinate]
        abs(first_value - second_value) < 1.0e-14 && continue
        low = lower[coordinate]
        high = upper[coordinate]
        left, right = first_value < second_value ?
            (first_value, second_value) :
            (second_value, first_value)
        uniform = rand(rng)
        beta = 1.0 + 2.0 * (left - low) / (right - left)
        alpha = 2.0 - beta^(-(eta + 1.0))
        beta_q = uniform <= inv(alpha) ?
            (uniform * alpha)^(inv(eta + 1.0)) :
            inv(2.0 - uniform * alpha)^(inv(eta + 1.0))
        child_left =
            0.5 * ((left + right) - beta_q * (right - left))

        beta = 1.0 + 2.0 * (high - right) / (right - left)
        alpha = 2.0 - beta^(-(eta + 1.0))
        beta_q = uniform <= inv(alpha) ?
            (uniform * alpha)^(inv(eta + 1.0)) :
            inv(2.0 - uniform * alpha)^(inv(eta + 1.0))
        child_right =
            0.5 * ((left + right) + beta_q * (right - left))
        child_left = clamp(child_left, low, high)
        child_right = clamp(child_right, low, high)
        if rand(rng) <= 0.5
            first_child[coordinate] = child_right
            second_child[coordinate] = child_left
        else
            first_child[coordinate] = child_left
            second_child[coordinate] = child_right
        end
    end
    return first_child, second_child
end

function _polynomial_mutation(
    rng::Random.AbstractRNG,
    candidate::Vector{Float64},
    lower::Vector{Float64},
    upper::Vector{Float64},
    probability::Float64,
    eta::Float64,
)
    result = copy(candidate)
    for coordinate in eachindex(candidate)
        rand(rng) > probability && continue
        low = lower[coordinate]
        high = upper[coordinate]
        high <= low && continue
        value = result[coordinate]
        delta_left = (value - low) / (high - low)
        delta_right = (high - value) / (high - low)
        uniform = rand(rng)
        power = inv(eta + 1.0)
        if uniform < 0.5
            residual = 1.0 - delta_left
            term =
                2.0 * uniform +
                (1.0 - 2.0 * uniform) * residual^(eta + 1.0)
            delta = term^power - 1.0
        else
            residual = 1.0 - delta_right
            term =
                2.0 * (1.0 - uniform) +
                2.0 * (uniform - 0.5) * residual^(eta + 1.0)
            delta = 1.0 - term^power
        end
        result[coordinate] =
            clamp(value + delta * (high - low), low, high)
    end
    return result
end

mutable struct NSGA2State{C<:RunConfig} <: AbstractSearchState
    config::C
    dimension::Int
    n_scores::Int
    population_size::Int
    lower::Vector{Float64}
    upper::Vector{Float64}
    population::Vector{Vector{Float64}}
    scores::Vector{Vector{Float64}}
    validity::Vector{Bool}
    iteration::Int
    next_id::Int
    pending::Vector{CandidateProposal}
    n_evaluated::Int
end

function _initialise_nsga2(
    design::NodeDesignSpec,
    config::RunConfig,
    n_scores::Int,
)
    centre = _initial_centre(design, config.initialisation)
    bound_scale = Float64(
        _option(config.options, :bound_scale, 6.0),
    )
    extent = bound_scale * config.initialisation.scale
    return NSGA2State(
        config,
        design.dimension,
        n_scores,
        Int(_option(config.options, :population, 32)),
        centre .- extent,
        centre .+ extent,
        Vector{Vector{Float64}}(),
        Vector{Vector{Float64}}(),
        Bool[],
        0,
        1,
        CandidateProposal[],
        0,
    )
end

function _oriented_scores(state::NSGA2State)
    if state.config.direction === :maximise
        return [copy(scores) for scores in state.scores]
    end
    return [-scores for scores in state.scores]
end

function _nsga_offspring(
    state::NSGA2State,
    rng::Random.AbstractRNG,
)
    objectives = _oriented_scores(state)
    fronts = _nondominated_fronts(objectives, state.validity)
    rank = Vector{Int}(undef, length(state.population))
    crowding = zeros(Float64, length(state.population))
    for (front_rank, front) in enumerate(fronts)
        distances = _crowding_distance(front, objectives)
        for (offset, index) in enumerate(front)
            rank[index] = front_rank
            crowding[index] = distances[offset]
        end
    end
    probability_crossover =
        Float64(_option(state.config.options, :pc, 0.9))
    eta_c = Float64(_option(state.config.options, :eta_c, 15.0))
    probability_mutation = Float64(
        _option(
            state.config.options,
            :pm,
            1.0 / state.dimension,
        ),
    )
    eta_m = Float64(_option(state.config.options, :eta_m, 20.0))
    offspring = Vector{Vector{Float64}}(undef, state.population_size)
    index = 1
    while index <= state.population_size
        first_parent = _tournament(
            rng,
            state.population,
            rank,
            crowding,
        )
        second_parent = _tournament(
            rng,
            state.population,
            rank,
            crowding,
        )
        first_child, second_child = _sbx(
            rng,
            first_parent,
            second_parent,
            state.lower,
            state.upper,
            probability_crossover,
            eta_c,
        )
        offspring[index] = _polynomial_mutation(
            rng,
            first_child,
            state.lower,
            state.upper,
            probability_mutation,
            eta_m,
        )
        index += 1
        if index <= state.population_size
            offspring[index] = _polynomial_mutation(
                rng,
                second_child,
                state.lower,
                state.upper,
                probability_mutation,
                eta_m,
            )
            index += 1
        end
    end
    return offspring
end

function propose!(
    state::NSGA2State,
    rng::Random.AbstractRNG,
)
    isempty(state.pending) ||
        throw(ArgumentError("observe pending proposals before proposing again"))
    state.iteration < state.config.iterations ||
        throw(ArgumentError("search has completed its configured iterations"))
    candidates = if isempty(state.population)
        centre = (state.lower .+ state.upper) ./ 2.0
        [
            clamp.(
                centre .+
                state.config.initialisation.scale .*
                randn(rng, state.dimension),
                state.lower,
                state.upper,
            )
            for _ in 1:state.population_size
        ]
    else
        _nsga_offspring(state, rng)
    end
    proposals, state.next_id = _proposals(
        candidates,
        state.iteration + 1,
        state.next_id,
    )
    state.pending = proposals
    return copy(proposals)
end

function _select_nsga_population!(
    state::NSGA2State,
    candidates::Vector{Vector{Float64}},
    scores::Vector{Vector{Float64}},
    validity::Vector{Bool},
)
    combined_population = vcat(state.population, candidates)
    combined_scores = vcat(state.scores, scores)
    combined_validity = vcat(state.validity, validity)
    objectives = state.config.direction === :maximise ?
        combined_scores :
        [-values for values in combined_scores]
    fronts = _nondominated_fronts(objectives, combined_validity)
    population = Vector{Vector{Float64}}()
    retained_scores = Vector{Vector{Float64}}()
    retained_validity = Bool[]
    for front in fronts
        if length(population) + length(front) <= state.population_size
            for index in front
                push!(population, copy(combined_population[index]))
                push!(retained_scores, copy(combined_scores[index]))
                push!(retained_validity, combined_validity[index])
            end
        else
            distances = _crowding_distance(front, objectives)
            order = sortperm(distances; rev=true)
            remaining = state.population_size - length(population)
            for offset in 1:remaining
                index = front[order[offset]]
                push!(population, copy(combined_population[index]))
                push!(retained_scores, copy(combined_scores[index]))
                push!(retained_validity, combined_validity[index])
            end
            break
        end
    end
    state.population = population
    state.scores = retained_scores
    state.validity = retained_validity
    return state
end

function observe!(state::NSGA2State, observations)
    ordered = _ordered_observations(state.pending, observations)
    all(
        observation -> length(observation.scores) == state.n_scores,
        ordered,
    ) ||
        throw(DimensionMismatch(
            "nsga2 requires $(state.n_scores) target scores per observation",
        ))
    candidates = [copy(proposal.coordinates) for proposal in state.pending]
    scores = [copy(observation.scores) for observation in ordered]
    validity = [observation.valid for observation in ordered]
    if isempty(state.population)
        state.population = candidates
        state.scores = scores
        state.validity = validity
    else
        _select_nsga_population!(state, candidates, scores, validity)
    end
    state.n_evaluated += length(ordered)
    state.iteration += 1
    empty!(state.pending)
    return state
end

function outcome(state::NSGA2State)
    isempty(state.population) &&
        throw(ArgumentError("nsga2 has no evaluated candidates"))
    objectives = _oriented_scores(state)
    front = first(_nondominated_fronts(objectives, state.validity))
    return (
        kind=:pareto,
        pareto=[
            (
                coordinates=copy(state.population[index]),
                scores=copy(state.scores[index]),
                valid=state.validity[index],
            )
            for index in front
        ],
    )
end

# CMA-ME keeps one elite per discretised descriptor cell. The emitter CMA
# states consume archive improvement, not a collapsed task score.

const ArchiveCell = NamedTuple{
    (:coordinates, :descriptor, :quality, :oriented_quality),
    Tuple{Vector{Float64},Vector{Float64},Float64,Float64},
}

mutable struct CMAEmitter
    core::SepCore
    since_improvement::Int
    needs_restart::Bool
end

mutable struct CMAMEState{C<:RunConfig} <: AbstractSearchState
    config::C
    dimension::Int
    n_scores::Int
    bins::Int
    emitter_count::Int
    emitter_population::Int
    patience::Int
    centre::Vector{Float64}
    emitters::Vector{CMAEmitter}
    archive::Dict{Tuple{Vararg{Int}},ArchiveCell}
    iteration::Int
    next_id::Int
    pending::Vector{CandidateProposal}
    pending_emitters::Vector{Int}
    n_evaluated::Int
end

function _initialise_cmame(
    design::NodeDesignSpec,
    config::RunConfig,
    n_scores::Int,
)
    return CMAMEState(
        config,
        design.dimension,
        n_scores,
        Int(_option(config.options, :bins, 5)),
        Int(_option(config.options, :emitters, 4)),
        Int(_option(config.options, :emitter_population, 6)),
        Int(_option(config.options, :patience, 8)),
        _initial_centre(design, config.initialisation),
        CMAEmitter[],
        Dict{Tuple{Vararg{Int}},ArchiveCell}(),
        0,
        1,
        CandidateProposal[],
        Int[],
        0,
    )
end

function _descriptor_key(descriptor::Vector{Float64}, bins::Int)
    return Tuple(
        clamp(floor(Int, value * bins), 0, bins - 1)
        for value in descriptor
    )
end

function _offer!(
    state::CMAMEState,
    coordinates::Vector{Float64},
    descriptor::Vector{Float64},
    quality::Float64,
)
    key = _descriptor_key(descriptor, state.bins)
    oriented = _oriented(quality, state.config.direction)
    existing = get(state.archive, key, nothing)
    if existing === nothing
        state.archive[key] = (
            coordinates=copy(coordinates),
            descriptor=copy(descriptor),
            quality=quality,
            oriented_quality=oriented,
        )
        return 1.0
    elseif oriented > existing.oriented_quality
        improvement = oriented - existing.oriented_quality
        state.archive[key] = (
            coordinates=copy(coordinates),
            descriptor=copy(descriptor),
            quality=quality,
            oriented_quality=oriented,
        )
        return improvement
    end
    return 0.0
end

function _archive_cells(state::CMAMEState)
    keys_ = sort!(collect(keys(state.archive)))
    return [state.archive[key] for key in keys_]
end

function _restart_emitter!(
    state::CMAMEState,
    emitter::CMAEmitter,
    rng::Random.AbstractRNG,
)
    cells = _archive_cells(state)
    centre = isempty(cells) ?
        state.centre :
        cells[rand(rng, eachindex(cells))].coordinates
    emitter.core = _new_sep_core(
        copy(centre),
        state.config.initialisation.scale,
        state.emitter_population,
    )
    emitter.since_improvement = 0
    emitter.needs_restart = false
    return emitter
end

function _ensure_emitters!(state::CMAMEState)
    isempty(state.emitters) || return state
    for _ in 1:state.emitter_count
        push!(
            state.emitters,
            CMAEmitter(
                _new_sep_core(
                    copy(state.centre),
                    state.config.initialisation.scale,
                    state.emitter_population,
                ),
                0,
                true,
            ),
        )
    end
    return state
end

function propose!(
    state::CMAMEState,
    rng::Random.AbstractRNG,
)
    isempty(state.pending) ||
        throw(ArgumentError("observe pending proposals before proposing again"))
    state.iteration < state.config.iterations ||
        throw(ArgumentError("search has completed its configured iterations"))
    candidates = Vector{Vector{Float64}}()
    emitter_indices = Int[]
    if isempty(state.archive)
        count_ = state.emitter_count * state.emitter_population
        for _ in 1:count_
            push!(
                candidates,
                state.centre .+
                state.config.initialisation.scale .*
                randn(rng, state.dimension),
            )
            push!(emitter_indices, 0)
        end
    else
        _ensure_emitters!(state)
        for (index, emitter) in enumerate(state.emitters)
            emitter.needs_restart &&
                _restart_emitter!(state, emitter, rng)
            proposed = _sep_propose(emitter.core, rng)
            append!(candidates, proposed)
            append!(emitter_indices, fill(index, length(proposed)))
        end
    end
    proposals, state.next_id = _proposals(
        candidates,
        state.iteration + 1,
        state.next_id,
    )
    state.pending = proposals
    state.pending_emitters = emitter_indices
    return copy(proposals)
end

function _validate_descriptors(
    state::CMAMEState,
    observations::Vector{Observation},
)
    all(
        observation -> length(observation.scores) == state.n_scores,
        observations,
    ) || throw(DimensionMismatch(
        "cmame requires $(state.n_scores) target scores per observation",
    ))
    for observation in observations
        observation.valid || continue
        all(score -> 0.0 <= score <= 1.0, observation.scores) ||
            throw(ArgumentError(
                "cmame descriptors must be normalised to [0, 1]",
            ))
    end
    return observations
end

function observe!(state::CMAMEState, observations)
    ordered = _ordered_observations(state.pending, observations)
    _validate_descriptors(state, ordered)
    reducer = Symbol(state.config.options.quality_reducer)
    candidates = [copy(proposal.coordinates) for proposal in state.pending]
    qualities = Float64[
        _score_reduction(reducer, observation.scores)
        for observation in ordered
    ]
    all(isfinite, qualities) ||
        throw(ArgumentError("cmame quality reducer returned a non-finite value"))
    improvements = Float64[
        ordered[index].valid ?
        _offer!(
            state,
            candidates[index],
            ordered[index].scores,
            qualities[index],
        ) :
        0.0
        for index in eachindex(candidates)
    ]

    if all(iszero, state.pending_emitters)
        _ensure_emitters!(state)
    else
        for emitter_index in 1:state.emitter_count
            indices = findall(==(emitter_index), state.pending_emitters)
            isempty(indices) && continue
            _sep_observe!(
                state.emitters[emitter_index].core,
                candidates[indices],
                .-improvements[indices],
            )
            emitter = state.emitters[emitter_index]
            if any(>(0.0), improvements[indices])
                emitter.since_improvement = 0
            else
                emitter.since_improvement += 1
                emitter.needs_restart =
                    emitter.since_improvement >= state.patience
            end
        end
    end
    state.n_evaluated += length(ordered)
    state.iteration += 1
    empty!(state.pending)
    empty!(state.pending_emitters)
    return state
end

function outcome(state::CMAMEState)
    isempty(state.archive) &&
        throw(ArgumentError("cmame has no evaluated archive entries"))
    keys_ = sort!(collect(keys(state.archive)))
    return (
        kind=:archive,
        archive=[
            (
                cell=collect(key),
                coordinates=copy(state.archive[key].coordinates),
                descriptor=copy(state.archive[key].descriptor),
                quality=state.archive[key].quality,
            )
            for key in keys_
        ],
    )
end

function initialise(
    spec::SearchStrategySpec,
    design::NodeDesignSpec,
    config::RunConfig;
    n_scores::Integer,
)
    count_ = validate_strategy(spec, config, n_scores)
    config.initialisation.centre === :model &&
        config.initialisation.coordinates === nothing &&
        throw(ArgumentError(
            "model-centred initialisation must be resolved to coordinates " *
            "before search initialisation",
        ))
    spec.key === :sepcma && return _initialise_sepcma(design, config)
    spec.key === :nsga2 && return _initialise_nsga2(design, config, count_)
    spec.key === :cmame && return _initialise_cmame(design, config, count_)
    throw(ArgumentError("unsupported search strategy :$(spec.key)"))
end

function initialise(
    design::NodeDesignSpec,
    config::RunConfig;
    n_scores::Integer,
)
    return initialise(
        _builtin_strategy_spec(config.strategy),
        design,
        config;
        n_scores,
    )
end

function _document_value(document::AbstractDict, key::String)
    haskey(document, key) && return document[key]
    symbol = Symbol(key)
    haskey(document, symbol) && return document[symbol]
    throw(ArgumentError("document is missing $(repr(key))"))
end

function _optional_document_value(
    document::AbstractDict,
    key::String,
    default=nothing,
)
    haskey(document, key) && return document[key]
    symbol = Symbol(key)
    haskey(document, symbol) && return document[symbol]
    return default
end

function model_reference_document(reference::ModelReference)
    return Dict{String,Any}(
        "path" => reference.path,
        "model_id" => reference.model_id,
        "node" => String(reference.node),
        "schema_sha256" => reference.schema_sha256,
        "coordinates_sha256" => reference.coordinates_sha256,
    )
end

function parse_model_reference(document::AbstractDict)
    return ModelReference(
        String(_document_value(document, "path")),
        String(_document_value(document, "model_id")),
        Symbol(_document_value(document, "node")),
        String(_document_value(document, "schema_sha256")),
        String(_document_value(document, "coordinates_sha256")),
    )
end

function _initialisation_document(initialisation::NormalInitialisation)
    document = Dict{String,Any}(
        "kind" => "normal",
        "centre" => String(initialisation.centre),
        "scale" => initialisation.scale,
    )
    if initialisation.reference !== nothing
        document["reference"] =
            model_reference_document(initialisation.reference)
    end
    if initialisation.coordinates !== nothing
        document["coordinates"] = copy(initialisation.coordinates)
    end
    return document
end

function _parse_initialisation(document::AbstractDict)
    String(_document_value(document, "kind")) == "normal" ||
        throw(ArgumentError("unknown search initialisation kind"))
    centre = Symbol(_document_value(document, "centre"))
    reference_document =
        _optional_document_value(document, "reference", nothing)
    reference = reference_document === nothing ?
        nothing :
        parse_model_reference(reference_document)
    coordinates = _optional_document_value(
        document,
        "coordinates",
        nothing,
    )
    return NormalInitialisation(
        ;
        centre,
        scale=_document_value(document, "scale"),
        reference,
        coordinates,
    )
end

function _option_document(options::NamedTuple)
    document = Dict{String,Any}()
    for name in propertynames(options)
        value = getproperty(options, name)
        document[String(name)] = value isa Symbol ?
            String(value) :
            value isa Tuple{Vararg{Symbol}} ?
            String.(collect(value)) :
            value
    end
    return document
end

function _parse_options(strategy::Symbol, document::AbstractDict)
    spec = _builtin_strategy_spec(strategy)
    pairs = Pair{Symbol,Any}[]
    for name in spec.allowed_options
        value = _optional_document_value(document, String(name), nothing)
        value === nothing && continue
        if name in (:reducer, :quality_reducer)
            value = Symbol(value)
        end
        push!(pairs, name => value)
    end
    provided = Set(Symbol(String(key)) for key in keys(document))
    unknown = setdiff(provided, Set(spec.allowed_options))
    isempty(unknown) || throw(ArgumentError(
        "unknown :$(strategy) options: " *
        join(":" .* string.(sort!(collect(unknown))), ", "),
    ))
    return (; pairs...)
end

function run_config_document(config::RunConfig)
    return Dict{String,Any}(
        "strategy" => String(config.strategy),
        "iterations" => config.iterations,
        "search_seed" => string(config.search_seed),
        "measure" => String(config.measure),
        "direction" => String(config.direction),
        "initialisation" =>
            _initialisation_document(config.initialisation),
        "options" => _option_document(config.options),
    )
end

function parse_run_config(document::AbstractDict)
    strategy = Symbol(_document_value(document, "strategy"))
    seed_value = _document_value(document, "search_seed")
    search_seed = seed_value isa Integer ?
        seed_value :
        parse(UInt64, String(seed_value))
    options_document = _optional_document_value(
        document,
        "options",
        Dict{String,Any}(),
    )
    options_document isa AbstractDict ||
        throw(ArgumentError("search options must be a table"))
    return RunConfig(
        ;
        strategy,
        iterations=Int(_document_value(document, "iterations")),
        search_seed,
        measure=Symbol(
            _optional_document_value(
                document,
                "measure",
                "normalized_score",
            ),
        ),
        direction=Symbol(
            _optional_document_value(
                document,
                "direction",
                "maximise",
            ),
        ),
        initialisation=_parse_initialisation(
            _document_value(document, "initialisation"),
        ),
        options=_parse_options(strategy, options_document),
    )
end

function _float_vector(value, label::AbstractString)
    value isa AbstractVector ||
        throw(ArgumentError("$(label) must be an array"))
    result = Vector{Float64}(Float64.(value))
    all(isfinite, result) ||
        throw(ArgumentError("$(label) must contain finite values"))
    return result
end

function _float_vectors(value, label::AbstractString)
    value isa AbstractVector ||
        throw(ArgumentError("$(label) must be an array"))
    return [
        _float_vector(item, "$(label) entry")
        for item in value
    ]
end

function _proposal_document(proposal::CandidateProposal)
    return Dict{String,Any}(
        "id" => proposal.id,
        "iteration" => proposal.iteration,
        "coordinates" => copy(proposal.coordinates),
    )
end

function _parse_proposal(document::AbstractDict)
    return CandidateProposal(
        Int(_document_value(document, "id")),
        Int(_document_value(document, "iteration")),
        _float_vector(
            _document_value(document, "coordinates"),
            "proposal coordinates",
        ),
    )
end

function _core_document(core::SepCore)
    return Dict{String,Any}(
        "n_dim" => core.n_dim,
        "lambda" => core.lambda,
        "mu" => core.mu,
        "weights" => copy(core.weights),
        "positive_weights" => copy(core.positive_weights),
        "mu_eff" => core.mu_eff,
        "c_sigma" => core.c_sigma,
        "d_sigma" => core.d_sigma,
        "c_c" => core.c_c,
        "c1" => core.c1,
        "c_mu" => core.c_mu,
        "chi_n" => core.chi_n,
        "x_mean" => copy(core.x_mean),
        "sigma" => core.sigma,
        "C_diag" => copy(core.C_diag),
        "p_c" => copy(core.p_c),
        "p_sigma" => copy(core.p_sigma),
        "countiter" => core.countiter,
        "countevals" => core.countevals,
    )
end

function _parse_core(document::AbstractDict)
    return SepCore(
        Int(_document_value(document, "n_dim")),
        Int(_document_value(document, "lambda")),
        Int(_document_value(document, "mu")),
        _float_vector(_document_value(document, "weights"), "CMA weights"),
        _float_vector(
            _document_value(document, "positive_weights"),
            "CMA positive weights",
        ),
        Float64(_document_value(document, "mu_eff")),
        Float64(_document_value(document, "c_sigma")),
        Float64(_document_value(document, "d_sigma")),
        Float64(_document_value(document, "c_c")),
        Float64(_document_value(document, "c1")),
        Float64(_document_value(document, "c_mu")),
        Float64(_document_value(document, "chi_n")),
        _float_vector(_document_value(document, "x_mean"), "CMA mean"),
        Float64(_document_value(document, "sigma")),
        _float_vector(
            _document_value(document, "C_diag"),
            "CMA diagonal covariance",
        ),
        _float_vector(_document_value(document, "p_c"), "CMA p_c"),
        _float_vector(_document_value(document, "p_sigma"), "CMA p_sigma"),
        Int(_document_value(document, "countiter")),
        Int(_document_value(document, "countevals")),
    )
end

function _state_document(state::AbstractSearchState)
    return Dict{String,Any}(
        "format" => "brainlesslab-search-state",
        "format_version" => 1,
        "strategy" => String(state.config.strategy),
        "config" => run_config_document(state.config),
        "dimension" => state.dimension,
        "iteration" => state.iteration,
        "next_id" => state.next_id,
        "pending" => _proposal_document.(state.pending),
        "n_evaluated" => state.n_evaluated,
    )
end

function snapshot(state::SepCMAState)::Dict{String,Any}
    document = _state_document(state)
    document["core"] = _core_document(state.core)
    document["selected_coordinates"] =
        state.selected_coordinates === nothing ?
        nothing :
        copy(state.selected_coordinates)
    document["selected_scores"] =
        state.selected_scores === nothing ?
        nothing :
        copy(state.selected_scores)
    document["selected_value"] =
        state.selected_coordinates === nothing ?
        nothing :
        state.selected_value
    document["selected_id"] = state.selected_id
    return document
end

function snapshot(state::NSGA2State)::Dict{String,Any}
    document = _state_document(state)
    document["n_scores"] = state.n_scores
    document["population_size"] = state.population_size
    document["lower"] = copy(state.lower)
    document["upper"] = copy(state.upper)
    document["population"] = copy.(state.population)
    document["scores"] = copy.(state.scores)
    document["validity"] = copy(state.validity)
    return document
end

function snapshot(state::CMAMEState)::Dict{String,Any}
    document = _state_document(state)
    document["n_scores"] = state.n_scores
    document["bins"] = state.bins
    document["emitter_count"] = state.emitter_count
    document["emitter_population"] = state.emitter_population
    document["patience"] = state.patience
    document["centre"] = copy(state.centre)
    document["pending_emitters"] = copy(state.pending_emitters)
    document["emitters"] = [
        Dict{String,Any}(
            "core" => _core_document(emitter.core),
            "since_improvement" => emitter.since_improvement,
            "needs_restart" => emitter.needs_restart,
        )
        for emitter in state.emitters
    ]
    document["archive"] = [
        Dict{String,Any}(
            "cell" => collect(key),
            "coordinates" => copy(state.archive[key].coordinates),
            "descriptor" => copy(state.archive[key].descriptor),
            "quality" => state.archive[key].quality,
            "oriented_quality" =>
                state.archive[key].oriented_quality,
        )
        for key in sort!(collect(keys(state.archive)))
    ]
    return document
end

function _validate_state_document(
    spec::SearchStrategySpec,
    document::AbstractDict,
)
    String(_document_value(document, "format")) ==
        "brainlesslab-search-state" ||
        throw(ArgumentError("unknown search state format"))
    Int(_document_value(document, "format_version")) == 1 ||
        throw(ArgumentError("unsupported search state format version"))
    strategy = Symbol(_document_value(document, "strategy"))
    strategy === spec.key || throw(ArgumentError(
        "snapshot strategy :$(strategy) does not match :$(spec.key)",
    ))
    config = parse_run_config(_document_value(document, "config"))
    config.strategy === spec.key || throw(ArgumentError(
        "snapshot RunConfig does not match :$(spec.key)",
    ))
    pending = CandidateProposal[
        _parse_proposal(item)
        for item in _document_value(document, "pending")
    ]
    return (
        config=config,
        dimension=Int(_document_value(document, "dimension")),
        iteration=Int(_document_value(document, "iteration")),
        next_id=Int(_document_value(document, "next_id")),
        pending=pending,
        n_evaluated=Int(_document_value(document, "n_evaluated")),
    )
end

function _restore_sepcma(
    common,
    document::AbstractDict,
)
    selected_coordinates_ =
        _optional_document_value(
            document,
            "selected_coordinates",
            nothing,
        )
    selected_scores_ =
        _optional_document_value(document, "selected_scores", nothing)
    return SepCMAState(
        common.config,
        common.dimension,
        _parse_core(_document_value(document, "core")),
        common.iteration,
        common.next_id,
        common.pending,
        selected_coordinates_ === nothing ?
        nothing :
        _float_vector(selected_coordinates_, "selected coordinates"),
        selected_scores_ === nothing ?
        nothing :
        _float_vector(selected_scores_, "selected scores"),
        _optional_document_value(document, "selected_value", nothing) === nothing ?
        -Inf :
        Float64(_document_value(document, "selected_value")),
        Int(_document_value(document, "selected_id")),
        common.n_evaluated,
    )
end

function _restore_nsga2(common, document::AbstractDict)
    validity = Vector{Bool}(_document_value(document, "validity"))
    population =
        _float_vectors(_document_value(document, "population"), "population")
    scores = _float_vectors(_document_value(document, "scores"), "scores")
    length(population) == length(scores) == length(validity) ||
        throw(DimensionMismatch("NSGA-II snapshot population is inconsistent"))
    return NSGA2State(
        common.config,
        common.dimension,
        Int(_document_value(document, "n_scores")),
        Int(_document_value(document, "population_size")),
        _float_vector(_document_value(document, "lower"), "lower bounds"),
        _float_vector(_document_value(document, "upper"), "upper bounds"),
        population,
        scores,
        validity,
        common.iteration,
        common.next_id,
        common.pending,
        common.n_evaluated,
    )
end

function _restore_cmame(common, document::AbstractDict)
    emitters = CMAEmitter[
        CMAEmitter(
            _parse_core(_document_value(item, "core")),
            Int(_document_value(item, "since_improvement")),
            Bool(_document_value(item, "needs_restart")),
        )
        for item in _document_value(document, "emitters")
    ]
    archive = Dict{Tuple{Vararg{Int}},ArchiveCell}()
    for item in _document_value(document, "archive")
        key = Tuple(Int.(collect(_document_value(item, "cell"))))
        archive[key] = (
            coordinates=_float_vector(
                _document_value(item, "coordinates"),
                "archive coordinates",
            ),
            descriptor=_float_vector(
                _document_value(item, "descriptor"),
                "archive descriptor",
            ),
            quality=Float64(_document_value(item, "quality")),
            oriented_quality=Float64(
                _document_value(item, "oriented_quality"),
            ),
        )
    end
    return CMAMEState(
        common.config,
        common.dimension,
        Int(_document_value(document, "n_scores")),
        Int(_document_value(document, "bins")),
        Int(_document_value(document, "emitter_count")),
        Int(_document_value(document, "emitter_population")),
        Int(_document_value(document, "patience")),
        _float_vector(_document_value(document, "centre"), "CMA-ME centre"),
        emitters,
        archive,
        common.iteration,
        common.next_id,
        common.pending,
        Int.(_document_value(document, "pending_emitters")),
        common.n_evaluated,
    )
end

function restore(
    spec::SearchStrategySpec,
    document::AbstractDict,
)::AbstractSearchState
    common = _validate_state_document(spec, document)
    spec.key === :sepcma && return _restore_sepcma(common, document)
    spec.key === :nsga2 && return _restore_nsga2(common, document)
    spec.key === :cmame && return _restore_cmame(common, document)
    throw(ArgumentError("unsupported search strategy :$(spec.key)"))
end

end # module Evolution
