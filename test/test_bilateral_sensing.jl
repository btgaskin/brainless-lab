using BrainlessLab
using Test

@testset "Bilateral mounted fields and encoders" begin
    arena = BrainlessLab.WalledArena(10.0)
    field_x = BrainlessLab.LinearSpatialField((0.0, 0.0), (1.0, 0.0); offset=0.0, scale=10.0)
    field_y = BrainlessLab.LinearSpatialField((0.0, 0.0), (0.0, 1.0); offset=0.0, scale=10.0)
    probe = BrainlessLab.BilateralFieldProbe(baseline=2.0)

    raw = BrainlessLab.sample_bilateral_fields(
        probe,
        (x=field_x, y=field_y),
        (5.0, 5.0),
        0.0,
        0,
        arena,
    )
    # x field is equal at both lateral mounts; y field is higher on the left.
    @test raw ≈ [0.5, 0.5, 0.6, 0.4]
    @test BrainlessLab.encode_bilateral(BrainlessLab.RawBilateralEncoder(), raw) == raw
    @test BrainlessLab.encode_bilateral(BrainlessLab.CommonModeEncoder(), raw) ≈ [0.5, 0.5]
    contrast = BrainlessLab.encode_bilateral(BrainlessLab.UnitContrastEncoder(1e-12), raw)
    @test contrast[1] ≈ 0.5
    @test contrast[2] ≈ 0.4

    mirrored = BrainlessLab.sample_bilateral_fields(
        probe,
        (y=field_y,),
        (5.0, 5.0),
        pi,
        0,
        arena,
    )
    mirrored_contrast = only(BrainlessLab.encode_bilateral(BrainlessLab.UnitContrastEncoder(1e-12), mirrored))
    @test mirrored_contrast ≈ 1.0 - contrast[2]
    @test_throws DimensionMismatch BrainlessLab.encode_bilateral(BrainlessLab.CommonModeEncoder(), [1.0])

    torus_raw = BrainlessLab.sample_bilateral_fields(
        BrainlessLab.BilateralFieldProbe(baseline=1.0),
        (constant=BrainlessLab.ConstantSpatialField(0.75),),
        (0.1, 5.0),
        pi / 2,
        0,
        BrainlessLab.Torus(10.0),
    )
    @test torus_raw == [0.75, 0.75]
end

@testset "First-order response and split deterministic noise" begin
    response = BrainlessLab.SensorResponse(
        tau=1.0,
        dt=1.0,
        shared_sigma=0.1,
        independent_sigma=0.05,
        minimum=-Inf,
        maximum=Inf,
    )
    state = BrainlessLab.SensorResponseState(4; shared_seed=11, independent_seed=22)
    input = ones(4)
    groups = [1, 1, 2, 2]
    first = copy(BrainlessLab.respond!(state, response, input; groups=groups))
    filtered_first = BrainlessLab.response_alpha(response)
    @test all(value -> isfinite(value), first)
    @test all(value -> value > filtered_first - 1.0, first)

    second = copy(BrainlessLab.respond!(state, response, input; groups=groups))
    @test state.values == fill(1.0 - exp(-2.0), 4)
    @test second != first

    reset!(state)
    @test copy(BrainlessLab.respond!(state, response, input; groups=groups)) == first

    shared_only = BrainlessLab.SensorResponse(shared_sigma=0.2, minimum=-Inf, maximum=Inf)
    shared_state = BrainlessLab.SensorResponseState(4; shared_seed=7, independent_seed=8)
    shared_values = copy(BrainlessLab.respond!(shared_state, shared_only, zeros(4); groups=groups))
    @test shared_values[1] == shared_values[2]
    @test shared_values[3] == shared_values[4]
    @test shared_values[1] != shared_values[3]

    independent_only = BrainlessLab.SensorResponse(independent_sigma=0.2, minimum=-Inf, maximum=Inf)
    independent_state = BrainlessLab.SensorResponseState(2; shared_seed=7, independent_seed=8)
    independent_values = copy(BrainlessLab.respond!(independent_state, independent_only, zeros(2); groups=[1, 1]))
    @test independent_values[1] != independent_values[2]

    probe = BrainlessLab.BilateralFieldProbe(response=shared_only)
    bilateral_state = BrainlessLab.SensorResponseState(2; shared_seed=7, independent_seed=8)
    output = BrainlessLab.respond_bilateral_fields!(bilateral_state, probe, [0.0, 0.0])
    @test output[1] == output[2]
end
