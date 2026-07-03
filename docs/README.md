# BrainlessLab documentation

An extensible Julia lab for **"brainless" cognition** -- behaviour emerging from collectives of simple
neuron-like nodes, with no homunculus and no hand-wired control. This `docs/` set explains the parts,
what is stable, and how they connect.

## Contents

- **[onboarding.md](onboarding.md)** -- short setup guide for the root package, `demo/`, and `bench/`.
- **[nodes.md](nodes.md)** -- node types and variants, including the paper-faithful Falandays baseline.
- **[tasks.md](tasks.md)** -- the tasks and their **input/output (receptor/effector) mappings** -- what each
  task senses, what it acts with, how the counts are set and linked.
- **[contracts.md](contracts.md)** -- participant-facing contracts for effectors, normalized scores,
  collective metrics, and extension methods.
- **[receptors-effectors.md](receptors-effectors.md)** -- how the sensorimotor interface works today (fixed
  per task/body) and the **planned tunable + evolvable** design.
- **[collective.md](collective.md)** -- the n-agent / dyad (swarm) setup: bodies, the torus medium, coupling.
- **[evolution.md](evolution.md)** -- evolved versions: training, the genotype store + provenance, fitness,
  and a worked 20-generation readiness run.

## Stable baseline vs Experimental

**Stable baseline:** `:falandays_base` (with `:falandays` as an alias) is the settled, validated,
paper-faithful baseline: the 2021 Falandays homeostatic reservoir with its exact constants, run against the
2024 case-study task set implemented in this repo. Use this when you need the known reference model.

**Experimental platform:** the rest of BrainlessLab is the framework around that baseline: the
compartmental/CTRNN nodes, the evolution tooling, the swarm/VEN layer, and the Falandays variants beyond
base (`:falandays_noisy`, `:falandays_ablated`, `:falandays_hemispheric`, `:falandays_oosawa`). These pieces
are meant for summer-institute experiments and may change as the testbed develops.

Validation against numpy v0/v0.2 means bit-fidelity to the reference implementation used for fixtures. It
does not make the experimental pieces paper-faithful; v0.2 itself includes documented departures from the
2021 model.

## The core abstraction

Everything is *neurons as nodes within a collective* -- the same node contract at every scale:

```
NodeModel -> Reservoir -> Body -> Agent -> Ensemble{Medium} -> Task -> Runner(evolve|fixed) -> Run
                                                       \-> Recorder ->  (viz reads this, off the hot path)
```

A single-agent task is an `Ensemble` of **one** agent; a dyad is `n_agents=2`; a swarm is `n_agents=N`.
The same `step!(collective)` runs both.

## The sensorimotor contract (read this first)

Each tick, for every agent:

```
percept --receptors(body,.)--> R --step!(reservoir,R)--> spikes --effectors(reservoir,.)--> E --decode_effectors(body,.)--> command --actuate!(medium,.)--> world
```

- **Receptors (R)** = the reservoir's sensory input vector; **Effectors (E)** = its motor output vector.
- The **Body** mediates: `PassthroughBody` relays a task env's R/E directly; `VENBody` turns bearing-vision
  into R and VEN kinematics out of E (the embodied swarm agent).
- A node is built to match the task/body `(n_receptors, n_effectors)`; the reservoir is task-agnostic.
- Effector semantics are **not uniform across tasks**: wall, tracking, pong, cartpole, and torus all decode
  the output vector differently. See [contracts.md](contracts.md).

See [tasks.md](tasks.md) for the exact R/E of each task and [receptors-effectors.md](receptors-effectors.md)
for how to configure and eventually evolve them.

## Quick start

```julia
using BrainlessLab, CairoMakie
sim = simulate(:wall; node=:falandays_base, ticks=300)   # stable baseline, 1 agent
visualize(sim)
explore(:torus; node=:falandays_base, n_agents=6)         # interactive swarm (needs GLMakie)
```

Tooling: `demo/` (turnkey behaviour GIFs), `bench/` (statistical neuron x task benchmark). See the top-level
[README](../README.md) and [onboarding.md](onboarding.md).
