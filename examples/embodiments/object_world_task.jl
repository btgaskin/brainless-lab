using BrainlessLab
using Random

"""Concrete, copy-ready setup callable for a physical `ObjectWorld` task."""
struct ObjectWorldExampleSetup end

function (::ObjectWorldExampleSetup)(;
    seed::Integer=7,
    rng=nothing,
    body=nothing,
    n_nodes::Integer=80,
    kwargs...,
)
    isempty(kwargs) || throw(ArgumentError(
        "unsupported object-world example options: $(sort!(collect(keys(kwargs))))",
    ))
    Int(n_nodes) >= 1 || throw(ArgumentError("n_nodes must be positive"))

    body_ = if body === nothing
        preset = joinpath(
            pkgdir(BrainlessLab),
            "examples",
            "embodiments",
            "differential_robot.toml",
        )
        materialize_embodiment(read_embodiment_config(preset))
    elseif body isa AbstractBody
        body
    else
        throw(ArgumentError("body must be an AbstractBody or nothing"))
    end

    beacon = ObjectType(
        :beacon;
        radius=0.45,
        appearance=rgb_appearance((1.0, 0.15, 0.02)),
    )
    world = ObjectWorld(
        WalledArena(12.0),
        [MotionState2D(position=(2.0, 6.0), heading=0.0)];
        populations=(ObjectPopulation(beacon, [(7.0, 6.0)]),),
        rng=rng === nothing ? MersenneTwister(seed) : rng,
    )
    return TaskSetup(world, [body_])
end

const OBJECT_WORLD_EXAMPLE_TASK = TaskSpec(
    :object_world_example,
    ObjectWorldExampleSetup();
    default_ticks=25,
    default_window=25,
    score_key=nothing,
)

"""Run the neutral physical example through `simulate`, returning a `SimResult`."""
function run_object_world_task(;
    ticks::Integer=25,
    seed::Integer=7,
    n_nodes::Integer=80,
)
    return simulate(
        OBJECT_WORLD_EXAMPLE_TASK;
        node=:falandays,
        ticks=ticks,
        seed=seed,
        n_nodes=n_nodes,
        repair_masks=true,
        record=(:spikes, :rate, :poses, :receptors, :components, :objects),
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    sim = run_object_world_task()
    final_pose = only(last(getchannel(sim.recorder, :poses)))
    println("task $(sim.task) ended at $(final_pose)")
    println("metrics $(sim.metrics)")
end
