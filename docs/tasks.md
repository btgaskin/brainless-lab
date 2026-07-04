# Tasks and their input/output (receptor/effector) mappings

Every task defines a sensorimotor contract: how many **receptors** (R, the reservoir's sensory input) and
**effectors** (E, its motor output) it needs, how the world is encoded into R, and how E is decoded into
action. A node is built to match `(n_receptors, n_effectors)`; the controller itself is task-agnostic.

`tasks()` lists what is registered: `:wall`, `:tracking`, `:pong`, `:pong_hitrate`, `:cartpole`,
`:cartpole_hard`, `:cartpole_swingup`, `:cartpole_long`, `:torus`, and `:forage`. Today R/E counts and encodings are
**fixed per task/body** (see [receptors-effectors.md](receptors-effectors.md) for the plan to make them
tunable/evolvable).

## Single-agent tasks

Single-agent tasks use `PassthroughBody`: the env's `sense(env)` vector is passed straight to the reservoir,
and the reservoir's effector vector is passed straight to `step!(env, E)`.

| task | R | sensory encoding | E | effector decode | scoring |
|---|---:|---|---:|---|---|
| `:wall` | **2** | two ray-cast distance sensors at **+/-45 deg** to the nearest wall; `c = 1 - d/d_max`, `d_max = sqrt(2 * 15^2)`, clamped to `(eps, 1]` | **2** | differential wheel-like speeds: `v = (eL + eR)/2`, heading change `dtheta = eR - eL`; wall hit -> random +/-45 deg turn | `nav_score = collision_free_rate * movement_gate` over the scoring window, bounded `[0, 1]` (rewards collision-free navigation while actually moving) |
| `:tracking` | **62** | **two eyes** offset **+/-30 deg**, each with **31** Gaussian-tuned sensors over `-60:4:60 deg`; sensor value `exp(-(delta^2)/10)` where `delta` is the angle to the rotating stimulus | **2** | eye-rotation command `dtheta = 10 * (e1 - e2) deg` per tick | mean `cos` alignment of gaze to the stimulus |
| `:pong` | **46** | bearing from paddle to ball over `-90:4:90 deg`; the matching angular bin is active when the ball is in front of the paddle | **2** | paddle vote/differential command: `paddle_y += 100 * (e1 - e2)`, clamped to the paddle range | `hit_rate` (fraction of return opportunities hit); floor ~= 0.356, ceiling ~= 0.701 |
| `:pong_hitrate` | **46** | same env and sensors as `:pong` | **2** | same paddle command as `:pong` | identical TaskSpec to `:pong` (same `hit_rate` key, floor, and ceiling) |
| `:cartpole` | **8** | **Spike-FF-2**: the 4 state dims (`x`, `xdot`, `theta`, `thetadot`) each normalized and split into **2 polarities** (negative/positive channels) -> 8 | **2** | binary force vote: `e1 >= e2` applies negative force, otherwise positive force | fraction of ticks balanced |
| `:cartpole_hard` | **8** | same encoding as `:cartpole` | **2** | same binary force vote, with tighter bounds / weaker actuation | fraction balanced |
| `:cartpole_swingup` | **8** | same encoding; pole starts hanging **down** | **2** | same binary force vote; termination on angle disabled | mean uprightness `mean((cos(theta)+1)/2)` |
| `:cartpole_long` | **8** | same encoding; 2x pole length | **2** | same binary force vote | fraction balanced |

### How the counts are set and linked

- **Receptors** come from the env's `sense(env)` -- its length is `n_receptors(env)`, a fixed constant per
  env type. The encoding is bespoke per task (ray-cast, two-eye Gaussian, angular pong bin, spike-FF, ...).
- **Effectors** are `n_effectors(env)` for the env task. All current single-agent env tasks use **2**
  effectors, but they decode them differently.
- The reservoir is constructed with exactly these `(R, E)` dims; spikes -> E via the node's output map, then
  the env turns E into world change.

## Ensemble tasks (n-agent / dyad)

| task | per-agent R | sensory encoding | per-agent E | effector decode | coupling |
|---|---:|---|---:|---|---|
| `:torus` | **64** | `VENBody` bearing vision over neighbours: two eyes (+/-30 deg) x 31 angles = **62 bearing sensors**, then padded into a **64-channel receptor vector** (`inputs[3:64]`); values are binary by default (`sens_agent_dist=0`) or `1 - d/d_max` when distance coding is enabled, plus additive `sensory_noise` (default 0.1), clipped >= 0 and optionally sum-normalized | **3** | **VEN kinematics**: `e1`/`e2` set heading acceleration by their difference, `e3` sets forward acceleration; speed and heading rate are capped by `VENParams` | agents see each other on a periodic torus; mutual vision is the default coupling |
| `:forage` | **128** | same 64-channel conspecific bank as `:torus`, plus a second 64-channel source-vision bank; `conspecific_vision=false` zeros only the conspecific bank | **3** | same VEN kinematics as `:torus` | periodic torus with a source target; metrics include `mean_distance_to_source`, `frac_within_capture`, `time_to_first_arrival`, and bounded `forage_score` |

- **Dyad** = `simulate(:torus; n_agents=2, ...)`; **swarm** = any `n_agents=N`.
- The body here is `VENBody` (vs `PassthroughBody` for single-agent tasks). See [collective.md](collective.md).
- `:torus` and `:forage` are registered swarm task symbols, not `TaskSpec`s with `normalized_score`; read
  them via ensemble metrics such as polarization, milling, pairwise distance, input stability, liveness, and
  the forage-specific source metrics.

## Adding a task

`register_task!(:myname, TaskSpec(:myname, MyEnv; default_ticks=..., default_window=...))`. `MyEnv <:
TaskWorld` must implement `sense(env) -> Vector` (length = its `n_receptors`), `step!(env, E)`,
`metrics(env, window)`, and `n_receptors`/`n_effectors`. It then auto-joins `tasks()` and is available to
the profile, benchmark, sweep, and ablation tooling where the task contract fits.
