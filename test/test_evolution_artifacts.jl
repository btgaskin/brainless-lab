using BrainlessLab
import SHA
using TOML
using Test

struct ArtifactNodeModel <: NodeModel
    gain::Float64
    weights::Vector{Float64}
end

function _artifact_design()
    return Evolution.NodeDesignSpec(
        ArtifactNodeModel,
        (
            Evolution.DesignBlock(:gain, (1,), 1:1),
            Evolution.DesignBlock(:weights, (2,), 2:3),
        ),
        model -> [model.gain; model.weights],
        coordinates -> ArtifactNodeModel(coordinates[1], coordinates[2:3]),
        ;
        stability=:experimental,
    )
end

_artifact_digest(character) = repeat(String(character), 64)
_artifact_sha256(path) = open(path, "r") do io
    bytes2hex(SHA.sha256(io))
end

@testset "portable node models round trip through text artifacts" begin
    directory = mktempdir()
    cd(directory) do
        design = _artifact_design()
        references = Evolution.write_models(
            "records/example",
            :artifact_node,
            design,
            (
                (model_id="champion", role="champion", model=ArtifactNodeModel(0.5, [1.0, 2.0])),
                (model_id="baseline", role="baseline", model=ArtifactNodeModel(0.0, [0.0, 0.0])),
            ),
        )
        @test getfield.(references, :model_id) == ["baseline", "champion"]
        champion = only(filter(reference -> reference.model_id == "champion", references))
        indexed = Evolution.model_reference("records/example", "champion")
        @test indexed.path == champion.path
        @test indexed.schema_sha256 == champion.schema_sha256
        @test indexed.coordinates_sha256 == champion.coordinates_sha256
        restored = Evolution.read_model(champion, :artifact_node, design)
        @test restored.gain == 0.5
        @test restored.weights == [1.0, 2.0]
        @test Set(readdir("records/example/models")) ==
            Set(("schema.toml", "models.csv", "coordinates.csv"))
        @test all(path -> !occursin("/private/", read(path, String)), (
            "records/example/models/schema.toml",
            "records/example/models/models.csv",
            "records/example/models/coordinates.csv",
        ))
    end
end

@testset "absolute record roots persist portable model references" begin
    parent = mktempdir()
    record = joinpath(parent, "absolute-record")
    reference = only(Evolution.write_models(
        record,
        :artifact_node,
        _artifact_design(),
        ((model_id="candidate", role="candidate", model=ArtifactNodeModel(0.5, [1.0, 2.0])),),
    ))
    @test reference.path == "absolute-record"
    @test !isabspath(reference.path)
    @test !(".." in split(reference.path, '/'))
    cd(parent) do
        @test Evolution.read_model(
            reference,
            :artifact_node,
            _artifact_design(),
        ).weights == [1.0, 2.0]
    end
    Evolution.write_checkpoint(
        record;
        completed_iteration=1,
        run_digest=_artifact_digest("a"),
        resolution_digest=_artifact_digest("b"),
        provenance_digest=_artifact_digest("c"),
        strategy_key=:sepcma,
        runner_document=Dict{String,Any}(
            "strategy" => Dict{String,Any}("iteration" => 1),
        ),
        committed_candidate_count=2,
    )
    @test Evolution.read_checkpoint(record, 1).completed_iteration == 1
end

@testset "model artifacts reject unsafe references and corrupted data" begin
    directory = mktempdir()
    cd(directory) do
        design = _artifact_design()
        reference = only(Evolution.write_models(
            "records/example",
            :artifact_node,
            design,
            ((model_id="candidate", role="candidate", model=ArtifactNodeModel(0.5, [1.0, 2.0])),),
        ))
        @test_throws ArgumentError Evolution.ModelReference(
            "../records/example",
            "candidate",
            :artifact_node,
            reference.schema_sha256,
            reference.coordinates_sha256,
        )
        @test_throws ArgumentError Evolution.read_model(reference, :wrong_node, design)

        wrong_design = Evolution.NodeDesignSpec(
            ArtifactNodeModel,
            (Evolution.DesignBlock(:all, (3,), 1:3),),
            model -> [model.gain; model.weights],
            coordinates -> ArtifactNodeModel(coordinates[1], coordinates[2:3]),
            ;
            stability=:experimental,
        )
        @test_throws ArgumentError Evolution.read_model(
            reference,
            :artifact_node,
            wrong_design,
        )

        coordinates_path = "records/example/models/coordinates.csv"
        open(coordinates_path, "a") do io
            write(io, "candidate,4,3.0\n")
        end
        @test_throws ArgumentError Evolution.read_model(
            reference,
            :artifact_node,
            design,
        )
    end

    nonfinite = mktempdir()
    cd(nonfinite) do
        @test_throws ArgumentError Evolution.write_models(
            "records/nonfinite",
            :artifact_node,
            _artifact_design(),
            ((model_id="bad", role="candidate", model=ArtifactNodeModel(Inf, [1.0, 2.0])),),
        )
        short_design = Evolution.NodeDesignSpec(
            ArtifactNodeModel,
            (
                Evolution.DesignBlock(:gain, (1,), 1:1),
                Evolution.DesignBlock(:weights, (2,), 2:3),
            ),
            model -> [model.gain, only(model.weights)],
            coordinates -> ArtifactNodeModel(coordinates[1], coordinates[2:3]),
            ;
            stability=:experimental,
        )
        @test_throws ArgumentError Evolution.write_models(
            "records/wrong-length",
            :artifact_node,
            short_design,
            ((model_id="short", role="candidate", model=ArtifactNodeModel(0.5, [1.0, 2.0])),),
        )
    end

    wrong_length = mktempdir()
    cd(wrong_length) do
        design = _artifact_design()
        reference = only(Evolution.write_models(
            "records/example",
            :artifact_node,
            design,
            ((model_id="candidate", role="candidate", model=ArtifactNodeModel(0.5, [1.0, 2.0])),),
        ))
        coordinate_path = "records/example/models/coordinates.csv"
        lines = readlines(coordinate_path)
        open(coordinate_path, "w") do io
            for line in lines[1:end - 1]
                println(io, line)
            end
        end
        coordinate_sha256 = _artifact_sha256(coordinate_path)
        schema_path = "records/example/models/schema.toml"
        schema = TOML.parsefile(schema_path)
        schema["coordinates_sha256"] = coordinate_sha256
        open(schema_path, "w") do io
            TOML.print(io, schema; sorted=true)
        end
        updated = Evolution.ModelReference(
            reference.path,
            reference.model_id,
            reference.node,
            _artifact_sha256(schema_path),
            coordinate_sha256,
        )
        @test_throws ArgumentError Evolution.read_model(
            updated,
            :artifact_node,
            design,
        )
    end
end

@testset "generation-boundary checkpoints are atomic and portable" begin
    directory = mktempdir()
    cd(directory) do
        runner = Dict{String,Any}(
            "strategy" => Dict{String,Any}(
                "mean" => [0.1, 0.2],
                "iteration" => 7,
                "nested" => (best=1.5, role=:champion),
                "optional" => nothing,
                "missing_value" => missing,
                "root_seed" => typemax(UInt64),
            ),
            "candidate_history" => [(id="candidate-1", fitness=1.0)],
            "trial_rows" => [(candidate="candidate-1", score=1.0)],
            "seed_rows" => [(candidate="candidate-1", seed=typemax(UInt64))],
        )
        checkpoint = Evolution.write_checkpoint(
            "records/run",
            ;
            completed_iteration=7,
            run_digest=_artifact_digest("a"),
            resolution_digest=_artifact_digest("b"),
            provenance_digest=_artifact_digest("c"),
            strategy_key=:sepcma,
            runner_document=runner,
            committed_candidate_count=64,
        )
        @test basename(checkpoint) == "generation-00000007"
        @test Set(readdir(checkpoint)) ==
            Set(("checkpoint.toml", "runner.toml", "DONE"))
        restored = Evolution.read_checkpoint(
            "records/run",
            7;
            run_digest=_artifact_digest("a"),
            resolution_digest=_artifact_digest("b"),
            provenance_digest=_artifact_digest("c"),
            strategy_key=:sepcma,
        )
        @test restored.completed_iteration == 7
        @test restored.committed_candidate_count == 64
        @test restored.strategy_snapshot["mean"] == [0.1, 0.2]
        @test restored.strategy_snapshot["nested"] == (best=1.5, role=:champion)
        @test restored.strategy_snapshot["optional"] === nothing
        @test ismissing(restored.strategy_snapshot["missing_value"])
        @test restored.strategy_snapshot["root_seed"] === typemax(UInt64)
        @test restored.runner_document["candidate_history"] ==
            [(id="candidate-1", fitness=1.0)]
        @test Evolution.latest_checkpoint(
            "records/run";
            run_digest=_artifact_digest("a"),
        ).completed_iteration == 7

        incomplete = "records/run/checkpoints/generation-00000008"
        mkpath(incomplete)
        write(joinpath(incomplete, "checkpoint.toml"), "format = \"incomplete\"\n")
        @test Evolution.latest_checkpoint("records/run").completed_iteration == 7
        @test_throws ArgumentError Evolution.read_checkpoint("records/run", 8)

        @test_throws ArgumentError Evolution.read_checkpoint(
            "records/run",
            7;
            resolution_digest=_artifact_digest("d"),
        )
        open(joinpath(checkpoint, "runner.toml"), "a") do io
            write(io, "\n# corruption\n")
        end
        @test_throws ArgumentError Evolution.read_checkpoint("records/run", 7)
    end
end
