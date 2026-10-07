# Contributing to BrainlessLab

Work on the Python and Quadrants implementation. Read [AGENTS.md](AGENTS.md) and the
small project-local [skill](skills/brainless-lab/SKILL.md). The public guide documents
the current contract; source, tests and immutable records establish what it implements.

## Set up and resolve a plan

```bash
uv sync --locked --group dev
uv run brainlesslab check python/plans/delayed-cue.toml
```

The check resolves model defaults, task options, ports and timing without advancing
a world. Use a small development plan to reproduce an issue. Preserve unrelated
dirty files and use an isolated worktree for broad or parallel work.

## Make one reviewable change

Keep scientific specifications, execution policy, device buffers and offline analysis
separate. Use stable IDs, destination/source matrices, synchronous updates, owned
snapshots and complete reset. Preserve per-frame failure masks and deterministic streams.

Use the existing narrow model, task or analysis module. There is no general plugin
registry. Update the guide when commands, outputs or supported scope change.
Add tests for the failing contract and run the smallest relevant checks first.

For a public change:

```bash
uv build
BRAINLESSLAB_TEST_WHEEL=dist/brainlesslab-0.4.0-py3-none-any.whl uv run pytest
uv run ruff check python
uv run ruff format --check python
uv run pyright
cd site
bun test
bun run typecheck
bun run build
```

Check `git diff --check` and execute referenced examples. Configured architecture jobs
need actual CI receipts before their platforms are called qualified.
Use the [0.4.0 publication checklist](docs/python/release.md) to prepare a release.

## Report performance with enough context

Follow the [performance protocol](docs/python/performance.md). Keep precision, trial
identities and recording fixed across execution comparisons. Retain repeated samples,
actual completed work, failed trials, admitted batch capacity and host conditions.
Separate compilation, warmed evaluation, recording and tracing.

Warm evaluation includes construction and summaries. Process RSS is not VRAM.
A noisy diagnostic, a compiler count or a faster random-action kernel does not establish
a reservoir speedup. Use a minimal standalone reproduction for a Quadrants issue.

## Preserve research evidence

Do not inspect sealed data for implementation or debugging. Do not edit accepted
contributions, benchmark tables or reference fixtures to accommodate a code change.
Keep calibration, selection and confirmation worlds disjoint. Blocks or trials are
the inferential units; their ticks and neurons are not extra samples.

Only a human maintainer accepts research contributions. A linked maintainer replay
is reproduction, not independent evidence. Historical records retain their source
revisions through [ARCHIVE.md](ARCHIVE.md).

In the handoff, state resulting behaviour, checks, numerical policy, measured
performance and remaining limits. Keep software conformance, task behaviour and
scientific evidence distinct. Continue with [implementation exercises](docs/python/learning.md).
