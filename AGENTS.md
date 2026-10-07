# Working on BrainlessLab with an agent

BrainlessLab is an experimental research platform. Preserve software and scientific safeguards while making it easier to use.

## Read the maintained guidance

Before changing BrainlessLab code, read `skills/brainless-lab/SKILL.md` in full. `.agents/skills/brainless-lab` points to this checked-in file. Use the current worktree; do not install independent global copies.

The active implementation is Python and Quadrants under `python/src/brainlesslab/`. Read `docs/python/README.md` and only relevant references. [Version history](site/src/content/docs/legacy.mdx) locates the earlier implementation. Its protocols and accepted records retain their original source revisions.

## Preserve the scientific boundary

- Historical Falandays validation covers declared reference trajectories at their recorded source revision. Do not change its fixtures or language to make the rewrite pass.
- Python equation conformance, historical fixture parity, backend qualification and observed task performance are separate evidence.
- A task score operationalises one task. It does not establish cognition, general capability, biological fidelity or external validity.
- Use `task_outcome` and retain the outcome key, raw value, normalised value, scoring window and calibration status. Other fields remain diagnostics.
- Null-adjusted scores may be negative. Do not clip them. Task upper bounds are not implemented oracles.
- Diagnostic probe labels belong to offline analysis and must never reach the online controller.
- Never inspect sealed evaluation data for planning, implementation or debugging.
- Never present development seeds, selected cells or website recordings as sealed evidence.
- Use independent randomised blocks or trials as inferential units. Agents and ticks within one world are not extra replicates.

## Work safely

1. Inspect the branch, worktree and dirty files before editing. Preserve user changes.
2. Use an isolated worktree for broad or parallel work.
3. State the outcome and checks. Use `apply_patch` for hand edits and avoid destructive Git commands.
4. Keep scientific specifications independent of placement, memory budgets and device buffers.
5. Use canonical destination/source matrices, stable entity and feature IDs, owned snapshots and explicit random streams.
6. Keep fixed ndarray ranks and runtime batch/node dimensions. Use ordered destination-owned sums without floating-point atomics.
7. Run focused tests first, then package and site gates for public changes.
8. Report verified, inferred, unqualified and experimental results separately.

## Keep readiness separate from study evidence

The active website guide lives under `site/src/content/docs/`. Historical pages are labelled and linked to their source revision. `available` describes software capability, not a biological interpretation or accepted study.

`Plan` records a scientific question, version, named targets, operation and evidence state. It does not create another operation-specific schema. Construction and scientific randomness belong to declared specifications and seed partitions. `ExecutionSpec` controls backend, batch size, memory and recording. These execution choices must not silently alter a protocol.

Keep calibration, training, tuning, variance-pilot, confirmation and robustness seeds disjoint. Paired conditions share declared world streams while distinct mechanisms retain declared streams. Choose a null that answers the claim: random action, blind input, shifted/sham input and ablation answer different questions.

Offline probe decoding requires one fixed wiring per independent block and full trial resets. Split whole trials. Fit scaling on fit trials only; tune on validation only. Evaluation labels stay untouched by the permutation null. Ticks and observation points never create additional independent samples.

Calibration signatures include task options, initialisation, scored horizon, warm-up, action cadence, numerical/RNG policy and world-source hashes. They exclude reservoir kind, count, topology and input gain. Use exactly 1,024 independent trajectories for empirical calibration. Propagate model-block and calibration-trajectory uncertainty independently. Do not drop bootstrap draws with invalid denominators.

## Preserve research records

Query `research/catalogue.json` first for accepted public runs. Follow its paths to submitted plans, resolved configurations, seeds, trial tables, summaries and reports. Filter within matching experiment, version, operation, task, node and protocol settings.

Treat maintainer replay as a linked reproduction check, not another independent result. Only a human maintainer accepts contributions. Never modify accepted contribution directories. Preserve historical experiment bundles, benchmark tables and source references. A new complete Python record does not promote or rerun historical evidence.

## Verification

```bash
uv sync --locked --group dev
uv run pytest
uv run ruff check python
uv run pyright
uv build
cd site
bun test
bun run build
```

Warm kernels before timing. Separate compilation, transfer, runtime and recording costs. Check exports, executable examples, deterministic streams, reset/ownership, batch independence and `git diff --check` for public changes. Match README, site and project skills to implemented vocabulary. CPU64 is the reference arithmetic policy; Metal32 and each CPU architecture require explicit qualification receipts. CI configuration alone is not a passed receipt.

## Documentation

Follow `docs/WRITING.md`: British English, stable terms, plain instructions and minimal decorative emphasis. Explain the question, minimum command, expected output, success check, permitted conclusion and next step. Keep unsupported capabilities visible in `site/src/content/docs/platform-limits.mdx`. Do not describe future checkpointing, autodiff, registries or backend tooling as implemented.
