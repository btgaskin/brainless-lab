# Receptors & effectors: configuration and (planned) evolution

The **sensorimotor interface** — how many sensors an agent has, where they point, how the world is encoded
into receptor currents, and how effector outputs become action — is a first-class part of the experiment,
not an implementation detail. This page describes how it works today and the design for making it tunable
and evolvable.

## The seam (recap)

```
percept ──receptors(body,·)──▶ R ──step!(reservoir,R)──▶ spikes ──effectors(reservoir,·)──▶ E ──motor(body,·)──▶ actuation
```

- **R** (length `n_receptors`) and **E** (length `n_effectors`) are the reservoir's I/O vectors.
- The **Body** owns the morphology: `PassthroughBody` relays a task env's R/E unchanged; `VENBody` produces
  bearing-vision R and consumes VEN-kinematics E.
- The **Env** owns the world encoding for single-agent tasks (`sense`/`step!`).

## Current state: fixed per task/body

Today the counts and placements are **hardcoded constants**:

- Each env declares `n_receptors(::Type{Env})` / `n_effectors(::Type{Env})` (e.g. wall 2/2, tracking 62/2,
  pong 46/2, cartpole 8/2). See [tasks.md](tasks.md) for the full table.
- Sensor *placements* are baked into the env: e.g. `TrackingEnv` has `eye_offsets_deg = (30, −30)` and
  `sensor_offsets_deg = −60:4:60`; `VENBody` uses `SENS_ANGLES_DEG` (two eyes × 31 angles = 62).
- All current tasks use **2 effectors** (differential / vote / kinematic pairs).

There is **no way to vary the sensor count or geometry without editing env code** — that's the gap.

## Planned: two angles

Both start from the same refactor: **lift the R/E layout out of hardcoded constants into a spec object**
that defaults to today's values.

```julia
struct SensorSpec
    angles_deg::Vector{Float64}   # one entry per sensor (placement)
    tuning::Float64               # Gaussian width / receptive-field size
    encoding::Symbol              # :raycast | :gaussian_bearing | :spikeff2 | …
    noise::Float64                # additive sensory noise
end
struct EffectorSpec
    n::Int
    decode::Symbol                # :differential | :vote | :ven_kinematics | …
end
```

The env/body would read its `SensorSpec`/`EffectorSpec` instead of constants; `n_receptors` becomes
`length(spec.angles_deg)`.

### Angle A — config-driven layout
Expose the spec through the TOML config so an experimenter sets sensor **count, placement, tuning,
encoding** (and effector count/decode) per task/body without touching code, e.g.:

```toml
[task.sensors]
encoding = "gaussian_bearing"
angles_deg = [-60, -40, -20, 0, 20, 40, 60]   # 7 sensors instead of 62
tuning = 10.0
noise = 0.1
[task.effectors]
n = 2
decode = "differential"
```

`resolve` validates (counts ≥ 1, angles in range) and the node is built to the resulting `(R, E)`.

### Angle B — evolvable morphology (within set ranges)
Make (part of) the spec a **bounded morphology genome** that sep-CMA co-evolves *alongside* the controller —
"evolve where the sensors point, and how many," with researcher-set ranges:

```toml
[task.sensors.evolve]
angle_range_deg = [-90, 90]     # each sensor angle bounded here
n_range = [2, 32]               # sensor count bounded here (variable-length handled via a fixed max + mask)
tuning_range = [4.0, 20.0]
```

Mechanics: a morphology parameter block is appended to the genome; each gene is mapped through its bound
(e.g. `lo + (hi−lo)·sigmoid(g)`); the env builds sensors from the decoded morphology each rollout. Variable
sensor count is handled by evolving a fixed-max layout plus per-sensor enable gates. The controller and the
body then co-adapt — the agent discovers its own sensorimotor arrangement.

## Why this matters for the collective

In the swarm (`:torus`), the *coupling* between agents is entirely through `VENBody` vision — so the sensor
geometry (eye offsets, field of view, vision range) **is** the interaction topology. Making it
tunable/evolvable means you can study how collective behaviour (flocking, milling) depends on, or co-evolves
with, the sensorimotor interface — which is a central question, not a detail.

## Timing & temporal coding

Distinct from *what* the sensors are (above) is *how the reservoir is clocked against the world*.

**Today:** exactly **one reservoir tick per env step**, graded continuous input, and the effector is read
from that **single tick's** spike pattern — so the "rate" is the **spatial** proportion of the N nodes
spiking (a population code), not a temporal accumulation. The reservoir is leaky + recurrent and is *not*
reset between steps, so temporal memory lives in its **state**; only the **readout** is instantaneous. This
is paper-faithful and, at large N, the spatial average is fairly smooth.

**Where it bites:** fast tasks with a sensitive readout — **Pong** above all (fast ball, jittery single-tick
paddle command), and small-N runs.

**Levers (planned, all defaulting to today's behaviour):**

| knob | default | meaning |
|---|---|---|
| `substeps` (K) | 1 | reservoir ticks per env step; accumulate output spikes over K → `E = mean`. Smoothest, but freezes the env during the window. |
| `input_encoding` | `:graded` | `:graded` (current value) vs `:poisson`/`:regular` (spike train at rate ∝ value over the window) |
| `output_window` (W) | 1 | moving-average the effector over the last W env-steps — cheap, doesn't freeze the env, lags by ~W |

For Pong, the env-preserving options (`output_window` or a small `substeps`) are preferable to a large
`substeps` that would freeze the ball. These belong to the same per-task spec as the sensor/effector layout
(Angle A) and would be set from config; defaults reproduce the current paper-faithful 1-tick/step scheme.

## Status

- ✅ Per-task R/E **documented and inspectable** (this page + [tasks.md](tasks.md)).
- ✅ Timing scheme **documented** (1 tick/env-step, graded in, spatial-rate readout).
- ⬜ Spec refactor (Angle A: sensor/effector layout **+ timing knobs**) — not yet built.
- ⬜ Evolvable morphology (Angle B) — not yet built; depends on A.

These are the next build targets for the I/O layer; see [evolution.md](evolution.md) for how the controller
genome is already evolved (the morphology genome would extend it).
