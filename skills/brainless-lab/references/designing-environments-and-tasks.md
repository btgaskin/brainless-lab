# Designing Environments and Tasks

## The sensorimotor contract is the design object

Everything in BrainlessLab flows through one loop, run once per tick per agent inside
`step!(ensemble)` (`src/world/Ensemble.jl`):

```julia
percept = observe(env, bodies)[i]        # world → percept
R = receptors(body, percept)             # percept → R  (sensory input vector)
s = step!(reservoir, R)                  # R → spikes   (the task-agnostic node)
E = effectors(reservoir, s)              # spikes → E   (motor output vector)
cmd = decode_effectors(body, E)          # E → command
actuate!(env, bodies, Es)                # command → world
```

`R` and `E` are the two vectors that pin the whole stack together: `R` has length
`n_receptors`, `E` has length `n_effectors`. **Designing a task is designing this contract** —
what the world exposes as `R`, how the reservoir's output `E` becomes an action, and how the
result is scored — *not* wiring up a new reservoir. The reservoir stays task-agnostic: it is
built `(n_nodes, n_receptors, n_effectors)` to *match* the task/body and knows nothing else
about the world. See `designing-nodes.md` for the other side of this seam.

## The Body seam: who owns the encoding

The `Body` is the adapter between world and reservoir (`src/world/Body.jl`,
`Morphology.jl`). Two exist, and the choice is a design decision:

- **`PassthroughBody`** relays a single-agent task env's `R`/`E` unchanged. The `TaskWorld`
  itself owns the encoding: `sense(env)` *is* the percept (already reservoir-shaped) and
  `step!(env, E)` consumes the raw effector vector. `receptors`/`decode_effectors` are
  identity. Reach for this when your env speaks the reservoir's `(R, E)` directly.
- **`VENBody`** is the embodied swarm agent: it *manufactures* `R` from bearing-vision and
  reads `E` as movement kinematics (`integrate_motion!` turns `e3` into forward accel,
  `e2 - e1` into heading accel, capped/damped by `VENParams`). Here the body owns the
  encoding, and the env (`TorusEnvironment`/`ForageEnvironment`) only supplies raw sensor
  cones and commits motion.

When you design a task you choose (or define) the body and thereby fix the `R`/`E` widths.
`n_receptors(morphology)` / `n_effectors(morphology)` are the single source of truth the
node constructor reads. A `VENMorphology` returns 64 (or 128 with `source_bank`) receptors
and 3 (or 4 with `signalling`) effectors — the counts are derived from the morphology, not
hardcoded at the call site. Docs: https://brainless-lab.pages.dev/receptors-effectors/.

## Effector semantics are deliberately non-uniform

There is no universal meaning for "channel 1." Each task/body decodes `E` differently:

| task / body | E | decode |
|---|---:|---|
| `:wall` (Passthrough) | 2 | differential wheel speeds: speed $(e_L+e_R)/2$, turn $e_R-e_L$ |
| `:tracking` | 2 | eye-rotation $10(e_1-e_2)°$ |
| `:pong` | 2 | paddle vote $100(e_1-e_2)$ |
| `:cartpole` | 2 | binary force: $e_1 \ge e_2 \Rightarrow$ push left |
| `:torus` / `VENBody` | 3 | VEN kinematics; 64 receptors in |
| `:forage` / `VENBody` | 3 (or 4) | same kinematics; 128 receptors (conspecific + source banks) |

This non-uniformity is *why raw scores are not comparable across tasks* — the effector
vector is a different physical quantity in each. Do not try to unify it; unify at the
**score** instead (below). See https://brainless-lab.pages.dev/contracts/.

## Adding a single-agent task

A single-agent task is a `TaskSpec` (`src/tasks/Tasks.jl`) wrapping a `TaskWorld`. Implement
the world contract (see `examples/templates/new_project/my_task.jl` for a copy-and-edit
scaffold):

```julia
n_receptors(::Type{MyEnv}) = 2      # and the instance methods; source of R width
n_effectors(::Type{MyEnv}) = 2      # E width; the reservoir is built to match
default_ticks(::Type{MyEnv}) = 300
default_window(::Type{MyEnv}) = 100
sense(env::MyEnv)                   # → the receptor vector R (this is your encoding)
step!(env::MyEnv, effectors)        # advance one tick; bound E with clamp to [0,1]
reset!(env::MyEnv)
metrics(env::MyEnv, window)         # NamedTuple incl. the raw score under score_key
```

Then declare the spec and register it (import, don't `using` — same idiom as nodes):

```julia
import BrainlessLab: TaskSpec, TaskWorld, sense, step!, reset!, metrics,
    n_receptors, n_effectors, default_ticks, default_window, register_task!

const MY_TASK = TaskSpec(:my_task, MyEnv;
    score_key=:score,                       # which metric is the raw score
    floor=analytic(0.0; note="chance"),     # or null_anchor(v, provenance)
    ceiling=analytic(1.0; note="optimal"))
register_task!(:my_task, MY_TASK)
```

Three things to get right: the **receptor encoding** in `sense` (what the world looks like
to the reservoir), the **effector decode** in `step!` (how `E` moves the world — always
`clamp` it, the reservoir emits arbitrary reals), and the **scoring**.

## Scoring: floor, ceiling, and normalized_score

Raw scores live in `metrics(env, window)` under `score_key`. `normalized_score(task, raw)`
(`src/tasks/Scoring.jl`) maps them onto `[0,1]`:

```julia
clamp((raw - floor) / (ceiling - floor), 0.0, 1.0)
```

This is the *only* cross-task-comparable number, and only well enough for optimizer
bookkeeping — it is **not a physical unit**. Design the anchors with intent:

- **floor** = chance / null behaviour. Prefer a measured `null_anchor(v, provenance)` (e.g.
  a random agent's score) over a guessed `analytic(0.0)` — `:wall`'s floor is `0.763`, not
  zero, because random navigation already scores high. Record seeds/git in the provenance
  string.
- **ceiling** = near-optimal. `analytic(1.0)` when there is a true optimum (collision-free
  navigation, perfect alignment); a `reference_anchor` when you have a trained agent.

A raw score pinned at 0 or 1 means it fell outside the anchors — the value is saturated, not
meaningfully equal to another task's. Calibrate floors/ceilings with the calibration tool
(see `cli-tools.md`) rather than hand-tuning. Cross-ref https://brainless-lab.pages.dev/contracts/.

## Single-agent and swarm are one abstraction

There is no separate "swarm code path." An `Ensemble` (`src/world/Ensemble.jl`) is a
population of `Agent`s; a single-agent task is an Ensemble of **one**, a dyad is
`n_agents=2`, a swarm is `n_agents=N`, and the *identical* `step!(ensemble)` drives all of
them. `observe` computes every agent's percept from the current world *before* anyone moves;
`actuate!` commits all motions after — a synchronous update with no within-tick order
dependence and no branch on the count. Assuming swarm is a different path than single-agent
is the most common wrong mental model; going from dyad to swarm is one integer.

Coupling in swarm tasks is therefore **not an explicit force** — it is vision. In
`TorusEnvironment`/`ForageEnvironment`, agent A's bearing sensors light up when agent B
falls in a sensor cone within `vision_range`; the sensor geometry *is* the interaction
topology, and `vision_range` sets how coupling decays with distance. `physical_coupling` is
an opt-in collision-resolution flag on top. Design coupling by shaping sensor geometry,
`vision_range`, `sensory_noise`, and (in forage) `conspecific_vision` on/off — that is the
"social vs blind" manipulation. See https://brainless-lab.pages.dev/collective/.

Collective order is read through metrics, not a scalar score: `polarization` (heading
alignment), `milling` (rotational order about the centroid), and pairwise/nearest-neighbour
distances (`src/world/Metrics.jl`). `:torus` is a registered swarm symbol, *not* a
`TaskSpec` with floor/ceiling — read torus/forage runs through these metrics. For measuring
critical/collective dynamics, see `designing-analyses.md`.

## The environment contract

`WallBox`/`CartPole`/`Torus` show the env shape: hold mutable state, expose an observation
(`sense` or `observe`), advance and record on `actuate!`/`step!`, and support `reset!`.
Single-agent envs are `TaskWorld`s wrapped by `TaskEnvironment`; swarm envs are
`AbstractTorusEnvironment`s whose `observe` builds one percept per body (conspecific bank,
plus a source bank for forage) and whose `actuate!` integrates motion, resolves collisions,
and appends history. `Torus` (`src/world/Torus.jl`) is the periodic substrate — every
distance, bearing, and centroid is wrap-aware. https://brainless-lab.pages.dev/environments-tasks/.

## Registration: the register_*! family

Everything is discovered by symbol through the registry (`src/core/Registry.jl`), same
import-not-`using` idiom as nodes: `register_task!(:sym, spec)`, `register_body!`,
`register_metric!(:sym, f)` (resolved by symbol in `rollout!`'s `metrics=` selection),
`register_ablation!`. Register at include time so `simulate`/`bench` can resolve your symbol
without a framework fork.

## Pitfalls

- **Mismatched R/E widths.** `n_receptors`/`n_effectors` on the env/morphology, the vector
  `sense` returns, and the node constructor must all agree — a mismatch throws
  `DimensionMismatch` at the first tick, not at construction. The morphology is the source
  of truth; make `sense` and the decode conform to it.
- **Unbounded or incomparable scoring.** A score with no meaningful floor/ceiling can't be
  normalized; `normalized_score` throws if `ceiling <= floor`. Anchor to *this task's* own
  chance and optimum, and never read a raw score as cross-task.
- **Forgetting to clamp E.** The reservoir emits arbitrary reals; every decode must clamp to
  `[0,1]` (see `_bounded_effectors`, `_ven_output_acts`) or the world integrates garbage.
- **Assuming swarm ≠ single-agent.** It is one `step!`; if you find yourself special-casing
  `n_agents==1`, you are fighting the abstraction.

See also: `designing-nodes.md`, `designing-analyses.md`, `usage-and-workflows.md`,
`cli-tools.md`.
