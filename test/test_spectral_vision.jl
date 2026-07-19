using BrainlessLab
using Test

@testset "Spectral validation and radiometric integration" begin
    grid = SpectralGrid([400.0, 500.0, 600.0])
    @test length(grid) == 3
    @test_throws ArgumentError SpectralGrid([500.0])
    @test_throws ArgumentError SpectralGrid([400.0, 400.0])
    @test_throws ArgumentError SpectralGrid([400.0, NaN])

    spectrum = Spectrum(grid, [0.0, 1.0, 2.0])
    reflectance = SpectralReflectance(grid, fill(0.5, 3))
    illuminant = SpectralIlluminant(grid, ones(3))
    @test spectrum.values == [0.0, 1.0, 2.0]
    @test_throws ArgumentError Spectrum(grid, [0.0, -1.0, 2.0])
    @test_throws ArgumentError SpectralReflectance(grid, [0.0, 1.1, 0.0])
    @test_throws ArgumentError SpectralIlluminant(grid, [1.0, -0.1, 1.0])
    @test_throws DimensionMismatch Spectrum(grid, ones(2))

    camera = SpectralCamera(
        grid,
        [:broad, :middle],
        [1.0 1.0 1.0; 0.0 1.0 0.0];
        ray_angles=[-0.1, 0.1],
        max_range=10.0,
        exposure=2.0,
    )
    @test n_camera_channels(camera) == 2
    @test n_camera_rays(camera) == 2
    # Trapezoid integral: 0.5 reflectance across a 200 nm interval, then exposure 2.
    @test relative_radiometric_response(camera, reflectance, illuminant) == [200.0, 100.0]
    @test_throws DimensionMismatch SpectralCamera(grid, [:x], ones(1, 2))
    @test_throws ArgumentError SpectralCamera(grid, [:x], zeros(1, 3))
    other_grid = SpectralGrid([400.0, 510.0, 600.0])
    @test_throws DimensionMismatch relative_radiometric_response(
        camera,
        SpectralReflectance(other_grid, ones(3)),
        illuminant,
    )
end

@testset "Mount and exact identity-preserving ray casts" begin
    mount = Mount2D(1.0, 2.0, pi / 4)
    pose = mounted_pose((3.0, 4.0), pi / 2, mount)
    @test pose.position ≈ [1.0, 5.0]
    @test pose.heading ≈ 3pi / 4

    arena = WalledArena(20.0)
    targets = [
        CircleTarget(:far, (8.0, 5.0), 1.0),
        CircleTarget(:near, (5.0, 5.0), 1.0),
        CircleTarget(:off_axis, (4.0, 8.0), 0.5),
    ]
    hit = nearest_circle_hit((0.0, 5.0), 0.0, targets, arena; max_range=20.0)
    @test hit.id === :near
    @test hit.target_index == 2
    @test hit.distance ≈ 4.0
    @test hit.point ≈ [4.0, 5.0]
    @test nearest_circle_hit((0.0, 5.0), pi, targets, arena; max_range=20.0) === nothing

    torus = Torus(10.0)
    seam_hit = nearest_circle_hit(
        (0.2, 5.0),
        pi,
        [CircleTarget(17, (9.2, 5.0), 0.2)],
        torus;
        max_range=2.0,
    )
    @test seam_hit.id == 17
    @test seam_hit.distance ≈ 0.8
    @test seam_hit.point[1] ≈ 9.4
end

@testset "Spectral camera is occluding and channel-major" begin
    grid = SpectralGrid([450.0, 550.0, 650.0])
    illuminant = SpectralIlluminant(grid, ones(3))
    blue = SpectralReflectance(grid, [1.0, 0.0, 0.0])
    red = SpectralReflectance(grid, [0.0, 0.0, 1.0])
    camera = SpectralCamera(
        grid,
        [:blue, :red],
        [1.0 0.0 0.0; 0.0 0.0 1.0];
        ray_angles=[0.0, pi / 2],
        max_range=20.0,
    )
    targets = [
        SpectralCircleTarget(:hidden_red, (8.0, 0.0), 1.0, red),
        SpectralCircleTarget(:near_blue, (5.0, 0.0), 1.0, blue),
        SpectralCircleTarget(:up_red, (0.0, 5.0), 1.0, red),
    ]
    sample = sample_spectral_camera(camera, (0.0, 0.0), 0.0, targets, illuminant, WalledArena(20.0))
    @test [hit.id for hit in sample.hits] == [:near_blue, :up_red]
    # [blue ray 1, blue ray 2, red ray 1, red ray 2]
    @test sample.values == [50.0, 0.0, 0.0, 50.0]

    dark = display_rgb(red, SpectralIlluminant(grid, zeros(3)))
    @test dark == (0.0, 0.0, 0.0)
    rgb_red = display_rgb(red, illuminant)
    @test all(value -> 0.0 <= value <= 1.0, rgb_red)
    @test rgb_red[1] > rgb_red[2]
    @test rgb_red[1] > rgb_red[3]
end
