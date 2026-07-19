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
    AbstractBody

Abstract supertype for embodied structures that connect reservoirs to an environment
or task.
"""
abstract type AbstractBody end

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
    n_nodes(reservoir)

Return the number of nodes in a reservoir. This is used by the generic
ensemble loop when an inactive body must retain its stable agent slot without
advancing neural state.
"""
function n_nodes end

"""
    portspec(body)

Return the receptor/effector port contract exposed by a body.
"""
function portspec end

"""
    receptor_link_profile(body, default_probability)

Return `nothing` when every receptor inherits the reservoir's ordinary input
probability, otherwise return one probability per receptor.
"""
function receptor_link_profile end

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
    prepare_step!(environment, bodies)

Advance environment-owned lifecycle state that must be visible to every agent
before the synchronous observation phase. The default is a no-op.
"""
prepare_step!(::Environment, bodies) = nothing

"""
    bind_entity_ids!(environment, ids)

Bind the stable ensemble identities associated with the environment's world
slots. Environments that record interactions can specialize this hook; the
default leaves environments without identity-aware state unchanged.
"""
bind_entity_ids!(::Environment, ids) = nothing

"""
    remember_receptors!(environment, receptor_vectors)

Optional hook receiving the exact vectors delivered to reservoirs after body
encoding. Environments that compute input-history metrics can retain them here.
"""
function remember_receptors! end
remember_receptors!(::Environment, receptor_vectors) = nothing

"""
    interaction_events(environment)

Return world-global interaction events from the most recent tick. Environments
without an interaction surface leave this generic inapplicable.
"""
function interaction_events end

"""
    object_snapshot(environment)

Return a stable, recordable snapshot of external objects. Environments without
objects leave this generic inapplicable.
"""
function object_snapshot end

"""
    conspecific_contacts(environment)

Return entity-aligned conspecific contact counts for the most recent tick.
Environments without this surface leave the generic inapplicable.
"""
function conspecific_contacts end

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
    apply_commands!(object, command, args...)

Apply an actuation command to an object.
"""
function apply_commands! end

"""
    update!(body, effects)

Commit end-of-tick body state changes from environment effects. Stateless
bodies implement this as a no-op; physiological bodies use it for their own
state transition.
"""
function update! end

"""
    alive(body)

Return whether a body participates in sensing, neural stepping, actuation,
interactions, and metrics.
"""
function alive end

"""
    inactive_command(body)

Return a neutral command with the same public command type that `decode!` emits
for `body`. The generic vector-body fallback returns a zero effector vector;
bodies with typed commands must specialize this method.
"""
function inactive_command end

"""
    expose!(body, effect)

Apply one typed environment effect to a body.
"""
function expose! end

"""
    sense!(object, args...)

Return receptor values available to a reservoir or body.
"""
function sense! end

"""
    encode!(object, args...)

Encode a raw percept into receptor values for a reservoir or body.
"""
function encode! end

"""
    encoder_sources(encoder)

Return the stable sensor component IDs consumed by `encoder`, or `nothing`
when the encoder uses the conventional whole-bank/positional composition
rules. Source-aware encoders should return a non-empty tuple of symbols.
"""
function encoder_sources end

"""
    decode!(object, args...)

Decode reservoir effectors into an actuation command for a body or morphology.
"""
function decode! end

"""
    integrate!(object, args...)

Integrate a body's kinematic state from decoded actuation commands.
"""
function integrate! end

"""
    rawspec(object)

Describe the raw physical samples produced by a sensor, sensor bank, body, or
environment before receptor encoding.
"""
function rawspec end

"""
    sample!(object, args...)

Sample raw physical observations. Stateful sensors update their response state
in this phase; stateless sources may return an immutable or freshly allocated
sample.
"""
function sample! end

"""
    component_state(object)

Return recordable state keyed by stable component identifiers. The default for
an embodied object with no recordable component state is an empty named tuple.
"""
function component_state end

"""
    readout(policy, reservoir, spikes)

Re-express a reservoir's output as an effector command vector under a readout
policy. The result is passed on to `decode!`. Every scheme is a
memoryless, bias-free re-expression of the reservoir's own output through the
same effector projection: the default returns `effectors(reservoir, spikes)`
unchanged, and graded schemes only substitute a different (still projected)
slice of the reservoir's internal state.
"""
function readout end

"""
    readout_policy(body)

Return the reservoir readout policy carried by an `AbstractBody`.
"""
function readout_policy end

"""
    metrics(object, args...)

Return named diagnostic metrics for a task, rollout, or system.
"""
function metrics end

# Environments may participate in the synchronous runtime without defining an
# objective or diagnostic surface. Specialized environments can extend this
# public generic; rollout code treats the empty named tuple as "no metrics".
metrics(::Environment, window::Integer=1) = NamedTuple()

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

"""
    develop(genotype_or_spec, context, args...)

Develop immutable genotype parameters into a fresh runtime-independent
phenotype blueprint. Dynamic runtime state is constructed afresh and is never
part of the genotype representation.
"""
function develop end

"""Mutate an immutable genotype using an explicit random-number generator."""
function mutate end

"""Recombine structurally compatible immutable genotypes."""
function recombine end
