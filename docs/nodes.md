# Node types and variants

A **node** is the neuron model that fills a reservoir. Every node satisfies the same contract --
`step!(r, R) -> spikes`, `effectors(r, spikes) -> E`, `reset!`, `n_receptors`, `n_effectors` -- so any
registered node can be built for any registered task/body dimensions. Pick one with `node=:symbol`;
`variants()` lists what is registered. Add your own with `register_node!`.

## Paper fidelity and status

The stable baseline is `:falandays_base` (also accepted as `:falandays`). It is the authors' 2021
homeostatic spiking reservoir: no rectification (`acts_neg=1`), Bernoulli recurrent/input/output
connectivity, no degree repair, binary input weights scaled by the task's `input_amp`, and online
target/weight updates during rollout.

The neuron equations are common across tasks:

| parameter | value |
|---|---:|
| `leak` | 0.25 |
| `threshold_mult` | 2.0 |
| `targ_min` | 1.0 |

The authors' scripts set several constants per task:

| task | `nnodes` | `input_amp` | `lrate_wmat` | `lrate_targ` | recurrent init | sensory noise |
|---|---:|---:|---:|---:|---|---:|
| `:wall` | 200 | 4.0 | 1.0 | 0.01 | all-excitatory `Normal(input_amp, 0.1)` | 0.1* |
| `:tracking` | 200 | 0.75 | 1.0 | 0.01 | all-excitatory `Normal(input_amp, 0.1)` | 0.0 |
| `:pong` | 500 | 2.75 | 1.0 | 0.1 | per-synapse 25% `Normal(-1, 0.1)` / 75% `Normal(0, 0.2)` | 0.0 |

`*` Wall sensory noise `0.1` is a labeled assumption: the committed authors file has `noise=0`, but the
published noisy wall runs used an uncommitted nonzero value. BrainlessLab applies this as no-clip
`Uniform(+/-0.1)` noise for the faithful wall high-level default.

The baseline is validated against a dumped trajectory generated from the authors' Julia construction and
dynamics (`test/fixtures/authors_<task>.jld2`). The old numpy v0.2 fixtures remain as legacy regression
coverage only; v0.2 itself contains documented departures from the authors' code. The other registered
Falandays variants are experimental perturbations around the baseline. The compartmental/CTRNN nodes are
**our construction**, not a Falandays paper model.

## Registered variants

| variant | status | what it adds |
|---|---|---|
| `:falandays_base` | **stable baseline** | the authors' 2021 Falandays homeostatic reservoir with task-specific paper constants; `:falandays` is an alias |
| `:falandays_noisy` | experimental | + **sensory** input noise (`Uniform(+/-0.1)`, clip >= 0 -- perturbs the receptor vector) |
| `:falandays_extended` | experimental | the paper's **extended** model: base + sensory noise + **Watts--Strogatz** small-world recurrent wiring + **Dale's law** (excitatory/inhibitory). Same neuron update as base; a richer substrate. The documented `base` vs `extended` contrast. |
| `:falandays_ablated` | experimental | **target homeostasis frozen** (`lrate_targ=0`): target pinned at 1.0, threshold fixed at 2.0; weights still learn -- an ablation probe of the homeostatic mechanism |
| `:falandays_hemispheric` | experimental | **two half-size reservoirs, contralateral wiring**: right sensors -> left effectors, left sensors -> right effectors; the hemispheres couple only through the body/world |
| `:falandays_oosawa` | experimental | + **Oosawa membrane drive**: target-modulated stochastic membrane noise. `sigma = membrane_noise + noise_gain * max(0, 2T - acts)` is the noise amplitude, so exploration grows when a node is below threshold and vanishes at set-point when there is no constant floor; keeps a blind network alive |
| `:falandays_spatial` | experimental | Falandays dynamics with an embedded metric-space connectome and distance-dependent connection probabilities |
| `:falandays_delayed` | experimental | Falandays dynamics with heterogeneous recurrent delays carried by spike-history buffers |
| `:sorn` | experimental | **SORN** criticality reference with STDP + intrinsic plasticity + synaptic normalization; Lazar/Pipa/Triesch 2009; not yet validated for avalanche-scaling criticality in this implementation |
| `:compartmental_dense` | experimental | dense dendrite -> soma -> hillock CTRNN cell with emergent weights and no online plasticity |
| `:compartmental_structured` | experimental | structured single-port dendrite/soma routing with emergent threshold; the recommended compartmental build |

The registry also includes `:falandays` as an alias for `:falandays_base`.

## Falandays family (homeostatic, online-plastic)

The base model is a leaky integrate-and-fire reservoir with **online learning during the rollout**: per-node
target `T` (floor 1), firing threshold `T' = 2T`, leak 0.25 (0.75 retained), recurrent matrix with no
self-connections. Learning each tick: `W -= E/N` (mean over active presynaptic), `T += lrate_targ * error`.
Because it self-organizes online, it is **fair to run untrained** (default params + random wiring per seed).
The evolvable genome is 7 scalars (`leak`, `lrate_wmat`, `lrate_targ`, `threshold_mult`, `targ_min`,
`input_weight`, `weight_init_std`) -- evolving it is optional and experimental. The faithful task defaults
thread `input_amp` and `weight_init_mode` as construction options, not as packed genotype fields.

Two noises are distinct: **membrane** noise (`:falandays_oosawa`, on the membrane potential `acts`) vs
**sensory** noise (`:falandays_noisy`, on the receptor input). See
[receptors-effectors.md](receptors-effectors.md).

## Registered ablations

Ablations are named perturbations applied to a node and/or environment during construction. They are the
mechanism behind `ablate(node, task)` and the sweep `ablation` axis.

| ablation | applies to | effect |
|---|---|---|
| `:freeze_plasticity` | Falandays, SORN | sets `learn_on=false`; compartmental nodes have no online plasticity and are reported as no-op |
| `:zero_recurrent` | Falandays, compartmental | removes recurrent weights/connectivity at build time |
| `:clamp_target` | Falandays | canonical target-homeostasis clamp: sets `lrate_targ=0`; `:falandays_ablated` is the packaged node preset for this same mechanism |
| `:disable_vision` | torus/forage environments | sets `conspecific_vision=false`, zeroing only the conspecific vision bank; physical collision handling remains controlled by `physical_coupling` |
| `:reset_dendrites` | compartmental | zeros dendritic state on each tick via the intervention hook |
| `:no_soma_back` | compartmental | removes soma-to-dendrite feedback weights |
| `:no_hillock_back` | compartmental | removes hillock-to-soma feedback weights |

## Compartmental / CTRNN family (emergent weights, no plasticity)

The compartmental cells are an experimental BrainlessLab construction: dendrite -> soma -> hillock CTRNN
reservoirs with **emergent/evolved weights and no online learning**. Because the weights do not adapt, an
**untrained** compartmental node is random/meaningless -- it **must be evolved** to be tested fairly (see
[evolution.md](evolution.md)). The genome is the full cell weight set.

**Integration:** forward Euler over **`substeps = 5`** sub-steps of `dt_sub = dt/substeps = 0.2` per env
update (total integration time `dt = 1.0` unchanged -- finer resolution). Each compartment updates
`y <- y + dt_sub * (-y + input) / tau`; the afferent input is held across the sub-steps and recurrence
propagates at the fine timescale. The env-step output is the per-node **spike rate over the sub-steps**
(`0, 0.2, ..., 1`); at `substeps=1` this collapses to the single `dt=1.0` step with a binary spike vector,
matching the numpy oracle path used by parity tests. Time constants: dendrite/soma
`tau = TAU_MIN(1.0) + softplus(evolved) >= 1` (per-compartment, evolved); hillock `hill_tau = 3.5`,
`hill_reset = 0`.

Why 5: with a single `dt=1.0` step and `tau` near its floor of 1.0, `dt/tau = 1` overwrites the state each
step (no memory, edge of Euler stability). Five sub-steps of `dt_sub=0.2` integrate the continuous dynamics
smoothly (`dt_sub/tau <= 0.2`), so the cell retains genuine temporal state regardless of the evolved `tau`.
Set `substeps` via the constructor (`CompartmentalReservoir(g, w; substeps=k)`); applies to both
`:compartmental_dense` and `:compartmental_structured`.

| variant | genome dim | notes |
|---|---:|---|
| `:compartmental_dense` | **404** | dense all-to-all cell; heavier |
| `:compartmental_structured` | **220** | single-port dendrite/soma routing, emergent threshold; faster |

## Plasticity => preparation

The benchmark uses this distinction directly (see [evolution.md](evolution.md)):

| family | online plasticity? | default benchmark prep |
|---|---|---|
| Falandays base | yes (learns during rollout) | **untrained** (fair) -- the stable baseline |
| Falandays variants | yes, except ablated target-homeostasis | **untrained** by default -- experimental perturbations |
| Compartmental | no (weights emergent/evolved) | **trained** (required) -- untrained is flagged not-comparable |

## Composing & extending

Node axes compose via kwargs: `simulate(:wall; node=:falandays_base, drive=OosawaDrive(...), sign=:dale,
topology=:watts_strogatz)`. The named variants are preset kwarg bundles. To add a genuinely new node:

```julia
import BrainlessLab: step!, effectors, n_receptors, n_effectors, reset!

struct MyNode <: Reservoir
    ...
end

# implement the contract, then:
register_node!(:mynode, (n_nodes, n_recep, n_eff; seed=0, kwargs...) -> MyNode(...))
simulate(:wall; node=:mynode)
```

Extending a node means adding *methods* to the package generics -- `import` them, do not rely on `using`.
See [contracts.md](contracts.md) for the `pack_params`/`snapshot_state` split when your node has evolvable
parameters as well as runtime state.
