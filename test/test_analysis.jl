using BrainlessLab
using Test

@testset "Branching ratio analysis" begin
    steady = BrainlessLab._branching_from_rates([1.0, 1.0, 1.0, 1.0])
    @test steady.per_tick == [1.0, 1.0, 1.0]
    @test steady.sigma ≈ 1.0

    doubling = BrainlessLab._branching_from_rates([1.0, 2.0, 4.0])
    @test doubling.per_tick == [2.0, 2.0]
    @test doubling.sigma ≈ 2.0

    with_zero = BrainlessLab._branching_from_rates([0.0, 2.0, 4.0])
    @test isnan(with_zero.per_tick[1])
    @test with_zero.per_tick[2] == 2.0
    @test with_zero.sigma ≈ 2.0

    sim = simulate(:wall; node=:falandays_base, ticks=60, seed=1)
    raw = getchannel(sim.recorder, :rate)
    br = branching_ratio(sim)
    @test length(br.per_tick) == length(raw) - 1
    @test isfinite(br.sigma)

    @test resolve_analysis(:branching_ratio) === branching_ratio
    @test :branching_ratio in analyses()
end

@testset "Task performance analyses" begin
    wall_sim = simulate(:wall; node=:falandays_base, ticks=40, seed=1, record=(:rate, :poses))
    wd = wall_distance(wall_sim)
    @test length(wd) == length(getchannel(wall_sim.recorder, :poses))
    @test all(isfinite, wd)
    @test all(x -> x >= 0.0, wd)

    tracking_sim = simulate(:tracking; node=:falandays_base, ticks=40, seed=1, record=(:rate, :scene))
    he = heading_error(tracking_sim)
    @test length(he) == length(getchannel(tracking_sim.recorder, :scene))
    @test all(isfinite, he)
    @test all(x -> x >= 0.0, he)

    pong_sim = simulate(:pong; node=:falandays_base, ticks=40, seed=1, record=(:rate, :scene))
    bpd = ball_paddle_distance(pong_sim)
    @test length(bpd) == length(getchannel(pong_sim.recorder, :scene))
    @test all(isfinite, bpd)
    @test all(x -> x >= 0.0, bpd)

    @test task_analyses(:wall) == [:wall_distance]
    @test isempty(task_analyses(:cartpole))
    @test :branching_ratio in analyses()
    @test !in(:wall_distance, analyses())
    @test :wall_distance in analyses(task=:wall)
    @test resolve_analysis(:branching_ratio) === branching_ratio
    @test analysis_meta(:heading_error).label == "heading error (rad)"
end
