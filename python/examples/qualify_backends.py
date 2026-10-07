"""Serial CPU32/Metal32 conformance over injected models and all task families.

This checks one software workload. It does not promise cross-backend long-run
bit equality, biological validity or qualification of machines not measured.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np


def worker(backend, destination):
    import quadrants as qd
    from brainlesslab.backend import initialise
    from brainlesslab.models import falandays, sorn
    from brainlesslab.specs import TASKS, ExecutionSpec, NumericalPolicy, TaskSpec
    from brainlesslab.tasks import TaskBatch, prepare

    runtime = initialise(ExecutionSpec(backend=backend), NumericalPolicy(dtype="float32"))

    def upload(value, integer=False):
        host = np.asarray(value, dtype=np.int32 if integer else np.float32)
        device = qd.ndarray(qd.i32 if integer else qd.f32, host.shape)
        device.from_numpy(host)
        return device

    values = {}
    active = upload([1, 0], True)
    inputs, noise = upload(np.zeros((2, 3))), upload(np.zeros((2, 12)))
    for name, module, config in (
        ("falandays", falandays, falandays.FalandaysConfig(drive="oosawa", membrane_noise=0.05)),
        ("sorn", sorn, sorn.SORNConfig(p_ee=0.4)),
    ):
        initial = module.construct(config, 12, 3, 2, np.random.Generator(np.random.Philox(714)))
        model = module.ModelBatch([initial, initial], dtype="float32")
        rng = np.random.Generator(np.random.Philox(281))
        for frame in range(12):
            inputs.from_numpy(rng.uniform(-0.2, 1.7, (2, 3)).astype(np.float32))
            noise.from_numpy(rng.standard_normal((2, 12)).astype(np.float32))
            if frame == 6:
                model.freeze_weights(active)
            model.step(inputs, noise, active)
            for key, value in model.snapshot().items():
                values[f"{name}/{frame}/{key}"] = value
        model.reset(active)
        for key, value in model.snapshot().items():
            values[f"{name}/reset/{key}"] = value
    task_active, effectors = upload([1, 0], True), upload([[0.75, 0.125], [0.3, 0.6]])
    for name in TASKS:
        initial = prepare(
            TaskSpec(name),
            np.random.Generator(np.random.Philox(817)),
            horizon=None if name not in TASKS[:3] else 96,
        )
        task = TaskBatch([initial, initial], dtype="float32")
        horizon = 32 if name in TASKS[:3] else initial.definition.default_horizon
        for _tick in range(horizon):
            for frame in range(1, task.definition.neural_frames + 1):
                task.encode(frame, task_active)
                task.accumulate(effectors, frame, task_active)
            task.advance(effectors, task_active)
        for key, value in task.snapshot().items():
            values[f"{name}/world/{key}"] = value
    qd.sync()
    np.savez_compressed(destination / f"{backend}.npz", **values)
    (destination / f"{backend}.json").write_text(json.dumps(runtime, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--worker", choices=("cpu", "metal"))
    args = parser.parse_args()
    if args.worker:
        worker(args.worker, args.destination)
        return
    args.destination.mkdir(parents=True, exist_ok=False)
    for backend in ("cpu", "metal"):
        result = subprocess.run(
            [sys.executable, __file__, str(args.destination), "--worker", backend],
            capture_output=True,
            text=True,
        )
        (args.destination / f"{backend}.stdout.txt").write_text(result.stdout)
        (args.destination / f"{backend}.stderr.txt").write_text(result.stderr)
        if result.returncode:
            raise RuntimeError(f"{backend} qualification failed; inspect saved process logs")
    cpu, metal = np.load(args.destination / "cpu.npz"), np.load(args.destination / "metal.npz")
    if set(cpu.files) != set(metal.files):
        raise AssertionError("backend snapshot inventories differ")
    maximum = 0.0
    for key in cpu.files:
        a, b = cpu[key], metal[key]
        if np.issubdtype(a.dtype, np.integer) or key.endswith(
            ("/spikes", "/activity", "/x", "/y", "/prev_x", "/prev_y")
        ):
            # x/y are neural arrays here; physical x is also expected identical
            # for this fixed short action tape, unless numeric tolerances apply.
            if "/world/" not in key or np.issubdtype(a.dtype, np.integer):
                np.testing.assert_array_equal(a, b, err_msg=key)
                continue
        np.testing.assert_allclose(a, b, rtol=2e-5, atol=2e-5, equal_nan=True, err_msg=key)
        finite = np.isfinite(a) & np.isfinite(b)
        if np.any(finite):
            maximum = max(maximum, float(np.max(np.abs(a[finite] - b[finite]))))
    receipt = {
        "format": "brainlesslab-backend-conformance",
        "version": 1,
        "status": "passed",
        "snapshots": len(cpu.files),
        "dtype": "float32",
        "rtol": 2e-5,
        "atol": 2e-5,
        "maximum_absolute_difference": maximum,
        "coverage": "12 injected model frames, freeze/reset/inactive slots; all ten task families",
        "limits": "one host, short deterministic action tapes; no long-run bit-equality claim",
    }
    (args.destination / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    main()
