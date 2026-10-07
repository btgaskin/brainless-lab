# Contributing to BrainlessLab

Work in the active Python and Quadrants implementation. Historical Julia software and its original research protocols remain available at [revision d0fc756d](https://github.com/btgaskin/brainless-lab/tree/d0fc756d).

## Set up the locked environment

```bash
uv sync --locked --group dev
uv run brainlesslab check python/plans/delayed-cue.toml
```

The check command should resolve a declared composition and protocol without advancing a world. Read [AGENTS.md](AGENTS.md) and both maintained project skills before changing the implementation.

## Make a reviewable change

1. Inspect the branch, worktree and dirty files. Preserve unrelated work.
2. Use a small contract test to reproduce the problem.
3. Keep model construction, scientific specifications, placement, runtime buffers and offline analysis separate.
4. Preserve destination/source matrix orientation, stable identities and owned snapshots.
5. Warm a kernel before measuring its steady-state cost. Record compilation separately.
6. Run the relevant tests and update the public guide when its contract changes.

```bash
uv run pytest
uv run ruff check python
uv run pyright
uv build
cd site
bun test
bun run build
```

CPU64 equation agreement, immutable Julia fixtures, CPU32 checks and Metal32 qualification are separate gates. Passing one does not imply another. The CI matrix has explicit CPU architecture jobs; record actual receipts before claiming those platforms are qualified.

## Preserve study evidence

A task score operationalises that task. A diagnostic decoder does not replace the native outcome or drive the controller. Ticks and agents within one world are not independent replicates. Keep training, tuning, calibration and confirmation seed partitions disjoint.

Do not inspect sealed evaluation data for implementation or debugging. Do not edit accepted contribution directories, benchmark tables or fidelity fixtures to accommodate a rewrite. Only a human maintainer accepts research contributions. Historical contributor/replay pairs retain linked roles and are not extra independent results.

A new Python record makes a run inspectable. It does not transfer historical validation, confirm a development observation or establish a biological interpretation. Current limitations belong in [the platform guide](site/src/content/docs/platform-limits.mdx).

## Handoff

Explain the resulting behaviour, exact checks, numerical policy and any measured performance. Keep software conformance, observed task performance and study evidence distinct. Report missing backend or architecture receipts explicitly. See [the implementation exercises](docs/python/learning.md) for profiling and compiler inspection.
