using BrainlessLab
using Random
using Test

_wrapper_trait_probe(wrapper) = (
    plasticity(wrapper),
    windowing(wrapper),
    temporal_window(wrapper),
    n_nodes(wrapper),
)
_wrapper_trait_probe_allocated(wrapper) = @allocated _wrapper_trait_probe(wrapper)

@testset "NoisyInput transparent reservoir contract" begin
    inner = BrainlessLab._falandays_native(18, 3, 2; seed=4, substeps=3)
    wrapper = BrainlessLab.NoisyInput(inner; sensory_noise=0.2, seed=7)

    @test_throws ArgumentError BrainlessLab.NoisyInput(inner; sensory_noise=-0.1)
    @test_throws ArgumentError BrainlessLab.NoisyInput(inner; sensory_noise=NaN)
    @test_throws ArgumentError BrainlessLab.NoisyInput(inner; sensory_noise=Inf)

    traits = @inferred _wrapper_trait_probe(wrapper)
    @test traits[1] isa OnlinePlasticity
    @test traits[2] isa SteppedWindow
    @test traits[3] == 3
    @test traits[4] == 18
    _wrapper_trait_probe(wrapper)
    _wrapper_trait_probe_allocated(wrapper)
    @test _wrapper_trait_probe_allocated(wrapper) == 0

    @test activations(wrapper) === activations(inner)
    @test weights(wrapper) === weights(inner)
    @test all(name -> hasproperty(wrapper, name), propertynames(inner))
    @test hasproperty(wrapper, :sensory_noise)
    @test network_snapshot(wrapper) == network_snapshot(inner)

    @test supports_intervention(FreezePlasticity(), wrapper)
    @test !supports_intervention(ResetDendrites(), wrapper)
    apply!(FreezePlasticity(), wrapper)
    @test !wrapper.params.learn_on
    @test temporal_window(wrapper) == 3
    @test_throws MethodError apply!(ResetDendrites(), wrapper)
end

@testset "NoisyInput state snapshots continue the wrapper RNG" begin
    make_wrapper() = BrainlessLab.NoisyInput(
        BrainlessLab._falandays_native(16, 3, 2; seed=9);
        sensory_noise=0.35,
        seed=21,
    )
    source = make_wrapper()
    restored = make_wrapper()
    inputs = (
        [0.2, 0.4, 0.6],
        [0.8, 0.1, 0.3],
        [0.5, 0.5, 0.2],
        [0.7, 0.2, 0.9],
    )

    step!(source, inputs[1])
    step!(source, inputs[2])
    state = snapshot_state(source)
    load_state!(restored, state)

    for receptors in inputs[3:4]
        @test step!(source, receptors) == step!(restored, receptors)
        @test source.acts == restored.acts
        @test source.targets == restored.targets
        @test source.wmat == restored.wmat
    end

    legacy = snapshot_state(source.inner)
    legacy_target = make_wrapper()
    @test load_state!(legacy_target, legacy) === legacy_target
    @test legacy_target.acts == source.acts
    @test legacy_target.targets == source.targets
    @test legacy_target.wmat == source.wmat
end

@testset "NoisyInput delegates recording, inspection, and interventions" begin
    sim = simulate(
        :wall;
        node=:falandays_noisy,
        n_nodes=12,
        ticks=3,
        seed=5,
        record=(:acts, :targets, :spectral_radius),
    )
    @test length(getchannel(sim.recorder, :acts)) == 3
    @test length(getchannel(sim.recorder, :targets)) == 3
    @test length(getchannel(sim.recorder, :spectral_radius)) == 3
    @test only(sim.config.networks) !== nothing

    zeroed = BrainlessLab._build_ensemble(
        :tracking,
        :falandays_noisy;
        ticks=2,
        seed=6,
        n_nodes=12,
        ablation=:zero_recurrent,
    )
    zeroed_reservoir = only(zeroed.ensemble.agents).reservoir
    @test all(iszero, zeroed_reservoir.wmat)

    scheduled = BrainlessLab._build_ensemble(
        :tracking,
        :falandays_noisy;
        ticks=2,
        seed=7,
        n_nodes=12,
        node_kwargs=(substeps=2,),
    )
    scheduled_reservoir = only(scheduled.ensemble.agents).reservoir
    BrainlessLab.rollout!(
        scheduled.ensemble,
        2;
        window=2,
        interventions=[(1, :freeze_plasticity)],
    )
    @test !scheduled_reservoir.params.learn_on
    @test temporal_window(scheduled_reservoir) == 2
end
