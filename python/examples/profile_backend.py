"""Serial, reproducible backend timing receipts with no fixed speed claim.

The parent process measures cold-cache, warm-cache/new-process, and warmed
in-process execution. Each backend gets its own process and cache. Background
compute is reported and requires an explicit opt-in; it is never stopped.
"""

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from pathlib import Path


def background_activity():
    output = subprocess.run(
        ["ps", "-axo", "pid=,comm="], capture_output=True, text=True, check=True
    ).stdout
    suspicious = []
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or int(parts[0]) in (os.getpid(), os.getppid()):
            continue
        name = Path(parts[1]).name
        if any(token in name.lower() for token in ("python", "julia", "ffmpeg", "node", "bun")):
            suspicious.append({"pid": int(parts[0]), "executable": name})
    return suspicious


def worker(args):
    from dataclasses import dataclass
    from typing import Final

    import numpy as np
    import quadrants as qd
    from brainlesslab.evaluation import execute
    from brainlesslab.plans import profile, resolve
    from brainlesslab.specs import (
        CompositionSpec,
        EvaluationSpec,
        ExecutionSpec,
        NodeSpec,
        NumericalPolicy,
        TaskSpec,
    )

    execution = ExecutionSpec(
        backend=args.worker_backend, batch_size=args.batch_size, cpu_threads=1, cache=True
    )
    numerics = NumericalPolicy(dtype=args.dtype)
    composition = CompositionSpec(NodeSpec(args.node), TaskSpec("delayed_cue"), count=args.count)
    plan = profile(
        composition,
        evaluation=EvaluationSpec(blocks=2, trials_per_block=4, horizon=144, root_seed=49001),
        numerics=numerics,
        id="software-timing",
    )
    resolved = resolve(plan)
    samples = []
    for index in range(3):
        started = time.perf_counter()
        result = execute(resolved, execution=execution)
        qd.sync()
        samples.append(
            {
                "phase": "first_run" if index == 0 else "warm_process",
                "wall_seconds": time.perf_counter() - started,
                "timings": dict(result.timings),
                "compiled_functions": qd.lang.impl.get_runtime().get_num_compiled_functions(),
                "raw_outcomes": [trial.outcome.raw for trial in result.trials],
                "trial_statuses": [trial.status for trial in result.trials],
            }
        )

    @dataclass(frozen=True)
    class TypedProbe:
        mode: Final[int]
        source: qd.types.NDArray[None, 2]
        output: qd.types.NDArray[None, 2]
        gain: qd.types.NDArray[None, 1]

    @qd.kernel(fastcache=True)
    def typed_kernel(bundle: TypedProbe):
        for b, i in qd.ndrange(bundle.source.shape[0], bundle.source.shape[1]):
            if qd.static(bundle.mode == 1):
                bundle.output[b, i] = bundle.source[b, i] * bundle.gain[0]
            else:
                bundle.output[b, i] = -bundle.source[b, i] * bundle.gain[0]

    real = qd.f64 if args.dtype == "float64" else qd.f32
    host_dtype = np.float64 if args.dtype == "float64" else np.float32
    counters = []
    for shape, gain, mode in (
        ((2, 3), 1.25, 1),
        ((2, 3), 2.75, 1),
        ((4, 7), 3.5, 1),
        ((4, 7), 3.5, 2),
    ):
        source, output = qd.ndarray(real, shape), qd.ndarray(real, shape)
        gains = qd.ndarray(real, (1,))
        source.from_numpy(np.ones(shape, dtype=host_dtype))
        gains.from_numpy(np.array([gain], dtype=host_dtype))
        typed_kernel(TypedProbe(mode, source, output, gains))
        np.testing.assert_allclose(output.to_numpy(), gain if mode == 1 else -gain, atol=1e-6)
        counters.append(qd.lang.impl.get_runtime().get_num_compiled_functions())
    if counters[0] != counters[1] or counters[1] != counters[2] or counters[3] != counters[2] + 1:
        raise RuntimeError(
            "runtime scalar/shape changes produced an unexpected kernel specialisation"
        )
    receipt = {
        "backend": args.worker_backend,
        "actual_arch": str(qd.lang.impl.current_cfg().arch),
        "dtype": args.dtype,
        "fast_math": False,
        "node": args.node,
        "count": args.count,
        "batch_size": args.batch_size,
        "samples": samples,
        "typed_bundle_compiled_counts": counters,
        "qualification": "software timing and bounded-specialisation diagnostic only",
    }
    print("PROFILE_RECEIPT=" + json.dumps(receipt, allow_nan=False, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--backends", nargs="+", choices=("cpu", "metal"), default=["cpu"])
    parser.add_argument("--dtype", choices=("float32", "float64"), default="float32")
    parser.add_argument("--node", choices=("falandays", "sorn"), default="falandays")
    parser.add_argument("--count", type=int, default=64)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--allow-background-activity", action="store_true")
    parser.add_argument("--worker-backend", choices=("cpu", "metal"), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker_backend:
        worker(args)
        return
    if "metal" in args.backends and args.dtype != "float32":
        parser.error("Metal requires explicitly matched Float32 numerics")
    processes = background_activity()
    if processes and not args.allow_background_activity:
        parser.error(
            "background compute detected; repeat when idle or pass "
            "--allow-background-activity to record it"
        )
    args.destination.mkdir(parents=True, exist_ok=False)
    receipts = []
    for backend in args.backends:
        cache = args.destination / f"{backend}-cache"
        cache.mkdir()
        for phase in ("cold_cache_new_process", "warm_cache_new_process"):
            environment = os.environ | {"BRAINLESSLAB_CACHE_DIR": str(cache)}
            command = [
                sys.executable,
                __file__,
                str(args.destination),
                "--worker-backend",
                backend,
                "--dtype",
                args.dtype,
                "--node",
                args.node,
                "--count",
                str(args.count),
                "--batch-size",
                str(args.batch_size),
            ]
            started = time.perf_counter()
            run = subprocess.run(
                command, env=environment, capture_output=True, text=True, check=False
            )
            elapsed = time.perf_counter() - started
            (args.destination / f"{backend}-{phase}.stdout.txt").write_text(run.stdout)
            (args.destination / f"{backend}-{phase}.stderr.txt").write_text(run.stderr)
            lines = [
                line.removeprefix("PROFILE_RECEIPT=")
                for line in run.stdout.splitlines()
                if line.startswith("PROFILE_RECEIPT=")
            ]
            if run.returncode or len(lines) != 1:
                receipts.append(
                    {
                        "backend": backend,
                        "phase": phase,
                        "status": "failed",
                        "returncode": run.returncode,
                        "process_wall_seconds": elapsed,
                    }
                )
                break
            receipts.append(
                {
                    "phase": phase,
                    "status": "complete",
                    "process_wall_seconds": elapsed,
                    **json.loads(lines[0]),
                }
            )
    document = {
        "format": "brainlesslab-backend-profile",
        "version": 1,
        "python_version": platform.python_version(),
        "machine": platform.machine(),
        "background_activity": processes,
        "background_activity_allowed": args.allow_background_activity,
        "measurements": receipts,
        "interpretation": (
            "No learning or fixed speed claim; compare matched numerics and workload."
        ),
    }
    (args.destination / "receipt.json").write_text(
        json.dumps(document, indent=2, allow_nan=False) + "\n"
    )
    print(args.destination / "receipt.json")
    if any(row["status"] != "complete" for row in receipts):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
