"""Measure synchronised evaluation latency in serial backend processes.

Trial counts and worlds stay fixed when batch capacity changes. Receipts separate
process start, first evaluation, warmed evaluation and optional record writing.
These measurements include host work and transfers; they are not kernel timings.
"""

import argparse
import hashlib
import importlib.metadata
import importlib.resources
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

EXECUTE_BOUNDARY = (
    "qd.sync before clock; execute; qd.sync before stopping clock. Includes fresh "
    "construction, uploads, noise staging, stepping, readback and summaries; first "
    "evaluation can compile kernels. Runtime preparation is outside this span."
)
RECORD_BOUNDARY = (
    "write_record wall time: serialisation, source archive and checksum verification. "
    "Optional event/replay capture and transfer remain inside execute wall time."
)


def background_activity(threshold=2.0):
    """A ps snapshot cannot establish sustained CPU load or GPU idleness."""
    telemetry = {
        "cpu_threshold_percent": threshold,
        "processes": [],
        "method": "ps CPU percentage snapshot; averaging is platform dependent",
        "limits": "does not establish sustained CPU load or GPU idleness",
    }
    if sys.platform == "win32":
        return telemetry | {"status": "unsupported", "diagnostic": "ps telemetry unsupported"}
    try:
        run = subprocess.run(
            ["ps", "-axo", "pid=,pcpu=,comm="], capture_output=True, text=True, check=True
        )
        parsed = 0
        for line in run.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) != 3:
                continue
            pid, cpu = int(parts[0]), float(parts[1])
            if not math.isfinite(cpu):
                raise ValueError("ps returned a non-finite CPU percentage")
            parsed += 1
            if pid in (os.getpid(), os.getppid()):
                continue
            name = Path(parts[2]).name
            candidate = any(t in name.lower() for t in ("python", "julia", "ffmpeg", "node", "bun"))
            if cpu >= threshold or candidate:
                telemetry["processes"].append(
                    {
                        "pid": pid,
                        "executable": name,
                        "cpu_percent": cpu,
                        "compute_candidate": candidate,
                    }
                )
        if not parsed:
            raise ValueError("ps returned no usable process data")
        return telemetry | {"status": "available"}
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return telemetry | {
            "status": "unavailable",
            "diagnostic": f"{type(error).__name__}: {error}",
        }


def peak_rss():
    """Per-process high-water mark, including compilation and record writing."""
    try:
        import resource

        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    except (ImportError, OSError) as error:
        return {"status": "unsupported", "diagnostic": type(error).__name__}
    units = (
        "bytes"
        if sys.platform == "darwin"
        else "KiB"
        if sys.platform.startswith("linux")
        else "platform_defined"
    )
    return {
        "status": "available",
        "value": value,
        "units": units,
        "bytes": value if units == "bytes" else value * 1024 if units == "KiB" else None,
        "scope": "process high-water mark; includes all stages, not VRAM or allocator pool",
    }


def statistics_for(values):
    values = sorted(values)
    if not values:
        return {"count": 0}

    def quantile(fraction):
        index = (len(values) - 1) * fraction
        low = int(index)
        return values[low] + (values[min(low + 1, len(values) - 1)] - values[low]) * (index - low)

    return {
        "count": len(values),
        "minimum": values[0],
        "maximum": values[-1],
        "median": statistics.median(values),
        "mean": statistics.mean(values),
        "standard_deviation": statistics.pstdev(values),
        "p25": quantile(0.25),
        "p75": quantile(0.75),
    }


def _hash(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    ).hexdigest()


def _result_work(result, requested, horizon=None):
    rows = result.trials
    statuses = [t.status for t in rows]
    raws = [t.outcome.raw for t in rows]
    valid_raws = all(v is not None and math.isfinite(v) for v in raws)
    identities = [(t.target_id, t.block_id, t.trial_id) for t in rows]
    completed = [t for t in rows if t.status == "completed"]
    valid_work = all(t.completed_ticks > 0 and t.neural_frames > 0 for t in completed)
    success = (
        len(rows) == requested
        and len(set(identities)) == requested
        and len(completed) == requested
        and valid_raws
        and valid_work
    )
    work = sorted(
        (
            t.target_id,
            t.block_id,
            t.trial_id,
            t.world_seed,
            t.wiring_id,
            t.completed_ticks,
            t.neural_frames,
        )
        for t in rows
    )
    identities = [values[:5] for values in work]
    return {
        "status": "complete" if success else "failed",
        "requested_trials": requested,
        "completed_trials": len(completed),
        "trial_statuses": statuses,
        "status_counts": dict(Counter(statuses)),
        "raw_outcomes": [v if v is None or math.isfinite(v) else None for v in raws],
        "nonfinite_raw_outcomes": {
            str(i): repr(v) for i, v in enumerate(raws) if v is not None and not math.isfinite(v)
        },
        "completed_world_ticks": sum(t.completed_ticks for t in completed),
        "completed_neural_frames": sum(t.neural_frames for t in completed),
        "identity_signature": _hash(identities),
        "work_signature": _hash(work),
        "early_ending_trials": sum(t.completed_ticks < horizon for t in completed)
        if horizon is not None
        else None,
        "early_ending_definition": "completed trials ending before the resolved horizon",
        "trial_work": [
            {
                "target_id": t.target_id,
                "block_id": t.block_id,
                "trial_id": t.trial_id,
                "world_seed": t.world_seed,
                "wiring_id": t.wiring_id,
                "status": t.status,
                "completed_world_ticks": t.completed_ticks,
                "completed_neural_frames": t.neural_frames,
            }
            for t in rows
        ],
        "outcome_signature": _hash(raws) if valid_raws else None,
        "admitted_batch_capacities": list(result.metadata.get("batch_capacities", ())),
        "error": None if success else "failed, incomplete, missing, duplicate or non-finite trials",
    }


def measure(execute, sync, *, requested, writer=None, clock=None, entry_started=None, horizon=None):
    """Synchronise only at evaluation boundaries, not after every kernel."""
    clock = clock or time.perf_counter
    sync()
    start = clock()
    result = execute()
    sync()
    finished = clock()
    elapsed = finished - start
    row = _result_work(result, requested, horizon)
    row |= {
        "wall_seconds": elapsed,
        "execute_wall_seconds": elapsed,
        "timing_boundary": EXECUTE_BOUNDARY,
        "isolated_kernel_time": False,
        "timings": dict(result.timings),
        "record_wall_seconds": None,
    }
    if entry_started is not None:
        row["entry_to_result_seconds"] = finished - entry_started
    if elapsed <= 0 or not math.isfinite(elapsed):
        row |= {"status": "failed", "error": "invalid measured duration"}
    row["world_ticks_per_second"] = (
        row["completed_world_ticks"] / elapsed if row["status"] == "complete" else None
    )
    row["neural_frames_per_second"] = (
        row["completed_neural_frames"] / elapsed if row["status"] == "complete" else None
    )
    if writer is not None:
        start = clock()
        try:
            row["record_path"] = writer(result)
        except Exception as error:
            row |= {"status": "failed", "error": f"record writing: {type(error).__name__}: {error}"}
        row["record_wall_seconds"] = clock() - start
        row["record_timing_boundary"] = RECORD_BOUNDARY
    row["combined_wall_seconds"] = elapsed + (row["record_wall_seconds"] or 0)
    if row["status"] != "complete":
        row["world_ticks_per_second"] = row["neural_frames_per_second"] = None
    return row, dict(result.metadata)


def make_plan(args):
    from brainlesslab.plans import profile
    from brainlesslab.specs import (
        CompositionSpec,
        EvaluationSpec,
        NodeSpec,
        NumericalPolicy,
        TaskSpec,
    )

    return profile(
        CompositionSpec(NodeSpec(args.node), TaskSpec(args.task), count=args.count),
        evaluation=EvaluationSpec(
            blocks=args.blocks,
            trials_per_block=args.trials // args.blocks,
            horizon=args.horizon,
            root_seed=args.seed,
        ),
        numerics=NumericalPolicy(dtype=args.dtype),
        id="software-timing",
        diagnostic=args.diagnostic,
    )


def source_metadata():
    import brainlesslab

    package = Path(brainlesslab.__file__).parent
    lock = package.parents[2] / "uv.lock"
    resource = importlib.resources.files("brainlesslab").joinpath("_resources", "uv.lock")
    locked = (
        lock.read_bytes()
        if lock.is_file()
        else resource.read_bytes()
        if resource.is_file()
        else None
    )
    return {
        "package_version": brainlesslab.__version__,
        "quadrants_version": importlib.metadata.version("quadrants"),
        "numpy_version": importlib.metadata.version("numpy"),
        "uv_lock_sha256": hashlib.sha256(locked).hexdigest() if locked is not None else None,
        "uv_lock_status": "captured" if locked is not None else "unavailable",
        "python_build": platform.python_build(),
        "python_compiler": platform.python_compiler(),
        "logical_cpu_count": os.cpu_count(),
        "profile_script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "package_source_sha256": {
            p.relative_to(package).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(package.rglob("*.py"))
        },
    }


def typed_cache_check(qd, dtype):
    from dataclasses import dataclass
    from typing import Final

    import numpy as np

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

    real = qd.f64 if dtype == "float64" else qd.f32
    host_dtype = np.float64 if dtype == "float64" else np.float32
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
    return counters


def worker(args):
    entry_started = time.perf_counter()
    import quadrants as qd
    from brainlesslab.backend import initialise
    from brainlesslab.evaluation import execute
    from brainlesslab.plans import resolve
    from brainlesslab.records import write_record
    from brainlesslab.specs import ExecutionSpec

    receipt = {
        "backend": args.worker_backend,
        "dtype": args.dtype,
        "fast_math": False,
        "node": args.node,
        "count": args.count,
        "batch_size": args.batch_size,
        "cpu_threads": args.cpu_threads,
        "requested_trials": args.trials,
        "samples": [],
        "warmups": [],
        "status": "failed",
        "recording": args.recording,
        "qualification": (
            "synchronised evaluation latency and bounded-specialisation diagnostic only"
        ),
    }
    try:
        resolved = resolve(make_plan(args))
        execution = ExecutionSpec(
            backend=args.worker_backend,
            batch_size=args.batch_size,
            cpu_threads=args.cpu_threads,
            cache=True,
            memory_budget_bytes=args.memory_budget_mib * 1024 * 1024,
            recording="summary" if args.recording == "none" else args.recording,
            recording_budget_bytes=args.recording_budget_mib * 1024 * 1024,
        )
        receipt["source"] = source_metadata()
        start = time.perf_counter()
        receipt["runtime"] = initialise(execution, resolved.request.numerics)
        qd.sync()
        receipt["runtime_preparation_seconds"] = time.perf_counter() - start
        receipt["runtime_preparation_boundary"] = (
            "explicit initialise and sync, including runtime fingerprint"
        )
        receipt["worker_entry_to_first_result_boundary"] = (
            "worker entry before imports through first result and sync; excludes "
            "interpreter startup, argparse and record writing"
        )
        receipt["actual_arch"] = str(qd.lang.impl.current_cfg().arch)
        receipt["protocol_signature"] = _hash(
            {"contract": resolved.contract_hash, "plan": str(resolved.request)}
        )
        receipt["protocol"] = {
            "task": args.task,
            "resolved_horizon": resolved.targets[0].horizon,
            "requested_horizon": args.horizon,
            "diagnostic": args.diagnostic,
            "controller": resolved.request.targets[0].controller,
            "scoring_warmup": resolved.request.evaluation.warmup,
            "blocks": args.blocks,
            "trials_per_block": args.trials // args.blocks,
            "root_seed": args.seed,
            "seed_partition": "development",
            "construction_scope": "block",
            "reset": "full",
        }
        phases = [
            ("first_run", 0),
            *[("warmup", i) for i in range(args.warmups)],
            *[("warm_process", i) for i in range(args.samples)],
        ]
        reference = None
        for phase, index in phases:
            writer = None
            if args.recording != "none" and phase != "warmup":
                path = (
                    args.destination
                    / "records"
                    / args.worker_backend
                    / args.process_phase
                    / f"{phase}_{index:04d}"
                )

                def writer(result, path=path):
                    return str(write_record(result, path).relative_to(args.destination))

            row, metadata = measure(
                lambda: execute(resolved, execution=execution),
                qd.sync,
                requested=args.trials,
                writer=writer,
                entry_started=entry_started if phase == "first_run" else None,
                horizon=resolved.targets[0].horizon,
            )
            if phase == "first_run":
                receipt["worker_entry_to_first_result_seconds"] = row.pop("entry_to_result_seconds")
            row |= {
                "phase": phase,
                "sample_index": index,
                "compiled_functions": qd.lang.impl.get_runtime().get_num_compiled_functions(),
            }
            signature = row["work_signature"], row["outcome_signature"]
            if reference is not None and signature != reference:
                row |= {
                    "status": "failed",
                    "error": "repeated scientific work or raw outcomes changed",
                }
                row["world_ticks_per_second"] = row["neural_frames_per_second"] = None
            reference = reference or signature
            receipt["runtime"] = metadata
            receipt["warmups" if phase == "warmup" else "samples"].append(row)
            if row["status"] != "complete":
                raise RuntimeError(row["error"])
        receipt["typed_bundle_compiled_counts"] = typed_cache_check(qd, args.dtype)
        warmed = [s for s in receipt["samples"] if s["phase"] == "warm_process"]
        receipt["statistics"] = {
            "execute_wall_seconds": statistics_for([s["execute_wall_seconds"] for s in warmed]),
            "world_ticks_per_second": statistics_for([s["world_ticks_per_second"] for s in warmed]),
            "neural_frames_per_second": statistics_for(
                [s["neural_frames_per_second"] for s in warmed]
            ),
            "record_wall_seconds": statistics_for(
                [s["record_wall_seconds"] for s in warmed if s["record_wall_seconds"] is not None]
            ),
            "scope": "warmed evaluation samples only; first run and warmups excluded",
        }
        receipt["status"] = "complete"
    except Exception as error:
        receipt["error"] = f"{type(error).__name__}: {error}"
    receipt["peak_rss"] = peak_rss()
    print("PROFILE_RECEIPT=" + json.dumps(receipt, allow_nan=False, sort_keys=True))
    return 0 if receipt["status"] == "complete" else 1


def parser_for():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--backends", nargs="+", choices=("cpu", "metal"), default=["cpu"])
    parser.add_argument("--dtype", choices=("float32", "float64"), required=True)
    parser.add_argument("--node", choices=("falandays", "sorn"), default="falandays")
    parser.add_argument(
        "--task",
        choices=("delayed_cue", "tracking", "pong", "cartpole_plank_easy"),
        default="delayed_cue",
    )
    for name, default in (
        ("count", 64),
        ("batch-size", 8),
        ("trials", 8),
        ("blocks", 2),
        ("samples", 7),
        ("warmups", 1),
        ("cpu-threads", 1),
        ("memory-budget-mib", 256),
        ("recording-budget-mib", 32),
        ("seed", 49001),
    ):
        parser.add_argument("--" + name, type=int, default=default)
    parser.add_argument("--horizon", type=int)
    parser.add_argument(
        "--diagnostic",
        action="store_true",
        help="explicitly permit short physical-task diagnostics",
    )
    parser.add_argument(
        "--recording", choices=("none", "summary", "probe_events", "replay"), default="none"
    )
    parser.add_argument("--allow-background-activity", action="store_true")
    parser.add_argument("--activity-cpu-threshold", type=float, default=2.0)
    parser.add_argument("--worker-backend", choices=("cpu", "metal"), help=argparse.SUPPRESS)
    parser.add_argument("--process-phase", default="worker", help=argparse.SUPPRESS)
    return parser


def validate_args(parser, args):
    for key in (
        "count",
        "batch_size",
        "trials",
        "blocks",
        "samples",
        "cpu_threads",
        "memory_budget_mib",
        "recording_budget_mib",
    ):
        if getattr(args, key) < 1:
            parser.error(f"--{key.replace('_', '-')} must be positive")
    if args.warmups < 0 or args.seed < 0 or (args.horizon is not None and args.horizon < 1):
        parser.error("warmups/seed must be non-negative and horizon must be positive")
    if args.trials % args.blocks:
        parser.error("--trials must be divisible by --blocks; batch size never changes trials")
    if not math.isfinite(args.activity_cpu_threshold) or args.activity_cpu_threshold <= 0:
        parser.error("activity CPU threshold must be finite and positive")
    if ("metal" in args.backends or args.worker_backend == "metal") and args.dtype != "float32":
        parser.error("Metal requires explicitly matched Float32 numerics")
    if len(set(args.backends)) != len(args.backends):
        parser.error("backends must be distinct")
    if args.recording == "probe_events" and args.task != "delayed_cue":
        parser.error("probe_events recording requires delayed_cue")


def _worker_success(receipt, args):
    rows = [*receipt.get("samples", ()), *receipt.get("warmups", ())]
    return (
        receipt.get("status") == "complete"
        and len(rows) == 1 + args.samples + args.warmups
        and all(
            r.get("status") == "complete" and r.get("trial_statuses") == ["completed"] * args.trials
            for r in rows
        )
    )


def main(argv=None):
    parser = parser_for()
    args = parser.parse_args(argv)
    validate_args(parser, args)
    if args.worker_backend:
        return worker(args)
    from brainlesslab.plans import resolve

    try:
        resolve(make_plan(args))
    except ValueError as error:
        parser.error(str(error))
    telemetry = background_activity(args.activity_cpu_threshold)
    if (
        telemetry["status"] != "available" or telemetry["processes"]
    ) and not args.allow_background_activity:
        parser.error(
            "background activity detected or telemetry unavailable; inspect diagnostics and "
            "repeat when idle, or explicitly use --allow-background-activity"
        )
    args.destination.mkdir(parents=True, exist_ok=False)
    receipts = []
    for backend in args.backends:
        cache = args.destination / f"{backend}-cache"
        cache.mkdir()
        reference = None
        for phase in ("cold_cache_new_process", "warm_cache_new_process"):
            before = sorted(
                p.relative_to(cache).as_posix() for p in cache.rglob("*") if p.is_file()
            )
            if phase == "warm_cache_new_process" and not before:
                receipts.append(
                    {
                        "backend": backend,
                        "phase": phase,
                        "status": "failed",
                        "cache_files_before": [],
                        "error": "application cache remains empty; warm-cache timing unavailable",
                    }
                )
                break
            environment = os.environ | {"BRAINLESSLAB_CACHE_DIR": str(cache.resolve())}
            command = [
                sys.executable,
                __file__,
                str(args.destination),
                "--worker-backend",
                backend,
                "--process-phase",
                phase,
                "--dtype",
                args.dtype,
                "--node",
                args.node,
                "--task",
                args.task,
                "--recording",
                args.recording,
            ]
            for key in (
                "count",
                "batch_size",
                "trials",
                "blocks",
                "samples",
                "warmups",
                "cpu_threads",
                "memory_budget_mib",
                "recording_budget_mib",
                "seed",
            ):
                command += ["--" + key.replace("_", "-"), str(getattr(args, key))]
            if args.horizon is not None:
                command += ["--horizon", str(args.horizon)]
            if args.diagnostic:
                command.append("--diagnostic")
            start = time.perf_counter()
            run = subprocess.run(
                command, env=environment, capture_output=True, text=True, check=False
            )
            elapsed = time.perf_counter() - start
            (args.destination / f"{backend}-{phase}.stdout.txt").write_text(run.stdout)
            (args.destination / f"{backend}-{phase}.stderr.txt").write_text(run.stderr)
            lines = [
                line.removeprefix("PROFILE_RECEIPT=")
                for line in run.stdout.splitlines()
                if line.startswith("PROFILE_RECEIPT=")
            ]
            row = {
                "backend": backend,
                "phase": phase,
                "status": "failed",
                "returncode": run.returncode,
                "process_wall_seconds": elapsed,
                "process_timing_boundary": (
                    "full worker process: start through exit; imports, runtime preparation, "
                    "all evaluations, optional records and typed-cache diagnostics"
                ),
                "cache_files_before": before,
            }
            try:
                receipt = json.loads(lines[0]) if len(lines) == 1 else {}
                if not isinstance(receipt, dict):
                    raise ValueError("worker receipt must be a JSON object")
                row |= receipt
                valid = run.returncode == 0 and _worker_success(receipt, args)
                first = receipt.get("samples", [{}])[0]
                signature = (
                    receipt.get("protocol_signature"),
                    first.get("work_signature"),
                    first.get("outcome_signature"),
                )
                if reference is not None and reference != signature:
                    valid = False
                    row["error"] = "scientific work/outcomes changed between processes"
                reference = reference or signature
                row["status"] = "complete" if valid else "failed"
                if not valid and not row.get("error"):
                    row["error"] = "worker failed or returned invalid sample statuses/counts"
            except (ValueError, TypeError, IndexError) as error:
                row["error"] = f"invalid worker receipt: {error}"
            receipts.append(row)
            if row["status"] != "complete":
                break
    document = {
        "format": "brainlesslab-backend-profile",
        "version": 1,
        "python_version": platform.python_version(),
        "machine": platform.machine(),
        "platform": platform.platform(),
        "background_activity": telemetry["processes"],
        "background_activity_allowed": args.allow_background_activity,
        "activity_telemetry": telemetry,
        "activity_after": background_activity(args.activity_cpu_threshold),
        "measurements": receipts,
        "timing_boundary": EXECUTE_BOUNDARY,
        "cache_scope": (
            "Empty application cache only; OS/driver caches uncontrolled. "
            "Compiled-function counts do not prove disk-cache hits."
        ),
        "interpretation": (
            "Repeated identical development worlds measure software latency, not additional "
            "independent scientific evidence or a fixed speed claim."
        ),
    }
    with (args.destination / "receipt.json").open("x") as stream:
        json.dump(document, stream, indent=2, allow_nan=False)
        stream.write("\n")
    print(args.destination / "receipt.json")
    return 0 if all(r["status"] == "complete" for r in receipts) else 1


if __name__ == "__main__":
    raise SystemExit(main())
