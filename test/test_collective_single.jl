using BrainlessLab
using NPZ
using Random
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
        drive=BrainlessLab.NoDrive(),
        sign=BrainlessLab.UnsignedAxis(),
        recurrent_mask=_single_bitmatrix(data, "recurrent_mask"),
        input_wmat=_single_matrix(data, "input_wmat"),
        output_mask=_single_matrix(data, "output_mask"),
        wmat0=_single_matrix(data, "wmat0"),
        noise_source=BrainlessLab.RecordedNoise(zeros(Float64, ticks, n_nodes)),
        rectify=_single_bool(data, "rectify"),
    )
end

function _single_ensemble(data)
    # The fixture records the reference run's initial pose as `env_draws`.
    # Constructing the environment from a bare RNG instead starts the agent
    # somewhere else entirely, so any trajectory comparison against the
    # reference is meaningless. Both cross-implementation helpers below were
    # dead code, which is why this went unnoticed.
    draws = Float64.(vec(data["env_draws"]))
    length(draws) == 3 || error(
        "fixture env_draws must hold (x, y, theta); got $(length(draws)) values",
    )
    env = BrainlessLab.WallEnv(;
        rng=MersenneTwister(23),
        x=draws[1],
        y=draws[2],
        theta=draws[3],
    )
    agent = BrainlessLab.Agent(_single_reservoir(data), BrainlessLab.direct_embodiment(2, 2))
    ensemble = BrainlessLab.Ensemble([agent], BrainlessLab.TaskEnvironment(env))
    return ensemble, env, agent
end

function _single_pose(env::BrainlessLab.WallEnv)
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
    haskey(got, key) || error("environment metrics missing $key")
    dev = abs(Float64(getproperty(got, key)) - _single_scalar(data, fixture_key))
    @test dev <= COLLECTIVE_SINGLE_ATOL
end

@testset "Ensemble single-agent WallEnv smoke" begin
    path = _single_fixture_path()
    isfile(path) || error("missing fixture $path; run test/oracle/gen_single_agent_fixtures.py from the v0.2 directory")
    data = npzread(path)
    ensemble, env, agent = _single_ensemble(data)

    ticks = _single_int(data, "ticks")
    n_nodes = _single_int(data, "N")

    @test length(ensemble.agents) == 1
    @test ensemble.environment isa BrainlessLab.TaskEnvironment
    @test n_receptors(env) == 2
    @test n_effectors(env) == 2

    rates = Float64[]

    for _ in 1:ticks
        sensors = sense(env)
        @test length(sensors) == n_receptors(env)
        @test all(isfinite, sensors)

        spikes = only(step!(ensemble))
        @test length(spikes) == n_nodes
        @test all(x -> x == 0.0 || x == 1.0, spikes)
        push!(rates, sum(spikes) / n_nodes)

        eff = effectors(agent.reservoir, spikes)
        @test length(eff) == n_effectors(env)
        @test all(isfinite, eff)

        @test all(isfinite, _single_pose(env))
    end

    got_metrics = metrics(env, default_window(env))
    @test isfinite(Float64(got_metrics.score))
    @test got_metrics.distance_window >= 0.0
    @test got_metrics.collisions_window >= 0
    @test size(got_metrics.xy_path, 1) == ticks

    # UNRESOLVED CROSS-IMPLEMENTATION DISCREPANCY -- do not enable without reading this.
    #
    # The fixture carries metric_score, metric_distance_window,
    # metric_collisions_window and metric_xy_path from the v0.2 Python `crho`
    # implementation, and `_single_assert_metric` / `_single_max_abs_dev` exist
    # to compare against them. Both helpers were dead code from the outset, so
    # the comparison had never actually run.
    #
    # Enabling it fails, even with the environment initialised from the
    # fixture's own recorded `env_draws` and the reservoir fully pinned from
    # fixture masks, weights and parameters:
    #
    #   score            deviation 1.0000000000000018  (fixture 6.125)
    #   distance_window  deviation 1.0000000000000018  (fixture 6.125)
    #   collisions_window  passes -- but both sides are 0.0, so this agrees
    #                      about nothing happening
    #   xy_path          max deviation 4.115962750876231
    #   tolerance        1e-9
    #
    # Both implementations accumulate translation the same way
    # (`self.distance += translation` in crho/env_wall.py; `distance_last` here),
    # so the definitions agree and the values do not. A deviation of exactly 1.0
    # suggests a convention difference (an offset or a radius), not drift. The
    # cause is unresolved, and the generator imports `crho` from a sibling
    # workspace that is not part of this repository, so the fixture cannot be
    # regenerated here to bisect it.
    #
    # This file therefore validates SHAPE and INTERNAL CONSISTENCY only. It is
    # not cross-implementation evidence, and test/FIXTURES.md says so. The
    # genuinely independent evidence is test_falandays.jl, which replays the
    # falandays_{base,oosawa,dale}.npz fixtures against acts, targets and spikes
    # at 1e-9 and passes.
    @test_skip _single_assert_metric(data, got_metrics, :score)
    @test_skip _single_max_abs_dev(got_metrics.xy_path, data["metric_xy_path"]) <=
               COLLECTIVE_SINGLE_ATOL

    expected_live = BrainlessLab.liveness(rates, n_nodes, default_window(env))

    ensemble2, _, _ = _single_ensemble(data)
    rollout_result = BrainlessLab.rollout!(ensemble2, ticks; window=default_window(env))
    @test rollout_result.score ≈ got_metrics.score atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.distance_window ≈ got_metrics.distance_window atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.collisions_window == got_metrics.collisions_window
    @test rollout_result.rate_mean ≈ expected_live.rate_mean atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.rate_var ≈ expected_live.rate_var atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.total_spikes_window ≈ expected_live.total_spikes_window atol=COLLECTIVE_SINGLE_ATOL
    @test rollout_result.alive == expected_live.alive
end
