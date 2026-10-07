# Active Python implementation

The [architecture ontology](architecture.md) describes responsibilities and
runtime boundaries. [ARCHIVE.md](../../ARCHIVE.md) locates historical capabilities.
The [local qualification receipts](qualification/README.md) record the package,
backend, calibration and website checks.

Use the [first-run guide](../../site/src/content/docs/tutorials/first-simulation.mdx) to resolve and run the locked example. The package lives under `python/src/brainlesslab/`; historical Julia source is preserved at Git revision `d0fc756d`.

The public layers are `NodeSpec`, `TaskSpec`, `CompositionSpec`, `EvaluationSpec`, `EvaluationTarget`, `Plan`, `NumericalPolicy` and `ExecutionSpec`. Scientific specifications are immutable host values. Execution policy owns placement and memory budgets. The runtime owns Quadrants arrays; snapshots own their host storage.

Models use canonical `[destination, source]` matrices. Ordered destination-owned sums avoid floating-point atomics. Batch and node dimensions are runtime values with fixed array ranks. Inspect [learning.md](learning.md) for exercises that verify these choices.

Raw outcomes keep their native task units. A calibrated adjustment subtracts the task-matched null mean and divides by remaining opportunity. It can be negative. Calibration signatures include task options, initialisation, scored horizon, warm-up, action cadence, numerical/RNG policies and world-source hashes. They exclude reservoir kind, topology, count and input gain.

Offline probe decoding remains a diagnostic. Use one fixed wiring per independent block and full trial resets. Default splits use 256 fit, 128 validation and 256 evaluation trials. Scale features from fit trials only. Tune ridge regularisation on validation trials only. Evaluate against unchanged labels, including the fit/validation permutation null. Shared splits across cue_end, delay_end and response prevent event leakage.

The recorded website reads generated Quadrants development frames. It does not run neural or world equations in TypeScript. See [platform limits](../../site/src/content/docs/platform-limits.mdx) for qualifications and deliberately unsupported capabilities.
