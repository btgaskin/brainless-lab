using BrainlessLab
using TOML
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

function _write_tiny_sweep(path; node="falandays_base", task="wall", axes=Dict("\"node.threshold_mult\"" => "[1.8]"), seeds="[0]", measures="[\"liveness\"]", max_cells=10, analytics_extra="")
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
        isempty(analytics_extra) || println(io, analytics_extra)
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
    for col in ("cell", "axis", "value", "score_mean", "score_std", "raw_score_mean", "raw_score_std", "frac_viable", "frac_alive", "spectral_radius_mean", "liveness_mean")
        @test col in header
    end

    rows = _csv_rows(joinpath(sweep.dir, "results.csv"))
    @test length(rows) == 4
    @test all(row -> isfinite(parse(Float64, row["score_mean"])), rows)
    @test all(row -> isfinite(parse(Float64, row["liveness_mean"])), rows)
    @test all(row -> isfinite(parse(Float64, row["frac_viable"])), rows)
    @test all(row -> isfinite(parse(Float64, row["frac_alive"])), rows)
    @test all(row -> isfile(joinpath(row["result_path"], "metrics.csv")), rows)
    @test all(row -> !isfile(joinpath(row["result_path"], "representative.gif")), rows)
    @test occursin("Viable cells:", read(joinpath(sweep.dir, "README.md"), String))

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
    @test "env.lam" in axis_paths
    @test "ablation" in axis_paths

    tracking_axes = [axis.path for axis in sweepable_axes(:falandays_base, :tracking)]
    @test "env.stim_speed_rad" in tracking_axes
    @test "env.sensory_gain" in tracking_axes
    @test !("env.lam" in tracking_axes)
    @test Set(axis.path for axis in sweep_env_axes(TrackingEnv)) ==
          Set(("env.stim_speed_rad", "env.sensory_gain"))
    @test only(sweep_env_axes(PongEnv)).path == "env.sensory_gain"

    tracking_env = TrackingEnv(; stim_speed_rad=0.03)
    @test tracking_env.stim_speed_rad == 0.03
    step!(tracking_env, [0.5, 0.5])
    @test tracking_env.phi ≈ 0.03

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

    tracking_sweep = _write_tiny_sweep(
        joinpath(dir, "tracking-speed.toml");
        task="tracking",
        axes=Dict("\"env.stim_speed_rad\"" => "[0.008726646259971648, 0.017453292519943295]"),
        analytics_extra="viable_threshold = 0.9",
    )
    tracking_out = run_sweep(tracking_sweep; root=joinpath(dir, "tracking-out"), force=true)
    tracking_rows = _csv_rows(tracking_out.results)
    @test length(tracking_rows) == 2
    @test all(row -> row["axis"] == "env.stim_speed_rad", tracking_rows)
    @test all(row -> isfinite(parse(Float64, row["frac_viable"])), tracking_rows)
    @test TOML.parsefile(joinpath(tracking_out.dir, "config.resolved.toml"))["analytics"]["viable_threshold"] == 0.9
    @test occursin("threshold=0.9", read(joinpath(tracking_out.dir, "README.md"), String))

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

    schema = BrainlessLab.SweepColumnSchema(
        metric_header=String[],
        float_columns=Set{String}(),
        int_columns=Set{String}(),
        bool_columns=Set{String}(),
        aggregate_columns=["score", "liveness"],
        viable_threshold=0.5,
        measure_columns=Dict{String,Vector{String}}(),
        ensemble_specs=NamedTuple[],
    )
    aggregate = BrainlessLab._aggregate_cell(
        "cell_nan",
        Dict{String,Any}("axis" => "env.source_gain", "value" => 1.0, "params" => Dict{String,Any}()),
        [Dict{String,Any}("score" => NaN, "liveness" => 1.0, "alive" => true, "warnings" => "", "error" => "", "regime" => "")],
        schema,
    )
    @test isnan(aggregate["frac_viable"])
    @test aggregate["frac_alive"] == 1.0
end

@testset "Swarm struct-valued sweep axes" begin
    dir = mktempdir()

    axis_infos = sweepable_axes(:falandays_base, :forage)
    axis_by_path = Dict(axis.path => axis for axis in axis_infos)
    @test "env.motor.scheme" in keys(axis_by_path)
    @test "env.motor.turn_gain" in keys(axis_by_path)
    @test !("env.motor.turn_gain_range" in keys(axis_by_path))
    @test "env.sensor.n_per_eye" in keys(axis_by_path)
    @test "env.sensor.encoding" in keys(axis_by_path)
    @test axis_by_path["env.motor.scheme"].default == KinematicMotor().scheme
    @test axis_by_path["env.sensor.n_per_eye"].description == "sets receptor width"

    base = BrainlessLab._resolve_sweep_baseline(BrainlessLab.SweepBaseline(
        node=:falandays_base,
        task=:forage,
        N=8,
        ticks=6,
        window=6,
        n_agents=2,
    ))
    default_kwargs = BrainlessLab._simulation_kwargs(base, 0, ["liveness"])
    @test !haskey(base.env_kwargs, :motor)
    @test !haskey(base.env_kwargs, :sensor)
    @test !haskey(default_kwargs, :motor)
    @test !haskey(default_kwargs, :sensor)

    cells, _, _ = BrainlessLab._build_sweep_cells(
        base,
        Dict{String,Any}(
            "env.motor.scheme" => ["signed_differential"],
            "env.sensor.n_per_eye" => [31, 41],
        ),
        "factorial",
    )
    @test length(cells) == 2
    wide = only(filter(cell -> cell["params"]["env.sensor.n_per_eye"] == 41, cells))
    @test wide["baseline"].env_kwargs[:sensor][:n_per_eye] == 41
    @test wide["baseline"].env_kwargs[:motor][:scheme] == "signed_differential"

    sim_kwargs = BrainlessLab._simulation_kwargs(wide["baseline"], 0, ["liveness"])
    @test sim_kwargs[:motor] isa KinematicMotor
    @test sim_kwargs[:motor].scheme === :signed_differential
    @test sim_kwargs[:sensor] isa BearingSensor
    @test BrainlessLab.encoding(sim_kwargs[:sensor]) === :binary
    @test n_sensors(sim_kwargs[:sensor]) == 82
    layout = SituatedSensorLayout(sensor=sim_kwargs[:sensor], source_bank=true)
    @test n_receptors(portspec(layout)) == 168

    config = joinpath(dir, "nested-struct-sweep.toml")
    open(config, "w") do io
        println(io, "[sweep]")
        println(io, "id = \"nested-struct-sweep\"")
        println(io, "mode = \"factorial\"")
        println(io, "seeds = [0]")
        println(io, "max_cells = 10")
        println(io, "threaded = false")
        println(io)
        println(io, "[baseline]")
        println(io, "node = \"falandays_base\"")
        println(io, "task = \"forage\"")
        println(io, "N = 8")
        println(io, "ticks = 6")
        println(io, "window = 6")
        println(io, "n_agents = 2")
        println(io, "\"env.sensor.encoding\" = \"graded\"")
        println(io)
        println(io, "[axes]")
        println(io, "\"env.sensor.n_per_eye\" = [41]")
        println(io, "\"env.motor.scheme\" = [\"signed_differential\"]")
        println(io)
        println(io, "[analytics]")
        println(io, "measures = [\"liveness\"]")
    end

    out = run_sweep(config; root=joinpath(dir, "out"), force=true)
    @test length(out.cells) == 1

    manifest = TOML.parsefile(joinpath(out.dir, "manifest.toml"))
    @test manifest["baseline"]["env_kwargs"]["sensor"]["encoding"] == "graded"

    cell_manifest = TOML.parsefile(joinpath(out.cells[1]["result_path"], "manifest.toml"))
    env_kwargs = cell_manifest["baseline"]["env_kwargs"]
    @test env_kwargs["sensor"]["encoding"] == "graded"
    @test env_kwargs["sensor"]["n_per_eye"] == 41
    @test env_kwargs["motor"]["scheme"] == "signed_differential"
    @test !haskey(env_kwargs["sensor"], "angles_deg")

    result_header = _csv_header(out.results)
    @test "n_sensors_mean" in result_header
    @test "n_receptors_mean" in result_header
    row = only(_csv_rows(out.results))
    @test parse(Float64, row["n_sensors_mean"]) == 82.0
    @test parse(Float64, row["n_receptors_mean"]) == 168.0

    bad = joinpath(dir, "bad-nested-struct-axis.toml")
    write(bad, replace(read(config, String), "env.motor.scheme" => "env.motor.bogus"))
    err = try
        run_sweep(bad; root=joinpath(dir, "bad-out"), force=true)
        nothing
    catch caught
        caught
    end
    @test err isa ArgumentError
    @test occursin("unknown axis 'env.motor.bogus'", sprint(showerror, err))
    @test occursin("did you mean", sprint(showerror, err))
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
    @test all(row -> haskey(row, "status") && haskey(row, "error"), null_rows)
    @test all(row -> haskey(row, "n_valid") && haskey(row, "n_requested"), null_rows)
    @test all(row -> haskey(row, "alternative") && haskey(row, "pvalue"), null_rows)
    partial_null = BrainlessLab._null_result_row(
        "partial",
        (
            real=1.0,
            null_mean=1.0,
            null_std=0.0,
            ratio=1.0,
            pvalue=1.0,
            n_valid=2,
            n_requested=3,
            alternative=:greater,
        ),
        3,
    )
    @test partial_null["status"] == "partial"
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
    percepts = sample!(env, bodies)
    receptors_ = sense!(bodies[1], percepts[1])
    @test all(iszero, @view(receptors_[1:BrainlessLab.DEFAULT_BEARING_BANK_RECEPTORS]))
end
