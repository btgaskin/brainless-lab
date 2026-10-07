"""Standalone Quadrants-only ndarray alias diagnostic; no BrainlessLab imports."""

import argparse
import json
import platform
import tempfile
from dataclasses import dataclass
from importlib.metadata import version

import numpy as np
import quadrants as qd


@dataclass(frozen=True)
class State:
    values: qd.types.NDArray[None, 1]


@dataclass(frozen=True)
class View:
    values: qd.types.NDArray[None, 1]


@qd.func
def read_view(view: View, b: qd.i32):
    return view.values[b]


@qd.func
def read_array(values: qd.types.NDArray[None, 1], b: qd.i32):
    return values[b]


@qd.func
def increment(state: State, b: qd.i32):
    state.values[b] = state.values[b] + 1


@qd.kernel
def through_alias(state: State, view: View, result: qd.types.NDArray[None, 2]):
    for b in range(state.values.shape[0]):
        for tick in range(result.shape[0]):
            result[tick, b] = read_view(view, b)
            increment(state, b)


@qd.kernel
def through_canonical(state: State, result: qd.types.NDArray[None, 2]):
    for b in range(state.values.shape[0]):
        for tick in range(result.shape[0]):
            result[tick, b] = read_array(state.values, b)
            increment(state, b)


def run(backend, dtype):
    real = qd.f64 if dtype == "float64" else qd.f32
    with tempfile.TemporaryDirectory(prefix="quadrants-alias-") as cache:
        qd.init(
            arch=qd.metal if backend == "metal" else qd.cpu,
            default_fp=real,
            fast_math=False,
            debug=True,
            enable_fallback=False,
            offline_cache=False,
            cpu_max_num_threads=1,
            offline_cache_file_path=cache,
        )
        values = qd.ndarray(real, (2,))
        result = qd.ndarray(real, (4, 2))
        state, view = State(values), View(values)
        values.fill(0)
        through_alias(state, view, result)
        qd.sync()
        aliased = result.to_numpy().tolist()
        values.fill(0)
        through_canonical(state, result)
        qd.sync()
        canonical = result.to_numpy().tolist()
        expected = np.repeat(np.arange(4, dtype=dtype)[:, None], 2, axis=1).tolist()
        print(
            json.dumps(
                {
                    "quadrants_version": version("quadrants"),
                    "backend": backend,
                    "runtime_arch": str(qd.lang.impl.current_cfg().arch),
                    "dtype": dtype,
                    "machine": platform.machine(),
                    "expected": expected,
                    "aliased": aliased,
                    "canonical": canonical,
                    "alias_matches": aliased == expected,
                    "canonical_matches": canonical == expected,
                },
                sort_keys=True,
            )
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=("cpu", "metal"), default="cpu")
    parser.add_argument("--dtype", choices=("float64", "float32"), default="float64")
    args = parser.parse_args()
    run(args.backend, args.dtype)
