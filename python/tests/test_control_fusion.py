"""Exact controller fusion parity in fresh strict CPU precision processes."""

import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
import quadrants as qd
from brainlesslab.specs import TASKS, TaskSpec
from brainlesslab.tasks import TaskBatch, prepare


def upload(values, dtype):
    host = np.asarray(
        values, dtype=np.int32 if dtype == qd.i32 else np.float32 if dtype == qd.f32 else np.float64
    )
    device = qd.ndarray(dtype, host.shape)
    device.from_numpy(host)
    return device


OPTIONS = {
    "delayed_cue": dict(cue_ticks=2, delays=(0, 2), response_ticks=2),
    "recall_interference": dict(cue_ticks=2, delay=32, response_ticks=2),
    "delayed_xor": dict(cue_ticks=2, gap=1, response_ticks=2),
    "evidence_accumulation": dict(pulse_count=4, evidence_fraction=0.5, response_ticks=2),
    "context_integration": dict(
        cue_ticks=2, pulse_count=4, evidence_fraction=0.5, response_ticks=2
    ),
    "temporal_order": dict(cue_ticks=2, gap=1, terminal_ticks=1, response_ticks=2),
    "reversal_adaptation": dict(
        rounds=48, cue_ticks=1, response_ticks=1, feedback_ticks=1, reversal_range=(24, 24)
    ),
}


def unfused(batch, policy, tile, horizons, guard, ticks):
    real = batch._real
    for offset in range(ticks):
        snapshot = batch.snapshot()
        mask = guard.to_numpy() * (
            (snapshot["done"] == 0) & (snapshot["finite"] != 0) & (snapshot["ticks"] < horizons)
        )
        guard.from_numpy(mask.astype(np.int32))
        indices = (
            np.minimum(snapshot["round"], tile.shape[0] - 1)
            if batch.definition.is_probe
            else offset
        )
        draws = (
            tile[indices, np.arange(batch.batch_size)]
            if batch.definition.is_probe
            else tile[offset]
        )
        randoms = upload(draws, real)
        for frame in range(1, batch.definition.neural_frames + 1):
            guard.from_numpy((guard.to_numpy() * batch.finite.to_numpy()).astype(np.int32))
            batch.encode(frame, guard)
            guard.from_numpy((guard.to_numpy() * batch.finite.to_numpy()).astype(np.int32))
            effectors = batch.control(policy, randoms, guard)
            batch.accumulate(effectors, frame, guard)
            guard.from_numpy((guard.to_numpy() * batch.finite.to_numpy()).astype(np.int32))
        batch.advance(effectors, guard)
        guard.from_numpy((guard.to_numpy() * batch.finite.to_numpy()).astype(np.int32))


def compare(left, right):
    a, b = left.snapshot(), right.snapshot()
    assert a.keys() == b.keys()
    for name in a:
        np.testing.assert_array_equal(a[name], b[name], err_msg=name)
    for name in ("memory", "counts", "effectors"):
        np.testing.assert_array_equal(
            getattr(left._controller, name).to_numpy(),
            getattr(right._controller, name).to_numpy(),
            err_msg=name,
        )
    np.testing.assert_array_equal(
        left._physical_controller.observations.to_numpy(),
        right._physical_controller.observations.to_numpy(),
    )


def exercise(dtype):
    real = qd.f32 if dtype == "float32" else qd.f64
    qd.init(
        arch=qd.cpu,
        default_fp=real,
        fast_math=False,
        enable_fallback=False,
        debug=True,
        cpu_max_num_threads=1,
        offline_cache=False,
        offline_cache_file_path=os.environ["BRAINLESSLAB_FUSION_CACHE"],
        raise_on_templated_floats=True,
    )
    cases = 0
    for kind in TASKS:
        spec = TaskSpec(kind, OPTIONS.get(kind, {}))
        initials = [prepare(spec, np.random.default_rng(seed), horizon=240) for seed in (1, 3, 8)]
        reference = TaskBatch(initials, dtype=dtype)
        for policy in sorted(reference._allowed_controls):
            warmup = 3 if kind in ("tracking", "pong") else 0
            slow, fast = [TaskBatch(initials, dtype=dtype, warmup=warmup) for _ in range(2)]
            horizon = 220 if kind == "pong" else 32 if kind == "cartpole_plank_easy" else 20
            if reference.definition.is_probe:
                horizon = max(v.stimuli.shape[0] for v in initials) + 3
            horizons = np.array([horizon, max(1, horizon - 3), horizon], np.int32)
            slow_guard, fast_guard = [upload([1, 1, 0], qd.i32) for _ in range(2)]
            rng = np.random.default_rng(991)
            episode = rng.random((max(1, max(v.labels.size for v in initials)), 3))
            for count in (3, horizon - 1):
                tile = episode if reference.definition.is_probe else rng.random((count, 3))
                tile = tile.astype(dtype)
                unfused(slow, policy, tile, horizons, slow_guard, count)
                output = fast.run_control(
                    policy,
                    upload(tile, real),
                    upload(horizons, qd.i32),
                    fast_guard,
                    tile_ticks=count,
                )
                assert output is fast._controller.effectors
                compare(slow, fast)
                np.testing.assert_array_equal(slow_guard.to_numpy(), fast_guard.to_numpy())
            cases += 1
    # Numerical failure discovered by an encoder must mask the controller in
    # that same frame and remain masked for every later frame and tick.
    for kind in ("tracking", "cartpole_plank_easy"):
        initials = [prepare(TaskSpec(kind), np.random.default_rng(9))]
        slow, fast = [TaskBatch(initials, dtype=dtype) for _ in range(2)]
        for batch in (slow, fast):
            state = batch._state.physical.to_numpy()
            state[0, 0] = np.inf
            batch._state.physical.from_numpy(state)
        horizons = np.array([4], np.int32)
        tile = np.full((4, 1), 0.7, dtype=dtype)
        a, b = [upload([1], qd.i32) for _ in range(2)]
        unfused(slow, "reference_null", tile, horizons, a, 4)
        fast.run_control("reference_null", upload(tile, real), upload(horizons, qd.i32), b, 4)
        compare(slow, fast)
        np.testing.assert_array_equal(a.to_numpy(), b.to_numpy())
        assert fast.finite.to_numpy()[0] == 0
    # Host argument validation happens without dispatching another kernel.
    batch = TaskBatch([prepare(TaskSpec("delayed_cue"), np.random.default_rng(9))], dtype=dtype)
    tile, horizon = upload([[0.4]], real), upload([4], qd.i32)
    for kwargs in (
        {"policy": "reservoir"},
        {"uniform_tile": upload([0.4], real)},
        {"horizons": upload([4], real)},
        {"tile_ticks": False},
        {"active_guard": upload([1], real)},
    ):
        arguments = dict(policy="oracle", uniform_tile=tile, horizons=horizon)
        arguments.update(kwargs)
        with pytest.raises(ValueError):
            batch.run_control(**arguments)
    print(f"{dtype}: {cases} task/controller pairs, failure masks and argument checks passed")


@pytest.mark.parametrize("dtype", ["float64", "float32"])
def test_all_controls_match_unfused_in_fresh_precision_process(dtype, tmp_path):
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(Path(__file__).resolve().parents[1] / "src")
    environment["BRAINLESSLAB_FUSION_CACHE"] = str(tmp_path / dtype)
    result = subprocess.run(
        [sys.executable, __file__, "--worker", dtype],
        env=environment,
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "task/controller pairs" in result.stdout


if __name__ == "__main__":
    exercise(sys.argv[-1])
