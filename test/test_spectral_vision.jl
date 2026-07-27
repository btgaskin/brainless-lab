using BrainlessLab
using Test

@testset "Spectral validation and radiometric integration" begin
    grid = BrainlessLab.SpectralGrid([400.0, 500.0, 600.0])
    @test length(grid) == 3
    @test_throws ArgumentError BrainlessLab.SpectralGrid([500.0])
    @test_throws ArgumentError BrainlessLab.SpectralGrid([400.0, 400.0])
    @test_throws ArgumentError BrainlessLab.SpectralGrid([400.0, NaN])

    spectrum = BrainlessLab.Spectrum(grid, [0.0, 1.0, 2.0])
    reflectance = BrainlessLab.SpectralReflectance(grid, fill(0.5, 3))
    illuminant = BrainlessLab.SpectralIlluminant(grid, ones(3))
    @test spectrum.values == [0.0, 1.0, 2.0]
    @test_throws ArgumentError BrainlessLab.Spectrum(grid, [0.0, -1.0, 2.0])
    @test_throws ArgumentError BrainlessLab.SpectralReflectance(grid, [0.0, 1.1, 0.0])
    @test_throws ArgumentError BrainlessLab.SpectralIlluminant(grid, [1.0, -0.1, 1.0])
    @test_throws DimensionMismatch BrainlessLab.Spectrum(grid, ones(2))

    camera = BrainlessLab.SpectralCamera(
        grid,
        [:broad, :middle],
        [1.0 1.0 1.0; 0.0 1.0 0.0];
        ray_angles=[-0.1, 0.1],
        max_range=10.0,
        exposure=2.0,
    )
    @test BrainlessLab.n_camera_channels(camera) == 2
    @test BrainlessLab.n_camera_rays(camera) == 2
    @test portspec(camera) === portspec(camera)
    # Trapezoid integral: 0.5 reflectance across a 200 nm interval, then exposure 2.
    @test BrainlessLab.relative_radiometric_response(camera, reflectance, illuminant) == [200.0, 100.0]
    @test_throws DimensionMismatch BrainlessLab.SpectralCamera(grid, [:x], ones(1, 2))
    @test_throws ArgumentError BrainlessLab.SpectralCamera(grid, [:x], zeros(1, 3))
    other_grid = BrainlessLab.SpectralGrid([400.0, 510.0, 600.0])
    @test_throws DimensionMismatch BrainlessLab.relative_radiometric_response(
        camera,
        BrainlessLab.SpectralReflectance(other_grid, ones(3)),
        illuminant,
    )
end

@testset "Mount and exact identity-preserving ray casts" begin
    mount = BrainlessLab.Mount2D(1.0, 2.0, pi / 4)
    pose = BrainlessLab.mounted_pose((3.0, 4.0), pi / 2, mount)
    @test pose.position ≈ [1.0, 5.0]
    @test pose.heading ≈ 3pi / 4

    arena = BrainlessLab.WalledArena(20.0)
    targets = [
        BrainlessLab.CircleTarget(:far, (8.0, 5.0), 1.0),
        BrainlessLab.CircleTarget(:near, (5.0, 5.0), 1.0),
        BrainlessLab.CircleTarget(:off_axis, (4.0, 8.0), 0.5),
    ]
    hit = BrainlessLab.nearest_circle_hit((0.0, 5.0), 0.0, targets, arena; max_range=20.0)
    @test hit.id === :near
    @test hit.target_index == 2
    @test hit.distance ≈ 4.0
    @test hit.point ≈ [4.0, 5.0]
    @test BrainlessLab.nearest_circle_hit((0.0, 5.0), pi, targets, arena; max_range=20.0) === nothing

    torus = BrainlessLab.Torus(10.0)
    seam_hit = BrainlessLab.nearest_circle_hit(
        (0.2, 5.0),
        pi,
        [BrainlessLab.CircleTarget(17, (9.2, 5.0), 0.2)],
        torus;
        max_range=2.0,
    )
    @test seam_hit.id == 17
    @test seam_hit.distance ≈ 0.8
    @test seam_hit.point[1] ≈ 9.4
end

@testset "Spectral camera is occluding and channel-major" begin
    grid = BrainlessLab.SpectralGrid([450.0, 550.0, 650.0])
    illuminant = BrainlessLab.SpectralIlluminant(grid, ones(3))
    blue = BrainlessLab.SpectralReflectance(grid, [1.0, 0.0, 0.0])
    red = BrainlessLab.SpectralReflectance(grid, [0.0, 0.0, 1.0])
    camera = BrainlessLab.SpectralCamera(
        grid,
        [:blue, :red],
        [1.0 0.0 0.0; 0.0 0.0 1.0];
        ray_angles=[0.0, pi / 2],
        max_range=20.0,
    )
    targets = [
        BrainlessLab.SpectralCircleTarget(:hidden_red, (8.0, 0.0), 1.0, red),
        BrainlessLab.SpectralCircleTarget(:near_blue, (5.0, 0.0), 1.0, blue),
        BrainlessLab.SpectralCircleTarget(:up_red, (0.0, 5.0), 1.0, red),
    ]
    sample = BrainlessLab.sample_spectral_camera(camera, (0.0, 0.0), 0.0, targets, illuminant, BrainlessLab.WalledArena(20.0))
    @test [hit.id for hit in sample.hits] == [:near_blue, :up_red]
    # [blue ray 1, blue ray 2, red ray 1, red ray 2]
    @test sample.values == [50.0, 0.0, 0.0, 50.0]

    dark = BrainlessLab.display_rgb(red, BrainlessLab.SpectralIlluminant(grid, zeros(3)))
    @test dark == (0.0, 0.0, 0.0)
    rgb_red = BrainlessLab.display_rgb(red, illuminant)
    @test all(value -> 0.0 <= value <= 1.0, rgb_red)
    @test rgb_red[1] > rgb_red[2]
    @test rgb_red[1] > rgb_red[3]
end
