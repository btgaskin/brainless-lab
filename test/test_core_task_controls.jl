using BrainlessLab
using Random
using Test

function _task_policy_rollout(env, policy, ticks::Integer)
    for _ in 1:Int(ticks)
        step!(env, policy(env))
    end
    return metrics(env, ticks)
end

@testset "core task sensory controls" begin
    @testset "tracking gain is explicit and validated" begin
        default = TrackingEnv()
        explicit = TrackingEnv(; sensory_gain=1.0)
        blind = TrackingEnv(; sensory_gain=0.0)

        @test sense(default) == sense(explicit)
        @test any(!iszero, sense(default))
        @test all(iszero, sense(blind))
        @test_throws ArgumentError TrackingEnv(; sensory_gain=-1.0)
        @test_throws ArgumentError TrackingEnv(; sensory_gain=Inf)

        custom_bank = TrackingEnv(; sensor_offsets_deg=[-8.0, 0.0, 8.0])
        @test n_receptors(custom_bank) == 6
        @test length(sense(custom_bank)) == 6
        @test_throws ArgumentError BrainlessLab.tracking_reference_policy(
            TrackingEnv(; movement_amp=0.0),
        )
    end

    @testset "pong gain is explicit and validated" begin
        default = PongEnv(; rng=RecordedDraws([250.0, 1.0]))
        explicit = PongEnv(; rng=RecordedDraws([250.0, 1.0]), sensory_gain=1.0)
        blind = PongEnv(; rng=RecordedDraws([250.0, 1.0]), sensory_gain=0.0)

        @test sense(default) == sense(explicit)
        @test any(!iszero, sense(default))
        @test all(iszero, sense(blind))
        @test_throws ArgumentError PongEnv(; sensory_gain=-1.0)
        @test_throws ArgumentError PongEnv(; sensory_gain=NaN)
    end
end

@testset "core task reference policies establish opportunity" begin
    tracking_reference = Float64[]
    tracking_stationary = Float64[]
    pong_reference = Float64[]
    pong_stationary = Float64[]

    for seed in 1:5
        tracking = TrackingEnv(;
            rng=MersenneTwister(seed),
            randomize_start=true,
        )
        stationary_tracking = TrackingEnv(;
            rng=MersenneTwister(seed),
            randomize_start=true,
        )
        push!(
            tracking_reference,
            _task_policy_rollout(
                tracking,
                BrainlessLab.tracking_reference_policy,
                400,
            ).track_score,
        )
        push!(
            tracking_stationary,
            _task_policy_rollout(stationary_tracking, _ -> (0.0, 0.0), 400).track_score,
        )

        pong = PongEnv(seed)
        stationary_pong = PongEnv(seed)
        push!(
            pong_reference,
            _task_policy_rollout(pong, BrainlessLab.pong_reference_policy, 2_000).hit_rate,
        )
        push!(
            pong_stationary,
            _task_policy_rollout(stationary_pong, _ -> (0.0, 0.0), 2_000).hit_rate,
        )
    end

    @test sum(tracking_reference) / length(tracking_reference) >
          sum(tracking_stationary) / length(tracking_stationary) + 0.25
    @test minimum(tracking_reference) > 0.9
    @test sum(pong_reference) / length(pong_reference) >
          sum(pong_stationary) / length(pong_stationary) + 0.25
    @test minimum(pong_reference) == 1.0
end
