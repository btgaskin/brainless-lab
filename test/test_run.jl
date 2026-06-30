using BrainlessLab
using JLD2
using TOML
using Test

function _tiny_run_config(; name="tiny-run", seed=17, generations=3, popsize=6, k_trials=2, N=40, ticks=80)
    return resolve(RunConfig(
        run=BrainlessLab.RunSection(
            name=name,
            driver=:evolve,
            seed_base=seed,
            suite_seed_base=seed + 100_000,
            profile=:teaching,
        ),
        model=BrainlessLab.ModelSection(
            family=:falandays,
            node=:falandays,
        ),
        task=BrainlessLab.TaskSection(
            train=(:wall,),
            suite=(:wall,),
            aggregator=:min,
            N=N,
            ticks=ticks,
            window=ticks,
            link_p=0.1,
            rho=0.2,
            lam=1.0,
        ),
        evolve=BrainlessLab.EvolveSection(
            generations=generations,
            popsize=popsize,
            sigma0=2.5,
            k_trials=k_trials,
            suite_every=0,
            k_suite=0,
            cma_seed=seed,
            threaded=false,
        ),
    ))
end

@testset "Run config round trip" begin
    cfg = _tiny_run_config()
    dir = mktempdir()
    path = joinpath(dir, "resolved.toml")
    write_config(cfg, path)
    reread = read_config(path)

    @test reread == cfg
    @test resolve(reread) == cfg
end

@testset "Run experiment artifacts" begin
    cfg = _tiny_run_config(seed=23)
    dir = mktempdir()
    out = run_experiment(cfg; dir=joinpath(dir, "run"))

    @test isdir(out.dir)
    @test isfile(joinpath(out.dir, "manifest.toml"))
    @test isfile(joinpath(out.dir, "config.resolved.toml"))
    @test isfile(joinpath(out.dir, "seeds.json"))
    @test isfile(joinpath(out.dir, "logs", "evolve_log.csv"))
    @test isfile(joinpath(out.dir, "logs", "suite_log.jsonl"))
    @test isfile(joinpath(out.dir, "genomes", "best.jld2"))
    @test isfile(joinpath(out.dir, "metrics", "final.json"))

    manifest = TOML.parsefile(joinpath(out.dir, "manifest.toml"))
    @test haskey(manifest, "git_sha")
    @test manifest["git_sha"] isa AbstractString
    @test haskey(manifest, "manifest_sha")
    @test haskey(manifest, "manifest_toml_fnv1a")
    @test manifest["manifest_sha"] == manifest["manifest_toml_fnv1a"]
    @test manifest["manifest_sha"] isa AbstractString
    @test haskey(manifest, "julia_version")
    @test haskey(manifest, "seeds")
    @test manifest["seeds"]["seed_base"] == cfg.run.seed_base
    @test manifest["seeds"]["cma_seed"] == cfg.evolve.cma_seed

    evolve_rows = readlines(joinpath(out.dir, "logs", "evolve_log.csv"))
    @test length(evolve_rows) >= cfg.evolve.generations + 1

    checkpoint = JLD2.load(joinpath(out.dir, "genomes", "best.jld2"))
    @test haskey(checkpoint, "best")
    @test haskey(checkpoint, "best_fitness")
    @test checkpoint["best_fitness"] == out.result.best_fitness
end

@testset "Run reproducibility from artifacts" begin
    cfg = _tiny_run_config(seed=31)
    dir = mktempdir()
    first = run_experiment(cfg; dir=joinpath(dir, "first"))

    artifact_cfg = read_config(joinpath(first.dir, "config.resolved.toml"))
    second = run_experiment(artifact_cfg; dir=joinpath(dir, "second"))

    @test reinterpret(UInt64, first.result.best_fitness) == reinterpret(UInt64, second.result.best_fitness)

    first_log = read(joinpath(first.dir, "logs", "evolve_log.csv"))
    second_log = read(joinpath(second.dir, "logs", "evolve_log.csv"))
    @test first_log == second_log
end

@testset "Sweep harness" begin
    dir = mktempdir()
    sweep_path = joinpath(dir, "sweep.toml")
    open(sweep_path, "w") do io
        println(io, "[sweep]")
        println(io, "id = \"two-seed-smoke\"")
        println(io)
        println(io, "[run]")
        println(io, "name = \"sweep-cell\"")
        println(io, "driver = \"evolve\"")
        println(io, "profile = \"teaching\"")
        println(io)
        println(io, "[model]")
        println(io, "family = \"falandays\"")
        println(io, "node = \"falandays\"")
        println(io)
        println(io, "[task]")
        println(io, "train = [\"wall\"]")
        println(io, "suite = [\"wall\"]")
        println(io, "aggregator = \"min\"")
        println(io, "N = 12")
        println(io, "ticks = 20")
        println(io, "window = 20")
        println(io)
        println(io, "[evolve]")
        println(io, "generations = 1")
        println(io, "popsize = 4")
        println(io, "sigma0 = 2.5")
        println(io, "k_trials = 1")
        println(io, "suite_every = 0")
        println(io, "k_suite = 0")
        println(io, "threaded = false")
        println(io)
        println(io, "[axes]")
        println(io, "seed = [0, 1]")
    end

    sweep = run_sweep(sweep_path; root=joinpath(dir, "sweeps"))
    @test length(sweep.cells) == 2
    @test isfile(sweep.index)
    @test all(row -> isdir(row["result_path"]), sweep.cells)
    @test all(row -> isfile(joinpath(row["result_path"], "DONE")), sweep.cells)

    index_rows = readlines(sweep.index)
    @test length(index_rows) == 3

    first_index = read(sweep.index, String)
    first_manifests = Dict(
        row["cell"] => read(joinpath(row["result_path"], "manifest.toml"), String)
        for row in sweep.cells
    )

    resumed = run_sweep(sweep_path; root=joinpath(dir, "sweeps"))
    @test length(resumed.cells) == 2
    @test resumed.dir == sweep.dir
    @test read(resumed.index, String) == first_index
    @test all(row -> isfile(joinpath(row["result_path"], "DONE")), resumed.cells)
    @test all(
        row -> read(joinpath(row["result_path"], "manifest.toml"), String) == first_manifests[row["cell"]],
        resumed.cells,
    )
end
