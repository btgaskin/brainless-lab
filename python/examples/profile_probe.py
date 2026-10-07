"""Run one small diagnostic; task accuracy and fitted decoding stay separate."""

import argparse
from pathlib import Path

from brainlesslab.plans import profile, resolve
from brainlesslab.records import write_record
from brainlesslab.specs import CompositionSpec, EvaluationSpec, ExecutionSpec, NodeSpec, TaskSpec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    from brainlesslab.evaluation import execute

    composition = CompositionSpec(
        NodeSpec("falandays"), TaskSpec("delayed_xor", {"gap": 32}), count=64
    )
    evaluation = EvaluationSpec(
        blocks=2,
        trials_per_block=8,
        horizon=56,
        warmup=0,
        construction_scope="block",
        root_seed=31002,
    )
    plan = profile(composition, evaluation=evaluation, id="xor-diagnostic")
    result = execute(resolve(plan), execution=ExecutionSpec(recording="probe_events"))
    write_record(result, args.destination)
    print(args.destination)


if __name__ == "__main__":
    main()
