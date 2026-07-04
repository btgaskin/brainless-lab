using BrainlessLab
using Random
using Test

function _cartpole_variant_rollout(env, policy, ticks::Integer)
    for _ in 1:Int(ticks)
        step!(env, policy(env))
    end
    return metrics(env, Int(ticks))
end

_cartpole_nothing_policy(env) = [0.0, 0.0]

function _assert_cartpole_variant_runs(task::Symbol; seed::Integer=11, ticks::Integer=120)
    spec = resolve_task(task)
    env = make_env(spec; rng=MersenneTwister(seed))
    @test n_receptors(env) == 8
    @test n_effectors(env) == 2

    for _ in 1:ticks
        sensors = sense(env)
        @test length(sensors) == 8
        @test all(isfinite, sensors)
        @test all(value -> 0.0 <= value <= 1.0, sensors)
        step!(env, [0.0, 0.0])
    end

    m = metrics(env, ticks)
    @test isfinite(Float64(m.score))
    @test 0.0 <= Float64(m.score) <= 1.0
    @test haskey(m, :balanced_fraction)
    @test haskey(m, :mean_uprightness)
    @test 0.0 <= Float64(m.balanced_fraction) <= 1.0
    @test 0.0 <= Float64(m.mean_uprightness) <= 1.0
end

function _assert_balance_oracle(task::Symbol; seeds=1:5, ticks::Integer=400)
    oracle_scores = Float64[]
    baseline_scores = Float64[]

    for seed in seeds
        oracle_env = make_env(task; rng=MersenneTwister(seed))
        baseline_env = make_env(task; rng=MersenneTwister(seed))
        oracle_metrics = _cartpole_variant_rollout(oracle_env, cartpole_balancer, ticks)
        baseline_metrics = _cartpole_variant_rollout(baseline_env, _cartpole_nothing_policy, ticks)
        push!(oracle_scores, Float64(oracle_metrics.score))
        push!(baseline_scores, Float64(baseline_metrics.score))
    end

    @test sum(oracle_scores) / length(oracle_scores) > sum(baseline_scores) / length(baseline_scores) + 0.10
    @test maximum(oracle_scores) > maximum(baseline_scores)
end

function _assert_swingup_oracle(; seeds=1:5, ticks::Integer=700)
    oracle_scores = Float64[]
    baseline_scores = Float64[]

    for seed in seeds
        oracle_env = make_env(:cartpole_swingup; rng=MersenneTwister(seed))
        baseline_env = make_env(:cartpole_swingup; rng=MersenneTwister(seed))
        oracle_metrics = _cartpole_variant_rollout(oracle_env, cartpole_swingup_controller, ticks)
        baseline_metrics = _cartpole_variant_rollout(baseline_env, _cartpole_nothing_policy, ticks)
        push!(oracle_scores, Float64(oracle_metrics.mean_uprightness))
        push!(baseline_scores, Float64(baseline_metrics.mean_uprightness))
    end

    @test sum(oracle_scores) / length(oracle_scores) > sum(baseline_scores) / length(baseline_scores) + 0.10
    @test maximum(oracle_scores) > maximum(baseline_scores)
end

@testset "CartPole variants" begin
    @test :cartpole in tasks()
    @test make_env(:cartpole; rng=MersenneTwister(1)) isa CartPoleEnv
    result = simulate(:cartpole; node=:falandays, ticks=20, seed=1, record=Symbol[])
    @test result isa SimResult
    @test isfinite(Float64(result.metrics.score))

    for task in (:cartpole_hard, :cartpole_swingup, :cartpole_long)
        @test task in tasks()
        @testset "$task constructs and runs" begin
            _assert_cartpole_variant_runs(task)
        end
    end

    @testset "balance oracle gates" begin
        _assert_balance_oracle(:cartpole)
        _assert_balance_oracle(:cartpole_hard)
        _assert_balance_oracle(:cartpole_long)
    end

    @testset "swingup oracle gate" begin
        _assert_swingup_oracle()
    end

    swingup = simulate(:cartpole_swingup; node=:falandays, ticks=200, seed=4, record=Symbol[])
    @test swingup isa SimResult
    @test swingup.task == :cartpole_swingup
    @test isfinite(Float64(swingup.metrics.score))
end
