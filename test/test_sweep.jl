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
    @test all(row -> !isfile(joinpath(row["result_path"], "representative.gif")), rows)

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

function _write_criticality_sweep(path; id=splitext(basename(path))[1], group="sample", timeseries=true, n_shifts=2, gif=false, source_values="[1.0, 2.0]")
    open(path, "w") do io
        println(io, "[sweep]")
        println(io, "id = \"", id, "\"")
        println(io, "mode = \"one_at_a_time\"")
        println(io, "seeds = [0]")
        println(io, "max_cells = 20")
        println(io)
        println(io, "[baseline]")
        println(io, "node = \"falandays_base\"")
        println(io, "task = \"forage\"")
        println(io, "N = 10")
        println(io, "n_agents = 4")
        println(io, "ticks = 72")
        println(io, "window = 72")
        println(io, "\"env.vision_range\" = 15.0")
        println(io, "\"env.sensory_noise\" = 0.0")
        println(io)
        println(io, "[axes]")
        println(io, "\"env.source_gain\" = ", source_values)
        println(io, "\"env.conspecific_vision\" = [true, false]")
        println(io)
        println(io, "[analytics]")
        println(io, "measures = [\"sigma_mr_node\", \"sigma_mr_agent\", \"dist_to_source\", \"susceptibility_node\", \"susceptibility_agent\", \"correlation_length\", \"contact_clusters\", \"spectral_radius\", \"liveness\"]")
        println(io)
        println(io, "[capture]")
        println(io, "group = \"", group, "\"")
        println(io, "timeseries = ", timeseries)
        println(io, "gif = ", gif)
        println(io, "window = 24")
        println(io, "stride = 12")
        println(io, "n_shifts = ", n_shifts)
        println(io, "seed = 123")
        println(io)
        println(io, "[capture.groups.sample]")
        println(io, "\"env.source_gain\" = 1.0")
        println(io)
        println(io, "[[ensemble]]")
        println(io, "kind = \"turn\"")
        println(io, "threshold = { quantile = 0.85 }")
        println(io, "[[ensemble]]")
        println(io, "kind = \"align\"")
        println(io, "threshold = { quantile = 0.85 }")
        println(io, "neighbor_radius = \"vision_range\"")
        println(io, "[[ensemble]]")
        println(io, "kind = \"speed\"")
        println(io, "threshold = { quantile = 0.85 }")
        println(io, "[[ensemble]]")
        println(io, "kind = \"graded\"")
    end
    return path
end

@testset "Forage criticality sweep capture" begin
    dir = mktempdir()
    config = _write_criticality_sweep(joinpath(dir, "criticality.toml"))
    out = run_sweep(config; root=joinpath(dir, "out"), force=true)
    header = _csv_header(out.results)
    for col in (
        "sigma_mr_node_mean",
        "dist_to_source_mean",
        "sigma_mr_agent__turn_q85_mean",
        "sigma_mr_agent__align_q85_mean",
        "sigma_mr_agent__speed_q85_mean",
        "sigma_mr_agent__graded_mean",
        "susceptibility_node_mean",
        "susceptibility_agent_mean",
        "correlation_length_mean",
        "cluster_largest_component_frac_mean",
    )
        @test col in header
    end

    captured = [cell for cell in out.cells if cell["captured"]]
    uncaptured = [cell for cell in out.cells if !cell["captured"]]
    @test length(captured) == 1
    @test !isempty(uncaptured)
    captured_dir = captured[1]["result_path"]
    @test isfile(joinpath(captured_dir, "criticality_timeseries.csv"))
    @test isfile(joinpath(captured_dir, "null_test.csv"))
    ts_header = _csv_header(joinpath(captured_dir, "criticality_timeseries.csv"))
    @test "m_agent__graded" in ts_header
    @test "cluster_largest_component_frac" in ts_header
    @test length(readlines(joinpath(captured_dir, "criticality_timeseries.csv"))) > 2
    null_rows = _csv_rows(joinpath(captured_dir, "null_test.csv"))
    @test any(row -> row["measure"] == "susceptibility_agent", null_rows)
    @test any(row -> row["measure"] == "sigma_mr_agent__graded", null_rows)
    @test all(cell -> isfile(joinpath(cell["result_path"], "metrics.csv")), uncaptured)
    @test all(cell -> !isfile(joinpath(cell["result_path"], "criticality_timeseries.csv")), uncaptured)

    resumed = run_sweep(config; root=joinpath(dir, "out"), force=true)
    resumed_rows = _csv_rows(resumed.results)
    @test all(row -> isfinite(parse(Float64, row["dist_to_source_mean"])), resumed_rows)
    @test all(row -> isfinite(parse(Float64, row["susceptibility_agent_mean"])), resumed_rows)
    @test all(row -> isfinite(parse(Float64, row["cluster_largest_component_frac_mean"])), resumed_rows)

    all_config = _write_criticality_sweep(joinpath(dir, "criticality-all.toml"); id="criticality-all", group="all", n_shifts=0, source_values="[1.0]")
    all_out = run_sweep(all_config; root=joinpath(dir, "all-out"), force=true)
    @test all(cell -> isfile(joinpath(cell["result_path"], "criticality_timeseries.csv")), all_out.cells)

    none_config = _write_criticality_sweep(joinpath(dir, "criticality-none.toml"); id="criticality-none", group="none", n_shifts=0, source_values="[1.0]")
    none_out = run_sweep(none_config; root=joinpath(dir, "none-out"), force=true)
    @test all(cell -> !isfile(joinpath(cell["result_path"], "criticality_timeseries.csv")), none_out.cells)
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
