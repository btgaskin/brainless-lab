using BrainlessLab
using Test

function _sweep_test_config(path; max_cells=10)
    open(path, "w") do io
        println(io, "[sweep]")
        println(io, "id = \"tiny-sweep\"")
        println(io, "mode = \"one_at_a_time\"")
        println(io, "seeds = [0]")
        println(io, "max_cells = ", max_cells)
        println(io)
        println(io, "[baseline]")
        println(io, "node = \"falandays_base\"")
        println(io, "task = \"wall\"")
        println(io, "N = 10")
        println(io, "ticks = 24")
        println(io, "window = 24")
        println(io)
        println(io, "[axes]")
        println(io, "\"node.threshold_mult\" = [1.8, 2.0]")
        println(io, "\"drive.noise_gain\" = [0.0, 0.2]")
        println(io)
        println(io, "[analytics]")
        println(io, "measures = [\"liveness\", \"spectral_radius\"]")
    end
    return path
end

function _csv_header(path)
    return split(first(readlines(path)), ",")
end

function _csv_rows(path)
    lines = readlines(path)
    header = split(first(lines), ",")
    return [
        Dict(header[i] => split(line, ","; keepempty=true)[i] for i in eachindex(header))
        for line in lines[2:end]
        if !isempty(strip(line))
    ]
end

@testset "Perturbation sweep engine" begin
    dir = mktempdir()
    config = _sweep_test_config(joinpath(dir, "sweep.toml"))

    sweep = run_sweep(config; root=joinpath(dir, "out"), force=true)
    @test length(sweep.cells) == 4
    @test isfile(joinpath(sweep.dir, "manifest.toml"))
    @test isfile(joinpath(sweep.dir, "sweep.resolved.toml"))
    @test isfile(joinpath(sweep.dir, "README.md"))
    @test isfile(joinpath(sweep.dir, "results.csv"))

    header = _csv_header(joinpath(sweep.dir, "results.csv"))
    for col in ("cell", "axis", "value", "score_mean", "score_std", "spectral_radius_mean", "liveness_mean")
        @test col in header
    end

    rows = _csv_rows(joinpath(sweep.dir, "results.csv"))
    @test length(rows) == 4
    @test all(row -> isfinite(parse(Float64, row["score_mean"])), rows)
    @test all(row -> isfinite(parse(Float64, row["liveness_mean"])), rows)
    @test all(row -> isfile(joinpath(row["result_path"], "metrics.csv")), rows)
    @test all(row -> isfile(joinpath(row["result_path"], "representative.gif")), rows)

    blocked = _sweep_test_config(joinpath(dir, "blocked.toml"); max_cells=1)
    @test_throws ArgumentError run_sweep(blocked; root=joinpath(dir, "blocked-out"))

    axis_paths = [axis.path for axis in sweepable_axes(:falandays_base, :wall)]
    @test "node.threshold_mult" in axis_paths
    @test "ablation" in axis_paths

    bad = joinpath(dir, "bad-axis.toml")
    _sweep_test_config(bad)
    text = read(bad, String)
    write(bad, replace(text, "node.threshold_mult" => "node.threshhold_mult"))
    err = try
        run_sweep(bad; root=joinpath(dir, "bad-out"), force=true)
        nothing
    catch caught
        caught
    end
    @test err isa ArgumentError
    @test occursin("did you mean 'node.threshold_mult'", sprint(showerror, err))
end

@testset "Ablate shortcut" begin
    dir = mktempdir()
    out = ablate(:falandays_base, :wall; seeds=[0], root=joinpath(dir, "ablations"), N=8, ticks=12, window=12)
    @test isfile(out.results)
    @test length(out.cells) == length(ablations()) + 1
    rows = _csv_rows(out.results)
    @test any(row -> row["value"] == "none", rows)
    for name in string.(ablations())
        @test any(row -> row["value"] == name, rows)
    end
end

@testset "Named ablation effects" begin
    frozen = BrainlessLab._build_collective(
        :wall,
        :falandays_base;
        ticks=6,
        seed=3,
        n_nodes=12,
        ablation=:freeze_plasticity,
        record=Symbol[],
    )
    frozen_r = frozen.collective.agents[1].reservoir
    @test frozen_r.params.learn_on == false
    w0 = copy(frozen_r.wmat)
    rollout!(frozen.collective, 6; window=6)
    @test frozen_r.wmat == w0

    clamped = BrainlessLab._build_collective(
        :wall,
        :falandays_base;
        ticks=1,
        seed=4,
        n_nodes=12,
        ablation=:clamp_target,
        record=Symbol[],
    )
    @test clamped.collective.agents[1].reservoir.params.lrate_targ == 0.0

    zeroed = BrainlessLab._build_collective(
        :wall,
        :falandays_base;
        ticks=1,
        seed=5,
        n_nodes=12,
        ablation=:zero_recurrent,
        record=Symbol[],
    )
    zero_r = zeroed.collective.agents[1].reservoir
    @test all(iszero, zero_r.wmat)
    @test all(iszero, zero_r.wmat0)
    @test !any(zero_r.recurrent_mask)

    forage = BrainlessLab._build_collective(
        :forage,
        :falandays_base;
        ticks=1,
        seed=11,
        n_agents=2,
        n_nodes=12,
        sensory_noise=0.0,
        source_gain=2.0,
        ablation=:disable_vision,
        record=Symbol[],
    )
    env = forage.collective.environment
    @test env.config.conspecific_vision == false
    bodies = [agent.body for agent in forage.collective.agents]
    percepts = observe(env, bodies)
    receptors_ = receptors(bodies[1], percepts[1])
    @test all(iszero, @view(receptors_[1:BrainlessLab.VEN_BANK_RECEPTORS]))
end
