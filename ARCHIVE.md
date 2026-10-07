# Historical Julia implementation

The complete Julia implementation is preserved at revision `d0fc756d` and local tag
`julia-v0.3-final`. Use that revision in a separate checkout to reproduce historical
programmes, broad reservoirs, bodies, evolution, CLI plans and Julia tests.

```bash
git worktree add ../brainlesslab-julia-history d0fc756d4efe23abbad79314574beb0d3500de61
cd ../brainlesslab-julia-history
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The active branch removes the Julia runtime, extensions, runner, old examples and
operational tools. Its maintained source is `python/src/brainlesslab/`; its fresh
version 4 plans live under `python/plans/`.

Independent reference data remain unchanged under `test/fixtures/`.
`experiments/`, `benchmarks/` and `research/` retain their historical plans,
tables, source revisions and evidence status. They require their declared
historical implementation. The Python rewrite neither reruns nor promotes them.
No accepted contribution directory is changed.

The historical Julia workflow is manual and checks out the selected source.
The merged-protocol reproduction workflow likewise requires the original
Julia revision. Current development uses the Python CPU and site workflow.

Python records may be inspected without importing the historical runtime.
They do not migrate old protocols or checkpoint state. Use the
[current architecture](docs/python/architecture.md) and
[implementation exercises](docs/python/learning.md) for the successor.
