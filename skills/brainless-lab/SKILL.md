---
name: brainless-lab
description: Operate and extend the Python and Quadrants BrainlessLab platform while preserving scientific identity, numerical conformance and research evidence.
---

# BrainlessLab

Read the current worktree's `AGENTS.md` before editing. The package is
`python/src/brainlesslab/`; the public guide is `site/src/content/docs/`.
Use this project-local skill. Do not install a second global copy.

## Start small

```bash
uv sync --locked --group dev
uv run brainlesslab check python/plans/delayed-cue.toml
uv run brainlesslab run python/plans/delayed-cue.toml --root records
uv run brainlesslab inspect records/RECORD_ID
```

Use the path printed by `run`. Check resolves without simulation; inspect verifies
checksums. A complete record establishes software execution, not scientific confirmation.

## Keep the core precise

Scientific specifications own model, task, protocol and seed identity.
`ExecutionSpec` owns placement, batch capacity, memory, cache and recording.
Use stable IDs, destination/source matrices, owned snapshots and complete trial reset.
Preserve synchronous updates and permanent per-frame failure masks.
Changing batch capacity or display labels must not change scientific work.

Falandays and SORN have separate equation and conformance boundaries.
Keep immutable fixtures and accepted records unchanged. Never inspect sealed worlds
for planning or debugging. Report task outcome key, raw and normalised value together.
Do not clip negative adjustments or combine task units into a competence score.

Use independent blocks or trials as inferential units. Keep calibration, development
and confirmation worlds disjoint. Offline labels never enter the controller.
Only a human maintainer accepts research contributions.

## Use the maintained guide

| Need | Read |
| --- | --- |
| First run and results | [First simulation](../../site/src/content/docs/tutorials/first-simulation.mdx) |
| Compare conditions | [Comparison guide](../../site/src/content/docs/tutorials/compare-conditions.mdx) |
| Architecture and ownership | [Architecture](../../docs/python/architecture.md) |
| Plans and CLI | [Plan reference](../../site/src/content/docs/reference/plan-format.mdx) |
| Analysis and calibration | [Analysis](../../site/src/content/docs/reference/analysis.mdx) |
| Speed, memory and profiling | [Performance guide](../../site/src/content/docs/python/performance.mdx) |
| Supported scope | [Platform limits](../../site/src/content/docs/platform-limits.mdx) |

Follow `AGENTS.md` for checks and `docs/WRITING.md` for prose. Run focused tests,
execute documented examples and complete package/site gates for public changes.
Inspect activity before timing; match precision and work, run GPU jobs serially,
and retain failures. Warm evaluation is not kernel-only time. RSS is not VRAM.
Report measured results separately from hypotheses and configured CI.
