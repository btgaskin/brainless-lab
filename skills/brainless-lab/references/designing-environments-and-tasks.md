# Designing Environments, Embodiments, and Tasks

## Design the closed-loop contract

`step!(ensemble)` runs one synchronous lifecycle for one agent or a mixed population:

```julia
prepare_step!(environment, bodies)
percepts = sample!(environment, bodies)          # same pre-action world

R = sense!(body, percept)                        # sensors/encoders + physiology
spikes = step!(reservoir, R)
E = readout(readout_policy(body), reservoir, spikes)
command = decode!(body, E)                       # reusable typed command

effects = apply_commands!(environment, bodies, commands)
update!(body, effects_for_body)                  # physiology / viability
```

The reservoir remains task-agnostic. It is constructed from `portspec(body)`, which fixes
the receptor vector `R` and effector vector `E`. Design the body/world relation before
changing the reservoir.

`Embodiment.sense!` returns a borrowed body-owned receptor buffer reused on the next call.
Consume it immediately in the reservoir step or copy it when retaining it outside the
lifecycle. The mutation suffix does not, by itself, promise zero allocation for every
custom body.

## Ownership table

| concern | owner |
|---|---|
| external geometry, objects, fields, contact, effects | environment |
| physical footprint | geometry component |
| raw physical samples | sensor component + environment sampling method |
| raw samples → receptor channels | encoder component |
| effectors → bounded typed command | actuator component |
| command → motion | dynamics component |
| internal variables, feedback, effect interpretation, viability | physiology component |
| rollout defaults and score anchors | `TaskSpec` |
| neural dynamics | reservoir |

The environment says “entity 41 contacted food 7 and received `Exposure(:energy, 0.2)`.”
The physiology says what `:energy` means. Do not put need equations in the world or object
search logic in the body.

## Body composition

`AbstractBody` is the dispatch boundary. Prefer the standard `Embodiment` over a new body
subtype. It holds geometry, sensor, encoder, actuator, dynamics, physiology, traits, and
runtime state components. Give every component a stable globally unique ID.
`traits` are optional metadata for direct Julia composition. Embodiment TOML does not
currently represent them, and preset materialization or physics must not depend on them.

`portspec(body)` derives namespaced receptor/effector ports from those IDs. Encoders can
bind inputs by stable sensor ID with `encoder_sources`; this is required for cross-sensor
encoders such as bilateral contrast. Actuators own reusable command buffers and mutate them
in `decode!`; dynamics integrate only compatible command types.

Strict TOML is the reusable composition surface:

```julia
config = read_embodiment_config("examples/embodiments/bilateral_insect.toml")
blueprint = materialize_blueprint(config)
body = materialize_embodiment(config)
```

Each `[[components]]` entry has `id`, generic `family`, registered `kind`, and validated
parameters. Query `component_info(family, kind).parameters` rather than guessing keys. This
reports required/optional names only, not types, defaults, or constraints.

## Choose the world path

There are three legitimate paths, serving different experiments.

### 1. Vector-valued `TaskWorld`

Use this when the environment already emits the exact receptor vector and consumes the
task-specific effector vector. The setup uses a direct `Embodiment`; its sensor/encoder and
actuator relay the vectors.

Implement:

```julia
n_receptors(::Type{MyEnv})
n_effectors(::Type{MyEnv})
default_ticks(::Type{MyEnv})
default_window(::Type{MyEnv})
sense(env::MyEnv)
step!(env::MyEnv, effectors)
reset!(env::MyEnv)
metrics(env::MyEnv, window)
```

The copy-ready scaffold is `examples/templates/new_project/my_task.jl`.

### 2. Generic `ObjectWorld`

Use this when the experiment needs independently composed physical components.
`ObjectWorld` currently supports torus/walled 2-D arenas, fixed agent motion states, static
circular objects, named analytic fields, spectral appearance/illumination, object capacity
and respawn, typed effects, and one actuator/dynamics command per body.

Objects have stable `ObjectID`s; agents have stable `EntityID`s. Bind/query through public
methods (`bind_entity_ids!`, `interaction_events`, `object_snapshot`) rather than storage.

Built-in sampling supports `SpectralCamera`, `MountedFieldProbe`, and blind
`DirectRelaySensor`. Extend another sensor with:

```julia
import BrainlessLab: rawspec, sample_world_sensor!

rawspec(sensor::MySensor) = (kind=:my_sensor, width=3)
sample_world_sensor!(sensor::MySensor,
                     world::ObjectWorld,
                     state::MotionState2D) = # raw vector of length 3
```

The `!` permits mutation of sensor or RNG state. The method returns the raw vector directly;
it does not receive a caller-owned destination or promise zero allocation.

The encoder still owns the raw-to-receptor map. Do not make `ObjectWorld` aware of a
reservoir or encoder.

Current limits are part of the contract: no births/replacement/lineage scheduler, moving
non-agent objects, arbitrary meshes, structural development, or multiple physical command
pairs per body.

### 3. Established `SituatedEnvironment` adapter

Use this when preserving the semantics and outputs of `:torus`, `:forage`, or signalling.
It constructs ordinary `Embodiment`s with
`SituatedSensorLayout`, `SituatedEncoder`, `SituatedActuator`, and `KinematicMotor`, but the
adapter retains its bearing-bank assembly, collisions, signalling, and history channels.

Do not generalize new physical component behavior into this adapter by default. Start with
`ObjectWorld`; change the situated path only when an established experiment requires it.

## Multiple needs and effects

`RegulatedPhysiology` contains any number of `RegulatedVariable`s. Each variable defines
bounds, initial value, setpoint/deficit rule, drift, response curve, feedback mode, gain,
emission probability, optional receptor link probability, and failure. `OffFeedback` is the
default control; tonic, Bernoulli, and replay modes are explicit.

World relations return `Exposure(name, delta)` values. Unknown effects are rejected by
default. Effects for one tick are accumulated before clamping/failure, so contact can rescue
an agent on a threshold tick. Death keeps stable identity but disables neural stepping,
sensing, motion, and interactions in the fixed population. Metrics must distinguish the
current active population from the original cohort: active-only motion summaries exclude
dead bodies, while survival or regulation objectives keep the original denominator so
death cannot improve the score.

## Task composition and scoring

A task setup callable returns `TaskSetup(environment, bodies)`. Declare it in a `TaskSpec`:

```julia
const MY_TASK = TaskSpec(
    :my_task,
    my_setup;
    score_key=:score,
    floor=analytic(0.0; note="chance"),
    ceiling=analytic(1.0; note="optimal"),
)

register_task!(:my_task, MY_TASK)
```

For a generic setup callable, accept `seed`, `rng`, `body`, `n_nodes`, and `kwargs...` so
the high-level runner can supply deterministic construction context without task-specific
coupling. `examples/embodiments/object_world_task.jl` is the copy-ready physical example.
Direct `ObjectWorld` construction exposes `Ensemble` + `Recorder`; `TaskSpec` adds
standardized `SimResult`, rollout defaults, and optional scoring.

`TaskSpec.n_receptors`/`n_effectors` are optional default metadata. The setup's body ports
are runtime truth. Use `score_key=nothing` when the task is characterized by multiple
collective/ecological measures rather than one objective.

`normalized_score` maps the task's raw score between its own floor and ceiling, clamped to
`[0,1]`. Prefer measured null anchors with provenance over guessed zero floors. A saturated
value is outside the anchors, not physically equal to another task's result.

## One to many, including mixed agents

An `Ensemble` of one and an ensemble of many use the same loop. Homogeneous agents keep a
concrete fast path. Mixed agent/body types are grouped by concrete agent type and port
signature; stable IDs preserve world identity at the gather/scatter boundary.

Use `agent_at_slot`, `body_at_slot`, `entity_ids`, and `foreach_group` rather than relying
on store fields. The current runtime has fixed membership: heterogeneity does not yet imply
birth, replacement, or lineage dynamics.

## Coupling and analyses

There is no implicit social force. Coupling is whatever agents can sense and affect in the
world. In the established swarm tasks, bearing vision is the interaction topology; in a
generic world, spectral rays, mounted probes, fields, contact, and effects can play that
role. Always identify the actual coupling seam before interpreting collective order.

Collective measures need nulls. Shared environmental input can mimic interaction; use
`crossshift_null` before interpreting a cross-agent statistic.

Lifecycle state crosses the generic public `sync_activity!(environment, bodies)` hook
before observation and again after physiology updates. Specialize that hook instead of
probing a private environment method with `applicable`; it keeps sensing, metrics,
recording, and rendering on the same definition of activity.

## Component registration

Register configured components with a `ComponentDescriptor` carrying:

- family and kind;
- strict config resolver;
- required/optional parameter names;
- capabilities;
- one focused conformance name and existing path;
- documentation and executable-example paths;
- readiness (`:available` = discoverable/materializable; `:integrated` adds standard
  runtime, exact serialization, docs, and executable example; `:core` is stable/default
  with named core-test coverage).

Registration validates evidence and refuses duplicate keys without `replace=true`.
Readiness is scoped evidence, while status remains experimental. The built-in physical
catalog currently claims `:integrated` through the tested `ObjectWorld` quickstart.

## Pitfalls

- **Hardcoded widths.** Derive node dimensions from `portspec(body)`.
- **Positional identity.** Target component/agent/object IDs, not tuple or vector positions.
- **Allocating command decode.** Reuse `command_buffer` and mutate it in `decode!`.
- **World-aware encoders.** Sensors sample worlds; encoders transform samples.
- **Body-aware ecology.** Worlds emit typed effects; physiology interprets them.
- **Overclaiming `ObjectWorld`.** It is currently fixed-population, circular-object, 2-D,
  one-command infrastructure. Analytic fields are explicit and independent of object banks,
  and other agents are not yet spectral/object interaction targets.
- **Treating the situated adapter as the generic API.** It preserves established tasks;
  new physical composition belongs in `ObjectWorld`.
- **Unbounded effectors or meaningless anchors.** Validate physical commands and scoring.
- **Mixing genotype and state.** `DevelopmentSpec` targets bounded configuration scalars;
  transient component state is never a gene.

See also `designing-nodes.md`, `designing-analyses.md`, `usage-and-workflows.md`, and
`cli-tools.md`.
