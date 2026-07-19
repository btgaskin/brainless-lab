using BrainlessLab
using Random
using Test

# Historical pre-policy differential-drive arithmetic, inlined verbatim so the
# default KinematicMotor can be asserted byte-identical to it.
function _old_integrate_motion(pos, heading, speed, hr, e, torus;
                               top_speed=0.2, accel_time=5.0,
                               top_heading_rate=pi / 8.0, h_accel_time=5.0, dt=1.0)
    oa = clamp.(Vector{Float64}(vec(Float64.(e))), 0.0, 1.0)
    max_a = top_speed / accel_time
    fric_a = max_a / top_speed
    accel = oa[3] * max_a
    speed = speed + (accel - fric_a * speed) * dt
    max_ha = top_heading_rate / h_accel_time
    fric_h = max_ha / top_heading_rate
    h_accel = (oa[2] - oa[1]) * max_ha
    hr = hr + (h_accel - fric_h * hr) * dt
    heading = mod(heading + hr * dt, 2 * pi)
    x = pos[1] + speed * cos(heading) * dt
    y = pos[2] + speed * sin(heading) * dt
    return (BrainlessLab.wrap(torus, x, y), heading, speed, hr)
end

_falandays_reservoir(n, nr, ne; seed=1) =
    FalandaysReservoir(n, nr, ne; seed=seed, weight_init_mode=:legacy_normal,
                       repair_masks=true, rectify=true)

@testset "Motor defaults and registry" begin
    m = KinematicMotor()
    @test m isa Motor
    @test m.scheme === :differential
    @test m.readout === :spike_fraction
    @test m.turn_gain == 1.0
    @test !m.allow_reverse && !m.brake
    # Kinematic constants match the historical situated-body defaults.
    @test m.top_speed == 0.2 && m.accel_time == 5.0
    @test m.top_heading_rate == pi / 8.0 && m.h_accel_time == 5.0 && m.dt == 1.0

    @test BrainlessLab.PASSTHROUGH_MOTOR === KinematicMotor()  # both isbits + all-default
    @test resolve_motor(:situated_kinematics) === KinematicMotor
    @test readout_policy(Embodiment()) === BrainlessLab.PASSTHROUGH_MOTOR
    @test readout_policy(situated_embodiment(SituatedSensorLayout())) === BrainlessLab.PASSTHROUGH_MOTOR
    custom = KinematicMotor(scheme=:signed_differential)
    @test readout_policy(situated_embodiment(SituatedSensorLayout(), custom)) === custom
end

@testset "KinematicMotor genome is opt-in and bounded" begin
    m0 = KinematicMotor()
    @test paramdim(m0) == 0
    @test isempty(BrainlessLab.paramspace(m0))
    @test isempty(pack_params(m0))
    @test unpack_params(m0, Float64[]) === m0

    m = KinematicMotor(
        readout=:graded_state,
        turn_gain=1.25,
        turn_gain_range=(0.5, 2.0),
        top_speed=0.3,
        top_speed_range=(0.1, 0.5),
        accel_time=5.0,
        accel_time_range=(5.0, 5.0),
        top_heading_rate=pi / 6.0,
        top_heading_rate_range=(pi / 12.0, pi / 4.0),
    )
    space = BrainlessLab.paramspace(m)
    @test paramdim(m) == 3
    @test [entry.label for entry in space] == [:turn_gain, :top_speed, :top_heading_rate]
    @test [(entry.lo, entry.hi) for entry in space] == [(0.5, 2.0), (0.1, 0.5), (pi / 12.0, pi / 4.0)]

    g = pack_params(m)
    @test length(g) == paramdim(m)
    m2 = unpack_params(m, g)
    @test m2 isa KinematicMotor
    @test m2.scheme === m.scheme
    @test m2.readout === m.readout
    @test m2.allow_reverse === m.allow_reverse
    @test m2.brake === m.brake
    @test m2.dt == m.dt
    @test m2.turn_gain_range == m.turn_gain_range
    @test m2.top_speed_range == m.top_speed_range
    @test m2.accel_time_range == m.accel_time_range
    @test m2.top_heading_rate_range == m.top_heading_rate_range
    @test isapprox(m2.turn_gain, m.turn_gain; atol=1e-6)
    @test isapprox(m2.top_speed, m.top_speed; atol=1e-6)
    @test isapprox(m2.accel_time, m.accel_time; atol=1e-6)
    @test isapprox(m2.top_heading_rate, m.top_heading_rate; atol=1e-6)
    @test isapprox(pack_params(m2), g; atol=1e-8)

    @test_throws DimensionMismatch unpack_params(m, g[1:2])
end

@testset "Default readout is a strict no-op (== effectors)" begin
    R = 0.2 .* rand(MersenneTwister(2), 64)
    m = KinematicMotor()

    r = _falandays_reservoir(40, 64, 3)
    s = step!(r, R)
    # Both spike-based schemes defer to effectors verbatim (no re-averaging).
    @test readout(m, r, s) == effectors(r, s)
    @test readout(KinematicMotor(readout=:window_rate), r, s) == effectors(r, s)

    # Non-Falandays reservoir: same no-op through the generic default.
    sorn = SORNReservoir(40, 64, 3; seed=1)
    ss = step!(sorn, R)
    @test readout(m, sorn, ss) == effectors(sorn, ss)
    @test readout(KinematicMotor(readout=:window_rate), sorn, ss) == effectors(sorn, ss)
end

@testset "Default integration is byte-identical to the old arithmetic" begin
    torus = Torus(15.0)
    m = KinematicMotor()
    rng = MersenneTwister(3)
    for _ in 1:500
        pos = (rand(rng) * 15, rand(rng) * 15)
        heading = rand(rng) * 2pi
        speed = rand(rng) * 0.3
        hr = (rand(rng) - 0.5) * 0.5
        e = [rand(rng), rand(rng), rand(rng)]
        new = integrate!(m, pos, heading, speed, hr, e, torus)
        old = _old_integrate_motion(pos, heading, speed, hr, e, torus)
        @test new === old   # exact bit-identity, not just ≈
    end
end

@testset "Default motor: swarm + forage sims unchanged (no-op through the pipeline)" begin
    for task in (:torus, :forage)
        base = simulate(task; node=:falandays_base, n_agents=6, n_nodes=40, ticks=50,
                        seed=7, record=(:poses,), metrics=(:polarization, :milling))
        withm = simulate(task; node=:falandays_base, n_agents=6, n_nodes=40, ticks=50,
                         seed=7, motor=KinematicMotor(), record=(:poses,),
                         metrics=(:polarization, :milling))
        @test getchannel(base.recorder, :poses) == getchannel(withm.recorder, :poses)
        @test base.metrics.polarization == withm.metrics.polarization
        @test base.metrics.milling == withm.metrics.milling
    end
end

@testset "Graded readouts: finite E of length n_effectors (Falandays only)" begin
    R = 0.2 .* rand(MersenneTwister(5), 64)
    r = _falandays_reservoir(40, 64, 3)
    s = step!(r, R)
    ne = n_effectors(r)

    for scheme in (:graded_state, :graded_deviation)
        E = readout(KinematicMotor(readout=scheme), r, s)
        @test length(E) == ne
        @test all(isfinite, E)
        @test E isa Vector{Float64}
    end
    # graded readouts re-express internal state, so they differ from the spike map
    @test readout(KinematicMotor(readout=:graded_state), r, s) != effectors(r, s)
end

@testset "Graded readout unsupported on a non-Falandays reservoir throws" begin
    R = 0.2 .* rand(MersenneTwister(6), 64)
    sorn = SORNReservoir(40, 64, 3; seed=1)
    ss = step!(sorn, R)
    for scheme in (:graded_state, :graded_deviation)
        err = @test_throws ArgumentError readout(KinematicMotor(readout=scheme), sorn, ss)
        @test occursin("graded readout", err.value.msg)
        @test occursin("SORNReservoir", err.value.msg)
    end
end

@testset ":signed_differential + allow_reverse produces reverse motion" begin
    torus = Torus(15.0)
    st0 = ((5.0, 5.0), 0.0, 0.0, 0.0)
    e_reverse = [0.5, 0.5, 0.0]   # thrust=0 -> signed drive = 2*0-1 = -1 (full reverse)

    # allow_reverse: speed crosses zero and stays negative (travels backward).
    mrev = KinematicMotor(scheme=:signed_differential, allow_reverse=true)
    st = st0
    for _ in 1:15
        st = integrate!(mrev, st..., e_reverse, torus)
    end
    @test st[3] < 0.0                     # negative speed == reverse

    # no allow_reverse: the same signed drive brakes to a standstill, never reverses.
    mbrake = KinematicMotor(scheme=:signed_differential, allow_reverse=false)
    st = st0
    for _ in 1:15
        st = integrate!(mbrake, st..., e_reverse, torus)
    end
    @test st[3] == 0.0                    # clamped to a stop

    # unknown scheme is rejected.
    @test_throws ArgumentError integrate!(
        KinematicMotor(scheme=:bogus), (0.0, 0.0), 0.0, 0.0, 0.0, [0.5, 0.5, 0.5], torus)
end

@testset ":signed_differential + reverse changes swarm trajectories vs the default" begin
    common = (node=:falandays_base, n_agents=8, n_nodes=40, ticks=60, seed=11,
              record=(:poses,))
    base = simulate(:torus; common..., motor=KinematicMotor())
    rev = simulate(:torus; common..., motor=KinematicMotor(scheme=:signed_differential, allow_reverse=true))
    @test getchannel(base.recorder, :poses) != getchannel(rev.recorder, :poses)
end
