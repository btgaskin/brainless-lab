using BrainlessLab
using NPZ
using Test

const COLLECTIVE_SINGLE_ATOL = 1e-9

function _single_fixture_path()
    return joinpath(@__DIR__, "fixtures", "single_agent_wall.npz")
end

function _single_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function _single_int(data, key::AbstractString)
    return Int(round(_single_scalar(data, key)))
end

function _single_bool(data, key::AbstractString)
    return Bool(round(Int, _single_scalar(data, key)))
end

function _single_matrix(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _single_vector(data, key::AbstractString)
    return Vector{Float64}(vec(Float64.(data[key])))
end

function _single_bitmatrix(data, key::AbstractString)
    raw = data[key]
    mask = falses(size(raw, 1), size(raw, 2))
    @inbounds for j in axes(mask, 2), i in axes(mask, 1)
        mask[i, j] = raw[i, j] != 0
    end
    return mask
end

function _single_params(data)
    return FalandaysParams(
        leak=_single_scalar(data, "leak"),
        lrate_wmat=_single_scalar(data, "lrate_wmat"),
        lrate_targ=_single_scalar(data, "lrate_targ"),
        threshold_mult=_single_scalar(data, "threshold_mult"),
        targ_min=_single_scalar(data, "targ_min"),
        input_weight=_single_scalar(data, "input_weight"),
        weight_init_std=_single_scalar(data, "weight_init_std"),
        learn_on=_single_bool(data, "learn_on"),
    )
end

function _single_reservoir(data)
    ticks = _single_int(data, "ticks")
    n_nodes = _single_int(data, "N")
    return FalandaysReservoir(
        params=_single_params(data),
        drive=NoDrive(),
        sign=BrainlessLab.Unsigned(),
        recurrent_mask=_single_bitmatrix(data, "recurrent_mask"),
        input_wmat=_single_matrix(data, "input_wmat"),
        output_mask=_single_matrix(data, "output_mask"),
        wmat0=_single_matrix(data, "wmat0"),
        noise_source=RecordedNoise(zeros(Float64, ticks, n_nodes)),
        rectify=_single_bool(data, "rectify"),
    )
end

function _single_collective(data)
    draws = RecordedDraws(_single_vector(data, "env_draws"))
    env = WallEnv(; rng=draws)
    agent = Agent(_single_reservoir(data), PassthroughBody())
    collective = Ensemble([agent], TaskMedium(env))
    return collective, env, agent
end

function _single_pose(env::WallEnv)
    return [env.box.x, env.box.y, env.box.theta]
end

function _single_max_abs_dev(a, b)
    av = Float64.(vec(a))
    bv = Float64.(vec(b))
    length(av) == length(bv) ||
        throw(DimensionMismatch("lengths $(length(av)) and $(length(bv)) differ"))
    isempty(av) && return 0.0
    return maximum(abs.(av .- bv))
end

function _single_assert_metric(data, got, key::Symbol)
    fixture_key = "metric_$(key)"
    haskey(data, fixture_key) || error("fixture missing $fixture_key")
    haskey(got, key) || error("medium metrics missing $key")
    dev = abs(Float64(getproperty(got, key)) - _single_scalar(data, fixture_key))
    @test dev <= COLLECTIVE_SINGLE_ATOL
end

@testset "Ensemble single-agent WallEnv oracle parity" begin
    path = _single_fixture_path()
    isfile(path) || error("missing fixture $path; run test/oracle/gen_single_agent_fixtures.py from the v0.2 directory")
    data = npzread(path)
    collective, env, agent = _single_collective(data)

    sensors = _single_matrix(data, "sensors")
    spikes_t = _single_matrix(data, "spikes")
    effectors_t = _single_matrix(data, "effectors")
    pose_t = _single_matrix(data, "pose")

    @test length(collective.agents) == 1
    @test collective.medium isa TaskMedium
    @test size(sensors, 1) == _single_int(data, "ticks")
    @test size(spikes_t, 2) == _single_int(data, "N")

    max_sensor = 0.0
    max_effector = 0.0
    max_pose = 0.0

    for t in axes(sensors, 1)
        sensor_dev = _single_max_abs_dev(sense(env), sensors[t, :])
        max_sensor = max(max_sensor, sensor_dev)
        @test sensor_dev <= COLLECTIVE_SINGLE_ATOL

        spikes = only(step!(collective))
        expected_spikes = vec(spikes_t[t, :])
        @test spikes == expected_spikes

        effector_dev = _single_max_abs_dev(effectors(agent.reservoir, spikes), effectors_t[t, :])
        max_effector = max(max_effector, effector_dev)
        @test effector_dev <= COLLECTIVE_SINGLE_ATOL

        pose_dev = _single_max_abs_dev(_single_pose(env), pose_t[t, :])
        max_pose = max(max_pose, pose_dev)
        @test pose_dev <= COLLECTIVE_SINGLE_ATOL
    end

    got_metrics = metrics(env, default_window(env))
    for key in (:score, :distance_window, :collisions_window)
        _single_assert_metric(data, got_metrics, key)
    end
    @test _single_max_abs_dev(got_metrics.xy_path, data["metric_xy_path"]) <= COLLECTIVE_SINGLE_ATOL

    rates = vec(sum(spikes_t, dims=2)) ./ size(spikes_t, 2)
    expected_live = liveness(rates, size(spikes_t, 2), default_window(env))

    collective2, _, _ = _single_collective(data)
    rollout_result = rollout!(collective2, size(spikes_t, 1); window=default_window(env))
    @test abs(rollout_result.score - _single_scalar(data, "metric_score")) <= COLLECTIVE_SINGLE_ATOL
    @test abs(rollout_result.distance_window - _single_scalar(data, "metric_distance_window")) <= COLLECTIVE_SINGLE_ATOL
    @test rollout_result.collisions_window == _single_int(data, "metric_collisions_window")
    @test rollout_result.rate_mean ≈ expected_live.rate_mean atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.rate_var ≈ expected_live.rate_var atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.total_spikes_window ≈ expected_live.total_spikes_window atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.alive == expected_live.alive

    @info "collective single-agent oracle parity" max_sensor max_effector max_pose
end
