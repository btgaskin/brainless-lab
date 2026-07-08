using BrainlessLab, Test, Random

function _wrapped_delta(a, b)
    return mod(Float64(a) - Float64(b) + pi, 2.0 * pi) - pi
end

@testset "TrackingEnv params" begin
    env = BrainlessLab.TrackingEnv()
    @test env.movement_amp == 10.0
    @test env.eye_offsets_deg == (30.0, -30.0)
    @test env.theta == pi / 2.0
    @test env.phi == 0.0
    @test env.direction == 1.0
    @test env.theta0 == pi / 2.0

    rng = MersenneTwister(0)
    BrainlessLab.TrackingEnv(; rng=rng)
    @test rand(rng) == rand(MersenneTwister(0))

    env10 = BrainlessLab.TrackingEnv(; movement_amp=10.0)
    before10 = env10.theta
    BrainlessLab.step!(env10, [1.0, 0.0])
    d10 = _wrapped_delta(env10.theta, before10)

    env20 = BrainlessLab.TrackingEnv(; movement_amp=20.0)
    before20 = env20.theta
    BrainlessLab.step!(env20, [1.0, 0.0])
    d20 = _wrapped_delta(env20.theta, before20)
    @test isapprox(d20, 2.0 * d10; atol=eps(Float64))

    env45 = BrainlessLab.TrackingEnv(; eye_offset_deg=45.0)
    @test env45.eye_offsets_deg == (45.0, -45.0)

    randomized7a = BrainlessLab.TrackingEnv(; rng=MersenneTwister(7), randomize_start=true)
    randomized7b = BrainlessLab.TrackingEnv(; rng=MersenneTwister(7), randomize_start=true)
    randomized8 = BrainlessLab.TrackingEnv(; rng=MersenneTwister(8), randomize_start=true)
    @test randomized7a.theta0 == randomized7b.theta0
    @test randomized7a.theta0 != randomized8.theta0
    @test randomized7a.theta0 != pi / 2.0

    reset_env = BrainlessLab.TrackingEnv(; rng=MersenneTwister(9), randomize_start=true)
    for _ in 1:3
        BrainlessLab.step!(reset_env, [1.0, 0.0])
    end
    BrainlessLab.reset!(reset_env)
    @test reset_env.theta == reset_env.theta0
    @test reset_env.phi == reset_env.phi0
    @test reset_env.direction == reset_env.direction0
end
