using BrainlessLab
using Random
using Test

const BL = BrainlessLab

# The historical 62-ray VEN bearing fan, hardcoded verbatim so the default sensor is
# pinned to a literal (not just re-derived from the same expression).
const _SENSOR_DEFAULT_ANGLES_DEG = Float64[
    90.0, 86.0, 82.0, 78.0, 74.0, 70.0, 66.0, 62.0, 58.0, 54.0, 50.0, 46.0, 42.0, 38.0,
    34.0, 30.0, 26.0, 22.0, 18.0, 14.0, 10.0, 6.0, 2.0, -2.0, -6.0, -10.0, -14.0, -18.0,
    -22.0, -26.0, -30.0, 30.0, 26.0, 22.0, 18.0, 14.0, 10.0, 6.0, 2.0, -2.0, -6.0, -10.0,
    -14.0, -18.0, -22.0, -26.0, -30.0, -34.0, -38.0, -42.0, -46.0, -50.0, -54.0, -58.0,
    -62.0, -66.0, -70.0, -74.0, -78.0, -82.0, -86.0, -90.0,
]

@testset "Default sensor is a strict byte-identical no-op" begin
    s = BL.BEARING_DEFAULT
    @test s isa BearingSensor
    @test s isa SensorSpec
    @test resolve_sensor(:bearing_cone) === BearingSensor

    # canonical geometry pinned to the literal 62-vector
    @test BL.angles_deg(s) == _SENSOR_DEFAULT_ANGLES_DEG
    @test length(_SENSOR_DEFAULT_ANGLES_DEG) == 62
    @test n_sensors(s) == 62
    @test BL.encoding(s) == :binary
    @test s.tuning_deg == 0.0

    # module constants are realizations of the default spec, values unchanged
    @test BL.SENS_ANGLES_DEG == _SENSOR_DEFAULT_ANGLES_DEG
    @test BL.SENS_ANGLES_RAD == _SENSOR_DEFAULT_ANGLES_DEG .* (pi / 180.0)
    @test BL.angles_rad(s) == BL.SENS_ANGLES_RAD
    @test BL.VEN_BEARING_SENSOR_COUNT == 62
    @test BL.VEN_BANK_RECEPTORS == 64
    @test BL.VEN_ACOUSTIC_RECEPTOR_INDEX == 65

    # default morphology widths + ports unchanged
    @test n_receptors(VENMorphology()) == 64
    @test n_receptors(VENMorphology(sensor=BearingSensor())) == 64
    ports_default = ports(portspec(VENMorphology())).receptors
    ports_explicit = ports(portspec(VENMorphology(sensor=BearingSensor()))).receptors
    @test [p.id for p in ports_default] == [p.id for p in ports_explicit]
    @test [p.placement for p in ports_default] == [p.placement for p in ports_explicit]
end

@testset "Default sensor: :torus + :forage sims reproduce the no-sensor run" begin
    for task in (:torus, :forage)
        base = simulate(task; node=:falandays_base, n_agents=6, n_nodes=40, ticks=50,
                        seed=7, record=(:poses,), metrics=(:polarization, :milling))
        withs = simulate(task; node=:falandays_base, n_agents=6, n_nodes=40, ticks=50,
                         seed=7, sensor=BearingSensor(), record=(:poses,),
                         metrics=(:polarization, :milling))
        @test getchannel(base.recorder, :poses) == getchannel(withs.recorder, :poses)
        @test base.metrics.polarization == withs.metrics.polarization
        @test base.metrics.milling == withs.metrics.milling
    end
end

@testset "encoding :binary/:graded match the legacy sens_agent_dist knob" begin
    torus = Torus(15.0)
    positions = [(5.0, 5.0), (7.0, 6.0), (4.0, 8.0), (8.0, 4.5)]
    ang = BL.SENS_ANGLES_RAD
    r = 0.5
    # Symbol encoding passed positionally == old integer knob (0 -> binary, 1 -> graded).
    bin_old = sense_agents(positions[1], 0.3, positions, 1, r, torus, ang, 0, 0.0, MersenneTwister(0))
    bin_new = sense_agents(positions[1], 0.3, positions, 1, r, torus, ang, :binary, 0.0, MersenneTwister(0))
    grd_old = sense_agents(positions[1], 0.3, positions, 1, r, torus, ang, 1, 0.0, MersenneTwister(0))
    grd_new = sense_agents(positions[1], 0.3, positions, 1, r, torus, ang, :graded, 0.0, MersenneTwister(0))
    @test bin_new == bin_old
    @test grd_new == grd_old
    @test bin_new != grd_new

    # An unknown encoding is rejected.
    @test_throws ArgumentError sense_agents(positions[1], 0.3, positions, 1, r, torus, ang, :bogus, 0.0)

    # A :graded sensor forces the graded map through the full sim; default is binary.
    common = (node=:falandays_base, n_agents=6, n_nodes=40, ticks=40, seed=7, record=(:poses,))
    binary_sim = simulate(:torus; common..., sensor=BearingSensor(encoding=:binary))
    graded_sim = simulate(:torus; common..., sensor=BearingSensor(encoding=:graded))
    legacy_graded = simulate(:torus; common..., sens_agent_dist=1)
    @test getchannel(binary_sim.recorder, :poses) != getchannel(graded_sim.recorder, :poses)
    # legacy sens_agent_dist=1 reproduces the :graded sensor exactly.
    @test getchannel(legacy_graded.recorder, :poses) == getchannel(graded_sim.recorder, :poses)
end

@testset "Non-default geometry: receptor width tracks 2 + n_sensors and runs" begin
    s = bearing_eyes(n_per_eye=15, half_fov_deg=45.0)   # two eyes -> 30 rays
    @test n_sensors(s) == 30
    @test n_receptors(VENMorphology(sensor=s)) == 2 + 30
    @test n_receptors(VENMorphology(sensor=s, source_bank=true)) == (2 + 30) + (2 + 30)

    # ports carry the spec's actual angle placement, generalized off n_sensors.
    rec_ports = ports(portspec(VENMorphology(sensor=s))).receptors
    @test length(rec_ports) == 32
    @test [p.id for p in rec_ports[3:end]] == [Symbol("bearing_", i) for i in 1:30]
    @test [p.placement for p in rec_ports[3:end]] == BL.angles_deg(s)

    # single-eye spec also runs and matches its width.
    single = bearing_eyes(n_eyes=1, eye_offsets_deg=(0.0,), half_fov_deg=60.0, n_per_eye=21)
    @test n_sensors(single) == 21
    sim = simulate(:torus; node=:falandays_base, n_agents=6, n_nodes=40, ticks=30, seed=7,
                   sensor=single, record=Symbol[], metrics=(:polarization, :milling))
    @test isfinite(sim.metrics.polarization)
    @test isfinite(sim.metrics.milling)

    # forage with a non-default sensor runs end-to-end.
    simf = simulate(:forage; node=:falandays_base, n_agents=6, n_nodes=40, ticks=30, seed=3,
                    sensor=s, record=Symbol[])
    @test isfinite(simf.metrics.forage_score)
end

@testset "enabled mask reduces the active ray count" begin
    mask = trues(62)
    mask[1:10] .= false
    gated = BearingSensor(enabled=mask)
    @test n_sensors(gated) == 52
    @test length(BL.angles_deg(gated)) == 52
    @test BL.angles_deg(gated) == BL.angles_deg(BL.BEARING_DEFAULT)[mask]
    @test n_receptors(VENMorphology(sensor=gated)) == 2 + 52

    # A wrong-length mask is rejected.
    @test_throws DimensionMismatch BearingSensor(enabled=trues(5))
    # An unknown encoding is rejected at construction.
    @test_throws ArgumentError BearingSensor(encoding=:nope)
end

@testset "paramspace / pack_params / unpack_params roundtrip (raw per-ray angles)" begin
    s = bearing_eyes(n_per_eye=15, half_fov_deg=45.0)
    space = BL.paramspace(s)
    @test length(space) == n_sensors(s)          # one entry per active ray, no tuning
    @test BL.paramdim(s) == n_sensors(s)
    @test all(e -> e.lo == -180.0 && e.hi == 180.0, space)
    @test [e.label for e in space] == [Symbol("angle_", i) for i in 1:n_sensors(s)]

    g = BL.pack_params(s)
    @test length(g) == BL.paramdim(s)
    s2 = BL.unpack_params(s, g)
    @test s2 isa BearingSensor
    @test isapprox(BL.angles_deg(s2), BL.angles_deg(s); atol=1e-6)
    @test BL.encoding(s2) == BL.encoding(s)
    # roundtrip is idempotent on the raw genome.
    @test isapprox(BL.pack_params(s2), g; atol=1e-8)

    # tuning enters the parameter space only when its range is non-degenerate.
    st = BearingSensor(tuning_range_deg=(0.0, 30.0), tuning_deg=5.0)
    @test BL.paramdim(st) == 62 + 1
    @test BL.paramspace(st)[end].label == :tuning
    gt = BL.pack_params(st)
    st2 = BL.unpack_params(st, gt)
    @test isapprox(st2.tuning_deg, st.tuning_deg; atol=1e-6)
    @test isapprox(BL.angles_deg(st2), BL.angles_deg(st); atol=1e-6)

    # the enabled mask restricts the genome to the active rays and is preserved.
    mask = trues(62); mask[1:10] .= false
    sg = BearingSensor(enabled=mask)
    @test BL.paramdim(sg) == 52
    sg2 = BL.unpack_params(sg, BL.pack_params(sg))
    @test sg2.enabled == sg.enabled
    @test isapprox(BL.angles_deg(sg2), BL.angles_deg(sg); atol=1e-6)
    # disabled rays are carried through untouched from the template.
    @test sg2.angles_deg[1:10] == sg.angles_deg[1:10]
end
