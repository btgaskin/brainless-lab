"""Freeze fresh task nulls after conformance, using separate backend processes."""

import argparse
import json
import subprocess
import sys
from pathlib import Path


def worker(args):
    from brainlesslab import ExecutionSpec, NumericalPolicy, TaskSpec, calibrate
    from brainlesslab.records import write_record

    execution = ExecutionSpec(backend=args.worker, batch_size=128, noise_tile_frames=512)
    numerics = NumericalPolicy(dtype="float64" if args.worker == "cpu" else "float32")
    receipt = []
    for task in ("tracking", "pong", "cartpole_plank_easy"):
        result = calibrate(TaskSpec(task), root_seed=91337, numerics=numerics, execution=execution)
        path = write_record(result, args.destination / f"{args.worker}-{task}")
        calibration = next(c for c in result.calibrations if c.signature.task == task)
        receipt.append(
            {
                "task": task,
                "backend": args.worker,
                "dtype": numerics.dtype,
                "record": path.name,
                "calibration_id": calibration.id,
                "null_mean": calibration.null_mean,
                "null_interval": calibration.null_interval,
                "trajectories": len(calibration.trial_scores),
                "timings": dict(result.timings),
            }
        )
        print(json.dumps(receipt[-1]), flush=True)
    (args.destination / f"{args.worker}-receipt.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--backends", nargs="+", choices=("cpu", "metal"), default=["cpu"])
    parser.add_argument("--worker", choices=("cpu", "metal"))
    args = parser.parse_args()
    if args.worker:
        worker(args)
        return
    args.destination.mkdir(parents=True, exist_ok=False)
    for backend in args.backends:
        subprocess.run(
            [sys.executable, __file__, str(args.destination), "--worker", backend], check=True
        )


if __name__ == "__main__":
    main()
