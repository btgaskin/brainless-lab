module CoreTaskCalibrationTest

using BrainlessLab
using Test
using TOML

include(joinpath(pkgdir(BrainlessLab), "calibration", "core_tasks.jl"))

@testset "core task calibration writes a traceable development artifact" begin
    output = mktempdir()
    unrelated_working_directory = mktempdir()
    cd(unrelated_working_directory) do
        main([
            "--seeds",
            "2",
            "--ticks",
            "20",
            "--output",
            output,
        ])
    end

    results_path = joinpath(output, "results.csv")
    report_path = joinpath(output, "README.md")
    manifest_path = joinpath(output, "manifest.toml")
    @test isfile(results_path)
    @test isfile(report_path)
    @test isfile(manifest_path)
    @test length(readlines(results_path)) == 17

    manifest = TOML.parsefile(manifest_path)["calibration"]
    @test manifest["id"] == "core-task-opportunity"
    @test manifest["evidence_status"] == "development"
    @test manifest["independent_unit"] == "one seeded task world"
    @test manifest["claim"] == "task opportunity and descriptive condition comparison"
    @test manifest["not_supported"] ==
          "confirmatory neural-mechanism or general-advantage claim"
    @test manifest["tasks"] == ["tracking", "pong"]
    @test manifest["conditions"] == ["falandays", "blind", "random", "reference"]
    @test manifest["seeds"] == [0, 1]
    @test manifest["ticks"] == 20
    @test haskey(manifest, "git_dirty")
    @test manifest["julia_threads"] == Threads.nthreads()
    @test manifest["git_sha"] ==
          readchomp(Cmd(`git rev-parse --short HEAD`; dir=pkgdir(BrainlessLab)))

    report = read(report_path, String)
    @test occursin("Development calibration only", report)
    @test occursin("Worktree dirty:", report)
    @test occursin("does not establish a neural mechanism", report)

    @test_throws ArgumentError main([
        "--seeds",
        "2",
        "--ticks",
        "20",
        "--output",
        output,
    ])
end

end
