# Node types and variants

A **node** is the neuron model that fills a reservoir. Every node satisfies the same contract — `step!(r,
R)→spikes`, `effectors(r, spikes)→E`, `reset!`, `n_receptors`, `n_effectors` — so any node runs any task.
Pick one with `node=:symbol`; `variants()` lists what's registered. Add your own with `register_node!`.

## Two families

### Falandays (homeostatic, online-plastic)
Leaky integrate-and-fire reservoir with **online learning during the rollout**: per-node target `T`
(floor 1), firing threshold `T′ = 2T`, leak 0.25 (0.75 retained), recurrent matrix with no self-connections.
Learning each tick: `W -= E/N` (mean over active presynaptic), `T += lrate_targ·error`. Because it
self-organizes online, it is **fair to run untrained** (default params + random wiring per seed).
The evolvable genome is 7 scalars (`leak, lrate_wmat, lrate_targ, threshold_mult, targ_min, input_weight,
weight_init_std`) — evolving it is *optional*.

| variant | what it adds |
|---|---|
| `:falandays_base` | the base model (alias `:falandays`); the default node |
| `:falandays_noisy` | + **sensory** input noise (`Uniform(±0.1)`, clip ≥0 — perturbs the receptor vector) |
| `:falandays_ablated` | **target homeostasis frozen** (`lrate_targ=0`): target pinned at 1.0, threshold fixed at 2.0; weights still learn — an ablation probe of the homeostatic mechanism |
| `:falandays_oosawa` | + **Oosawa membrane drive** (pure target-modulated: `σ = 0.8·max(0, 2T−acts)`, no constant floor) — endogenous self-activation that ramps up when a node is starved and switches off at set-point; keeps a blind network alive |
| `:falandays_hemispheric` | **two half-size reservoirs, contralateral wiring**: right sensors→left effectors, left sensors→right effectors; the hemispheres couple only through the body/world |

Two noises are distinct: **membrane** noise (`:oosawa`, on the membrane potential `acts`) vs **sensory**
noise (`:noisy`, on the receptor input). See [receptors-effectors.md](receptors-effectors.md).

### Compartmental / CTRNN (emergent weights, no plasticity)
A dendrite→soma→hillock CTRNN cell with **emergent (evolved) weights and no online learning**. Because the
weights don't adapt, an **untrained** compartmental node is random/meaningless — it **must be evolved** to be
tested fairly (see [evolution.md](evolution.md)). The genome is the full cell weight set.

| variant | genome dim | notes |
|---|---|---|
| `:compartmental_structured` | **220** | single-port dendrite/soma routing, emergent threshold; the recommended ("structured") build, faster |
| `:compartmental_dense` | **404** | dense all-to-all cell; heavier |

## Plasticity ⇒ preparation

The benchmark uses this distinction directly (see [evolution.md](evolution.md)):

| family | online plasticity? | default benchmark prep |
|---|---|---|
| Falandays | yes (learns during rollout) | **untrained** (fair) — evolving params is opt-in |
| Compartmental | no (weights emergent/evolved) | **trained** (required) — untrained is flagged not-comparable |

## Composing & extending

Node axes compose via kwargs: `simulate(:wall; node=:falandays_base, drive=OosawaDrive(...), sign=:dale,
topology=:watts_strogatz)`. The named variants are just preset kwarg bundles. To add a genuinely new node:

```julia
import BrainlessLab: step!, effectors, n_receptors, n_effectors, reset!
struct MyNode <: Reservoir; ...; end
# implement the contract, then:
register_node!(:mynode, (n_nodes, n_recep, n_eff; seed=0, kwargs...) -> MyNode(...))
simulate(:wall; node=:mynode)
```
(Extending a node means adding *methods* to the package generics — `import` them, don't `using`.)
