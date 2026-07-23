# Research workflow

Use this reference when a request moves beyond software conformance into selection,
comparison, or a scientific claim.

## Evidence ladder

1. Conformance: verify equations, geometry, ports, reset, replay, and RNG ownership.
2. Calibration: use static, random, blind, or oracle policies to establish task
   opportunity and timescale.
3. Exploration: inspect behaviour and failure modes; generate hypotheses.
4. Tuning or training: select parameters or genomes on development worlds.
5. Variance pilot: estimate paired variability on fresh blocks.
6. Frozen protocol: fix conditions, endpoints, exclusions, analysis, and stopping rule.
7. Sealed confirmation: execute once on untouched independent blocks.
8. Robustness: test declared perturbations without changing the primary result.
9. Promotion: archive the protocol, provenance, seeds, data, analysis, and figures.

Map this workflow to `ExperimentSpec.evidence_state`:

```text
planned → exploratory → tuned → frozen → confirmed → promoted
```

Use `retired` for a withdrawn or superseded protocol. Looking at sealed outcomes and then
changing an endpoint, exclusion, condition, or analysis returns the study to development.

## Version the scientific protocol

Use `ExperimentSpec` when a question has named conditions and one or more operations. It
records:

- a stable ID and version;
- title and research question;
- named `EvaluationTarget` conditions;
- operation plans;
- evidence state;
- limitations and metadata.

Write the bundle with `write_experiment`. Execute it with `run-experiment`. Each operation
still writes an ordinary record.

Create a new experiment version when a scientific change alters the question, conditions,
endpoint, seed policy, exclusions, or operation. A code correction that changes realised
behaviour also requires a new version or an explicit invalidation note.

## Define units and controls

Name the tick, agent, run, condition, sweep cell, paired block, seed, and independent unit.
Agents and ticks within one world are not automatically independent samples.

Choose the control from the claim:

- static or no-action: does action help?
- random action: does performance exceed the task/body/action floor?
- blind or off: is an information channel necessary?
- matched sham, shift, or yoke: do timing, direction, or information matter at matched
  exposure?
- registered ablation: is the mechanism necessary?
- model baseline: does the candidate differ from the declared reference?
- oracle: is the task solvable and how much headroom remains?

Exact replay establishes deterministic equivalence. It is not a causal control.

Use `AblationPlan` for causal interventions. Typed validation checks the intervention stage
and node capabilities. An inapplicable intervention must fail before evaluation.

## Separate seed stages

Keep these ledgers disjoint:

- conformance;
- calibration;
- tuning or training;
- variance pilot;
- confirmation;
- robustness.

Within a paired block, share declared nuisance randomisation across conditions. Record
separate streams for topology, node state, world layout, body state, task randomness, and
mechanism noise when applicable.

Declare the smallest meaningful effect before confirmation. Estimate paired variance on
fresh pilot blocks and plan the number of independent blocks prospectively. Resample
blocks, not nested agents or ticks. A no-effect claim needs an equivalence margin and a
prespecified equivalence procedure.

## Report operation results

For task performance, report:

- outcome key;
- raw score;
- normalised score when used;
- blocks and trials per block;
- construction scope and reset;
- horizon and warm-up;
- root seed and stream policy;
- missing, failed, and excluded trials.

For sweeps, report development cells rather than an optimum unless a selected cell has
fresh held-out evaluation. For evolution, retain the candidate history and report champion
selection separately from held-out performance. For benchmarks, keep tasks separate and
report paired within-task contrasts.

## Promotion requirements

A promoted study needs:

- frozen protocol and analysis plan;
- resolved configuration;
- full Git SHA and dirty-worktree state;
- Julia and project-environment provenance;
- seed ledger with overlap checks;
- per-block data and declared contrasts;
- inferential unit and failure policy;
- analysis version;
- machine-readable summary;
- figure inputs and representative-selection rule;
- checksums;
- immutable external archive identifiers for data not stored in Git.

The operation record supplies much of this provenance. Promotion still requires scientific
review of the protocol and interpretation.

Software readiness is independent of experiment evidence. An integrated component may lack
construct validity. A confirmed experiment may use a small stable implementation. Report
both states.

The public guide is `site/src/content/docs/core/design-study.mdx`. Current protocol bundles
live under `experiments/`; generated operation records live under the selected records
root.
