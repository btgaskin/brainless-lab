using Random
using Test

function _contended_object_winner(ids; seed)
    bodies = [_object_world_preset(:bilateral_insect) for _ in 1:2]
    resource = ObjectType(:resource; radius=0.35, capacity=1)
    world = ObjectWorld(
        Torus(8.0),
        [
            MotionState2D(position=(2.0, 2.0)),
            MotionState2D(position=(2.0, 2.0)),
        ];
        populations=(ObjectPopulation(resource, [(2.0, 2.0)]),),
        fields=(odor=ConstantSpatialField(0.5),),
        rng=MersenneTwister(seed),
    )
    agents = [
        Agent(_ObjectWorldReservoir(n_receptors(body), zeros(n_effectors(body))), body)
        for body in bodies
    ]
    ensemble = Ensemble(agents, world; ids=ids)
    step!(ensemble)
    return only(interaction_events(world)).agent
end

@testset "finite object arbitration is reproducible and exchangeable" begin
    stable_ids = EntityID[EntityID(91), EntityID(12)]
    for seed in 1:12
        forward = _contended_object_winner(stable_ids; seed)
        reversed = _contended_object_winner(reverse(stable_ids); seed)
        @test forward == reversed
    end

    winners = Set(_contended_object_winner(stable_ids; seed) for seed in 1:32)
    @test winners == Set(stable_ids)
end
