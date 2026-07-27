using BrainlessLab
using Random
using Test

@testset "Torus vision and metric seam corrections" begin
    torus = BrainlessLab.Torus(10.0)
    agent_radius = 0.5

    # A neighbour just across the wrap, sensed by a single rear-pointing sensor.
    # Agent 1 (self) is skipped; agent 2 is the neighbour.
    sensors = BrainlessLab.sense_agents(
        (5.0, 5.0), 0.0,
        [(5.0, 5.0), (4.0, 4.99)], 1, agent_radius,
        torus, [pi - 0.01], 0, 0,
    )
    @test only(sensors) == 1.0

    positions = [(9.8, 5.0), (0.2, 5.0)]
    centroid = BrainlessLab.circular_centroid(positions, torus)
    @test min(abs(centroid[1]), abs(centroid[1] - torus.size)) <= 1e-12
    @test centroid[2] ≈ 5.0 atol=1e-12

    headings = [-pi / 2, pi / 2]
    @test BrainlessLab.milling(positions, headings, centroid, torus) ≈ 1.0 atol=1e-12
end
