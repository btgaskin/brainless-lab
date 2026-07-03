using BrainlessLab
using NPZ
using Test

const ENV_ATOL = 1e-9

function _env_fixture_path(name)
    return joinpath(@__DIR__, "fixtures", "env_$(name).npz")
end

function _env_matrix(data, key::AbstractString)
    return Matrix{Float64}(Float64.(data[key]))
end

function _env_vector(data, key::AbstractString)
    return Vector{Float64}(vec(Float64.(data[key])))
end

function _env_int_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Int(value) : Int(only(value))
end

function _env_float_scalar(data, key::AbstractString)
    value = data[key]
    return value isa Number ? Float64(value) : Float64(only(value))
end

function _recorded_draws_from_fixture(data)
    raw = _env_vector(data, "draws")
    count = _env_int_scalar(data, "draw_count")
    count == 0 && return RecordedDraws(Float64[])
    return RecordedDraws(raw[1:count])
end

function _build_env(name::AbstractString, data)
    draws = _recorded_draws_from_fixture(data)
    if name == "wall"
        return WallEnv(; rng=draws)
    elseif name == "tracking"
        return TrackingEnv(; rng=draws)
    elseif name == "pong"
        return PongEnv(; rng=draws)
    elseif name == "cartpole"
        return CartPoleEnv(; rng=draws)
    end
    error("unknown env $name")
end

function _state_vector(env::WallEnv)
    return [env.box.x, env.box.y, env.box.theta, Float64(env.box.collisions)]
end

function _state_vector(env::TrackingEnv)
    return [env.theta, env.phi, env.direction, Float64(env.tick)]
end

function _state_vector(env::PongEnv)
    return [
        env.ball_x,
        env.ball_y,
        env.paddle_y,
        Float64(sum(env.hit_flags)),
        Float64(sum(env.miss_flags)),
    ]
end

function _state_vector(env::CartPoleEnv)
    return copy(env.state)
end

function _max_abs_dev(a, b)
    av = Float64.(vec(a))
    bv = Float64.(vec(b))
    length(av) == length(bv) ||
        throw(DimensionMismatch("lengths $(length(av)) and $(length(bv)) differ"))
    isempty(av) && return 0.0
    return maximum(abs.(av .- bv))
end

function _assert_metric_parity(name, env, data)
    got = metrics(env, default_window(env))
    for key in keys(data)
        key_s = String(key)
        startswith(key_s, "metric_") || continue
        metric_name = Symbol(key_s[8:end])
        haskey(got, metric_name) || error("$name missing metric $metric_name")
        observed = Float64(getproperty(got, metric_name))
        expected = _env_float_scalar(data, key_s)
        dev = abs(observed - expected)
        @test dev <= ENV_ATOL
    end
end

function _assert_env_replay(name)
    path = _env_fixture_path(name)
    isfile(path) || error("missing fixture $path; run test/oracle/gen_env_fixtures.py from the v0 directory")
    data = npzread(path)
    env = _build_env(name, data)

    effs = _env_matrix(data, "effs")
    sensors_T = _env_matrix(data, "sensors_T")
    state_T = _env_matrix(data, "state_T")

    @test size(effs, 1) == size(sensors_T, 1) == size(state_T, 1)
    @test size(effs, 2) == n_effectors(env)
    @test size(sensors_T, 2) == n_receptors(env)

    max_sensor = 0.0
    max_state = 0.0

    for t in axes(effs, 1)
        sensors = sense(env)
        sensor_dev = _max_abs_dev(sensors, sensors_T[t, :])
        max_sensor = max(max_sensor, sensor_dev)
        @test sensor_dev <= ENV_ATOL

        step!(env, vec(effs[t, :]))
        state_dev = _max_abs_dev(_state_vector(env), state_T[t, :])
        max_state = max(max_state, state_dev)
        @test state_dev <= ENV_ATOL
    end

    _assert_metric_parity(name, env, data)
    @info "environment oracle parity" name max_sensor max_state
end

@testset "Environment oracle parity" begin
    for name in ("wall", "tracking", "pong", "cartpole")
        @testset "$name" begin
            _assert_env_replay(name)
        end
    end
end

@testset "Environment RNG fields are concrete" begin
    wall = WallEnv(; rng=RecordedDraws([1.0, 1.0, 0.0]))
    tracking = TrackingEnv(; rng=RecordedDraws(Float64[]))
    pong = PongEnv(; rng=RecordedDraws([250.0, 1.0]))
    cartpole = CartPoleEnv(; rng=RecordedDraws([0.0, 0.0, 0.0, 0.0]))
    variant = CartPoleVariantEnv(; rng=RecordedDraws([0.0, 0.0, 0.0, 0.0]))

    for env in (wall, tracking, pong, cartpole, variant)
        @test fieldtype(typeof(env), :rng) === RecordedDraws
    end
    @test fieldtype(typeof(wall.box), :rng) === RecordedDraws
end
