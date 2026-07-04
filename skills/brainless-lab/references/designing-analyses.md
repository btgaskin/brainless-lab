# Designing Analyses and Measures

An analysis in BrainlessLab is a pure function over a finished rollout. It reads the
channels the `Recorder` captured off the hot path and returns a scalar or a NamedTuple of
summaries — it never perturbs the run, and it never touches the compute loop. That
separation is the whole point: the analytic surface is deliberately **measure-agnostic**,
so you can throw any candidate signature at a `SimResult` and ask whether it survives.

The principle this file exists to encode: *a cross-agent number that looks critical is
often an artifact of common input.* The library's answer is a built-in tool — a per-agent
**circular-shift null** (`crossshift_null`) that every candidate cross-agent measure must
clear before you trust it. Use it as a gate, not an afterthought. (This project's own
forage runs are a concrete reminder: measures that looked collective did not beat the null
— null-test rather than assume.)

See also `usage-and-workflows.md` (recording, the `SimResult` surface),
`cli-tools.md` (the sweep `[analytics] measures` set), and
`designing-environments-and-tasks.md` (what channels a task can emit). Prose:
<https://brainless-lab.pages.dev/analysis/> and <https://brainless-lab.pages.dev/notes/criticality-and-information/>.

## The analysis contract

An analysis is a function `f(sim::SimResult; kwargs...)` returning a `Number` or a
NamedTuple of summary fields. Register it so tooling can discover it:

```julia
register_analysis!(:susceptibility, susceptibility;
                   label="susceptibility χ (experimental)")     # global
register_analysis!(:distance_to_source, distance_to_source;
                   task=:forage, label="mean distance to forage source")  # task-scoped
```

`register_analysis!(sym, f; task=nothing, label=string(sym))` stores `(f, task, label)`.
Discover with `analyses()` / `analyses(task=:forage)` (global measures plus that task's
own) and `task_analyses(:forage)` (only that task's). `analysis_meta(sym)` returns
`(task, label)`; `resolve_analysis(sym)` returns the bare function. Most measures are also
callable directly on `sim`: `branching_ratio(sim)`, `branching_ratio_mr(sim; level=:node)`,
`susceptibility(sim)`, `spectral_radius(sim)`, `participation_ratio(sim)`,
`correlation_length(sim)`, `crossshift_null(sim, measure_fn; n_shifts, rng)`,
`transfer_entropy(...)`.

An honest `label` is part of the contract: mark a measure `(experimental)` until it has
been validated (null-tested, checked for finite-size sanity) — see the registry, where
transfer entropy, susceptibility, Fano factor, participation ratio, swarm regime,
correlation length, and the contact-graph clusters all carry that flag today.

## The measure families

**Criticality (node scale).** For population activity $A(t)$, the branching ratio $m$ is
how much activity one tick begets the next. The naive slope
$\hat m = \sum A_t A_{t+1}/\sum A_t^2$ is **biased under subsampling** (a scalar summary of
the population *is* subsampling), so prefer the Wilting–Priesemann multistep-regression
estimator `branching_ratio_mr`: fit $r_k = b\,m^{k}$ across lags and read $m$ off the
exponential decay. `branching_ratio` keeps the legacy through-origin `sigma` for
back-compat visualizations only. Avalanche size/duration exponents ($\tau$, $\alpha$) with
the crackling-noise check $\gamma_{\text{pred}} = (\alpha-1)/(\tau-1)$ come from
`avalanches`; the spectral radius $\rho(W) = \max_i|\lambda_i(W)|$ from `spectral_radius`
is the linear-stability read that complements the branching read. (Caveat: the Falandays
homeostat pins the population rate, so $m\approx1$ can be *rate-pinned* rather than
emergent — always read it beside $\rho(W)$.)

**Collective (agent scale).** Polarization and milling (from `Metrics.jl`), the
`swarm_regime` classifier, `correlation_length` (velocity-*fluctuation* correlation, Cavagna
form), and `contact_graph_clusters` (connected components of the within-vision contact
graph). All experimental.

**Cross-level / information.** `susceptibility` and `participation_ratio` at
`level=:node|:agent`; transfer entropy (`node_transfer_entropy`, `agent_transfer_entropy`)
— a plug-in, order-1, quantile-binned estimator with no bias correction, biased upward on
short series, hence **experimental**.

## Rigor: why null tests are the heart of this

A "collective" number is only interesting if it exceeds what *independent* single-agent
series would produce by chance. The **circular-shift null** constructs exactly that
counterfactual: it independently circular-shifts every agent's recorded time series by a
random offset, so each agent's *own* temporal statistics (autocorrelation, spectrum, event
rate) are preserved while the *cross-agent alignment* is destroyed.

```julia
using Random
res = crossshift_null(sim, s -> susceptibility(s; level=:agent);
                      n_shifts=200, rng=MersenneTwister(11))
# (; real, null_mean, null_std, ratio)  — ratio ≈ 1 ⇒ indistinguishable from null
```

The `measure_fn` must return a `Number` or a NamedTuple with a known scalar field
(`:m_mr`, `:susceptibility`, `:correlation_length`, or a contact-graph component field).
Read `ratio = real / null_mean`: near 1 means the measure is indistinguishable from
independent agents (shared drive, not coupling). Because the null strips *both* real
coupling and common-source drive, the cleanest coupling readout the library supports is a
**difference of conditions** — e.g. vision-on minus vision-off — rather than the raw
`ratio` of a single run; a measure that only clears the null in absolute terms may still be
common-source once you difference against a blind control.

Two further rigor points baked into the code:

- **Windowed vs pooled.** Most estimators have a `_windowed` variant
  (`branching_ratio_mr_windowed`, `susceptibility_windowed`, `correlation_length_windowed`,
  `contact_graph_clusters_windowed`). When the process is non-stationary — a forager
  approaching a source, a swarm condensing — a single pooled number averages over distinct
  regimes and reads as noise-flattened. Slide a window; report the trajectory. The
  branching-windowed path even lets you `residualize` against a `drive` series
  (e.g. `:distance_to_source`) so a slow common trend does not masquerade as $m$.
- **Subsampling bias.** The reason `branching_ratio_mr` exists at all: the single-lag
  slope is systematically biased when you observe a scalar population summary rather than
  every unit. The multi-lag exponential fit is invariant to that subsampling.

## Designing a NEW measure — the checklist

1. **Define it over recorded channels**, not over live simulation state. If the channel
   you need is not captured, the measure cannot run — decide what to record (below).
2. **Pick the scale.** Node-scale (`level=:node`, within each reservoir) or agent-scale
   (`level=:agent`, the ensemble)? Follow the existing `_analysis_level` convention and
   accept `level` as a keyword. Do not conflate the two: `:pooled` mixes distinct
   reservoirs and is a population summary, not "the reservoir's" dynamics.
3. **Provide a windowed variant** if the underlying dynamics are non-stationary. Reuse
   `_branching_window_starts` / `_window_centers` so window/stride semantics match the rest
   of the suite.
4. **Write a null test.** Circular-shift (`crossshift_null`) for any cross-agent claim; a
   phase-randomization or event-shuffle null for a within-series claim. Report the effect
   size *against the null distribution*, not the bare value.
5. **Register honestly.** `register_analysis!(:my_measure, my_measure; label="… (experimental)")`
   and keep the experimental flag until the null test and a finite-size sanity check pass.
6. **Make sure the channel is recorded** — see below.

```julia
function coactivation(sim::SimResult; level::Symbol=:agent)
    level = _analysis_level(level, :coactivation)
    rates = _analysis_rate_matrix(sim, :coactivation)   # ticks × agents
    C = cor(rates)
    return (; level, coactivation = mean(C[i,j] for i in axes(C,1) for j in axes(C,2) if i<j))
end
register_analysis!(:coactivation, coactivation; label="mean pairwise coactivation (experimental)")
# validate before trusting:
crossshift_null(sim, s -> coactivation(s).coactivation; n_shifts=200, rng=MersenneTwister(1))
```

## Recording: analyses read what the recorder captured

Analyses can only read channels the `Recorder` was told to keep:

```julia
sim = simulate(:torus; node=:falandays, n_agents=6, ticks=400,
               record=(:spikes, :rate, :poses, :polarization, :milling), every=1)
```

Node measures need `:spikes` (or fall back to `:rate` × node count); agent measures need
`:poses` (and `:polarization`/`:milling` if you want to skip recomputation); the spectral
radius needs its own `:spectral_radius` channel. That channel is expensive (an eigenvalue
solve per sample), so **stride it** with `spectral_every=K` rather than recording every
tick. Note `crossshift_null` knows how to shift the per-agent channels
(`:poses`, `:rate`, `:spikes`, …) and drops the whole-ensemble scalars (`:polarization`,
`:milling`, recomputed from shifted `:poses`); an unknown channel is left unshifted **with
a warning**, because a surrogate that looks nulled but isn't is worse than none.

The sweep tool exposes measures by short name in `[analytics] measures`
(`sigma_mr`, `susceptibility_node`, `correlation_length`, `contact_clusters`,
`spectral_radius`, `regime`, …); see `cli-tools.md`.

## Pitfalls

- **Trusting an un-null-tested measure.** The default assumption is that a cross-agent
  number reflects shared drive until the circular-shift null says otherwise.
- **Naive branching under subsampling.** Read `branching_ratio_mr` with its per-agent
  distribution and fit quality ($R^2$), not the bare mean — a low-$R^2$ fit still returns a
  finite $m$.
- **Comparing a measure across tasks with different R/E** (reservoir/embodiment) or across
  levels whose prefactors differ by an order of magnitude ($N\approx100$ nodes vs
  $n\approx6$ agents). Compare *peak positions* as a control parameter is swept, not raw
  magnitudes.
- **Reading a pooled number when the process is non-stationary.** Use the windowed variant.
- **Under-powered "confident" numbers.** Correlation length, agent susceptibility, and
  agent participation ratio return a finite value even at `n_agents=6`, where they are
  severely under-sampled — treat them as uninterpretable below ~20–30 agents.
