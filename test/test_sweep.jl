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
    header = BrainlessLab._parse_csv_record(first(lines))
    return [
        Dict(header[i] => BrainlessLab._parse_csv_record(line)[i] for i in eachindex(header))
        for line in lines[2:end]
        if !isempty(strip(line))
    ]
end

function _write_tiny_sweep(path; node="falandays_base", task="wall", axes=Dict("\"node.threshold_mult\"" => "[1.8]"), seeds="[0]", measures="[\"liveness\"]", max_cells=10)
    open(path, "w") do io
        println(io, "[sweep]")
        println(io, "id = \"", splitext(basename(path))[1], "\"")
        println(io, "mode = \"one_at_a_time\"")
        println(io, "seeds = ", seeds)
        println(io, "max_cells = ", max_cells)
        println(io)
        println(io, "[baseline]")
        println(io, "node = \"", node, "\"")
        println(io, "task = \"", task, "\"")
        println(io, "N = 8")
        println(io, "ticks = 8")
        println(io, "window = 8")
        task in ("torus", "forage") && println(io, "n_agents = 2")
        println(io)
        println(io, "[axes]")
        for (axis, values) in axes
            println(io, axis, " = ", values)
        end
        println(io)
        println(io, "[analytics]")
        println(io, "measures = ", measures)
    end
    return path
end

@testset "Perturbation sweep engine" begin
    dir = mktempdir()
    config = _sweep_test_config(joinpath(dir, "sweep.toml"))

    sweep = run_sweep(config; root=joinpath(dir, "out"), force=true)
    @test length(sweep.cells) == 4
    @test isfile(joinpath(sweep.dir, "manifest.toml"))
    @test isfile(joinpath(sweep.dir, "config.resolved.toml"))
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
    err_blocked = try
        run_sweep(blocked; root=joinpath(dir, "blocked-out"))
        nothing
    catch caught
        caught
    end
    @test err_blocked isa ArgumentError
    @test occursin("rollouts above max_rollouts", sprint(showerror, err_blocked))

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

    bad_env_axis = _write_tiny_sweep(
        joinpath(dir, "bad-env-axis.toml");
        task="tracking",
        axes=Dict("\"env.lam\"" => "[0.5]"),
    )
    err_env = try
        run_sweep(bad_env_axis; root=joinpath(dir, "bad-env-out"), force=true)
        nothing
    catch caught
        caught
    end
    @test err_env isa ArgumentError
    @test occursin("unknown axis 'env.lam'", sprint(showerror, err_env))

    bad_drive_axis = _write_tiny_sweep(
        joinpath(dir, "bad-drive-axis.toml");
        node="sorn",
        axes=Dict("\"drive.noise_gain\"" => "[0.2]"),
    )
    err_drive = try
        run_sweep(bad_drive_axis; root=joinpath(dir, "bad-drive-out"), force=true)
        nothing
    catch caught
        caught
    end
    @test err_drive isa ArgumentError
    @test occursin("unknown axis 'drive.noise_gain'", sprint(showerror, err_drive))

    @test_throws ArgumentError sweepable_axes(:sron, :wall)
    @test_throws ArgumentError sweepable_axes(:sorn, :waall)

    roundtrip = joinpath(dir, "roundtrip.csv")
    rows_with_commas = [
        Dict{String,Any}("seed" => 1, "alive" => false, "warnings" => "failed, with comma", "error" => "boom, exact", "score" => NaN),
    ]
    BrainlessLab._write_rows_csv(roundtrip, rows_with_commas; header=["seed", "alive", "warnings", "error", "score"])
    reread = BrainlessLab._read_simple_csv(roundtrip)
    @test reread[1]["warnings"] == "failed, with comma"
    @test reread[1]["error"] == "boom, exact"

    failing = _write_tiny_sweep(
        joinpath(dir, "failing-cell.toml");
        axes=Dict("\"task.N\"" => "[8, 0]"),
    )
    failed_out = run_sweep(failing; root=joinpath(dir, "failing-out"), force=true)
    failed_rows = _csv_rows(failed_out.results)
    @test length(failed_rows) == 2
    @test any(row -> !isempty(row["errors"]), failed_rows)
    @test occursin("Cells with recorded errors: 1 / 2", read(joinpath(failed_out.dir, "README.md"), String))

    sorn_sweep = _write_tiny_sweep(
        joinpath(dir, "sorn-sweep.toml");
        node="sorn",
        axes=Dict("\"node.learn_on\"" => "[true]"),
    )
    sorn_out = run_sweep(sorn_sweep; root=joinpath(dir, "sorn-out"), force=true)
    @test length(sorn_out.cells) == 1
    @test isfile(sorn_out.results)

    forage_sweep = _write_tiny_sweep(
        joinpath(dir, "forage-sweep.toml");
        task="forage",
        axes=Dict("\"env.source_gain\"" => "[1.0]"),
    )
    forage_out = run_sweep(forage_sweep; root=joinpath(dir, "forage-out"), force=true)
    @test length(forage_out.cells) == 1
    @test isfile(forage_out.results)
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
    frozen = BrainlessLab._build_ensemble(
        :wall,
        :falandays_base;
        ticks=6,
        seed=3,
        n_nodes=12,
        ablation=:freeze_plasticity,
        record=Symbol[],
    )
    frozen_r = frozen.ensemble.agents[1].reservoir
    @test frozen_r.params.learn_on == false
    w0 = copy(frozen_r.wmat)
    rollout!(frozen.ensemble, 6; window=6)
    @test frozen_r.wmat == w0

    clamped = BrainlessLab._build_ensemble(
        :wall,
        :falandays_base;
        ticks=1,
        seed=4,
        n_nodes=12,
        ablation=:clamp_target,
        record=Symbol[],
    )
    @test clamped.ensemble.agents[1].reservoir.params.lrate_targ == 0.0

    zeroed = BrainlessLab._build_ensemble(
        :wall,
        :falandays_base;
        ticks=1,
        seed=5,
        n_nodes=12,
        ablation=:zero_recurrent,
        record=Symbol[],
    )
    zero_r = zeroed.ensemble.agents[1].reservoir
    @test all(iszero, zero_r.wmat)
    @test all(iszero, zero_r.wmat0)
    @test !any(zero_r.recurrent_mask)

    forage = BrainlessLab._build_ensemble(
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
    env = forage.ensemble.environment
    @test env.config.conspecific_vision == false
    bodies = [agent.body for agent in forage.ensemble.agents]
    percepts = observe(env, bodies)
    receptors_ = receptors(bodies[1], percepts[1])
    @test all(iszero, @view(receptors_[1:BrainlessLab.VEN_BANK_RECEPTORS]))
end
