# Working on BrainlessLab with an agent

BrainlessLab is an experimental research platform. An agent should make it easier to use
without weakening its scientific or software safeguards.

## Begin with the repository's own guidance

Before changing Julia or BrainlessLab code, read these files in full:

- `skills/brainless-lab/SKILL.md`
- `skills/julia/SKILL.md`

Then read only the linked references that match the task. Treat checked-in code, tests,
configs, and immutable run artifacts as the source of truth. The website is the
human-readable guide; update it when the public contract changes.

## Preserve the scientific boundary

- `:falandays` is the canonical node validated on declared reference trajectories. Do not
  change its behaviour, fixtures, or validation language to make another change pass.
- Each other node, task, analysis, and component has its own declared stability and
  readiness. Do not inherit the Falandays validation boundary.
- A task score operationalizes performance on that task. It is not, by itself, evidence of
  cognition, general capability, biological fidelity, or external validity.
- Use `task_outcome(sim)` for the task-declared outcome. Report its key, raw value, and
  normalised value together; `nothing` means the task declares no scalar objective. Treat
  other metric fields as diagnostics unless the task contract says otherwise.
- Never present development seeds, tuned cells, representative runs, or exploratory plots
  as sealed evidence.
- Do not inspect a sealed evaluation set to answer a planning or debugging question.
- Use the independent randomised block or trial as the inferential unit. Agents and ticks
  within one world do not create additional independent samples.

## Work safely

1. Inspect the current branch, worktree, and dirty files before editing.
2. Preserve user changes. Use a separate worktree for broad or parallel work.
3. State the intended outcome and the checks that will establish it.
4. Prefer public interfaces and composed values over concrete-type branches.
5. Keep the homogeneous runtime fast path and use function barriers for heterogeneous groups.
6. Use stable component and entity IDs; do not infer identity from tuple or vector position.
7. Use `apply_patch` for hand edits. Avoid destructive Git commands.
8. Run the narrowest relevant tests first, then the full package and site gates when the
   public interface changes.
9. Report what is verified, what is inferred, and what remains experimental.

## Keep software readiness separate from study evidence

- The public guide lives under `site/src/content/docs/`. Core pages document the main
  composition and research interfaces.
- Experimental capabilities are listed under `site/src/content/docs/experimental/` with
  repository-backed source, example, and test metadata.
- `available` and `integrated` describe software readiness. They do not validate a
  biological interpretation, promote a study, or increase its evidence status.
- Experiment evidence (`planned`, `exploratory`, `tuned`, `frozen`, `confirmed`,
  `promoted`, or `retired`) belongs to the versioned `ExperimentSpec` and its records. It
  is independent of component readiness.

## Choose the narrowest extension

| Intent | Preferred approach |
| --- | --- |
| Change parameters of an existing reservoir | config or registered preset |
| Add a genuinely different neural substrate | `Reservoir` methods plus node registration |
| Reuse a body design | component TOML and `Embodiment` |
| Add sensing or actuation | the narrow sensor, encoder, actuator, dynamics, geometry, or physiology interface |
| Add a vector task | `TaskWorld` plus `TaskSpec` |
| Add a physical/ecological task | `Embodiment` plus `ObjectWorld` plus `TaskSpec` |
| Add a task result | `metrics(environment, window)` |
| Add a reusable measure | a pure analysis function plus analysis registration |
| Test a causal mechanism | intervention/ablation and an appropriate control |
| Search parameters | development-only sweep, training, or evolution; freeze before confirmation |

Registries provide discovery and configuration by name. Ordinary Julia dispatch and direct
composition remain public; do not add a registry merely to avoid defining a clear type or
method.

## Research workflow

Use the evidence ladder in `site/src/content/docs/core/design-study.mdx`:

conformance → calibration → exploration → tuning/training → variance pilot → frozen
protocol → sealed confirmation → robustness → promoted evidence.

For causal comparisons, share randomised worlds within a paired block while giving distinct
mechanisms their declared streams. Keep training, selection, variance-pilot, confirmation,
and robustness seeds disjoint. The null must match the claim: random action, blind input,
shifted or sham input, an ablation, a baseline model, and an oracle answer different
questions.

Use an `ExperimentSpec` when a study needs a stable question, version, named conditions,
limitations, and one or more operations. Keep these bundles under `experiments/`. Do not
revive the archived bespoke experiment runner or add another operation-specific schema.

## Verification

For Julia changes:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Also run focused contract tests while iterating. For hot paths, warm the call before checking
inference or allocations. Fixture parity is a separate gate from behavioural performance.

For site changes:

```bash
cd site
bun run build
```

For public changes, also check:

- exported names resolve;
- `Test.detect_ambiguities(BrainlessLab; recursive=true)` has no new ambiguity;
- examples referenced by docs execute;
- no absolute local paths or retired study references remain;
- README, site, examples, and both skills use the same vocabulary;
- canonical Core routes and Experimental feature metadata resolve.

## Documentation standard

Write for a reader who may know neither Julia nor experimental simulation. Lead with why and
what the user can accomplish; introduce exact types and commands only when needed. Every
guide should say:

- what question the operation answers;
- the minimum safe command or configuration;
- what output to expect;
- how to tell whether it worked;
- what may not be concluded;
- where to go next.

Do not describe planned automation as implemented. Keep current limits visible and link to
`site/src/content/docs/platform-limits.mdx`.

Follow `docs/WRITING.md`: use British English, stable technical terms, soft-STE sentence
control, and minimal decorative emphasis.
