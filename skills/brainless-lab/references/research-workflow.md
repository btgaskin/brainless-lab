# Research Workflow

Use this reference whenever a request moves beyond mechanism conformance into tuning,
comparison, or a scientific claim.

## Evidence ladder

1. **Conformance:** component equations, geometry, ports, reset, replay, and RNG ownership.
2. **Calibration:** static/random/blind/oracle policies establish task opportunity and
   timescales.
3. **Exploration:** inspect behavior and failure modes; generate hypotheses.
4. **Tuning/training:** select parameters or genomes on development-only worlds.
5. **Variance pilot:** estimate paired variability on fresh blocks for sample-size planning.
6. **Frozen protocol:** fix conditions, endpoints, exclusions, analysis, and stopping rule.
7. **Sealed confirmation:** execute once on untouched independent blocks.
8. **Robustness:** test declared perturbations without rewriting the primary result.
9. **Promotion:** bundle protocol, code/environment provenance, seeds, data, analysis, and
   figures immutably.

Looking at sealed outcomes and then changing a parameter, endpoint, exclusion, or analysis
returns the study to development.

## Units and controls

Name tick, agent, run, condition, sweep cell, paired block, seed, and independent unit.
Agents and ticks within one world are not automatically independent samples.

Choose the null from the claim:

- static/no-action: does action help?
- random action: above this task/body/action floor?
- blind/off: is the channel necessary relative to zero input?
- matched sham, shift, or yoke: does timing/direction/information matter at matched dose?
- mechanism ablation: is the mechanism necessary?
- model baseline: does the candidate differ from the declared reference?
- oracle/reference: is the task solvable and how much headroom remains?

Exact replay establishes deterministic equivalence; it is not a causal null.

## Seed stages and power

Keep conformance, tuning/training, variance-pilot, confirmation, and robustness seed
ledgers disjoint. Within a paired block, share declared nuisance randomization across
conditions. Record independent streams for topology, initial state, world layout, agent
pose, mechanism noise, and endogenous drive as applicable.

Declare a smallest meaningful effect. Estimate paired variance on fresh pilot blocks and
plan the number of independent blocks prospectively. Resample blocks, not nested agents or
ticks. Retrospective achieved power does not certify confirmation. A no-effect claim needs
a declared equivalence margin and equivalence procedure.

## Promotion bundle

Require frozen protocol/analysis, resolved config, full SHA and dirty flag, Julia and
Project/Manifest hashes, seed ledger and overlap check, per-block data, contrasts,
inferential unit, failure/exclusion policy, analysis version, schema-versioned summary,
figure inputs, representative-selection rule, checksums, and immutable external archive
hashes where needed.

The canonical prose is `site/src/content/docs/research-workflow.mdx`.
