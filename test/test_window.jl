using BrainlessLab
using Test

@testset "WindowTrait dispatch" begin
    fr = BrainlessLab._falandays_native(20, 4, 2; seed=1)
    cr = BrainlessLab._compartmental_structured_native(20, 4, 2; seed=1)

    # Falandays: single-tick map -> framework-looped window (default K=1).
    @test windowing(fr) === SteppedWindow()
    @test temporal_window(fr) == 1
    @test temporal_window(BrainlessLab._falandays_native(20, 4, 2; seed=1, substeps=5)) == 5

    # Compartmental: owns its own sub-integration -> IntrinsicWindow, not looped.
    @test windowing(cr) === IntrinsicWindow()
    @test temporal_window(cr) == 5   # its constructor default
end

@testset "step_window! K=1 is a bare step!" begin
    R = [0.3, 0.7, 0.1, 0.5]
    a = BrainlessLab._falandays_native(20, 4, 2; seed=3, substeps=1)
    b = BrainlessLab._falandays_native(20, 4, 2; seed=3, substeps=1)
    @test BrainlessLab.step_window!(a, R) == step!(b, R)
end

@testset "step_window! mean-reduces K sub-ticks (SteppedWindow)" begin
    R = [0.3, 0.7, 0.1, 0.5]
    K = 3
    windowed = BrainlessLab._falandays_native(20, 4, 2; seed=5, substeps=K)
    manual = BrainlessLab._falandays_native(20, 4, 2; seed=5, substeps=1)  # identical wiring/noise

    got = BrainlessLab.step_window!(windowed, R)
    ticks = [step!(manual, R) for _ in 1:K]
    expected = sum(ticks) ./ K

    @test got ≈ expected
    # For K>1 the readout is a fractional rate, not a binary vector.
    @test any(0.0 .< got .< 1.0) || all(iszero, got)
end

@testset "step_window! IntrinsicWindow calls step! once" begin
    R = [0.2, 0.4, 0.6, 0.8]
    a = BrainlessLab._compartmental_structured_native(20, 4, 2; seed=9)
    b = BrainlessLab._compartmental_structured_native(20, 4, 2; seed=9)
    # IntrinsicWindow must not be looped by the framework: identical to one step!.
    @test BrainlessLab.step_window!(a, R) == step!(b, R)
end

@testset "substeps knob reaches simulate and changes behavior" begin
    s1 = simulate(:wall; node=:falandays_base, seed=7, ticks=120, node_kwargs=(substeps=1,))
    s5 = simulate(:wall; node=:falandays_base, seed=7, ticks=120, node_kwargs=(substeps=5,))
    @test isfinite(s1.metrics.score)
    @test isfinite(s5.metrics.score)
    @test s1.metrics.score != s5.metrics.score   # the knob does something
end
