using Test, BrainlessLab
include(joinpath(@__DIR__, "freeze_curves.jl"))

@testset "capacity freeze authoring" begin
    programme = capacity_freeze_programme()
    @test length(programme.children) == 7
    for branch in programme.children
        @test branch.evidence_state == :exploratory
        @test all(t -> t.evaluation.blocks==10 && t.evaluation.warmup==0 &&
            t.evaluation.reset==:full && t.evaluation.construction_scope==:block, branch.conditions)
        @test isempty(first(branch.conditions).interventions)
        cuts = branch.metadata.adaptive_ticks
        @test first(cuts)==0
        @test all(t -> isempty(t.interventions) || only(t.interventions).tick-1 in cuts, branch.conditions)
        if first(branch.conditions).composition.task==:reversal_adaptation
            @test first(branch.conditions).composition.task_options[:reversal_range] == (48,48)
            @test all(n -> n%24==0,cuts)
        end
    end
    mktempdir() do d
        write_experiment(joinpath(d,"protocol"),programme)
        loaded = read_experiment(joinpath(d,"protocol"))
        @test length(loaded.children)==7
    end
    all_cells = capacity_freeze_programme(cells=capacity_probe_presets(), blocks=1, trials_per_block=1)
    @test length(all_cells.children)==64
    @test BrainlessLab.validate(all_cells, DEFAULT_REGISTRY) === all_cells
    @test_throws ArgumentError capacity_freeze_programme(blocks=0)
    @test_throws ArgumentError capacity_freeze_programme(scales=(0.1,0.1))
    @test_throws ArgumentError capacity_freeze_programme(cutoffs=Dict(:missing=>[1]))
    @test_throws ArgumentError capacity_freeze_programme(mechanisms=(:zero_recurrent,))
    @test_throws ArgumentError capacity_freeze_programme(cutoffs=Dict(:delayed_cue__delay_32=>[48]))
end
