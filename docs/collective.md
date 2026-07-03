# The collective: n-agent and dyad

A single-agent task is an `Ensemble` of one. The **same machinery** scales to dyads (`n_agents=2`) and
swarms (`n_agents=N`) -- one `step!(collective)` drives all of them. This is the "neurons as nodes within a
collective" idea applied at the agent scale: each agent *is* a reservoir-in-a-body, and the collective is
the population.

```julia
simulate(:torus; node=:falandays_base, n_agents=2)    # dyad
simulate(:torus; node=:falandays_base, n_agents=12)   # swarm
simulate(:forage; node=:falandays_base, n_agents=12)  # social/blind source foraging
explore(:torus; node=:falandays_base, n_agents=6)     # interactive (needs GLMakie)
```

`falandays_base` remains the stable baseline node; the torus/VEN swarm itself is part of the experimental
platform around that baseline.

## The pieces

- **`Ensemble{Environment}`** -- a population of `Agent{Reservoir, Body}`, run by the tick protocol
  `observe -> step! -> actuate -> commit`.
- **`TorusEnvironment`** -- a periodic 2-D world. Knobs: `sensory_noise` (default 0.1, added to each bearing
  sensor), `vision_range` (neighbours beyond it are invisible, so coupling drops out as agents disperse),
  torus size, optional visual/physical coupling flags.
- **`VENBody`** -- the embodied swarm agent. Vision-in / kinematics-out:
  - **receptors (R = 64):** bearing vision starts as 62 sensors -- two eyes (+/-30 deg) x 31 angles. The
    body pads those values into a 64-channel receptor vector (`inputs[3:64]`) and, by default, normalizes
    the vector by its sum when activity is nonzero.
  - **forage receptors (R = 128):** `:forage` keeps that 64-wide conspecific bank and appends a second
    64-wide source-vision bank with the same bearing geometry. `source_gain` weights the source bank.
  - **effectors (E = 3):** VEN kinematics require exactly three values. `e3` drives forward acceleration;
    `e2 - e1` drives heading acceleration. Speed and heading rate are damped/capped by `VENParams`.

Contrast: single-agent tasks use `PassthroughBody` (the env already speaks R/E); the swarm uses `VENBody`
(the body manufactures R from the world and turns E into motion).

## Coupling = vision

By default there is **no explicit interaction term** -- agents influence each other by being seen. Agent A's
sensors light up when agent B falls in a sensor cone within `vision_range`; that drives A's reservoir, which
drives A's motion, which changes what B sees. So:

- the **sensor geometry is the interaction topology** (see [receptors-effectors.md](receptors-effectors.md));
- `vision_range` controls how coupling decays with distance;
- collective order is emergent, not imposed.

`physical_coupling` exists as a config flag for collision resolution, but the default swarm coupling path is
visual.

## Foraging

`simulate(:forage; node=:falandays_base, n_agents=N, seed=0, conspecific_vision=true)` runs the torus swarm
with one stationary source sampled from the same rollout RNG as the initial agent poses. Agents receive two
visual banks: conspecific bearing vision and source bearing vision. Setting `conspecific_vision=false` zeros
the conspecific bank and disables inter-agent collision resolution, while preserving population size and the
source bank.

## Metrics

Swarm behaviour is read through swarm metrics rather than a single normalized task score:

- **Polarization (P)** -- alignment of headings (0 = disordered, 1 = all aligned).
- **Milling (M)** -- rotational/circling order about the centroid.
- **Mean nearest-neighbour / pairwise distance** -- spatial spread on the torus.
- **Input stability** -- cosine similarity of recent sensory input histories.
- **Liveness** -- firing-rate sanity check from the population activity window.
- **Forage metrics (`:forage`)** -- `mean_distance_to_source`, `frac_within_capture`,
  `time_to_first_arrival`, and bounded `forage_score`, alongside polarization/milling.

The behaviour GIF for `:torus` animates all agents moving with heading arrows and live P/M. See
[contracts.md](contracts.md) for the metric definitions participants should use when comparing runs.

## Validation

The single-agent-as-`Ensemble{N=1}` path and the dyad/torus path are Float64 oracle-validated against the
numpy v0.2 `multi_agent_episode` fixtures. That is implementation bit-fidelity to the v0.2 reference path;
it does not make the torus/VEN extension part of the 2021 Falandays paper baseline.

## Status & next

- Done: n-agent / dyad simulation, swarm metrics, behaviour GIFs.
- Planned: deeper collective science (flocking/milling regimes, predator-prey, coupling/criticality sweeps,
  evolving collectives). The abstractions support it; the experiments are beyond the stable baseline.
- Planned: tunable/evolvable vision geometry (it is the coupling) -- see
  [receptors-effectors.md](receptors-effectors.md).
