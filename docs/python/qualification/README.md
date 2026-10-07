# Local implementation qualification

These receipts describe the Python rewrite checked on 7 October 2026. The host was
macOS arm64 with Python 3.12.13 and Quadrants 1.3.3, build `00423caa`, LLVM 22.1.0.
They establish software behaviour on this host. They do not qualify other machines,
promote historical studies or demonstrate learning.

## What passed

| Check | Result | Receipt |
| --- | --- | --- |
| CPU64 package suite | 182 tests passed, including an installed wheel | [software.json](software.json) |
| Ruff and Pyright | Lint and formatting passed; no type errors or warnings | [software.json](software.json) |
| CPU32 versus Metal32 | 637 snapshots; maximum absolute difference 0.00000190735 | [backend-conformance.json](backend-conformance.json) |
| Fused reference controllers | Exact state and frame-ledger parity for 55 policies and 27 staged failures on Metal32 | [software.json](software.json) |
| Both core plans | 32 completed, calibrated trials and four paired contrasts per node | [runtime.json](runtime.json) |
| Sparse-event decoding | Two independent wiring blocks per node; six results per node | [runtime.json](runtime.json) |
| Capacity authoring | All 64 plans per node resolved; trajectories were not executed | [runtime.json](runtime.json) |
| Recorded website | Eight tests, type check and 58-page build passed; desktop and phone inspection completed | [software.json](software.json) |

Falandays tests compare independent equations and the three unchanged 40-step reference
fixtures. The authors-source fixture is an independent transcription, not an
author-produced artefact. These checks preserve the declared trajectory boundary;
they do not transfer historical behavioural evidence. SORN has its own independent
equation and state-transition checks.

Backend conformance covers short injected trajectories, reset, frozen adaptation,
inactive slots and all ten task families. Float comparisons use absolute and relative
tolerances of 0.00002. Integer and declared discrete states use exact comparison.
It does not establish long-run bit equality. Metal does not support the compiler's
out-of-bounds checking mode; host validation and parity checks remain active.

The runtime decoder check uses 16 fit, eight validation and eight evaluation trials per
block. This is a bounded software diagnostic. The default research diagnostic retains
256/128/256 whole-trial splits. Neither check establishes learning or cognition.
Output names in `runtime.json` identify local verification artefacts, which are not
bundled here. Fresh runs write their own complete records.

## Task null calibrations

The [CPU receipt](cpu-calibration-receipt.json) and
[Metal receipt](metal-calibration-receipt.json) each cover Tracking, Pong and
CartPole. Each frozen calibration contains 1,024 unique independent trajectories.
The three CPU sets contain 3,072 mutually disjoint world identities. Core evaluation
worlds are also disjoint from those calibration worlds.

Full scores, identities, uncertainty and content hashes are retained in
[`calibrations/`](calibrations/). The signature binds task defaults, timing, numerical
policy, backend, runtime build and relevant source hashes. Reuse is accepted only when
these values match. Other platforms or changed world code need fresh calibration.

Run the core CPU plan with these records when the signature matches:

```bash
uv run brainlesslab run python/plans/falandays-core.toml --root records \
  --calibration docs/python/qualification/calibrations/cpu-tracking.json \
  --calibration docs/python/qualification/calibrations/cpu-pong.json \
  --calibration docs/python/qualification/calibrations/cpu-cartpole_plank_easy.json
```

Use `python/plans/sorn-core.toml` for SORN. Both plans share declared world streams
with their task nulls. A complete record retains raw and signed null-adjusted outcomes.
It remains development evidence.

## Compilation and timing

The [profile receipt](backend-profile.json) separates a cold cache, a warm cache in
a new process and warm execution for an eight-world, 256-node Falandays probe.
Both backends retained the same kernel count when runtime scalars and dimensions
changed. Changing a declared static mode added exactly one compiled specialisation.

Background processes were observed and the diagnostic opt-in was recorded. These
wall times are not a reliable CPU/GPU throughput comparison. No fixed speedup is
claimed. Use the [profiling exercises](../learning.md) for a controlled measurement.

The maintained engine has 5,185 nonblank Python lines in 19 modules. The earlier implementation's
`src/` and `ext/` contained 38,273 nonblank lines in 97 files: an 86.5% reduction.
The new capability scope is narrower. This is not feature equivalence or a measure
of algorithmic speed. [ARCHIVE.md](../../../ARCHIVE.md) locates the complete predecessor.

## Repeat the checks

```bash
uv sync --locked --group dev
uv build
BRAINLESSLAB_TEST_WHEEL=dist/brainlesslab-0.4.0-py3-none-any.whl uv run pytest
uv run ruff check python
uv run ruff format --check python
uv run pyright
uv run python python/examples/qualify_backends.py fresh-conformance
```

The last command requires an Apple host with Metal access. Run GPU jobs serially.
Follow [the architecture](../architecture.md) for responsibility boundaries and
[the upstream reproduction](../upstream/README.md) for the isolated Quadrants issue.
Configured Windows and Linux CI jobs remain unqualified until actual runs pass.
