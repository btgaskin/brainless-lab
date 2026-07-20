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

- `:falandays_base` is the fixture-validated baseline. Do not change its behavior, fixtures,
  or fidelity language to make another change pass.
- Everything outside that baseline is experimental unless evidence says otherwise.
- A task score operationalizes performance on that task. It is not, by itself, evidence of
  cognition, general capability, biological fidelity, or external validity.
- Never present development seeds, tuned cells, representative runs, or exploratory plots
  as sealed evidence.
- Do not inspect a sealed evaluation set to answer a planning or debugging question.
- Use the independent randomized block or trial as the inferential unit. Agents and ticks
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
   public surface changes.
9. Report what is verified, what is inferred, and what remains experimental.

## Choose the narrowest extension

| Intent | Preferred seam |
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

Use the evidence ladder in `site/src/content/docs/research-workflow.mdx`:

conformance → calibration → exploration → tuning/training → variance pilot → frozen
protocol → sealed confirmation → robustness → promoted evidence.

For causal comparisons, share randomized worlds within a paired block while giving distinct
mechanisms their declared streams. Keep training, selection, variance-pilot, confirmation,
and robustness seeds disjoint. The null must match the claim: random action, blind input,
shifted or sham input, an ablation, a baseline model, and an oracle answer different
questions.

## Verification

For Julia changes:

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

Also run focused contract tests while iterating. For hot paths, warm the call before checking
inference or allocations. Fixture parity is a separate gate from behavioral performance.

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
- README, site, examples, and both skills use the same vocabulary.

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
