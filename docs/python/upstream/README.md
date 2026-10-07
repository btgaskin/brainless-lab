# Quadrants ndarray alias diagnostic

This directory contains a local reproduction and an issue draft for maintainer
review. Nothing has been posted upstream.

Two frozen Python dataclasses contain the same `qd.ndarray` object. Within one
world's serial loop, a helper reads through the second dataclass and another
helper increments through the first. Four reads should produce `0, 1, 2, 3`.
The installed Quadrants 1.3.3 wheel returns `0, 0, 0, 0`. Reading through the
same canonical ndarray path as the writer returns the expected sequence.

Run each configuration in a fresh process:

```bash
uv run python docs/python/upstream/ndarray_aliasing.py --backend cpu --dtype float64
uv run python docs/python/upstream/ndarray_aliasing.py --backend cpu --dtype float32
uv run python docs/python/upstream/ndarray_aliasing.py --backend metal --dtype float32
```

The last command needs an Apple host with Metal access. Run GPU tests serially.
The script prints environment information, expected and actual arrays, and
comparison flags. It does not import BrainlessLab or inspect research records.
The committed [results](results.json) are local software diagnostics on an
arm64 macOS host, not qualification of another platform or empirical task
performance. Metal reports that bounds checking is unavailable even with
`debug=True`; this example uses fixed valid indices.

The local upstream reference `47e9dfb5bc527e607519d11e530519c6493fb9e7` documents
Python dataclasses containing ndarrays, frozen kernel arguments, and read-write
tensor member indexing. A search of its user guide found no general prohibition
on shared ndarray storage between arguments. Its scan algorithm separately
prohibits in-place input/output aliasing. This review does not establish that
every possible aliasing arrangement is supported.

The same reference's `quadrants/analysis/alias_analysis.cpp` classifies external
pointers with different argument IDs as different storage. That is consistent
with the observed stale loads, but remains a causal inference: the installed
wheel reports commit `00423caa`, which is unavailable in the local source
checkout. No upstream compiler change has been made or tested here.

BrainlessLab avoids the observed case by passing one canonical input/output
array path to each fused helper and passing tick/round cursors as scalars. The
helpers also return mutable finite status explicitly, so callers can filter
the current frame without rereading a second bundle view after a helper write.
The full-state controller fusion test compares this path against individual kernel
launches for all ten task families and their declared controls in fresh CPU
float64 and float32 processes. Reversal rounds exercise the stale-cursor
regression. See [the local issue draft](issue-draft.md) for a proposed upstream
contract and regression test.
