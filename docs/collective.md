# The collective: n-agent and dyad

A single-agent task is a `Collective` of one. The **same machinery** scales to dyads (`n_agents=2`) and
swarms (`n_agents=N`) — one `step!(collective)` drives all of them. This is the "neurons as nodes within a
collective" idea applied at the agent scale: each agent *is* a reservoir-in-a-body, and the collective is
the population.

```julia
simulate(:torus; node=:falandays_base, n_agents=2)    # dyad
simulate(:torus; node=:falandays_base, n_agents=12)   # swarm
explore(:torus; node=:falandays_base, n_agents=6)     # interactive (needs GLMakie)
```

## The pieces

- **`Collective{Medium}`** — a population of `Agent{Reservoir, Body}`, run by the tick protocol
  `observe → step! → actuate → commit`.
- **`TorusMedium`** — a periodic 2-D world. Knobs: `sensory_noise` (default 0.1, added to each sensor),
  `vision_range` (neighbours beyond it are invisible → coupling drops out as agents disperse), torus size.
- **`VENBody`** — the embodied agent. Vision-in / kinematics-out:
  - **receptors (R = 62):** bearing-vision — two eyes (±30°) × 31 angles; each sensor reports `1 − d/d_max`
    to the nearest neighbour edge in its cone (0 if none in range), plus `sensory_noise`, clipped ≥0.
  - **effectors (E = 2):** VEN kinematics — `(e₁, e₂)` map to forward acceleration (speed, capped at
    `top_speed`) and heading-rate change (capped at `top_heading_rate`).

Contrast: single-agent tasks use `PassthroughBody` (the env already speaks R/E); the swarm uses `VENBody`
(the body manufactures R from the world and turns E into motion).

## Coupling = vision

There is **no explicit interaction term** — agents influence each other *only* by being seen. Agent A's
sensors light up when agent B falls in a sensor cone within `vision_range`; that drives A's reservoir, which
drives A's motion, which changes what B sees. So:

- the **sensor geometry IS the interaction topology** (see [receptors-effectors.md](receptors-effectors.md));
- `vision_range` controls how coupling decays with distance;
- collective order is *emergent*, not imposed.

## Metrics

Collective behaviour is scored by swarm metrics rather than a single task score, recorded per tick and shown
in the swarm view title:

- **Polarization (P)** — alignment of headings (0 = disordered, 1 = all aligned).
- **Milling (M)** — rotational/circling order about the centroid.

(plus per-agent poses, the population raster, and firing rate). The behaviour GIF for `:torus` animates all
agents moving with heading arrows and live P/M.

## Validation

The single-agent-as-`Collective{N=1}` path and the dyad/torus path are both float64 oracle-validated against
the numpy v0.2 `multi_agent_episode` (collective single-agent parity 495, dyad torus parity 1211).

## Status & next

- ✅ n-agent / dyad simulation, swarm metrics, behaviour GIFs.
- ⬜ Deeper collective science (flocking/milling regimes, predator–prey, coupling/criticality sweeps,
  evolving collectives) is the flagged follow-up phase — the abstractions support it; the experiments are
  past v1.
- ⬜ Tunable/evolvable vision geometry (it *is* the coupling) — see
  [receptors-effectors.md](receptors-effectors.md).
