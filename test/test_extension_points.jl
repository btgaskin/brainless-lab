using BrainlessLab
using LinearAlgebra
using Random
using Test

struct _ExtensionPointSensor <: BrainlessLab.AbstractSensor end
struct _ExtensionPointMotor <: BrainlessLab.Motor end
struct _ExtensionPointAblation <: BrainlessLab.Intervention end

_extension_point_analysis(value) = (value=value,)

function _seeded_parallel_sample(seed::Integer)
    sleep(0.001 * mod(seed, 4))
    return rand(Random.Xoshiro(seed), UInt64, 16)
end

function _parallel_result_bytes(results)
    values = reduce(vcat, results)
    return collect(reinterpret(UInt8, values))
end

@testset "outside contributors can register supported extension points" begin
    analysis_key = :test_extension_point_analysis
    sensor_key = :test_extension_point_sensor
    motor_key = :test_extension_point_motor
    ablation_key = :test_extension_point_ablation

    try
        @test register_analysis!(
            analysis_key,
            _extension_point_analysis;
            task=:tracking,
            label="test extension analysis",
        ) === analysis_key
        @test resolve_analysis(analysis_key) === _extension_point_analysis
        @test BrainlessLab.analysis_meta(analysis_key) ==
            (task=:tracking, label="test extension analysis")
        @test analysis_key in analyses(; task=:tracking)
        @test analysis_key in BrainlessLab.task_analyses(:tracking)
        @test_throws ArgumentError register_analysis!(
            analysis_key,
            identity,
        )
        @test resolve_analysis(analysis_key) === _extension_point_analysis

        @test register_sensor!(sensor_key, _ExtensionPointSensor) ===
            _ExtensionPointSensor
        @test resolve_sensor(sensor_key) === _ExtensionPointSensor
        @test_throws ArgumentError register_sensor!(sensor_key, identity)
        @test resolve_sensor(sensor_key) === _ExtensionPointSensor

        @test register_motor!(motor_key, _ExtensionPointMotor) ===
            _ExtensionPointMotor
        @test resolve_motor(motor_key) === _ExtensionPointMotor
        @test_throws ArgumentError register_motor!(motor_key, identity)
        @test resolve_motor(motor_key) === _ExtensionPointMotor

        @test register_ablation!(ablation_key, _ExtensionPointAblation) ===
            _ExtensionPointAblation
        @test resolve_ablation(ablation_key) === _ExtensionPointAblation
        @test ablation_key in ablations()
        @test_throws ArgumentError register_ablation!(
            ablation_key,
            identity,
        )
        @test resolve_ablation(ablation_key) === _ExtensionPointAblation
    finally
        delete!(BrainlessLab.ANALYSES, analysis_key)
        delete!(BrainlessLab.SENSORS, sensor_key)
        delete!(BrainlessLab.MOTORS, motor_key)
        delete!(BrainlessLab.ABLATIONS, ablation_key)
    end

    @test_throws KeyError resolve_analysis(analysis_key)
    @test_throws KeyError resolve_sensor(sensor_key)
    @test_throws KeyError resolve_motor(motor_key)
    @test_throws KeyError resolve_ablation(ablation_key)
end

@testset "explore explains its optional backend requirement" begin
    error = try
        BrainlessLab.explore(:torus)
        nothing
    catch caught
        caught
    end
    @test error isa ArgumentError
    @test occursin("GLMakie", sprint(showerror, error))
end

@testset "parallel_map preserves seeded output bytes and order" begin
    expected_threads = get(ENV, "BRAINLESSLAB_EXPECT_THREADS", "")
    if !isempty(expected_threads)
        @test Threads.nthreads() == parse(Int, expected_threads)
    end

    seeds = collect(1:24)
    serial = BrainlessLab.parallel_map(
        _seeded_parallel_sample,
        seeds;
        threaded=false,
    )
    threaded = BrainlessLab.parallel_map(
        _seeded_parallel_sample,
        seeds;
        threaded=true,
    )

    @test serial == threaded
    @test _parallel_result_bytes(serial) ==
        _parallel_result_bytes(threaded)
end

@testset "init_parallelism reports and restores process settings" begin
    original_blas_threads = LinearAlgebra.BLAS.get_num_threads()
    try
        info = BrainlessLab.init_parallelism!()
        @test info.julia_threads == Threads.nthreads()
        @test info.blas_threads ==
            (Threads.nthreads() > 1 ? 1 : original_blas_threads)
    finally
        LinearAlgebra.BLAS.set_num_threads(original_blas_threads)
    end
end
