# Embodiment presets

These strict TOML files exercise the public component graph. They are reusable
configurations and conformance examples, not claims that the simplified dynamics reproduce
a particular animal or vehicle.

| preset | sensors and encoding | actuation and dynamics | physiology |
|---|---|---|---|
| `bilateral_insect.toml` | two mounted odor probes → unit contrast | forward/turn → unicycle | energy and temperature variables |
| `differential_robot.toml` | three-channel spectral camera | wheel speeds → differential drive | none |
| `planar_uav.toml` | spectral camera plus two radio probes → contrast | planar force/yaw → rigid body | none |

## Load and inspect

```julia
using BrainlessLab

config = read_embodiment_config(
    "examples/embodiments/bilateral_insect.toml",
)

blueprint = materialize_blueprint(config)
body = materialize_embodiment(config)

component_slots(body)
portspec(body)
component_state(body)
```

Every call to `materialize_embodiment` creates fresh runtime state. The TOML component IDs
are retained in the body; receptor and effector port IDs are namespaced by them.
Optional `traits` are direct-Julia composition metadata: TOML does not currently represent
them, and these presets or their physics do not depend on them.

Encoder completion is deliberate. A TOML with no encoder components receives one stable
`:identity_encoder` over all sensors. When every declared encoder names its sensor sources,
any unclaimed sensor receives an identity encoder named `<sensor>__identity_encoder`. This is
why `differential_robot.toml` needs no explicit camera encoder, and why the UAV camera remains
available alongside its explicit bilateral radio encoder. Inspect `component_slots(body)` to
see the completed runtime graph.

## Use in a world

The generic physical path is `ObjectWorld`. It samples each sensor component at the body's
`MotionState2D`, lets the body encode the raw samples, applies the reservoir's decoded typed
command through the body's dynamics, and returns typed effects for physiology.

The tested executable example is:

```julia
include("examples/embodiments/object_world_quickstart.jl")
result = run_object_world_quickstart(ticks=25, seed=7)

result.ensemble
result.recorder
result.objects
```

It loads `differential_robot.toml`, creates an RGB beacon, sizes a Falandays reservoir from
the body's ports, runs an `EntityID`-aware ensemble, and returns the final object snapshot.

The copy-ready high-level physical task is:

```julia
include("examples/embodiments/object_world_task.jl")
sim = run_object_world_task(ticks=25, seed=7)

sim isa SimResult
sim.metrics
getchannel(sim.recorder, :objects)
```

It wraps the differential robot and beacon world in a concrete setup callable and `TaskSpec`,
then runs the ordinary `simulate` path. This produces a `SimResult` with standardized metrics,
configuration, replay, and visualization support. The setup accepts the `seed`, `body`, and
`n_nodes` keywords supplied by the high-level runner, plus an optional `rng`.

`object_world_quickstart.jl` deliberately shows the lower-level alternative: direct
`ObjectWorld` composition exposes `Ensemble` + `Recorder`. Add a `TaskSpec` when an experiment
needs the standard `SimResult`, scoring, or rendering APIs.

The current world supports toroidal or walled 2-D arenas, fixed agent populations, static
circular objects, named analytic fields, spectral appearance/illumination, and one
actuator/dynamics command pair per body. A `DirectRelaySensor` is deliberately blind in this
world; add another physical sensor by extending `sample_world_sensor!`.

Objects and analytic fields are separate. An object's `bank` labels the object and its render
channel, but does not emit a field. `MountedFieldProbe(channel=:odor, ...)` reads the explicitly
supplied `world.fields.odor`; position that field deliberately, or add a new field type when an
experiment needs an object-centred gradient.

## Modify safely

Copy a preset and edit component parameters, or use one-level `extends` plus `[overrides]`
targeted at stable component IDs. The parser rejects unknown keys, unknown parameters,
duplicate IDs, missing bilateral references, and incompatible physical commands.

To see the accepted parameter names for a configured kind:

```julia
component_info(:sensor, :spectral_camera).parameters
component_info(:physiology, :regulated).parameters
```

These are required/optional names only; the catalog does not yet expose types, defaults, or
constraints.

Use `canonical_embodiment_toml(config)` to inspect the fully resolved form and
`write_embodiment_config(path, config)` to persist it deterministically.

## Evolve bounded parameters

`DevelopmentSpec` targets existing real scalar parameter paths on stable component IDs.
Development preserves the graph: it does not add components, vary topology, or carry
runtime state between phenotypes. See the site [Evolution](../../site/src/content/docs/evolution.mdx)
page for a complete example.
