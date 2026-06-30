# BrainlessLab documentation

An extensible Julia lab for **"brainless" cognition** — behaviour emerging from collectives of simple
neuron-like nodes, with no homunculus and no hand-wired control. This `docs/` set explains the parts and
how they connect.

## Contents

- **[nodes.md](nodes.md)** — node types and variants (the neuron models you can drop in).
- **[tasks.md](tasks.md)** — the tasks and their **input/output (receptor/effector) mappings** — what each
  task senses, what it acts with, how the counts are set and linked.
- **[receptors-effectors.md](receptors-effectors.md)** — how the sensorimotor interface works today (fixed
  per task/body) and the **planned tunable + evolvable** design.
- **[collective.md](collective.md)** — the n-agent / dyad (swarm) setup: bodies, the torus medium, coupling.
- **[evolution.md](evolution.md)** — evolved versions: training, the genotype store + provenance, fitness,
  and a worked 20-generation readiness run.

## The core abstraction

Everything is *neurons as nodes within a collective* — the same node contract at every scale:

```
NodeModel → Reservoir → Body → Agent → Collective{Medium} → Task → Driver(evolve|fixed) → Run
                                                       ↘ Recorder ↗  (viz reads this, off the hot path)
```

A single-agent task is a `Collective` of **one** agent; a dyad is `n_agents=2`; a swarm is `n_agents=N`.
The same `step!(collective)` runs both.

## The sensorimotor seam (read this first)

Each tick, for every agent:

```
percept ──receptors(body,·)──▶ R ──step!(reservoir,R)──▶ spikes ──effectors(reservoir,·)──▶ E ──motor(body,·)──▶ actuation
```

- **Receptors (R)** = the reservoir's sensory input vector; **Effectors (E)** = its motor output vector.
- The **Body** mediates: `PassthroughBody` relays a task env's R/E directly; `VENBody` turns bearing-vision
  into R and VEN kinematics out of E (the embodied swarm agent).
- A node is built to match the task's `(n_receptors, n_effectors)`; the reservoir is task-agnostic.

See [tasks.md](tasks.md) for the exact R/E of each task and [receptors-effectors.md](receptors-effectors.md)
for how to configure and (eventually) evolve them.

## Quick start

```julia
using BrainlessLab, CairoMakie
sim = simulate(:wall; node=:falandays_base, ticks=300)   # 1 agent
visualize(sim)
explore(:torus; node=:falandays_base, n_agents=6)         # interactive swarm (needs GLMakie)
```

Tooling: `demo/` (turnkey behaviour GIFs), `bench/` (statistical neuron×task benchmark). See the top-level
[README](../README.md).
