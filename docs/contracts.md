# Participant contracts

This page states the contracts that matter when interpreting results or adding new parts. The short version:
do not assume effectors mean the same thing across tasks, do not compare raw scores across tasks, and keep
evolvable parameters separate from runtime state.

## Effector semantics by task

Reservoirs emit an effector vector `E`, but each task/body decodes that vector differently.

| task/body | E width | meaning |
|---|---:|---|
| `:wall` | 2 | differential wheel-like speeds. `eL` and `eR` are clamped to `[0, 1]`; speed is `(eL + eR)/2`, heading change is `eR - eL`, and a wall hit causes a random +/-45 deg turn with no translation. |
| `:tracking` | 2 | eye-rotation command. The eye heading changes by `10 * (e1 - e2)` degrees per tick while the stimulus advances separately. |
| `:pong`, `:pong_hitrate` | 2 | paddle vote/differential command. The paddle moves by `100 * (e1 - e2)` and is clamped to its allowed range. |
| `:cartpole`, `:cartpole_hard`, `:cartpole_swingup`, `:cartpole_long` | 2 | binary force vote. If `e1 >= e2`, the env applies negative force; otherwise it applies positive force. Variant envs change force/bounds/initial state, not the vote interface. |
| `:torus` / `VENBody` | 3 | VEN kinematics. `e3` drives forward acceleration; `e2 - e1` drives heading acceleration. Speed and heading rate are damped/capped by `VENParams`. |

These are intentionally non-uniform by task. Effector channel 1 in Pong is not the same physical quantity as
effector channel 1 in cartpole or torus.

## `normalized_score`

`normalized_score(task, raw_score)` is the per-task transform used by `rollout`, `evolve`, and the benchmark:

```
clamp((raw_score - score_floor) / (score_ceiling - score_floor), 0, 1)
```

It makes fitness values comparable enough for optimizer bookkeeping. It is not a universal physical unit,
and saturation at 0 or 1 means the raw score is outside the chosen floor/ceiling range.

| task | raw score key | floor | ceiling | what raw score means |
|---|---|---:|---:|---|
| `:wall` | `:score` | 0.0 | 77.3 | distance over the scoring window minus collision penalty |
| `:tracking` | `:score` | 0.0 | 1.0 | mean cosine alignment to the stimulus |
| `:pong` | `:mean_align` | 0.33 | 0.972 | mean paddle-ball alignment |
| `:pong_hitrate` | `:hit_rate` | 0.30 | 0.52 | fraction of return opportunities hit |
| `:cartpole` | `:score` | 0.0 | 1.0 | fraction of default ticks balanced |
| `:cartpole_hard` | `:score` | 0.0 | 1.0 | fraction balanced under the hard variant |
| `:cartpole_swingup` | `:mean_uprightness` | 0.02 | 1.0 | mean `(cos(theta)+1)/2` |
| `:cartpole_long` | `:score` | 0.0 | 1.0 | fraction balanced with the long pole |

Base `:cartpole` reports survival as `step_count / default_ticks`; cartpole variants report the selected
variant window score (`balanced_fraction` or `mean_uprightness`). Both are normalized onto `[0, 1]`, but the
raw score meanings are not identical.

`:torus` is a registered swarm task symbol, not a `TaskSpec` with a `normalized_score` floor/ceiling. Read
torus runs through collective metrics.

## Ensemble metrics

`rollout!(collective, ticks; window)` returns the medium/task metrics plus liveness diagnostics.

- **`score`** -- task-specific raw scalar from single-agent envs. Its meaning depends on the task table
  above; normalize through `normalized_score` before cross-task fitness comparisons.
- **`polarization`** -- heading alignment for swarms: the length of the mean unit heading vector. `0` means
  disordered headings; `1` means all headings are aligned.
- **`milling`** -- absolute mean rotational order about the current centroid: high values mean agents are
  moving tangentially around the group center.
- **`liveness`** -- reservoir activity sanity check over the scoring window. It reports `rate_mean`,
  `rate_var`, `total_spikes_window`, and `alive`. The current `alive` flag requires
  `0.01 < rate_mean < 0.99`, nonzero variance, and enough total spikes in the window.

Swarm metrics also include mean nearest-neighbour distance, mean pairwise distance, cohesion
(`nearest + pairwise`), and input stability.

## Node and extension contract

A high-level node constructor must accept:

```julia
(n_nodes, n_receptors, n_effectors; seed=0, kwargs...)
```

and return a `Reservoir` implementing:

```julia
step!(r, receptors)      # advance one reservoir tick and return spikes/rates
effectors(r, spikes)     # map spikes/rates to an E-vector of length n_effectors(r)
reset!(r)                # reset runtime state
n_receptors(r)
n_effectors(r)
```

When extending package generics, use `import`, not only `using`:

```julia
import BrainlessLab: step!, effectors, reset!, n_receptors, n_effectors
```

Without `import`, Julia will not add methods to BrainlessLab's generic functions, and high-level APIs such
as `simulate` will not dispatch to your implementation.

Keep genotype and runtime state separate:

- **`pack_params` / `unpack_params` / `paramdim`** are for evolvable parameters: values an optimizer can
  store, mutate, and reload as a genome.
- **`snapshot_state` / `load_state!`** are for transient simulation state: membrane activations, learned
  weights, spike buffers, noise index, compartment voltages, and similar replay/reset state.

Do not hide runtime state inside `pack_params`, and do not expect `snapshot_state` to define the evolvable
search space.
