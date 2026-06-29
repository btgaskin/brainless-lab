#!/usr/bin/env python3
"""Generate NumPy oracle fixtures for the compartmental reservoir family."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np


SCRIPT = Path(__file__).resolve()
NEURAL_COGNITION = SCRIPT.parents[3]
V0_ROOT = Path.cwd()
if not (V0_ROOT / "crho").is_dir():
    V0_ROOT = NEURAL_COGNITION / "v0"
sys.path.insert(0, str(V0_ROOT))

from crho import cell  # noqa: E402
from crho.reservoir import Reservoir, build_wiring  # noqa: E402
from crho.sweep import find_alive_centroid  # noqa: E402


OUT_DIR = SCRIPT.parents[1] / "fixtures"
N = 24
N_RECEPTORS = 8
N_EFFECTORS = 2
TICKS = 40
INPUT_SEED = 20260628
WIRING_SEEDS = {
    "dense": 41001,
    "structured": 42001,
}


def _sigmoid(z):
    return 1.0 / (1.0 + np.exp(-np.clip(z, -60.0, 60.0)))


def _input_stream():
    rng = np.random.default_rng(INPUT_SEED)
    return rng.random((TICKS, N_RECEPTORS), dtype=float)


def _alive_raw(mode):
    cache_path = OUT_DIR / f"compartmental_{mode}_alive_raw.npy"
    return find_alive_centroid(
        mode=mode,
        N=N,
        ticks=120,
        n_samples=120,
        search_seed=0,
        cache_path=cache_path,
    )


def _empty_dense_wiring_arrays(wiring):
    # Dense mode does not use the structured-only routing arrays, but NPZ.jl
    # cannot read zero-size arrays, so emit non-empty zero placeholders of the
    # natural structured shapes (the dense Julia step! ignores them).
    N, K, S = int(wiring.N), int(wiring.K), int(cell.S)
    if wiring.fwd_unit is None:
        fwd_unit = np.zeros((N, K), dtype=np.int64)
    else:
        fwd_unit = np.asarray(wiring.fwd_unit, dtype=np.int64).copy()

    if wiring.back_src is None:
        back_src = np.zeros((N, K), dtype=np.int64)
    else:
        back_src = np.asarray(wiring.back_src, dtype=np.int64).copy()

    if wiring.R_fwd is None:
        R_fwd = np.zeros((N, K, S), dtype=float)
    else:
        R_fwd = np.asarray(wiring.R_fwd, dtype=float).copy()

    if wiring.fwd_count is None:
        fwd_count = np.zeros((N, S), dtype=float)
    else:
        fwd_count = np.asarray(wiring.fwd_count, dtype=float).copy()

    return fwd_unit, back_src, R_fwd, fwd_count


def _wiring_snapshot(wiring):
    fwd_unit, back_src, R_fwd, fwd_count = _empty_dense_wiring_arrays(wiring)
    return {
        "N": np.int64(wiring.N),
        "K_rec": np.int64(wiring.K_rec),
        "K_in": np.int64(wiring.K_in),
        "K": np.int64(wiring.K),
        "n_receptors": np.int64(wiring.n_receptors),
        "n_effectors": np.int64(wiring.n_effectors),
        "dend_source": np.asarray(wiring.dend_source, dtype=np.int64).copy(),
        "node_sources": np.asarray(wiring.node_sources, dtype=np.int64).copy(),
        "receptor_sources": np.asarray(wiring.receptor_sources, dtype=np.int64).copy(),
        "fwd_unit": fwd_unit,
        "back_src": back_src,
        "R_fwd": R_fwd,
        "fwd_count": fwd_count,
        "M_ne": np.asarray(wiring.M_ne, dtype=np.int8).copy(),
    }


def _drive_phi(reservoir):
    g = reservoir.g
    soma_out = _sigmoid(reservoir.soma_y)
    if g.mode == "dense":
        drive = soma_out @ g.w_s_drv
        phi = g.thr_base + g.thr_gain * (soma_out @ g.w_s_thr)
    else:
        drive = g.w_drv * soma_out[:, cell.DRIVE_UNIT]
        phi = soma_out[:, cell.THR_UNIT]
    return drive.astype(float), phi.astype(float)


def _run_fixture(raw, wiring, inputs):
    reservoir = Reservoir(raw, wiring)

    dend_y_T = np.zeros((TICKS, wiring.N * wiring.K * cell.D), dtype=float)
    soma_y_T = np.zeros((TICKS, wiring.N * cell.S), dtype=float)
    V_T = np.zeros((TICKS, wiring.N), dtype=float)
    spikes_T = np.zeros((TICKS, wiring.N), dtype=float)
    margin_T = np.zeros((TICKS, wiring.N), dtype=float)

    for t in range(TICKS):
        prev_V = reservoir.V.copy()
        spikes = reservoir.step(inputs[t])
        drive, phi = _drive_phi(reservoir)
        V_after = prev_V + reservoir.dt * (-prev_V + drive) / reservoir.hill_tau

        dend_y_T[t] = reservoir.dend_y.reshape(-1)
        soma_y_T[t] = reservoir.soma_y.reshape(-1)
        V_T[t] = reservoir.V
        spikes_T[t] = spikes
        margin_T[t] = V_after - phi

    return {
        "inputs": inputs,
        "dend_y_T": dend_y_T,
        "soma_y_T": soma_y_T,
        "V_T": V_T,
        "spikes_T": spikes_T,
        "margin_T": margin_T,
    }


def _build_spiking_case(mode, raw, inputs):
    seed0 = WIRING_SEEDS[mode]
    last_data = None
    last_wiring = None
    last_seed = None

    for attempt in range(60):
        wiring_seed = seed0 + attempt
        wiring = build_wiring(
            N,
            seed=wiring_seed,
            n_receptors=N_RECEPTORS,
            n_effectors=N_EFFECTORS,
            mode=mode,
        )
        data = _run_fixture(raw, wiring, inputs)
        total_spikes = float(np.sum(data["spikes_T"]))
        last_data = data
        last_wiring = wiring
        last_seed = wiring_seed
        if total_spikes > 0.0:
            return wiring, data, wiring_seed

    raise RuntimeError(
        f"{mode}: no spiking fixture after 60 wiring seeds; "
        f"last_seed={last_seed} total_spikes={float(np.sum(last_data['spikes_T'])) if last_data is not None else 0.0}"
    )


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for mode in ("dense", "structured"):
        inputs = _input_stream()
        raw = np.asarray(_alive_raw(mode), dtype=float)
        expected = cell.dim_for(mode)
        if raw.shape != (expected,):
            raise RuntimeError(f"{mode}: expected raw shape {(expected,)}, got {raw.shape}")

        wiring, data, wiring_seed = _build_spiking_case(mode, raw, inputs)
        out = {
            "mode_id": np.int64(0 if mode == "dense" else 1),
            "raw": raw,
            "D": np.int64(cell.D),
            "S": np.int64(cell.S),
            "hill_tau": np.float64(3.5),
            "hill_reset": np.float64(0.0),
            "input_seed": np.int64(INPUT_SEED),
            "wiring_seed": np.int64(wiring_seed),
            **_wiring_snapshot(wiring),
            **data,
        }

        out_path = OUT_DIR / f"compartmental_{mode}.npz"
        np.savez(out_path, **out)
        print(
            f"{mode}: wrote {out_path} "
            f"N={wiring.N} K={wiring.K} raw={raw.shape} "
            f"inputs={data['inputs'].shape} total_spikes={float(np.sum(data['spikes_T'])):.0f}"
        )


if __name__ == "__main__":
    main()
