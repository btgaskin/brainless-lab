# Historical implementation

[Version history](site/src/content/docs/legacy.mdx) retains the earlier source revision,
checkout commands, migration details and validation boundary.

The maintained source is `python/src/brainlesslab/`; its version 4 plans live under
`python/plans/`.

Independent reference data remain unchanged under `test/fixtures/`.
`experiments/`, `benchmarks/` and `research/` retain their historical plans,
tables, source revisions and evidence status. They require their declared
historical implementation. The Python rewrite neither reruns nor promotes them.
No accepted contribution directory is changed.

Historical reproduction requires each protocol's declared source revision.
Current development uses the Python CPU and site workflow.

Python records may be inspected without importing the historical runtime.
They do not migrate old protocols or checkpoint state. Use the
[current architecture](docs/python/architecture.md) and
[implementation exercises](docs/python/learning.md) for the successor.
