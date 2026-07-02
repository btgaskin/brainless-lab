"""
    NodeModel

Abstract supertype for evolvable node parameter bundles.

A `NodeModel` represents the genotype-side description of one node family. Its
evolvable values are exposed through `pack_params`, `unpack_params`, and
`paramdim`; dynamic runtime values belong to reservoir state and are exposed
through `snapshot_state` and `load_state!`.
"""
abstract type NodeModel end

"""
    Reservoir

Abstract supertype for a population of nodes plus its dynamic state.

Reservoir parameters and reservoir state are intentionally separate. Parameters
are evolvable genotype data handled by `pack_params`, `unpack_params`, and
`paramdim`. State is transient simulation data handled by `snapshot_state` and
`load_state!`.
"""
abstract type Reservoir end

"""
    Body

Abstract supertype for embodied structures that connect reservoirs to a medium
or task.
"""
abstract type Body end

"""
    Medium

Abstract supertype for the environment or substrate in which bodies and
reservoirs operate.
"""
abstract type Medium end

"""
    AbstractTask

Abstract supertype for task definitions.

Named `AbstractTask` to avoid clashing with `Base.Task`.
"""
abstract type AbstractTask end

"""
    Runner

Abstract supertype for simulation runners that coordinate reservoirs, bodies,
media, tasks, drives, and interventions.
"""
abstract type Runner end

"""
    Drive

Abstract supertype for external drive signals applied to a reservoir or system.
"""
abstract type Drive end

"""
    Intervention

Abstract supertype for perturbations or experimental manipulations applied to a
system.
"""
abstract type Intervention end

"""
    AbstractEvolutionStrategy

Abstract supertype for optimizers or evolution strategies that propose and
consume candidate parameter vectors.
"""
abstract type AbstractEvolutionStrategy end

"""
    step!(object, args...)

Advance an object by one simulation step.
"""
function step! end

"""
    effectors(object, args...)

Return the current effector values exposed by an object.
"""
function effectors end

"""
    reset!(object, args...)

Reset dynamic runtime state without changing evolvable parameters.
"""
function reset! end

"""
    n_receptors(object, args...)

Return the number of receptor channels accepted by an object.
"""
function n_receptors end

"""
    n_effectors(object, args...)

Return the number of effector channels emitted by an object.
"""
function n_effectors end

"""
    pack_params(object, args...)

Pack evolvable parameters into a flat genotype representation.

Parameter packing is separate from state snapshotting: use `snapshot_state` for
dynamic runtime state.
"""
function pack_params end

"""
    unpack_params(object, params, args...)

Load evolvable parameters from a genotype representation.

Parameter unpacking is separate from state loading: use `load_state!` for
dynamic runtime state.
"""
function unpack_params end

"""
    paramdim(object, args...)

Return the number of evolvable scalar parameters represented by `object`.
"""
function paramdim end

"""
    snapshot_state(object, args...)

Return a representation of dynamic runtime state.

State snapshots are not evolvable genotype data. Use `pack_params` for
parameters.
"""
function snapshot_state end

"""
    load_state!(object, state, args...)

Restore dynamic runtime state from a state snapshot.

State loading is separate from parameter unpacking: use `unpack_params` for
evolvable genotype data.
"""
function load_state! end

"""
    observe(object, args...)

Return task, medium, body, or reservoir observations.
"""
function observe end

"""
    actuate!(object, command, args...)

Apply an actuation command to an object.
"""
function actuate! end

"""
    receptors(object, args...)

Return receptor values available to a reservoir or body.
"""
function receptors end

"""
    motor(object, args...)

Return or compute motor commands from an object.
"""
function motor end

"""
    score(task, args...)

Return the scalar objective score for a task or rollout.
"""
function score end

"""
    metrics(object, args...)

Return named diagnostic metrics for a task, rollout, or system.
"""
function metrics end

"""
    apply_drive!(drive, object, args...)

Apply an external drive signal to an object.
"""
function apply_drive! end

"""
    apply!(intervention, object, args...)

Apply an intervention to an object.
"""
function apply! end

"""
    ask(strategy, args...)

Ask an evolution strategy for candidate parameters.
"""
function ask end

"""
    tell!(strategy, results, args...)

Update an evolution strategy with evaluated candidate results.
"""
function tell! end

"""
    result(strategy, args...)

Return the current result or summary from an evolution strategy.
"""
function result end
