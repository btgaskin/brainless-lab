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

    # The fixture's `metric_*`, `sensors` and `pose` keys are LEGACY. Do not
    # compare the wall trajectory against them; it can never match, by design.
    #
    # Commit 6552af5 ("make :falandays_base + wall/tracking/pong worlds
    # authors-faithful") deliberately re-based WallBox off the v0.2 Python
    # `crho` implementation and onto the Falandays authors' conventions. Four
    # differ, and they are recorded only in that commit message:
    #
    #   1. sensor rays cast from the sensor point on the agent's circle, not
    #      from its centre  (Julia distance is shorter by r)
    #   2. translate along the OLD heading, then rotate
    #   3. clamp-and-slide collision response, crediting partial translation
    #   4. post-collision heading turns +/-45 degrees from the new heading
    #
    # The fixture predates that commit and was never regenerated, so its wall
    # keys describe the crho conventions. Reimplementing WallBox with (1) and
    # (2) switched back reproduces the fixture bit-exactly across all 120 ticks
    # on sensors, spikes, effectors, pose and xy_path; (3) and (4) are untested
    # here because both sides record zero collisions.
    #
    # The previously recorded "deviation of exactly 1.0" was a red herring
    # twice over: it was measured from the default centre pose rather than the
    # fixture's `env_draws`, and effectors here are drawn from {0, 0.25}, so
    # with no collisions the distance is always a multiple of 0.125 and landing
    # on eight quanta is arithmetic coincidence, not a fencepost.
    #
    # What the fixture still proves is node-level parity, which is independent
    # of wall geometry: driving the pinned reservoir with the fixture's OWN
    # recorded sensor currents reproduces its spikes and effectors exactly.
    @testset "Julia-Python node parity on recorded sensor currents" begin
        replay = _single_reservoir(data)
        fixture_sensors = _single_matrix(data, "sensors")
        fixture_spikes = _single_matrix(data, "spikes")
        fixture_effectors = _single_matrix(data, "effectors")
        spike_dev = 0.0
        effector_dev = 0.0
        for t in 1:ticks
            got_spikes = step!(replay, vec(fixture_sensors[t, :]))
            got_eff = effectors(replay, got_spikes)
            spike_dev = max(spike_dev, _single_max_abs_dev(got_spikes, fixture_spikes[t, :]))
            effector_dev = max(effector_dev, _single_max_abs_dev(got_eff, fixture_effectors[t, :]))
        end
        @test spike_dev <= COLLECTIVE_SINGLE_ATOL
        @test effector_dev <= COLLECTIVE_SINGLE_ATOL
    end

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
