#!/usr/bin/env python3
"""Generate NumPy oracle fixtures for compartmental ablations."""

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
from crho.reservoir import Reservoir, Wiring, build_wiring  # noqa: E402
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
ABLATION_MODES = ("normal", "no_soma_back", "no_hillock_back", "reset_dendrites")


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


def _schema_offset(mode, name):
    offset = 0
    for field, shape in cell.schema_for(mode):
        size = int(np.prod(shape))
        if field == name:
            return offset, offset + size
        offset += size
    raise KeyError(f"{mode}: unknown genome field {name!r}")


def _zero_block(raw, mode, name):
    out = np.asarray(raw, dtype=float).copy()
    start, stop = _schema_offset(mode, name)
    out[start:stop] = 0.0
    return out


def _variant_raw(raw, mode, ablation):
    if ablation == "normal" or ablation == "reset_dendrites":
        return np.asarray(raw, dtype=float).copy()
    if ablation == "no_soma_back":
        return _zero_block(raw, mode, "W_s_d" if mode == "dense" else "w_back")
    if ablation == "no_hillock_back":
        return _zero_block(raw, mode, "w_h_s" if mode == "dense" else "w_hb")
    raise ValueError(f"unknown ablation mode {ablation!r}")


def _empty_dense_wiring_arrays(wiring):
    N_, K, S = int(wiring.N), int(wiring.K), int(cell.S)
    if wiring.fwd_unit is None:
        fwd_unit = np.zeros((N_, K), dtype=np.int64)
    else:
        fwd_unit = np.asarray(wiring.fwd_unit, dtype=np.int64).copy()

    if wiring.back_src is None:
        back_src = np.zeros((N_, K), dtype=np.int64)
    else:
        back_src = np.asarray(wiring.back_src, dtype=np.int64).copy()

    if wiring.R_fwd is None:
        R_fwd = np.zeros((N_, K, S), dtype=float)
    else:
        R_fwd = np.asarray(wiring.R_fwd, dtype=float).copy()

    if wiring.fwd_count is None:
        fwd_count = np.zeros((N_, S), dtype=float)
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


def _wiring_from_snapshot(data, mode):
    M_ne = np.asarray(data["M_ne"], dtype=bool).copy()
    effector_sources = tuple(
        np.flatnonzero(M_ne[:, k]).astype(int) for k in range(M_ne.shape[1])
    )
    fwd_unit = np.asarray(data["fwd_unit"], dtype=int).copy()
    back_src = np.asarray(data["back_src"], dtype=int).copy()
    R_fwd = np.asarray(data["R_fwd"], dtype=float).copy()
    fwd_count = np.asarray(data["fwd_count"], dtype=float).copy()

    if mode == "dense":
        fwd_unit = None
        back_src = None
        R_fwd = None
        fwd_count = None

    return Wiring(
        N=int(data["N"]),
        mode=mode,
        n_receptors=int(data["n_receptors"]),
        n_effectors=int(data["n_effectors"]),
        K_rec=int(data["K_rec"]),
        K_in=int(data["K_in"]),
        K=int(data["K"]),
        dend_source=np.asarray(data["dend_source"], dtype=int).copy(),
        node_sources=np.asarray(data["node_sources"], dtype=int).copy(),
        receptor_sources=np.asarray(data["receptor_sources"], dtype=int).copy(),
        M_ne=M_ne,
        effector_sources=effector_sources,
        fwd_unit=fwd_unit,
        back_src=back_src,
        R_fwd=R_fwd,
        fwd_count=fwd_count,
    )


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


def _run_fixture(raw, wiring, inputs, ablation):
    reservoir = Reservoir(_variant_raw(raw, wiring.mode, ablation), wiring)
    ticks = int(inputs.shape[0])

    dend_y_T = np.zeros((ticks, wiring.N * wiring.K * cell.D), dtype=float)
    soma_y_T = np.zeros((ticks, wiring.N * cell.S), dtype=float)
    V_T = np.zeros((ticks, wiring.N), dtype=float)
    spikes_T = np.zeros((ticks, wiring.N), dtype=float)
    margin_T = np.zeros((ticks, wiring.N), dtype=float)

    for t in range(ticks):
        prev_V = reservoir.V.copy()
        spikes = reservoir.step(inputs[t])
        drive, phi = _drive_phi(reservoir)
        V_after = prev_V + reservoir.dt * (-prev_V + drive) / reservoir.hill_tau

        if ablation == "reset_dendrites":
            reservoir.dend_y[:] = 0.0

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


def _base_case_from_compartmental_fixture(mode):
    path = OUT_DIR / f"compartmental_{mode}.npz"
    if not path.is_file():
        return None

    with np.load(path) as data:
        raw = np.asarray(data["raw"], dtype=float).copy()
        inputs = np.asarray(data["inputs"], dtype=float).copy()
        wiring = _wiring_from_snapshot(data, mode)
        wiring_seed = int(data["wiring_seed"]) if "wiring_seed" in data else WIRING_SEEDS[mode]
    return raw, inputs, wiring, wiring_seed


def _build_candidate(mode, raw, inputs, seed):
    wiring = build_wiring(
        N,
        seed=seed,
        n_receptors=N_RECEPTORS,
        n_effectors=N_EFFECTORS,
        mode=mode,
    )
    normal = _run_fixture(raw, wiring, inputs, "normal")
    reset = _run_fixture(raw, wiring, inputs, "reset_dendrites")
    return wiring, normal, reset


def _build_load_bearing_case(mode):
    base = _base_case_from_compartmental_fixture(mode)
    if base is None:
        inputs = _input_stream()
        raw = np.asarray(_alive_raw(mode), dtype=float)
        seed0 = WIRING_SEEDS[mode]
    else:
        raw, inputs, wiring, wiring_seed = base
        normal = _run_fixture(raw, wiring, inputs, "normal")
        reset = _run_fixture(raw, wiring, inputs, "reset_dendrites")
        if np.any(normal["spikes_T"] != reset["spikes_T"]):
            return raw, inputs, wiring, wiring_seed, normal, reset
        seed0 = wiring_seed + 1

    expected = cell.dim_for(mode)
    if raw.shape != (expected,):
        raise RuntimeError(f"{mode}: expected raw shape {(expected,)}, got {raw.shape}")

    last_total = 0.0
    for attempt in range(120):
        wiring_seed = seed0 + attempt
        wiring, normal, reset = _build_candidate(mode, raw, inputs, wiring_seed)
        last_total = float(np.sum(normal["spikes_T"]))
        if last_total > 0.0 and np.any(normal["spikes_T"] != reset["spikes_T"]):
            return raw, inputs, wiring, wiring_seed, normal, reset

    raise RuntimeError(
        f"{mode}: no load-bearing reset_dendrites fixture after 120 seeds; "
        f"last total_spikes={last_total:.0f}"
    )


def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for mode in ("dense", "structured"):
        raw, inputs, wiring, wiring_seed, normal, reset = _build_load_bearing_case(mode)
        data_by_ablation = {
            "normal": normal,
            "reset_dendrites": reset,
            "no_soma_back": _run_fixture(raw, wiring, inputs, "no_soma_back"),
            "no_hillock_back": _run_fixture(raw, wiring, inputs, "no_hillock_back"),
        }

        for ablation in ABLATION_MODES:
            out = {
                "mode_id": np.int64(0 if mode == "dense" else 1),
                "ablation_id": np.int64(ABLATION_MODES.index(ablation)),
                "raw": raw,
                "raw_variant": _variant_raw(raw, mode, ablation),
                "D": np.int64(cell.D),
                "S": np.int64(cell.S),
                "hill_tau": np.float64(3.5),
                "hill_reset": np.float64(0.0),
                "input_seed": np.int64(INPUT_SEED),
                "wiring_seed": np.int64(wiring_seed),
                **_wiring_snapshot(wiring),
                **data_by_ablation[ablation],
            }

            out_path = OUT_DIR / f"ablation_{mode}_{ablation}.npz"
            np.savez(out_path, **out)
            print(
                f"{mode}/{ablation}: wrote {out_path} "
                f"N={wiring.N} K={wiring.K} total_spikes={float(np.sum(out['spikes_T'])):.0f}"
            )


if __name__ == "__main__":
    main()
