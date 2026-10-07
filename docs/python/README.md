# Python implementation

BrainlessLab couples a locally adapting neural reservoir to a declared task.
NumPy constructs models and analyses results. Quadrants advances neural and world
state in bounded batches on CPU or Metal.

Use the [first-run guide](../../site/src/content/docs/tutorials/first-simulation.mdx)
for a complete small evaluation. The package lives under `python/src/brainlesslab/`.

## Read the part you need

| Question | Reference |
| --- | --- |
| Who owns scientific identity, timing and device state? | [Architecture ontology](architecture.md) |
| How do I learn the compiler and tooling? | [Implementation exercises](learning.md) |
| How do I measure latency, throughput and memory? | [Performance protocol](performance.md) |
| What has actually passed? | [Qualification receipts](qualification/README.md) |
| How do I turn a compiler issue into a contribution? | [Minimal upstream reproduction](upstream/README.md) |

Scientific specifications are immutable host values. `ExecutionSpec` owns placement,
memory budgets, cache and recording. Device batches own state; snapshots own their
host storage. Stable scientific keys are independent of batch slots and display labels.

Models use `[destination, source]` matrices and ordered destination-owned sums.
Array ranks remain fixed; node and batch dimensions are runtime values.

Raw outcomes retain native task units. Matching calibration can supply a signed
null-adjusted value. Sparse offline decoding uses whole-trial splits and fit-only
scaling. Its labels never enter the online controller.

The website reads generated development recordings. It contains no numerical engine.
See [platform limits](../../site/src/content/docs/platform-limits.mdx) for supported
scope and [ARCHIVE.md](../../ARCHIVE.md) for preserved historical evidence.
