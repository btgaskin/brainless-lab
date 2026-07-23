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
            interaction_cycle=FixedRateCycle(2),
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
    directory = tempname()
    @test write_experiment(directory, experiment) == directory
    @test isfile(joinpath(directory, "experiment.toml"))
    @test isfile(joinpath(directory, "plans", "01-profile_tracking_null.toml"))

    parsed = read_experiment(directory)
    @test parsed.id === experiment.id
    @test parsed.version == experiment.version
    @test parsed.evidence_state === :planned
    @test parsed.metadata.programme == "core_demo"
    @test operation_targets(only(parsed.operations))[1].composition.interaction_cycle ==
        FixedRateCycle(2)
    @test_throws ArgumentError write_experiment(directory, experiment)
end

@testset "an experiment executes its declared operations" begin
    experiment = _experiment_io_fixture()
    root = mktempdir()
    run = run_experiment(experiment; root=root, id="experiment-run")
    @test length(run.results) == 1
    @test only(run.results) isa ProfileResult
    @test isfile(joinpath(run.directory, "experiment-run.toml"))
    @test isfile(joinpath(run.directory, "DONE"))
    @test isfile(joinpath(run.directory, only(run.records), "DONE"))
end
