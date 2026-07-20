using BrainlessLab
using Random
using Test

const _NB = BrainlessLab.DEFAULT_BEARING_SENSOR_COUNT      # 62 bearing sensors
const _ANG = BrainlessLab.SENS_ANGLES_RAD

@testset "Colour receptor widths" begin
    # Colour-blind defaults are a pure no-op.
    @test n_receptors(portspec(SituatedSensorLayout())) == 64
    @test n_receptors(portspec(SituatedSensorLayout(source_bank=true))) == 128

    # C == 1 colour_sensing reproduces the colour-blind width exactly.
    @test n_receptors(portspec(SituatedSensorLayout(colour_sensing=true, n_colours=1))) == 64
    @test n_receptors(portspec(SituatedSensorLayout(colour_sensing=true, n_colours=1, source_bank=true))) == 128

    # 2 reserved leads + C*62 conspecific receptors (126 for C=2).
    @test n_receptors(portspec(SituatedSensorLayout(colour_sensing=true, n_colours=2))) == 2 + 2 * _NB == 126
    @test n_receptors(portspec(SituatedSensorLayout(colour_sensing=true, n_colours=3))) == 2 + 3 * _NB

    # Forage adds the SINGLE (uncoloured) 64-wide source bank: 2 + C*62 + 64.
    @test n_receptors(portspec(SituatedSensorLayout(colour_sensing=true, n_colours=2, source_bank=true))) ==
          2 + 2 * _NB + 64 == 190
    @test n_receptors(portspec(SituatedSensorLayout(colour_sensing=true, n_colours=3, source_bank=true))) ==
          2 + 3 * _NB + 64
end

@testset "Colour receptor ports" begin
    spec = portspec(SituatedSensorLayout(colour_sensing=true, n_colours=2))
    receptors = ports(spec).receptors
    @test length(receptors) == 126
    @test receptors[1].id == :reserved_1
    @test receptors[2].id == :reserved_2
    @test receptors[3].id == :conspecific_c0_bearing_1        # first bank
    @test receptors[2 + _NB + 1].id == :conspecific_c1_bearing_1  # second bank

    # Acoustic receptor is COMPUTED to the start of the source region under colour.
    fspec = portspec(SituatedSensorLayout(colour_sensing=true, n_colours=2, source_bank=true, signalling=true))
    @test ports(fspec).receptors[2 + 2 * _NB + 1].id == :acoustic
    # Single-colour keeps the legacy index 65.
    sspec = portspec(SituatedSensorLayout(source_bank=true, signalling=true))
    @test ports(sspec).receptors[BrainlessLab.DEFAULT_SIGNAL_RECEPTOR_INDEX].id == :acoustic
end

@testset "max over colour banks == colour-blind bank (pre-noise)" begin
    torus = Torus(15.0)
    positions = [(5.0, 5.0), (7.0, 6.0), (4.0, 8.0), (8.0, 4.5)]
    colours = [0, 0, 1, 1]
    r = 0.5

    for sens_agent_dist in (0, 1)
        blind = sense_agents(positions[1], 0.3, positions, 1, r, torus, _ANG, sens_agent_dist, 0.0, MersenneTwister(0))
        col = sense_agents_coloured(positions[1], 0.3, positions, colours, 1, r, torus, _ANG,
                                    sens_agent_dist, 0.0, MersenneTwister(0); n_colours=2)
        red = col[1:_NB]
        green = col[(_NB + 1):(2 * _NB)]
        @test length(col) == 2 * _NB
        @test max.(red, green) ≈ blind
    end

    # An agent is never told its own colour — self is excluded via `skip`. A lone
    # agent (only itself present) therefore reports an all-zero coloured view.
    solo = [(5.0, 5.0)]
    lone = sense_agents_coloured(solo[1], 0.3, solo, [0], 1, r, torus, _ANG, 0, 0.0, MersenneTwister(0); n_colours=2)
    @test length(lone) == 2 * _NB
    @test all(iszero, lone)
end

@testset "Colour assignment (interleaved + explicit)" begin
    # Balanced interleaved default: 0,1,0,1,0,1 -> 3 of each for C=2.
    env = TorusEnvironment(SwarmConfig(n_agents=6, n_colours=2, colour_sensing=true))
    @test env.colours == [0, 1, 0, 1, 0, 1]
    @test count(==(0), env.colours) == 3
    @test count(==(1), env.colours) == 3

    env3 = TorusEnvironment(SwarmConfig(n_agents=7, n_colours=3, colour_sensing=true))
    @test env3.colours == [0, 1, 2, 0, 1, 2, 0]

    # Explicit assignment is honoured verbatim.
    env_x = TorusEnvironment(SwarmConfig(n_agents=4, n_colours=2, colour_sensing=true, colours=[1, 1, 0, 0]))
    @test env_x.colours == [1, 1, 0, 0]

    # Wrong-length explicit colours are rejected.
    @test_throws ArgumentError TorusEnvironment(SwarmConfig(n_agents=4, n_colours=2, colours=[0, 1]))
end

@testset "colour_sensing=false encodes identically to the pre-colour path" begin
    raw = collect(1.0:Float64(_NB))
    base = assemble_inputs(raw)                                            # legacy path
    @test assemble_inputs(raw; n_colours=1, colour_sensing=false) == base
    @test assemble_inputs(raw; n_colours=1, colour_sensing=true) == base   # C=1 == blind
    @test length(base) == 64

    # Forage: colour-blind path matches the legacy 128-wide layout.
    src = collect(1.0:Float64(_NB)) ./ 10.0
    fbase = assemble_forage_inputs(raw, src; source_gain=2.0)
    @test assemble_forage_inputs(raw, src; source_gain=2.0, n_colours=1, colour_sensing=false) == fbase
    @test length(fbase) == 128

    # Full observe path is identical between the default and an explicit no-op config.
    torus = Torus(20.0)
    positions = [(3.0, 4.0), (6.0, 7.0), (10.0, 2.0)]
    cfg_default = SwarmConfig(n_agents=3, space_size=20.0, sensory_noise=0.0)
    cfg_noop = SwarmConfig(n_agents=3, space_size=20.0, sensory_noise=0.0, n_colours=1, colour_sensing=false)
    env_a = TorusEnvironment(torus, positions; config=cfg_default, rng=MersenneTwister(3))
    env_b = TorusEnvironment(torus, positions; config=cfg_noop, rng=MersenneTwister(3))
    bodies = [situated_embodiment(SituatedSensorLayout()) for _ in 1:3]
    ia = sample!(env_a, bodies)
    ib = sample!(env_b, bodies)
    @test all(length(v) == 64 for v in ia)
    @test ia == ib
end

@testset "Coloured observe width composes with :torus and :forage" begin
    torus = Torus(20.0)
    positions = [(3.0, 4.0), (6.0, 7.0), (10.0, 2.0), (12.0, 15.0)]
    bodies = [situated_embodiment(SituatedSensorLayout(colour_sensing=true, n_colours=2)) for _ in 1:4]

    cfg = SwarmConfig(n_agents=4, space_size=20.0, sensory_noise=0.0, n_colours=2, colour_sensing=true)
    tenv = TorusEnvironment(torus, positions; config=cfg, rng=MersenneTwister(5))
    ti = sample!(tenv, bodies)
    @test all(length(v) == 126 for v in ti)

    fbodies = [situated_embodiment(SituatedSensorLayout(colour_sensing=true, n_colours=2, source_bank=true)) for _ in 1:4]
    fcfg = SwarmConfig(n_agents=4, space_size=20.0, sensory_noise=0.0, n_colours=2, colour_sensing=true,
                       source_position=(10.0, 10.0), source_gain=1.5, capture_radius=0.5)
    fenv = ForageEnvironment(torus, positions; config=fcfg, rng=MersenneTwister(5))
    fi = sample!(fenv, fbodies)
    @test all(length(v) == 190 for v in fi)
end

@testset "segregation metric" begin
    torus = Torus(100.0)
    # Reds clustered together, greens far away -> strongly assortative.
    pos = [(10.0, 10.0), (11.0, 10.0), (10.0, 11.0), (80.0, 80.0), (81.0, 80.0), (80.0, 81.0)]
    col = [0, 0, 0, 1, 1, 1]
    seg = segregation(pos, col, torus)
    @test seg.assortativity > 0.5
    @test seg.same_dist < seg.cross_dist

    # Spatially checkerboarded colours -> near-chance (not colour-sorted).
    mixed = [(0.0, 0.0), (1.0, 0.0), (2.0, 0.0), (0.0, 1.0), (1.0, 1.0), (2.0, 1.0)]
    mix = segregation(mixed, [0, 1, 0, 1, 0, 1], torus)
    @test abs(mix.assortativity) < 0.2
    @test mix.assortativity < seg.assortativity
end

@testset "Coloured simulate runs and segregation computes" begin
    sim = simulate(:torus; node=:falandays_oosawa, n_agents=12, n_nodes=60, ticks=60, seed=1,
                   space_size=30.0, vision_range=18.0, n_colours=3, colour_sensing=true,
                   record=[:poses], metrics=:segregation)
    @test sim isa SimResult
    @test sim.task == :torus
    @test sim.config.environment.n_colours == 3
    @test sim.config.environment.colour_sensing == true
    @test length(sim.config.environment.colours) == 12
    @test isfinite(sim.metrics.assortativity)
    @test -1.0 <= sim.metrics.assortativity <= 1.0

    # Colour-blind control (colours assigned, sensing off) is the natural null.
    ctrl = simulate(:torus; node=:falandays_oosawa, n_agents=12, n_nodes=60, ticks=60, seed=1,
                    space_size=30.0, vision_range=18.0, n_colours=3, colour_sensing=false,
                    record=[:poses], metrics=:segregation)
    @test ctrl.config.environment.colour_sensing == false
    @test isfinite(ctrl.metrics.assortativity)
end
