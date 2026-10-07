# Learn the implementation

Use these exercises to connect a software question with an observable result.
Start with the locked development environment. Numerical and timing evidence remain
separate from learning or biological claims.

## 1. Explain an update before optimising it

```bash
uv sync --locked --group dev
uv run pytest python/tests/test_falandays.py python/tests/test_sorn.py
```

Read the independent NumPy equations beside the Quadrants kernels. Follow old-state
inputs, destination/source orientation, threshold equality and plasticity order.
Predict a toy update before running it. Preserve immutable reference fixtures.

The tests should pass. They establish their declared equation and state-transition
boundary; they do not establish performance on a new task.

## 2. Follow scientific identity through batching

```bash
uv run pytest python/tests/test_specs_random.py python/tests/test_evaluation.py
```

Compare world, wiring and mechanism IDs across batch partitions. Explain why a display
label or physical device slot cannot define a random stream. Follow full reset,
inactive worlds, early termination and permanent numerical-failure masks.

Expect the same declared scientific work across supported batch partitions.
Ticks and nodes still do not become independent replications.

## 3. Inspect compilation and cache reuse

```bash
uv run pytest python/tests/test_compilation.py
```

Follow the frozen ndarray bundle fields and static family/mode choices. Change array
dimensions or runtime scalar values in a copied toy example. Compare compiled counts
with a static-mode change. Counts detect specialisation; they do not prove a cache hit.

For compiler IR, use a separate scratch process and the installed Quadrants diagnostics.
The [official guide](https://genesis-embodied-ai.github.io/quadrants/user_guide/index.html)
describes supported options. Preserve runtime version, precision and backend.

## 4. Measure a complete workload

Use the [performance guide](performance.md). It separates an empty application cache,
a populated cache in a fresh process and repeated warmed evaluation. Keep trial count
fixed when changing batch capacity, synchronise timing boundaries and inspect actual
work counts. Use py-spy for host stacks and Instruments for this Mac's native/Metal work.

Collect unprofiled timings separately from traces. A profiler can identify a cause
without producing an unbiased throughput measurement. Additional backends need their
own numerical qualification before their profiling tools become relevant.

## 5. Make a result portable

```bash
uv build
BRAINLESSLAB_TEST_WHEEL=dist/brainlesslab-0.4.0-py3-none-any.whl uv run pytest python/tests/test_records.py
```

Inspect the submitted/resolved plan, seed table, trial rows, source archive, lock and
checksums in a new record. Read the installed-wheel test. Explain which inputs another
machine needs to repeat the run. A portable record is not a resumable device checkpoint.

## 6. Reduce a compiler issue

```bash
uv run python docs/python/upstream/ndarray_aliasing.py --backend cpu --dtype float64
```

This example imports Quadrants without BrainlessLab. Compare the two argument paths
against the expected array. Read the [issue draft](upstream/issue-draft.md), which states
the measured version, workaround and limits of the proposed explanation.

The draft has not been submitted upstream. A useful contribution needs a minimal
reproducer, a precise expected contract, a regression test and maintainer agreement.
Keep issue triage, local fixes and accepted contributions distinct.
