# Receptors & effectors: configuration and (planned) evolution

The **sensorimotor interface** -- how many sensors an agent has, where they point, how the world is encoded
into receptor currents, and how effector outputs become action -- is a first-class part of the experiment,
not an implementation detail. This page describes how it works today and the design for making it tunable
and evolvable.

## The contract (recap)

```
percept --receptors(body,.)--> R --step!(reservoir,R)--> spikes --effectors(reservoir,.)--> E --motor(body,.)--> actuation
```

- **R** (length `n_receptors`) and **E** (length `n_effectors`) are the reservoir's I/O vectors.
- The **Body** owns morphology: `PassthroughBody` relays a task env's R/E unchanged; `VENBody` produces
  bearing-vision R and consumes VEN-kinematics E.
- The **Env** owns the world encoding for single-agent tasks (`sense`/`step!`).
- Effector semantics are task-specific, not globally uniform. See [contracts.md](contracts.md).

## Current state: fixed per task/body

Today the counts and placements are **hardcoded constants**:

| task/body | receptors | effectors | where the count comes from |
|---|---:|---:|---|
| `WallEnv` / `:wall` | 2 | 2 | two ray-cast wall sensors; differential wheel-like env step |
| `TrackingEnv` / `:tracking` | 62 | 2 | two eyes x 31 Gaussian bearing sensors; eye-rotation command |
| `PongEnv` / `:pong`, `:pong_hitrate` | 46 | 2 | `-90:4:90 deg` ball-bearing bins; paddle vote/differential command |
| `CartPoleEnv` and variants | 8 | 2 | 4 state dims x 2 polarities; binary force vote |
| `VENBody` / `:torus` | **64** | **3** | 62 bearing-vision sensors padded to 64 receptor inputs; 3-effector kinematic decode |
| `VENBody` / `:forage` | **128** | **3** | two 64-wide visual banks: conspecific bearing vision plus source bearing vision; same VEN kinematic decode |

Important TORUS detail: `sense_agents` computes **62** bearing-vision sensor values, but `VENBody.receptors`
passes a **64**-channel vector to the reservoir by copying those values into `inputs[3:64]`. The swarm
reservoirs are therefore built as `(n_receptors=64, n_effectors=3)` in the high-level API.

For `:forage`, `VENBody` keeps that first 64-channel conspecific convention intact and appends a second
64-channel source bank with the same bearing geometry. Reservoirs are therefore built as
`(n_receptors=128, n_effectors=3)`. `source_gain` weights the source bank; effector semantics are unchanged.

Sensor *placements* are baked into the env/body: e.g. `TrackingEnv` has `eye_offsets_deg = (30, -30)` and
`sensor_offsets_deg = -60:4:60`; `VENBody` uses `SENS_ANGLES_DEG` (two eyes x 31 angles = 62 before
padding).

There is **no way to vary the sensor count or geometry without editing env/body code** -- that is the gap.

## Planned: two angles

Both start from the same refactor: **lift the R/E layout out of hardcoded constants into a spec object**
that defaults to today's values.

```julia
struct SensorSpec
    angles_deg::Vector{Float64}   # one entry per sensor (placement)
    tuning::Float64               # Gaussian width / receptive-field size
    encoding::Symbol              # :raycast | :gaussian_bearing | :spikeff2 | ...
    noise::Float64                # additive sensory noise
end

struct EffectorSpec
    n::Int
    decode::Symbol                # :differential | :vote | :ven_kinematics | ...
end
```

The env/body would read its `SensorSpec`/`EffectorSpec` instead of constants; `n_receptors` becomes the
decoded input width after any task/body padding.

### Angle A -- config-driven layout

Expose the spec through the TOML config so an experimenter sets sensor **count, placement, tuning,
encoding** (and effector count/decode) per task/body without touching code, e.g.:

```toml
[task.sensors]
encoding = "gaussian_bearing"
angles_deg = [-60, -40, -20, 0, 20, 40, 60]   # 7 sensors instead of the default layout
tuning = 10.0
noise = 0.1

[task.effectors]
n = 2
decode = "differential"
```

`resolve` would validate counts, angles, and decode compatibility, then build the node to the resulting
`(R, E)`.

### Angle B -- evolvable morphology (within set ranges)

Make part of the spec a **bounded morphology genome** that sep-CMA co-evolves *alongside* the controller:
"evolve where the sensors point, and how many," with researcher-set ranges:

```toml
[task.sensors.evolve]
angle_range_deg = [-90, 90]     # each sensor angle bounded here
n_range = [2, 32]               # variable length via fixed max + mask
tuning_range = [4.0, 20.0]
```

Mechanics: a morphology parameter block is appended to the genome; each gene is mapped through its bound
(for example `lo + (hi - lo) * sigmoid(g)`); the env builds sensors from the decoded morphology each
rollout. Variable sensor count is handled by evolving a fixed-max layout plus per-sensor enable gates. The
controller and the body then co-adapt -- the agent discovers its own sensorimotor arrangement.

## Why this matters for the collective

In the swarm (`:torus`), the default coupling between agents is through `VENBody` vision -- so the sensor
geometry (eye offsets, field of view, vision range) **is** the interaction topology. Making it
tunable/evolvable means you can study how collective behaviour (flocking, milling) depends on, or co-evolves
with, the sensorimotor interface.

## Timing & temporal coding

Distinct from *what* the sensors are is *how the reservoir is clocked against the world*.

**Today for the Falandays path:** exactly **one reservoir tick per env step**, graded continuous input, and
the effector is read from that **single tick's** spike pattern. The "rate" is the **spatial** proportion of
the N nodes spiking (a population code), not a temporal accumulation. The reservoir is leaky + recurrent and
is not reset between steps, so temporal memory lives in its **state**; only the **readout** is instantaneous.
This is the stable baseline clocking for `:falandays_base`.

**Where it bites:** fast tasks with a sensitive readout -- **Pong** above all (fast ball, jittery single-tick
paddle command), and small-N runs.

**Levers (planned, all defaulting to today's behaviour):**

| knob | default | meaning |
|---|---:|---|
| `substeps` (K) | 1 | reservoir ticks per env step; accumulate output spikes over K -> `E = mean`. Smoothest, but freezes the env during the window. |
| `input_encoding` | `:graded` | `:graded` (current value) vs `:poisson`/`:regular` (spike train at rate proportional to value over the window) |
| `output_window` (W) | 1 | moving-average the effector over the last W env-steps -- cheap, does not freeze the env, lags by about W |

For Pong, the env-preserving options (`output_window` or a small `substeps`) are preferable to a large
`substeps` that would freeze the ball. These belong to the same per-task spec as the sensor/effector layout
(Angle A) and would be set from config; defaults reproduce the current 1-tick/step Falandays baseline.

**Built so far (CTRNN only):** the compartmental nodes already implement integration sub-stepping --
`CompartmentalReservoir(...; substeps=k)`, **default 5** (`dt_sub = dt/5 = 0.2`), with the afferent held
across sub-steps and the env-step output being the per-node spike *rate* over the sub-steps; `substeps=1`
reproduces the oracle single-step. See [nodes.md](nodes.md). This is the CTRNN's internal-integration
version of the knob; the **readout-side** `output_window`/`input_encoding` for the Falandays nodes are still
unbuilt.

## Status

- Done: per-task/body R/E documented and inspectable (this page + [tasks.md](tasks.md)).
- Done: timing scheme documented (1 tick/env-step for Falandays baseline; CTRNN internal substeps).
- Planned: spec refactor (Angle A: sensor/effector layout + timing knobs).
- Planned: evolvable morphology (Angle B); depends on Angle A.

These are next build targets for the I/O layer; see [evolution.md](evolution.md) for how the controller
genome is already evolved (the morphology genome would extend it).
