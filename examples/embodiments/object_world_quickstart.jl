using BrainlessLab
using Random

"""Load a configured robot and run it in the generic spectral object world."""
function run_object_world_quickstart(; ticks::Integer=25, seed::Integer=7)
    preset = joinpath(
        pkgdir(BrainlessLab),
        "examples",
        "embodiments",
        "differential_robot.toml",
    )
    body = BrainlessLab.materialize_embodiment(BrainlessLab.read_embodiment_config(preset))

    beacon = BrainlessLab.ObjectType(
        :beacon;
        radius=0.45,
        appearance=BrainlessLab.rgb_appearance((1.0, 0.15, 0.02)),
    )
    world = BrainlessLab.ObjectWorld(
        BrainlessLab.WalledArena(12.0),
        [BrainlessLab.MotionState2D(position=(2.0, 6.0), heading=0.0)];
        populations=(BrainlessLab.ObjectPopulation(beacon, [(7.0, 6.0)]),),
        rng=MersenneTwister(seed),
    )

    reservoir = FalandaysReservoir(
        80,
        n_receptors(body),
        n_effectors(body);
        seed=seed,
        repair_masks=true,
    )
    recorder = Recorder(enabled=(:poses, :receptors, :objects, :components))
    ensemble = BrainlessLab.Ensemble(
        [BrainlessLab.Agent(reservoir, body)],
        world;
        ids=[BrainlessLab.EntityID(101)],
        recorder=recorder,
    )
    for _ in 1:Int(ticks)
        step!(ensemble)
    end
    return (ensemble=ensemble, recorder=recorder, objects=BrainlessLab.object_snapshot(world))
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = run_object_world_quickstart()
    final_pose = last(getchannel(result.recorder, :poses))
    println("entity $(only(final_pose.ids)) ended at $(only(final_pose))")
end
