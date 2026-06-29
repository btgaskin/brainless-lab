#!/usr/bin/env python3
"""Generate NumPy oracle fixtures for the four CRHO task environments."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

import numpy as np


SCRIPT = Path(__file__).resolve()
NEURAL_COGNITION = SCRIPT.parents[3]
V0_ROOT = Path.cwd()
if not (V0_ROOT / "crho").is_dir():
    V0_ROOT = NEURAL_COGNITION / "v0"
sys.path.insert(0, str(V0_ROOT))

from crho.envs import CartPoleEnv, PongEnv, TrackingEnv, WallEnv  # noqa: E402


OUT_DIR = SCRIPT.parents[1] / "fixtures"
EFF_SEED = 20260628
ENV_SEEDS = {
    "wall": 31001,
    "tracking": 31002,
    "pong": 31003,
    "cartpole": 31004,
}
TICKS = {
    "wall": 60,
    "tracking": 60,
    "pong": 60,
    "cartpole": 200,
}


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

    def standard_normal(self, size=None, dtype=np.float64, out=None):
        return self._record(self.rng.standard_normal(size=size, dtype=dtype, out=out))

    def random(self, size=None, dtype=np.float64, out=None):
        return self._record(self.rng.random(size=size, dtype=dtype, out=out))

    def __getattr__(self, name):
        return getattr(self.rng, name)


def _make_env_recorded(env_class, seed):
    original_default_rng = np.random.default_rng
    draws: list[float] = []

    def factory(*args, **kwargs):
        return RecordingRNG(original_default_rng(*args, **kwargs), draws)

    with patch("numpy.random.default_rng", side_effect=factory):
        env = env_class(seed)

    return env, draws


def _effector_stream(name, ticks):
    seed = EFF_SEED + sum(ord(ch) for ch in name)
    rng = np.random.default_rng(seed)
    return rng.random((ticks, 2), dtype=float)


def _state(env, name):
    if name == "wall":
        return np.asarray(
            [env.box.x, env.box.y, env.box.theta, float(env.box.collisions)],
            dtype=float,
        )
    if name == "tracking":
        return np.asarray(
            [env.theta, env.phi, env.direction, float(env.tick)],
            dtype=float,
        )
    if name == "pong":
        return np.asarray(
            [
                env.ball_x,
                env.ball_y,
                env.paddle_y,
                float(np.sum(env.hit_flags)),
                float(np.sum(env.miss_flags)),
            ],
            dtype=float,
        )
    if name == "cartpole":
        return np.asarray(env.state, dtype=float).reshape(4)
    raise KeyError(name)


def _numeric_metrics(metrics, env, name):
    out = {}
    for key, value in metrics.items():
        if isinstance(value, (bool, np.bool_)):
            out[f"metric_{key}"] = np.int8(bool(value))
        elif isinstance(value, (int, float, np.integer, np.floating)):
            value_f = float(value)
            if np.isfinite(value_f):
                out[f"metric_{key}"] = np.float64(value_f)
    if name == "cartpole" and "metric_ticks" not in out:
        out["metric_ticks"] = np.float64(env.step_count)
    return out


def _run_case(name, env_class):
    ticks = TICKS[name]
    effs = _effector_stream(name, ticks)
    env, draws = _make_env_recorded(env_class, ENV_SEEDS[name])

    sensors = np.zeros((ticks, env.n_receptors), dtype=float)
    state0 = _state(env, name)
    state_t = np.zeros((ticks, state0.size), dtype=float)

    for t in range(ticks):
        sensors[t] = env.sense()
        env.step(effs[t])
        state_t[t] = _state(env, name)

    metrics = env.metrics(env.default_window)
    draw_values = np.asarray(draws if draws else [0.0], dtype=float)
    out = {
        "effs": effs,
        "draws": draw_values,
        "draw_count": np.int64(len(draws)),
        "sensors_T": sensors,
        "state_T": state_t,
        "seed": np.int64(ENV_SEEDS[name]),
        "eff_seed": np.int64(EFF_SEED + sum(ord(ch) for ch in name)),
        "ticks": np.int64(ticks),
        **_numeric_metrics(metrics, env, name),
    }
    return out


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    envs = {
        "wall": WallEnv,
        "tracking": TrackingEnv,
        "pong": PongEnv,
        "cartpole": CartPoleEnv,
    }

    for name, env_class in envs.items():
        data = _run_case(name, env_class)
        out_path = OUT_DIR / f"env_{name}.npz"
        np.savez(out_path, **data)
        metric_keys = sorted(k for k in data if k.startswith("metric_"))
        print(
            f"{name}: wrote {out_path} "
            f"effs={data['effs'].shape} draws={int(data['draw_count'])} "
            f"sensors={data['sensors_T'].shape} state={data['state_T'].shape} "
            f"metrics={','.join(metric_keys)}"
        )


if __name__ == "__main__":
    main()
