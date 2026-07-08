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

Abstract supertype for embodied structures that connect reservoirs to an environment
or task.
"""
abstract type Body end

"""
    Environment

Abstract supertype for the substrate/world that an `Ensemble` observes and
actuates.
"""
abstract type Environment end

"""
    AbstractTask

Abstract supertype for task definitions.

Named `AbstractTask` to avoid clashing with `Base.Task`.
"""
abstract type AbstractTask end

"""
    Runner

Abstract supertype for simulation runners that coordinate reservoirs, bodies,
environments, tasks, drives, and interventions.
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
    genome_type(node)

Return the `NodeModel` type that represents a registered node's evolvable
parameters. Evolution code uses this type with `pack_params`, `paramdim`, and
`unpack_params` instead of branching on built-in node symbols.
"""
function genome_type end

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

Return task, environment, body, or reservoir observations.
"""
function observe end

"""
    bounds(object, args...)

Return visual or task bounds as `(xlo, xhi, ylo, yhi)`, or `nothing`.
"""
function bounds end

"""
    pose(object, args...)

Return a visualizable pose tuple, or `nothing`.
"""
function pose end

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
    encode_receptors(object, args...)

Encode a raw percept into receptor values for a reservoir or body.
"""
function encode_receptors end

"""
    decode_effectors(object, args...)

Decode reservoir effectors into an actuation command for a body or morphology.
"""
function decode_effectors end

"""
    integrate_motion!(object, args...)

Integrate a body's kinematic state from decoded actuation commands.
"""
function integrate_motion! end

"""
    readout(motor, reservoir, spikes)

Re-express a reservoir's output as an effector command vector under a `Motor`'s
readout scheme. The result is passed on to `decode_effectors`. Every scheme is a
memoryless, bias-free re-expression of the reservoir's own output through the
same effector projection: the default returns `effectors(reservoir, spikes)`
unchanged, and graded schemes only substitute a different (still projected)
slice of the reservoir's internal state.
"""
function readout end

"""
    motor(body)

Return the `Motor` (effector-decode policy) carried by a `Body`.
"""
function motor end

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
