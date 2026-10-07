"""Author the 64 development cells through the ordinary v4 plan writer."""

import argparse
from pathlib import Path

from brainlesslab.plans import profile, write_plan
from brainlesslab.specs import CompositionSpec, EvaluationSpec, NodeSpec, TaskSpec
from brainlesslab.tasks import capacity_probe_presets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--node", choices=("falandays", "sorn"), default="falandays")
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=False)
    for cell in capacity_probe_presets():
        composition = CompositionSpec(
            NodeSpec(args.node), TaskSpec(cell.task, cell.task_options), count=64
        )
        evaluation = EvaluationSpec(
            blocks=4,
            trials_per_block=8,
            horizon=cell.horizon,
            warmup=0,
            construction_scope="block",
            root_seed=31001,
        )
        plan = profile(composition, evaluation=evaluation, id=cell.id)
        write_plan(plan, args.destination / f"{cell.id}.toml")
    print(f"Wrote 64 development plans to {args.destination}")


if __name__ == "__main__":
    main()
