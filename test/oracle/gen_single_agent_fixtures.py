#!/usr/bin/env python3
"""Generate the single-agent Ensemble parity fixture."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

import numpy as np


SCRIPT = Path(__file__).resolve()
NEURAL_COGNITION = SCRIPT.parents[3]
V02_ROOT = Path.cwd()
if not (V02_ROOT / "crho").is_dir():
    V02_ROOT = NEURAL_COGNITION / "v0.2"
sys.path.insert(0, str(V02_ROOT))

from crho.envs import WallEnv  # noqa: E402
from crho.falandays import TASK_INPUT_WEIGHT, FalandaysParams, FalandaysReservoir  # noqa: E402


OUT_DIR = SCRIPT.parents[1] / "fixtures"
OUT_PATH = OUT_DIR / "single_agent_wall.npz"
SEED = 42001
TICKS = 120
N = 30
N_RECEPTORS = 2
N_EFFECTORS = 2


class RecordingRNG:
    def __init__(self, rng, draws):
        self.rng = rng
        self.draws = draws

    def _record(self, draw):
        arr = np.asarray(draw, dtype=float)
        self.draws.extend(arr.reshape(-1).tolist())
        return draw

    def uniform(self, low=0.0, high=1.0, size=None):
        return self._record(self.rng.uniform(low, high, size))

    def choice(self, a, size=None, replace=True, p=None, axis=0, shuffle=True):
        return self._record(
            self.rng.choice(a, size=size, replace=replace, p=p, axis=axis, shuffle=shuffle)
        )

    def __getattr__(self, name):
        return getattr(self.rng, name)


def _make_wall_env_recorded(seed):
    original_default_rng = np.random.default_rng
    draws: list[float] = []

    def factory(*args, **kwargs):
        return RecordingRNG(original_default_rng(*args, **kwargs), draws)

    with patch("numpy.random.default_rng", side_effect=factory):
        env = WallEnv(seed)

    return env, draws


def _pose(env):
    return np.asarray([env.box.x, env.box.y, env.box.theta], dtype=float)


def _numeric_metrics(metrics):
    out = {}
    for key, value in metrics.items():
        if isinstance(value, (bool, np.bool_)):
            out[f"metric_{key}"] = np.int8(bool(value))
        elif isinstance(value, (int, float, np.integer, np.floating)):
            value_f = float(value)
            if np.isfinite(value_f):
                out[f"metric_{key}"] = np.float64(value_f)
    if metrics.get("xy_path") is not None:
        out["metric_xy_path"] = np.asarray(metrics["xy_path"], dtype=float)
    return out


def build_fixture():
    params = FalandaysParams.default()
    input_weight = float(TASK_INPUT_WEIGHT["wall"])
    env, env_draws = _make_wall_env_recorded(SEED)
    reservoir = FalandaysReservoir(
        N,
        N_RECEPTORS,
        N_EFFECTORS,
        params,
        SEED,
        input_weight=input_weight,
    )

    sensors = np.zeros((TICKS, N_RECEPTORS), dtype=float)
    spikes_t = np.zeros((TICKS, N), dtype=float)
    effectors_t = np.zeros((TICKS, N_EFFECTORS), dtype=float)
    pose_t = np.zeros((TICKS, 3), dtype=float)

    input_wmat = np.asarray(reservoir.input_wmat, dtype=float).copy()
    wmat0 = np.asarray(reservoir._initial_wmat, dtype=float).copy()
    recurrent_mask = np.asarray(reservoir.recurrent_mask, dtype=bool).copy()
    output_mask = np.asarray(reservoir.output_mask, dtype=float).copy()

    for t in range(TICKS):
        c = env.sense()
        spikes = reservoir.step(c)
        e = reservoir.effectors(spikes)
        env.step(e)

        sensors[t] = c
        spikes_t[t] = spikes
        effectors_t[t] = e
        pose_t[t] = _pose(env)

    metrics = env.metrics(env.default_window)
    return {
        "seed": np.int64(SEED),
        "ticks": np.int64(TICKS),
        "N": np.int64(N),
        "n_receptors": np.int64(N_RECEPTORS),
        "n_effectors": np.int64(N_EFFECTORS),
        "leak": np.float64(params.leak),
        "lrate_wmat": np.float64(params.lrate_wmat),
        "lrate_targ": np.float64(params.lrate_targ),
        "threshold_mult": np.float64(params.threshold_mult),
        "targ_min": np.float64(params.targ_min),
        "input_weight": np.float64(input_weight),
        "weight_init_std": np.float64(params.weight_init_std),
        "learn_on": np.int8(bool(params.learn_on)),
        "rectify": np.int8(True),
        "input_wmat": input_wmat,
        "wmat0": wmat0,
        "recurrent_mask": recurrent_mask,
        "output_mask": output_mask,
        "env_draws": np.asarray(env_draws, dtype=float),
        "sensors": sensors,
        "spikes": spikes_t,
        "effectors": effectors_t,
        "pose": pose_t,
        **_numeric_metrics(metrics),
    }


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    data = build_fixture()
    np.savez(OUT_PATH, **data)
    print(
        f"wrote {OUT_PATH} ticks={TICKS} N={N} "
        f"total_spikes={int(np.sum(data['spikes']))} "
        f"final_score={float(data['metric_score']):.12g}"
    )


if __name__ == "__main__":
    main()
