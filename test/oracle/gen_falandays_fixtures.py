#!/usr/bin/env python3
"""Generate NumPy oracle fixtures for the Falandays reservoir family."""

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

from crho.falandays import FalandaysParams, FalandaysReservoir  # noqa: E402
from crho.node_variant import SwarmVariantReservoir  # noqa: E402


OUT_DIR = SCRIPT.parents[1] / "fixtures"
N = 24
N_RECEPTORS = 8
N_EFFECTORS = 2
TICKS = 40
INPUT_SEED = 20260628
BASE_SEED = 19001
OOSAWA_SEED = 19002
DALE_SEED = 19003


class RecordingNoise:
    def __init__(self, rng):
        self.rng = rng
        self.draws = []

    def standard_normal(self, size=None):
        draw = self.rng.standard_normal(size)
        self.draws.append(np.asarray(draw, dtype=float).copy())
        return draw


def _input_stream():
    rng = np.random.default_rng(INPUT_SEED)
    return rng.random((TICKS, N_RECEPTORS), dtype=float)


def _params_dict(params: FalandaysParams, reservoir, membrane_noise, noise_gain, rectify):
    input_weight = (
        float(params.input_weight)
        if params.input_weight is not None
        else float(reservoir.input_weight)
    )
    return {
        "leak": float(params.leak),
        "lrate_wmat": float(params.lrate_wmat),
        "lrate_targ": float(params.lrate_targ),
        "threshold_mult": float(params.threshold_mult),
        "targ_min": float(params.targ_min),
        "input_weight": input_weight,
        "weight_init_std": float(params.weight_init_std),
        "learn_on": np.int8(bool(params.learn_on)),
        "membrane_noise": float(membrane_noise),
        "noise_gain": float(noise_gain),
        "rectify": np.int8(bool(rectify)),
    }


def _snapshot(reservoir, signed):
    sign = (
        np.asarray(reservoir.inhibitory_nodes, dtype=np.int64).copy()
        if signed
        else np.ones(reservoir.N, dtype=np.int64)
    )
    recurrent_mask = (
        np.asarray(reservoir.link_mat, dtype=bool).copy()
        if signed
        else np.asarray(reservoir.recurrent_mask, dtype=bool).copy()
    )
    return {
        "input_wmat": np.asarray(reservoir.input_wmat, dtype=float).copy(),
        "wmat0": np.asarray(reservoir.wmat, dtype=float).copy(),
        "recurrent_mask": recurrent_mask,
        "output_mask": np.asarray(reservoir.output_mask, dtype=float).copy(),
        "sign": sign,
    }


def _run_case(name, reservoir, params, inputs, membrane_noise, noise_gain, rectify):
    recorder = None
    if membrane_noise > 0.0 or noise_gain > 0.0:
        recorder = RecordingNoise(reservoir._noise_rng)
        reservoir._noise_rng = recorder

    acts_t = np.zeros((TICKS, reservoir.N), dtype=float)
    targets_t = np.zeros((TICKS, reservoir.N), dtype=float)
    spikes_t = np.zeros((TICKS, reservoir.N), dtype=float)
    margin_t = np.zeros((TICKS, reservoir.N), dtype=float)

    for t in range(TICKS):
        thresholds = reservoir.targets.copy() * params.threshold_mult
        spikes = reservoir.step(inputs[t])
        acts_before_subtract = reservoir.acts + spikes * thresholds
        margin_t[t] = acts_before_subtract - thresholds
        acts_t[t] = reservoir.acts
        targets_t[t] = reservoir.targets
        spikes_t[t] = spikes

    if recorder is None:
        noise_draws = np.zeros((TICKS, reservoir.N), dtype=float)
    else:
        noise_draws = np.vstack(recorder.draws).astype(float)
        if noise_draws.shape != (TICKS, reservoir.N):
            raise RuntimeError(
                f"{name}: expected noise draws {(TICKS, reservoir.N)}, got {noise_draws.shape}"
            )

    return {
        "inputs": inputs,
        "noise_draws": noise_draws,
        "acts_T": acts_t,
        "targets_T": targets_t,
        "spikes_T": spikes_t,
        "margin_T": margin_t,
        **_params_dict(params, reservoir, membrane_noise, noise_gain, rectify),
    }


def build_base(inputs):
    params = FalandaysParams.default()
    reservoir = FalandaysReservoir(
        N,
        N_RECEPTORS,
        N_EFFECTORS,
        params,
        BASE_SEED,
    )
    data = _snapshot(reservoir, signed=False)
    data.update(_run_case("base", reservoir, params, inputs, 0.0, 0.0, True))
    return data


def build_oosawa(inputs):
    params = FalandaysParams.default()
    membrane_noise = 1.0
    noise_gain = 0.5
    reservoir = FalandaysReservoir(
        N,
        N_RECEPTORS,
        N_EFFECTORS,
        params,
        OOSAWA_SEED,
        membrane_noise=membrane_noise,
        noise_gain=noise_gain,
    )
    data = _snapshot(reservoir, signed=False)
    data.update(_run_case("oosawa", reservoir, params, inputs, membrane_noise, noise_gain, True))
    return data


def build_dale(inputs):
    params = FalandaysParams.default()
    membrane_noise = 0.0
    noise_gain = 0.0
    reservoir = SwarmVariantReservoir(
        N,
        N_RECEPTORS,
        N_EFFECTORS,
        params,
        DALE_SEED,
        membrane_noise=membrane_noise,
        noise_gain=noise_gain,
    )
    data = _snapshot(reservoir, signed=True)
    data.update(
        _run_case(
            "dale",
            reservoir,
            params,
            inputs,
            membrane_noise,
            noise_gain,
            not reservoir.acts_neg,
        )
    )
    data["acts_neg"] = np.int8(bool(reservoir.acts_neg))
    return data


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    builders = {
        "base": build_base,
        "oosawa": build_oosawa,
        "dale": build_dale,
    }

    for name, builder in builders.items():
        inputs = _input_stream()
        data = builder(inputs)
        out_path = OUT_DIR / f"falandays_{name}.npz"
        np.savez(out_path, **data)
        print(
            f"{name}: wrote {out_path} "
            f"inputs={data['inputs'].shape} noise_draws={data['noise_draws'].shape}"
        )


if __name__ == "__main__":
    main()
