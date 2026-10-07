"""Explicit process-local Quadrants lifecycle and conservative memory admission."""

from __future__ import annotations

import os
import hashlib
import importlib.metadata
import json
from functools import lru_cache
from pathlib import Path

from .specs import ExecutionSpec, NumericalPolicy

_key: tuple[object, ...] | None = None
_program: object | None = None


@lru_cache(maxsize=1)
def runtime_fingerprint() -> str:
    distribution = importlib.metadata.distribution("quadrants")
    hashes = {str(f): hashlib.sha256(Path(str(distribution.locate_file(f))).read_bytes()).hexdigest()
              for f in distribution.files or ()
              if str(f).endswith((".py", ".so", ".dylib", ".pyd"))}
    payload = {"version": distribution.version, "files": hashes}
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def initialise(execution: ExecutionSpec, numerics: NumericalPolicy) -> dict[str, object]:
    import quadrants as qd

    global _key, _program
    if execution.backend == "metal" and numerics.dtype != "float32":
        raise ValueError("Metal requires Float32; select an explicit NumericalPolicy")
    key = (execution.backend, numerics.dtype, execution.cpu_threads, execution.cache)
    try:
        current = qd.lang.impl.get_runtime().prog
    except qd.lang.exception.QuadrantsRuntimeError:
        current = None
    if current is _program and _key is not None:
        if key != _key:
            raise RuntimeError("a process owns one numerical runtime; use another process")
    else:
        cache = Path(os.environ.get("BRAINLESSLAB_CACHE_DIR", ".cache/quadrants"))
        cache.mkdir(parents=True, exist_ok=True)
        qd.init(
            arch=qd.cpu if execution.backend == "cpu" else qd.metal,
            default_fp=qd.f64 if numerics.dtype == "float64" else qd.f32,
            fast_math=False, enable_fallback=False, raise_on_templated_floats=True,
            cpu_max_num_threads=execution.cpu_threads,
            offline_cache=execution.cache, src_ll_cache=execution.cache,
            offline_cache_file_path=str(cache),
        )
        _key, _program = key, qd.lang.impl.get_runtime().prog
    return {
        "quadrants_version": ".".join(map(str, qd.__version__)),
        "requested_backend": execution.backend,
        "actual_arch": str(qd.lang.impl.current_cfg().arch),
        "dtype": numerics.dtype, "fast_math": False,
        "cpu_threads": execution.cpu_threads, "cache_enabled": execution.cache,
        "runtime_fingerprint": runtime_fingerprint(),
    }


def admit_batch(per_trial_bytes: int, execution: ExecutionSpec, *, fixed_bytes: int = 0) -> int:
    available = execution.allocation_budget - fixed_bytes
    if per_trial_bytes <= 0 or available < per_trial_bytes:
        required = per_trial_bytes + fixed_bytes
        raise MemoryError(
            f"one trajectory needs at least {required} managed bytes; allocation budget is "
            f"{execution.allocation_budget}; increase memory_budget_bytes explicitly"
        )
    return min(execution.batch_size, available // per_trial_bytes)
