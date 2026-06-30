# Tasks and their input/output (receptor/effector) mappings

Every task defines a sensorimotor contract: how many **receptors** (R, the reservoir's sensory input) and
**effectors** (E, its motor output) it needs, how the world is encoded into R, and how E is decoded into
action. A node is built to match `(n_receptors, n_effectors)`; the controller itself is task-agnostic.

`tasks()` lists what's registered. Today R/E counts and encodings are **fixed per task** (see
[receptors-effectors.md](receptors-effectors.md) for the plan to make them tunable/evolvable).

## Single-agent tasks

| task | R | sensory encoding | E | motor decode | scoring |
|---|---|---|---|---|---|
| `:wall` | **2** | two ray-cast distance sensors at **±45°** to the nearest wall; `c = 1 − d/d_max`, `d_max = √(2·15²)`, clamped to `(ε,1]` | **2** | left/right wheel speeds = proportion of spikes routed to each effector; heading change `ΔH = (R−L)/2r`; wall hit → random ±45° turn | distance travelled without collisions (CS3 wall-avoidance) |
| `:tracking` | **62** | **two eyes** offset **±30°**, each with **31** Gaussian-tuned sensors over `−60:4:60°`; sensor value `exp(−Δ²/10)` where Δ is the angle to the rotating stimulus | **2** | eye rotation `Δθ = 10·(e₁−e₂)°` per tick | mean alignment of gaze to the stimulus |
| `:pong` | **46** | spatial encoding of ball position + paddle position | **2** | paddle up/down vote | `mean_align` (paddle tracks ball); floor ≈ 0.33 |
| `:pong_hitrate` | 46 | (same as pong) | 2 | (same) | fraction of balls returned (a distinct scoring of the same env) |
| `:cartpole` | **8** | **Spike-FF-2**: the 4 state dims (`x, ẋ, θ, θ̇`) each normalized and split into **2 polarities** (positive/negative channels) → 8 | **2** | force left/right by vote (`e₁` vs `e₂`) | fraction of ticks balanced |
| `:cartpole_hard` | 8 | (same encoding) | 2 | (same) | tighter bounds / weaker actuation |
| `:cartpole_swingup` | 8 | (same encoding; pole starts hanging **down**) | 2 | (same) | mean uprightness `mean((cos θ+1)/2)` |
| `:cartpole_long` | 8 | (same encoding; 2× pole length) | 2 | (same) | fraction balanced |

### How the counts are set and linked
- **Receptors** come from the env's `sense(env)` — its length is `n_receptors(env)`, a fixed constant per
  env type. The encoding is bespoke per task (ray-cast, two-eye Gaussian, spike-FF, …).
- **Effectors** are `n_effectors(env)` (all current tasks use **2**); the env's `step!(env, E)` decodes the
  2-vector into action (differential drive, eye torque, paddle, or cart force).
- The reservoir is constructed with exactly these `(R, E)` dims; spikes → E via the node's output map, then
  the env (or body) turns E into world change.

## Collective tasks (n-agent / dyad)

| task | per-agent R | sensory encoding | per-agent E | motor decode | coupling |
|---|---|---|---|---|---|
| `:torus` | **62** | **bearing-vision over neighbours**: two eyes (±30°) × 31 angles, value `1 − d/d_max` to the nearest neighbour edge in each sensor cone, plus additive `sensory_noise` (default 0.1), clipped ≥0; neighbours beyond `vision_range` are invisible | **2** | **VEN kinematics**: `e₁,e₂` → forward acceleration (speed, capped) + heading-rate change | agents see *each other* on a periodic torus → mutual vision is the only coupling |

- **Dyad** = `simulate(:torus; n_agents=2, …)`; **swarm** = any `n_agents=N`.
- The body here is `VENBody` (vs `PassthroughBody` for single-agent tasks). See [collective.md](collective.md).
- Scoring is via collective metrics (polarization P, milling M, …) rather than a single task score.

## Adding a task

`register_task!(:myname, TaskSpec(:myname, MyEnv; default_ticks=…, default_window=…))`. `MyEnv <: Environment`
must implement `sense(env) -> Vector` (length = its `n_receptors`), `step!(env, E)`, `metrics(env, window)`,
and `n_receptors`/`n_effectors`. It then auto-joins `tasks()`, the demo, and the benchmark grid.
