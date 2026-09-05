using BrainlessLab, Random, Test
using BrainlessLab: resource_report, resolve_composition

@testset "CTRNN integration, ownership, and declared resources" begin
    for family in (BrainlessLab.DenseCompartmental, BrainlessLab.StructuredCompartmental)
        mode = family === BrainlessLab.DenseCompartmental ? :dense : :structured
        model = unpack_params(family, randn(MersenneTwister(113), paramdim(family)))
        wiring = BrainlessLab.build_wiring(20, 17; n_receptors=3, n_effectors=2,
            mode, k_rec=4, k_in=2, output_fanout=3)
        multi = BrainlessLab.CompartmentalReservoir(model, wiring; substeps=5)
        single = BrainlessLab.CompartmentalReservoir(model, wiring; dt=0.2, substeps=1)
        input = [1.0, 0.0, 1.0]
        output = step!(multi, input)
        expected = sum(step!(single, input) for _ in 1:5) / 5
        @test output == expected
        @test snapshot_state(multi) == snapshot_state(single)
        saved = copy(output)
        step!(multi, input)
        @test output == saved
        @test effectors(multi, output) == [sum(output[sources]) / length(sources) for sources in wiring.effector_sources]
        @test all(==(3), length.(wiring.effector_sources))
        report = resource_report(multi)
        @test report.recurrent_edges == 80
        @test report.input_edges == 40
        @test report.output_edges == 6
        @test report.internal_states == 20 * (6 * 6 + 12 + 1)
        @test report.integration_updates_per_frame == 5 * report.internal_states
        step!(multi, input)
        @test (@allocated step!(multi, input)) < 1500
        @test_throws ArgumentError BrainlessLab.CompartmentalReservoir(model, wiring; substeps=0)
        @test_throws ArgumentError BrainlessLab.CompartmentalReservoir(model, wiring; dt=NaN)
        @test_throws ArgumentError BrainlessLab.build_wiring(20, 1; n_receptors=3, n_effectors=2, k_rec=20)
        @test_throws ArgumentError BrainlessLab.build_wiring(20, 1; n_receptors=3, n_effectors=2, output_fanout=21)
        node = Symbol(:compartmental_, mode)
        composition = CompositionSpec(:declared_ctrnn, node, :delayed_cue; n_nodes=20,
            parameters=Dict(:dt => 0.5, :substeps => 2, :k_rec => 4, :k_in => 2, :output_fanout => 3))
        resolved = resolve_composition(composition, DEFAULT_REGISTRY)
        setup = BrainlessLab._build_composition(resolved, EvaluationSpec(horizon=144); model)
        reservoir = first(setup.ensemble.agents).reservoir
        @test reservoir.dt_sub == 0.25
        @test reservoir.wiring.K == 6
        @test all(==(3), length.(reservoir.wiring.effector_sources))
        replacement = unpack_params(family, zeros(paramdim(family)))
        reservoir.genome = replacement
        @test reservoir.model.kernel == BrainlessLab._compartmental_kernel(replacement)
    end
end
