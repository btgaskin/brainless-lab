#!/usr/bin/env python3
"""Generate the two-agent torus Collective parity fixture."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np


SCRIPT = Path(__file__).resolve()
NEURAL_COGNITION = SCRIPT.parents[3]
V02_ROOT = Path.cwd()
if not (V02_ROOT / "crho").is_dir():
    V02_ROOT = NEURAL_COGNITION / "v0.2"
sys.path.insert(0, str(V02_ROOT))

from crho.collective import SwarmConfig, SwarmWorld, make_reservoirs  # noqa: E402
from crho.falandays import FalandaysParams  # noqa: E402
from crho.metrics import swarm_metrics  # noqa: E402


OUT_DIR = SCRIPT.parents[1] / "fixtures"
OUT_PATH = OUT_DIR / "dyad_torus.npz"
SEED = 0
TICKS = 150
WINDOW = TICKS


def _pose(body):
    return np.asarray([body.pos[0], body.pos[1], body.heading], dtype=float)


def _metric_payload(metrics):
    out = {}
    for key, value in metrics.items():
        if isinstance(value, (bool, np.bool_)):
            out[f"metric_{key}"] = np.int8(bool(value))
        elif isinstance(value, (int, float, np.integer, np.floating)):
            value_f = float(value)
            if np.isfinite(value_f):
                out[f"metric_{key}"] = np.float64(value_f)
    return out


def build_fixture():
    config = SwarmConfig(
        n_agents=2,
        seed=SEED,
        visual_coupling=True,
        physical_coupling=False,
        sensory_noise=0.0,
        membrane_noise=0.0,
        node_kind="standard",
    )
    world = SwarmWorld(config)
    reservoirs = make_reservoirs(world)

    params = FalandaysParams.default()
    n_agents = len(world.bodies)
    n_nodes = int(config.n_nodes)
    n_receptors = int(world.n_receptors)
    n_effectors = int(world.n_effectors)

    initial_pose = np.asarray([_pose(body) for body in world.bodies], dtype=float)
    initial_speed = np.asarray([body.speed for body in world.bodies], dtype=float)
    initial_heading_rate = np.asarray(
        [body.heading_rate for body in world.bodies],
        dtype=float,
    )

    input_wmat = np.asarray(
        [np.asarray(reservoir.input_wmat, dtype=float).copy() for reservoir in reservoirs],
        dtype=float,
    )
    wmat0 = np.asarray(
        [np.asarray(reservoir._initial_wmat, dtype=float).copy() for reservoir in reservoirs],
        dtype=float,
    )
    recurrent_mask = np.asarray(
        [np.asarray(reservoir.recurrent_mask, dtype=bool).copy() for reservoir in reservoirs],
        dtype=bool,
    )
    output_mask = np.asarray(
        [np.asarray(reservoir.output_mask, dtype=float).copy() for reservoir in reservoirs],
        dtype=float,
    )

    sensors = np.zeros((TICKS, n_agents, n_receptors), dtype=float)
    spikes_t = np.zeros((TICKS, n_agents, n_nodes), dtype=float)
    effectors_t = np.zeros((TICKS, n_agents, n_effectors), dtype=float)
    pose_t = np.zeros((TICKS, n_agents, 3), dtype=float)

    for t in range(TICKS):
        inputs = world.sense_all()
        outputs = []
        for i, (reservoir, inp) in enumerate(zip(reservoirs, inputs)):
            spikes = reservoir.step(inp)
            effectors = reservoir.effectors(spikes)

            sensors[t, i] = inp
            spikes_t[t, i] = spikes
            effectors_t[t, i] = effectors
            outputs.append(effectors)

        world.step_all(outputs)

        for i, body in enumerate(world.bodies):
            pose_t[t, i] = _pose(body)

    metrics = swarm_metrics(world, WINDOW)

    return {
        "seed": np.int64(SEED),
        "ticks": np.int64(TICKS),
        "window": np.int64(WINDOW),
        "n_agents": np.int64(n_agents),
        "N": np.int64(n_nodes),
        "n_receptors": np.int64(n_receptors),
        "n_effectors": np.int64(n_effectors),
        "torus_size": np.float64(world.torus.size),
        "sens_agent_dist": np.int64(config.sens_agent_dist),
        "sensory_noise": np.float64(config.sensory_noise),
        "sensory_scaling": np.int8(bool(config.sensory_scaling)),
        "visual_coupling": np.int8(bool(config.visual_coupling)),
        "physical_coupling": np.int8(bool(config.physical_coupling)),
        "top_speed": np.float64(config.ven.top_speed),
        "accel_time": np.float64(config.ven.accel_time),
        "top_heading_rate": np.float64(config.ven.top_heading_rate),
        "h_accel_time": np.float64(config.ven.h_accel_time),
        "dt": np.float64(config.ven.dt),
        "agent_radius": np.float64(config.ven.agent_radius),
        "leak": np.float64(params.leak),
        "lrate_wmat": np.float64(params.lrate_wmat),
        "lrate_targ": np.float64(params.lrate_targ),
        "threshold_mult": np.float64(params.threshold_mult),
        "targ_min": np.float64(params.targ_min),
        "input_weight": np.float64(reservoirs[0].input_weight),
        "weight_init_std": np.float64(params.weight_init_std),
        "learn_on": np.int8(bool(params.learn_on)),
        "rectify": np.int8(True),
        "initial_pose": initial_pose,
        "initial_speed": initial_speed,
        "initial_heading_rate": initial_heading_rate,
        "input_wmat": input_wmat,
        "wmat0": wmat0,
        "recurrent_mask": recurrent_mask,
        "output_mask": output_mask,
        "sensors": sensors,
        "spikes": spikes_t,
        "effectors": effectors_t,
        "pose": pose_t,
        **_metric_payload(metrics),
    }


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    data = build_fixture()
    np.savez(OUT_PATH, **data)

    totals = np.sum(data["spikes"], axis=(0, 2)).astype(int)
    print(
        f"wrote {OUT_PATH} ticks={TICKS} N={int(data['N'])} "
        f"total_spikes_agent0={int(totals[0])} "
        f"total_spikes_agent1={int(totals[1])} "
        f"final_polarization={float(data['metric_polarization']):.12g} "
        f"final_milling={float(data['metric_milling']):.12g}"
    )


if __name__ == "__main__":
    main()
