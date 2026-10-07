# Measure speed and memory

The maintained [performance guide](../../site/src/content/docs/python/performance.mdx)
defines the timing boundaries, fixed-work batch matrix, recording costs, memory units
and profiling tools for the Python implementation.

Start with an explicitly selected float32 CPU diagnostic:

```bash
uv run python python/examples/profile_backend.py scratch-speed-cpu \
  --backends cpu --dtype float32 --node falandays --task delayed_cue \
  --count 64 --batch-size 8 --trials 8 --blocks 2 --samples 7 --warmups 1
```

Use a new destination. Inspect `receipt.json` and worker logs. On an Apple host,
repeat with `--backends cpu metal` in another new directory. Keep total trial count
and seeds fixed across batch capacities; retain actual admitted capacity and completed work.

The tool measures synchronised evaluations, including fresh construction and summaries.
It does not isolate kernel-only stepping. Background-activity opt-in retains a noisy
diagnostic and cannot establish a reliable speedup. The
[qualification receipts](qualification/README.md) remain software evidence on their
declared host, not a throughput comparison.
