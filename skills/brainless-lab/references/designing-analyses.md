# Designing analyses and measures

An analysis reads a completed `SimResult`. It must not alter the simulation. Keep analysis
code outside the runtime loop so the same recorded run can support several measures and
null tests.

## Analysis interface

An analysis function accepts a `SimResult` and returns a `Number` or named tuple:

```julia
function my_measure(sim::SimResult; window=nothing)
    samples = getchannel(sim.recorder, :rate)
    isempty(samples) &&
        throw(ArgumentError("record :rate before running my_measure"))
    # Compute and return a scalar or named tuple.
end
```

Register it for discovery and profile plans:

```julia
register!(
    DEFAULT_REGISTRY,
    :analyses,
    ImplementationSpec(
        :my_measure,
        my_measure;
        label="my measure (experimental)",
        metadata=(task=nothing,),
    ),
)
```

Typed registration rejects duplicate keys. Discover analyses with:

```julia
analyses(DEFAULT_REGISTRY)
analyses(DEFAULT_REGISTRY; task=:tracking)
```

The task filter returns global measures and measures assigned to that task.

A registered analysis may declare `required_channels` in its metadata. `ProfilePlan`
combines these requirements before running the target. If an analysis still cannot run,
the profile result must report the failure rather than omit it silently.

## Choose the scale before the estimator

State whether a measure describes:

- nodes within one reservoir;
- agents within one world;
- a relation between levels;
- the task outcome;
- a body or world variable.

Do not pool nodes from distinct reservoirs and call the result one reservoir statistic.
Do not treat agents or ticks within one world as independent replicates.

## Built-in measure families

Node-scale activity measures include:

- `branching_ratio` for the legacy one-step activity ratio;
- `branching_ratio_mr` for multistep regression;
- `avalanches` for thresholded event sizes and durations;
- `spectral_radius` for the recurrent weight matrix;
- `node_target_error` for homeostatic target error;
- node-level susceptibility, participation ratio, and transfer entropy.

Agent-scale measures include polarization, milling, velocity-fluctuation correlation
length, contact-graph clusters, susceptibility, participation ratio, and transfer entropy.
Most are experimental.

The estimators answer different questions. The spectral radius
$\rho(W)=\max_i|\lambda_i(W)|$ is a linear matrix diagnostic, not a general stability
criterion for a nonlinear plastic system. Avalanche exponents require enough events,
threshold checks, competing distributions, and finite-size evidence.

The multistep-regression branching estimator fits activity correlations across lags and is
more robust to subsampling under its assumptions. It is not universally unbiased. Report
fit quality, lag range, observation process, and aggregation. See Wilting and Priesemann,
*Nature Communications* 9, 2325 (2018),
<https://doi.org/10.1038/s41467-018-04725-4>.

The transfer-entropy implementation is an order-one, quantile-binned plug-in estimator
without bias correction. Short series can bias it upward. Keep it experimental and report
binning, history order, sample size, and null distribution.

## Record the required channels

Analyses can only read channels retained by the recorder:

```julia
sim = simulate(
    :torus;
    node=:falandays,
    n_agents=6,
    ticks=400,
    record=(:spikes, :rate, :poses, :polarization, :milling),
    every=1,
)
```

Node activity measures need `:spikes` or `:rate`. Agent motion measures need `:poses`.
The spectral-radius measure needs its own channel. Sample that channel with
`spectral_every=K` because each sample requires an eigenvalue calculation.

If a measure needs a new channel, add and test the recorder path before registering the
measure. Do not reach into live private state from a post-run analysis.

## Use windows for non-stationary processes

A pooled value can hide movement between regimes. Provide a windowed form when activity,
distance, density, or coupling changes during the run. Return window bounds or centres
with each value.

Built-in windowed functions include forms of multistep branching, susceptibility,
correlation length, and contact-graph clustering. Select the window length before viewing
held-out outcomes.

## Match the null to the claim

A cross-agent statistic can arise from shared environmental drive. `crossshift_null`
independently circular-shifts each agent's recorded series. It preserves each series'
temporal structure while disrupting cross-agent alignment:

```julia
using Random

result = crossshift_null(
    sim,
    shifted -> susceptibility(shifted; level=:agent).susceptibility;
    n_shifts=200,
    rng=MersenneTwister(11),
)
```

Report the observed value, null distribution, valid surrogate count, alternative, effect
summary, and Monte Carlo p-value. A value near the null mean does not establish
equivalence.

Circular shifts disrupt both interaction timing and common-source timing. Pair the
surrogate with a causal condition when the claim concerns communication or social
coupling. Examples include vision-on versus vision-off, a matched sham, or a yoked input.

Use another null when circular shifts do not represent the intended counterfactual:

- event shuffles for event-timing claims;
- phase randomisation for spectral dependence;
- label permutation for group assignments;
- random-action or blind policies for task opportunity;
- registered ablations for mechanism necessity.

Exact replay tests deterministic equivalence. It is not a causal null.

## Example: agent coactivation

```julia
using Statistics

function coactivation(sim::SimResult; level::Symbol=:agent)
    level === :agent ||
        throw(ArgumentError("coactivation supports only level=:agent"))
    samples = getchannel(sim.recorder, :rate)
    isempty(samples) &&
        throw(ArgumentError("record :rate before running coactivation"))

    n_agents = length(first(samples))
    n_agents >= 2 ||
        throw(ArgumentError("coactivation needs at least two agents"))

    rates = Matrix{Float64}(undef, length(samples), n_agents)
    for (tick, sample) in enumerate(samples)
        length(sample) == n_agents ||
            throw(DimensionMismatch("rate width changed at tick $tick"))
        rates[tick, :] .= Float64.(collect(sample))
    end

    correlations = cor(rates)
    pairs = (
        correlations[i, j]
        for i in axes(correlations, 1), j in axes(correlations, 2)
        if i < j
    )
    return (; level, coactivation=mean(pairs))
end
```

Register the function as experimental. Test it on synthetic independent, shared-drive,
and coupled data before interpreting a real run. Then apply a suitable surrogate and
causal control.

## Readiness and evidence

A registered analysis with tests is software-ready. This does not establish construct
validity. Keep estimator limits, task scope, finite-size behaviour, and null requirements
in its metadata and documentation.

Use a `ProfilePlan` for repeatable descriptive analysis. Use an `ExperimentSpec` when the
analysis forms part of a versioned scientific protocol. Store the resulting tables in the
standard operation record rather than in a bespoke analysis directory.

See `usage-and-workflows.md` for recording, `cli-tools.md` for profile plans, and
`research-workflow.md` for evidence stages.
