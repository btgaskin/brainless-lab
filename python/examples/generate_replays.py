"""Generate development-only display frames with the active Quadrants engine."""

import argparse
import hashlib
import json
from pathlib import Path

from brainlesslab import (CompositionSpec, EvaluationSpec, ExecutionSpec, NodeSpec,
                          TaskSpec, execute, profile)
from brainlesslab.records import export_replay


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    args.destination.mkdir(parents=True, exist_ok=False)
    cases = []
    for node in ("falandays", "sorn"):
        for task in ("tracking", "pong", "cartpole_plank_easy", "delayed_cue"):
            identity = f"{node}-{task.replace('_', '-')}"
            horizon = {"tracking": 240, "pong": 240, "cartpole_plank_easy": 96,
                       "delayed_cue": 144}[task]
            plan = profile(CompositionSpec(NodeSpec(node), TaskSpec(task), count=64),
                           evaluation=EvaluationSpec(horizon=horizon, root_seed=91407),
                           id=identity, diagnostic=task != "delayed_cue")
            result = execute(plan, ExecutionSpec(recording="replay"))
            if any(t.status != "completed" for t in result.trials):
                raise RuntimeError(f"display generation failed for {identity}")
            path = export_replay(result, args.destination / f"{identity}.json")
            cases.append({"id": identity, "task": task, "node": node,
                          "label": f"{node.title()} · {task.replace('_', ' ').title()} · development",
                          "path": f"/replays/{identity}.json",
                          "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    index = {"format": "brainlesslab-replay-index", "version": 1, "cases": cases}
    (args.destination / "index.json").write_text(json.dumps(index, indent=2) + "\n")
    print(args.destination / "index.json")


if __name__ == "__main__":
    main()
