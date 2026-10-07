# Draft: stale ndarray reads through aliased frozen dataclass arguments

Local review only; do not post without maintainer approval.

On Quadrants 1.3.3, two typed frozen Python dataclass arguments may contain the
same ndarray. In a serial loop, a helper reads through one argument and another
helper writes through the other. The read stays at its initial value. Reading
through the canonical writer argument returns the expected changing values.

The attached standalone `ndarray_aliasing.py` has no application dependencies.
It launches two worlds in parallel, with four serial ticks per world. Each
world exclusively owns its ndarray element. There is no cross-thread sharing,
out-of-bounds index, float atomic, rebinding, or fastcache requirement.

Expected columns: `[0, 1, 2, 3]`.
Observed alias-path columns: `[0, 0, 0, 0]`.
Observed canonical-path columns: `[0, 1, 2, 3]`.

This reproduces with `fast_math=False`, `enable_fallback=False`, `debug=True`
and fresh processes on CPU float64, CPU float32 and Metal float32. Environment:
macOS arm64, Python 3.12.13, Quadrants wheel 1.3.3, reported build commit
`00423caa`, LLVM 22.1.0. Metal notes that bounds checking is unsupported.
`results.json` contains the local comparison receipt.

Could you confirm the supported contract for identical ndarray storage across
kernel arguments, including flattened dataclass members? The compound-type
guide describes frozen ndarray containers and read-write indexing. I found no
general no-alias requirement in the user guide at upstream reference
`47e9dfb5bc527e607519d11e530519c6493fb9e7`.

At that reference, external pointers with different argument IDs are classified
as different storage in `quadrants/analysis/alias_analysis.cpp`. This appears
consistent with the load being treated as invariant, but the wheel's source
revision was unavailable locally, so this is an inference rather than a
confirmed compiler diagnosis.

Proposed acceptance requirements:

- Sequential reads observe preceding writes when arguments refer to the same
  ndarray, including frozen container members and calls through `@qd.func`.
- If this alias pattern is intentionally unsupported, document the restriction
  and reject it at launch rather than returning a stale result silently.
- Add regression coverage for aliasing and distinct storage, canonical access,
  scalar and ndarray indices, and repeated launches with changed argument
  identities. Preserve runtime ranks/shapes and cache-key correctness.
- Exercise CPU float64/float32 and Metal float32 where available. CUDA and
  other backends remain untested by this report.

Current workaround: use one canonical ndarray argument path throughout a fused
kernel. Pass mutable cursors as scalar helper arguments read from that path,
and pass the canonical output ndarray explicitly. In fusion, return the updated
finite status explicitly from a helper and use that scalar to guard the next
operation, rather than relying on a bundle reload after the helper writes it.
Individual kernel launches also avoid the within-loop stale-read case in our
application tests.
