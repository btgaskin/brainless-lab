using BrainlessLab
using NPZ
using Random
using Test

const SearchEvolution = BrainlessLab.Evolution
const SEARCH_CMA_TRACE_ATOL = 1e-12

struct SearchStrategyToyModel <: BrainlessLab.NodeModel
    gain::Float64
    bias::Float64
end

function _search_design()
    return SearchEvolution.NodeDesignSpec(
        SearchStrategyToyModel,
        (
            SearchEvolution.DesignBlock(:gain, (1,), 1:1),
            SearchEvolution.DesignBlock(:bias, (1,), 2:2),
        ),
        model -> [model.gain, model.bias],
        coordinates ->
            SearchStrategyToyModel(coordinates[1], coordinates[2]),
    )
end

function _proposal_coordinates(proposals)
    return [copy(proposal.coordinates) for proposal in proposals]
end

function _portable_search_document(value)
    if value isa Union{Nothing,Bool,Integer,AbstractFloat,String}
        return !(value isa AbstractFloat) || isfinite(value)
    elseif value isa AbstractVector
        return all(_portable_search_document, value)
    elseif value isa AbstractDict
        return all(key -> key isa String, keys(value)) &&
            all(_portable_search_document, values(value))
    end
    return false
end

function _state_has_rng(state)
    return any(
        name -> getfield(state, name) isa Random.AbstractRNG,
        fieldnames(typeof(state)),
    )
end

function _search_fixture_path(name::AbstractString)
    return joinpath(@__DIR__, "fixtures", name)
end

@testset "experimental node design and model references" begin
    design = _search_design()
    @test design.model_type === SearchStrategyToyModel
    @test design.dimension == 2
    @test design.stability === :experimental
    @test SearchEvolution.encode(
        design,
        SearchStrategyToyModel(0.2, -0.4),
    ) == [0.2, -0.4]
    @test SearchEvolution.decode(design, [0.3, 0.7]) ==
        SearchStrategyToyModel(0.3, 0.7)

    @test_throws DimensionMismatch SearchEvolution.DesignBlock(
        :bad,
        (2,),
        1:1,
    )
    @test_throws ArgumentError SearchEvolution.NodeDesignSpec(
        SearchStrategyToyModel,
        (
            SearchEvolution.DesignBlock(:first, (1,), 1:1),
            SearchEvolution.DesignBlock(:gap, (1,), 3:3),
        ),
        identity,
        identity,
    )

    reference = SearchEvolution.ModelReference(
        "models/falandays/reference.toml",
        "falandays-default",
        :falandays,
        repeat("a", 64),
        repeat("b", 64),
    )
    reference_document =
        SearchEvolution.model_reference_document(reference)
    parsed_reference =
        SearchEvolution.parse_model_reference(reference_document)
    @test SearchEvolution.model_reference_document(parsed_reference) ==
        reference_document
    @test_throws ArgumentError SearchEvolution.ModelReference(
        "/absolute/reference.toml",
        "model",
        :falandays,
        repeat("a", 64),
        repeat("b", 64),
    )
    @test_throws ArgumentError SearchEvolution.ModelReference(
        "models/../reference.toml",
        "model",
        :falandays,
        repeat("a", 64),
        repeat("b", 64),
    )

    unresolved = SearchEvolution.NormalInitialisation(
        ;
        centre=:model,
        scale=0.5,
        reference,
    )
    @test unresolved.coordinates === nothing
    @test_throws ArgumentError SearchEvolution.initialise(
        design,
        SearchEvolution.RunConfig(
            ;
            strategy=:sepcma,
            iterations=1,
            search_seed=1,
            initialisation=unresolved,
            options=(reducer=:mean,),
        );
        n_scores=1,
    )
end

@testset "run configuration and strategy capabilities" begin
    initialisation = SearchEvolution.NormalInitialisation(; scale=0.4)
    config = SearchEvolution.RunConfig(
        ;
        strategy=:sepcma,
        iterations=3,
        search_seed=9,
        initialisation,
        options=(population=4, reducer=:minimum),
    )
    @test config.measure === :normalized_score
    @test config.direction === :maximise
    @test config.search_seed === UInt64(9)
    @test SearchEvolution.parse_run_config(
        SearchEvolution.run_config_document(config),
    ).options == config.options

    specs = SearchEvolution.builtin_strategy_specs()
    @test getfield.(specs, :key) == (:sepcma, :nsga2, :cmame)
    @test all(spec -> spec.stability === :experimental, specs)
    @test sort(collect(getfield.(specs, :key))) ==
        [:cmame, :nsga2, :sepcma]

    @test_throws ArgumentError SearchEvolution.RunConfig(
        ;
        strategy=:sepcma,
        iterations=1,
        search_seed=1,
        initialisation,
    )
    @test_throws ArgumentError SearchEvolution.RunConfig(
        ;
        strategy=:sepcma,
        iterations=1,
        search_seed=1,
        initialisation,
        options=(reducer=:mean, targets=(:a,)),
    )
    @test_throws ArgumentError SearchEvolution.RunConfig(
        ;
        strategy=:nsga2,
        iterations=1,
        search_seed=1,
        initialisation,
        options=(population=3,),
    )

    nsga_config = SearchEvolution.RunConfig(
        ;
        strategy=:nsga2,
        iterations=1,
        search_seed=1,
        initialisation,
        options=(population=4,),
    )
    @test_throws ArgumentError SearchEvolution.validate_strategy(
        SearchEvolution.nsga2_spec(),
        nsga_config,
        1,
    )
    @test SearchEvolution.validate_strategy(
        SearchEvolution.nsga2_spec(),
        nsga_config,
        2,
    ) == 2

    cmame_config = SearchEvolution.RunConfig(
        ;
        strategy=:cmame,
        iterations=1,
        search_seed=1,
        measure=:raw_score,
        initialisation,
        options=(quality_reducer=:mean,),
    )
    @test_throws ArgumentError SearchEvolution.validate_strategy(
        SearchEvolution.cmame_spec(),
        cmame_config,
        2,
    )
end

@testset "SepCMA lifecycle selects through an explicit reducer" begin
    design = _search_design()
    config = SearchEvolution.RunConfig(
        ;
        strategy=:sepcma,
        iterations=2,
        search_seed=41,
        direction=:maximise,
        initialisation=SearchEvolution.NormalInitialisation(; scale=0.25),
        options=(population=4, reducer=:mean),
    )
    first = SearchEvolution.initialise(design, config; n_scores=2)
    second = SearchEvolution.initialise(design, config; n_scores=2)
    @test !_state_has_rng(first)

    first_proposals =
        SearchEvolution.propose!(first, Random.Xoshiro(500))
    second_proposals =
        SearchEvolution.propose!(second, Random.Xoshiro(500))
    @test _proposal_coordinates(first_proposals) ==
        _proposal_coordinates(second_proposals)

    observations = [
        SearchEvolution.Observation(
            proposal,
            index == 1 ? [100.0, 100.0] : [index / 10, index / 20];
            valid=index != 1,
        )
        for (index, proposal) in enumerate(first_proposals)
    ]
    SearchEvolution.observe!(first, observations)
    selected = SearchEvolution.outcome(first)
    @test propertynames(selected) == (:kind, :selected, :n_evaluated)
    @test selected.kind === :selected
    @test selected.selected.id != first_proposals[1].id

    document = SearchEvolution.snapshot(first)
    @test document isa Dict{String,Any}
    @test _portable_search_document(document)
    restored = SearchEvolution.restore(
        SearchEvolution.sepcma_spec(),
        document,
    )
    first_next =
        SearchEvolution.propose!(first, Random.Xoshiro(700))
    restored_next =
        SearchEvolution.propose!(restored, Random.Xoshiro(700))
    @test _proposal_coordinates(first_next) ==
        _proposal_coordinates(restored_next)

    invalid_only =
        SearchEvolution.initialise(design, config; n_scores=2)
    invalid_proposals = SearchEvolution.propose!(
        invalid_only,
        Random.Xoshiro(800),
    )
    SearchEvolution.observe!(
        invalid_only,
        [
            SearchEvolution.Observation(
                proposal,
                [0.0, 0.0];
                valid=false,
            )
            for proposal in invalid_proposals
        ],
    )
    invalid_document = SearchEvolution.snapshot(invalid_only)
    @test invalid_document["selected_value"] === nothing
    @test _portable_search_document(invalid_document)
    @test SearchEvolution.snapshot(
        SearchEvolution.restore(
            SearchEvolution.sepcma_spec(),
            invalid_document,
        ),
    ) == invalid_document
    @test_throws ArgumentError SearchEvolution.outcome(invalid_only)
end

@testset "SepCMA injected pycma trace parity" begin
    data = npzread(_search_fixture_path("cma_sphere_trace.npz"))
    x0 = Float64.(vec(data["x0"]))
    sigma0 = Float64(data["sigma0"])
    population_size = Int(data["popsize"])
    populations = Float64.(data["X"])
    losses = Float64.(data["losses"])
    reference_means = Float64.(data["mean"])
    reference_sigmas = Float64.(vec(data["sigma"]))

    @test size(populations) == (10, population_size, length(x0))
    @test size(losses) == (size(populations, 1), population_size)
    @test size(reference_means) == (size(populations, 1), length(x0))
    @test length(reference_sigmas) == size(populations, 1)

    core = SearchEvolution._new_sep_core(
        x0,
        sigma0,
        population_size,
    )
    for generation in axes(populations, 1)
        candidates = [
            Float64.(vec(populations[generation, index, :]))
            for index in axes(populations, 2)
        ]
        generation_losses = Float64.(vec(losses[generation, :]))
        @test generation_losses ≈ sum.(abs2, candidates) atol =
            SEARCH_CMA_TRACE_ATOL rtol = SEARCH_CMA_TRACE_ATOL

        SearchEvolution._sep_observe!(
            core,
            candidates,
            generation_losses,
        )

        @test core.x_mean ≈
            Float64.(vec(reference_means[generation, :])) atol =
            SEARCH_CMA_TRACE_ATOL rtol = SEARCH_CMA_TRACE_ATOL
        @test core.sigma ≈ reference_sigmas[generation] atol =
            SEARCH_CMA_TRACE_ATOL rtol = SEARCH_CMA_TRACE_ATOL
    end
end

@testset "NSGA-II returns only the Pareto set" begin
    design = _search_design()
    config = SearchEvolution.RunConfig(
        ;
        strategy=:nsga2,
        iterations=2,
        search_seed=42,
        initialisation=SearchEvolution.NormalInitialisation(; scale=0.2),
        options=(population=4,),
    )
    state = SearchEvolution.initialise(design, config; n_scores=2)
    @test !_state_has_rng(state)
    proposals =
        SearchEvolution.propose!(state, Random.Xoshiro(501))
    scores = ([0.0, 1.0], [0.4, 0.6], [1.0, 0.0], [10.0, 10.0])
    SearchEvolution.observe!(
        state,
        [
            SearchEvolution.Observation(
                proposal,
                scores[index];
                valid=index != 4,
            )
            for (index, proposal) in enumerate(proposals)
        ],
    )
    result = SearchEvolution.outcome(state)
    @test propertynames(result) == (:kind, :pareto)
    @test result.kind === :pareto
    @test all(entry -> entry.valid, result.pareto)
    @test length(result.pareto) == 3

    document = SearchEvolution.snapshot(state)
    @test _portable_search_document(document)
    restored = SearchEvolution.restore(
        SearchEvolution.nsga2_spec(),
        document,
    )
    original_next =
        SearchEvolution.propose!(state, Random.Xoshiro(701))
    restored_next =
        SearchEvolution.propose!(restored, Random.Xoshiro(701))
    @test _proposal_coordinates(original_next) ==
        _proposal_coordinates(restored_next)
end

@testset "CMA-ME returns only a normalised descriptor archive" begin
    design = _search_design()
    config = SearchEvolution.RunConfig(
        ;
        strategy=:cmame,
        iterations=2,
        search_seed=43,
        initialisation=SearchEvolution.NormalInitialisation(; scale=0.3),
        options=(
            bins=3,
            emitters=2,
            emitter_population=2,
            patience=2,
            quality_reducer=:mean,
        ),
    )
    invalid_state =
        SearchEvolution.initialise(design, config; n_scores=2)
    invalid_proposals = SearchEvolution.propose!(
        invalid_state,
        Random.Xoshiro(502),
    )
    @test_throws ArgumentError SearchEvolution.observe!(
        invalid_state,
        [
            SearchEvolution.Observation(proposal, [1.1, 0.5])
            for proposal in invalid_proposals
        ],
    )

    failed_state =
        SearchEvolution.initialise(design, config; n_scores=2)
    failed_proposals = SearchEvolution.propose!(
        failed_state,
        Random.Xoshiro(504),
    )
    SearchEvolution.observe!(
        failed_state,
        [
            SearchEvolution.Observation(
                proposal,
                [10.0, -10.0];
                valid=false,
            )
            for proposal in failed_proposals
        ],
    )
    @test_throws ArgumentError SearchEvolution.outcome(failed_state)

    state = SearchEvolution.initialise(design, config; n_scores=2)
    @test !_state_has_rng(state)
    proposals =
        SearchEvolution.propose!(state, Random.Xoshiro(503))
    descriptors = ([0.0, 0.5], [0.4, 0.4], [0.7, 0.2], [1.0, 1.0])
    SearchEvolution.observe!(
        state,
        [
            SearchEvolution.Observation(proposal, descriptors[index])
            for (index, proposal) in enumerate(proposals)
        ],
    )
    result = SearchEvolution.outcome(state)
    @test propertynames(result) == (:kind, :archive)
    @test result.kind === :archive
    @test !isempty(result.archive)
    @test all(
        entry -> all(score -> 0.0 <= score <= 1.0, entry.descriptor),
        result.archive,
    )

    document = SearchEvolution.snapshot(state)
    @test _portable_search_document(document)
    restored = SearchEvolution.restore(
        SearchEvolution.cmame_spec(),
        document,
    )
    original_next =
        SearchEvolution.propose!(state, Random.Xoshiro(703))
    restored_next =
        SearchEvolution.propose!(restored, Random.Xoshiro(703))
    @test _proposal_coordinates(original_next) ==
        _proposal_coordinates(restored_next)
end
