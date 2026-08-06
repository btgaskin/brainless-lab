using BrainlessLab
using Test

function _experiment_io_fixture()
    target = EvaluationTarget(
        :tracking,
        CompositionSpec(
            :tracking_null,
            :null_random,
            :tracking;
            n_nodes=8,
            interaction_cycle=BrainlessLab.FixedRateCycle(2),
        ),
        EvaluationSpec(
            blocks=1,
            trials_per_block=1,
            horizon=2,
            root_seed=818,
        ),
    )
    profile = ProfilePlan(:profile_tracking_null, target)
    return ExperimentSpec(
        :experiment_io,
        v"1.0.0";
        title="Experiment IO smoke",
        question="Can a versioned protocol round-trip and execute?",
        conditions=(target,),
        operations=(profile,),
        evidence_state=:planned,
        limitations=("Smoke scale only.",),
        metadata=(programme=:core_demo,),
    )
end

@testset "version-one experiments round trip" begin
    experiment = _experiment_io_fixture()
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    mktempdir() do root
        directory = joinpath(root, "experiment")
        @test write_experiment(directory, experiment; registry) == directory
        @test isfile(joinpath(directory, "experiment.toml"))
        @test isfile(joinpath(
            directory,
            "plans",
            "01-profile_tracking_null.toml",
        ))

        parsed = read_experiment(directory; registry)
        @test parsed.id === experiment.id
        @test parsed.version == experiment.version
        @test parsed.evidence_state === :planned
        @test parsed.metadata.programme == "core_demo"
        @test BrainlessLab.operation_targets(
            only(parsed.operations),
        )[1].composition.interaction_cycle ==
            BrainlessLab.FixedRateCycle(2)
        @test_throws ArgumentError write_experiment(directory, experiment; registry)
    end
end

@testset "an experiment executes its declared operations" begin
    registry = BrainlessLabTestUtils.diagnostic_registry((:tracking,))
    experiment = _experiment_io_fixture()
    mktempdir() do root
        run = run_experiment(
            experiment;
            registry,
            root=root,
            id="experiment-run",
        )
        @test length(run.results) == 1
        @test only(run.results) isa BrainlessLab.ProfileResult
        @test isfile(joinpath(run.directory, "experiment-run.toml"))
        @test isfile(joinpath(run.directory, "DONE"))
        @test isfile(joinpath(run.directory, only(run.records), "DONE"))
    end
end

@testset "checked fixed-design evolution experiment is planned and valid" begin
    directory = normpath(joinpath(
        @__DIR__,
        "..",
        "experiments",
        "examples",
        "structured-ctrnn-smoke",
    ))
    experiment = read_experiment(directory)
    @test experiment.id === :structured_ctrnn_smoke
    @test experiment.evidence_state === :planned
    @test length(experiment.operations) == 1
    @test all(operation -> operation isa EvolutionPlan, experiment.operations)
    @test Set(condition.id for condition in experiment.conditions) == Set((
        :tracking_development,
        :tracking_heldout,
    ))
    operation = only(experiment.operations)
    @test only(operation.training_targets).composition.node === :compartmental_structured
    @test length(operation.heldout_targets) == 1
    @test operation.run.strategy === :sepcma
    @test validate(experiment, DEFAULT_REGISTRY) === experiment
end
