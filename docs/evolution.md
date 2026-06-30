# Evolved versions: training, the genotype store, and fitness

Some nodes learn online and can be run as-is; others have **emergent weights with no plasticity** and must
be **evolved** before they mean anything. This page covers how training works, how evolved genomes are
stored and tracked, and how fitness is computed.

Evolution is part of the experimental platform around the stable Falandays baseline. `:falandays_base` with
default parameters is the 2021 paper-faithful model. Evolving its 7 control parameters is an optional
experiment, not the settled baseline. The compartmental/CTRNN nodes are our construction and require
evolution because their weights are the genotype.

## Who needs evolving

| family | online plasticity | evolution |
|---|---|---|
| Falandays base (`:falandays_base`, alias `:falandays`) | yes | **optional** -- the settled baseline is the default 2021 constants |
| Falandays variants (`:falandays_noisy`, `:falandays_ablated`, `:falandays_hemispheric`, `:falandays_oosawa`) | yes, with target homeostasis disabled in `:falandays_ablated` | **optional/experimental** -- useful perturbations, not the paper-faithful baseline |
| Compartmental (`:compartmental_dense`, `:compartmental_structured`) | no | **required** -- untrained weights are random; only an evolved genome is a fair test |

## The optimiser

A hand-rolled **separable CMA-ES** (diagonal covariance), validated to ~1e-6 against pycma. It minimises
`loss = -fitness`.

- **Initialisation** -- `find_alive_centroid`: sweep random genomes and start CMA from one that is alive on
  at least two seeds (avoids starting in a dead region of a non-plastic genome space). For Falandays models,
  the default starting vector is `pack_params(FalandaysParams())`.
- **Population** -- sep-CMA default lambda is about `4 + floor(3 * log(n))` for genome dim `n` (about 20 for
  the 220-dim structured genome); raise it (for example 32) to explore more on short runs.
- **Common random numbers** -- every candidate in a generation is evaluated on the *same* trial seeds
  (`wiring_seed_base + gen * 10007 + i`), so comparisons within a generation are fair.

## Fitness

For each candidate, **per train task**: run `k_trials` rollouts at distinct CRN seeds and take the
**mean** of their normalized scores. Then aggregate **across tasks** with the `aggregator`:

- `:min` across tasks (default) -- worst-case over tasks; rewards a genome that does well on *every* task.
- `:mean` across tasks -- average over tasks.

So the per-seed aggregation is always the mean; the `:min`/`:mean` choice acts *across tasks*. For
single-task training (the common case) the across-task step is a no-op, and the fitness is simply the
mean over the `k_trials` seeds. Normalized score is the task-specific `TaskSpec` floor/ceiling transform
clamped to `[0, 1]`; see [contracts.md](contracts.md) for the exact table.

## Training workflow & the genotype store

`bench/train.jl` evolves one `(neuron, task)` and writes a tagged store entry:

```bash
cd bench
julia --project=. -t 8 train.jl compartmental_structured wall \
    --generations 20 --popsize 32 --k-trials 8 --N 200 --sigma0 2.5
```

Output:

- `bench/genomes/<neuron>__<task>/genome.jld2` -- the evolved weight or parameter vector.
- `bench/genomes/<neuron>__<task>/train_manifest.toml` -- git SHA, neuron, task, seed, generations,
  popsize, `k_trials`, `N`, ticks, `sigma0`, **best_fitness**, timestamp, and a content-hash **`tag`**
  identifying the run.

The benchmark ([bench/](../bench/README.md)) then loads these for `:trained` cells, copies the genome +
provenance into each cell's output, and records `prep = trained:<tag>` -- so every reported number is
traceable to the exact weights and the run that produced them. A cell that needs training but has no stored
genome is run untrained and **flagged**.

## A worked readiness run (20 generations, all main tasks)

`compartmental_structured`, 20 gen, lambda=32, fitness = mean over 8 CRN trials (single task), N=200,
alive-centroid init:

| task | evolved best fitness | untrained baseline |
|---|---:|---:|
| wall | **0.728** | ~0 |
| tracking | 0.523 | ~0 / negative |
| pong | 0.327 | approximately floor (0.33) |
| cartpole | 0.043 | ~0 |
| cartpole_swingup | 0.109 | ~0 |

**Reading it:** the loop works -- wall went from a dead 0 to a competent ~0.73 avoider and tracking made
real progress. But **20 generations on a 220-dim genome is a short probe** -- pong sits at its floor and
cartpole/swing-up barely moved. Competent agents on the hard control tasks need many more generations
(hundreds), and pong likely wants the author size N=500. The machinery is ready; the budget in this run was
deliberately small.

## Open design points

These are flagged for a dedicated design pass:

1. **Statistical honesty** -- a trained benchmark cell currently uses one evolved genome over n eval-seeds
   (evaluation variance only). The fair version runs K independent evolution runs per cell (search variance)
   and reports the distribution.
2. **Specialist vs generalist** -- train per-(neuron, task) vs one genome on a task suite.
3. **Ergonomics** -- `train --all`, training profiles (quick/standard/thorough), resumable, parallel.
4. **Store management** -- list/inspect/supersede/best-of-K genomes.
5. **Co-evolving morphology** -- extend the genome with the bounded sensor/effector layout (Angle B in
   [receptors-effectors.md](receptors-effectors.md)).
