"""Independent equation checks for the Python SORN software contract."""

from dataclasses import replace
from pathlib import Path
import tempfile

import numpy as np
import pytest
import quadrants as qd

from brainlesslab.models.sorn import ModelBatch, SORNConfig, construct


@pytest.fixture(scope="module", autouse=True)
def cpu_runtime():
    # A package-level fixture may already have selected the backend.
    try:
        qd.lang.impl.get_runtime().prog
    except qd.lang.exception.QuadrantsRuntimeError:
        qd.init(arch=qd.cpu, default_fp=qd.f64, offline_cache=False,
                cpu_max_num_threads=1, debug=True, fast_math=False,
                enable_fallback=False,
                offline_cache_file_path=str(Path(tempfile.gettempdir()) / "brainlesslab-sorn-test-cache"))


def device(values, integer=False, dtype="float64"):
    values = np.asarray(values, dtype=np.int32 if integer else dtype)
    array = qd.ndarray(qd.i32 if integer else (qd.f32 if dtype == "float32" else qd.f64), shape=values.shape)
    array.from_numpy(values)
    return array


def step(batch, inputs, active=None):
    active = np.ones(batch.batch_size, dtype=np.int32) if active is None else active
    batch.step(device(inputs, dtype=batch.dtype),
               device(np.zeros((batch.batch_size, batch.count)), dtype=batch.dtype),
               device(active, integer=True))


def equation(initial, inputs, steps):
    """Host oracle, independent of the device implementation and its buffers."""
    x, y = initial.x.copy(), initial.y.copy()
    te = initial.t_e.copy()
    weights, mask = initial.w_ee.copy(), initial.ee_mask.copy()
    config = initial.config
    for index in range(steps):
        old_x, old_y = x.copy(), y.copy()
        x = (weights @ old_x - initial.w_ei @ old_y +
             initial.w_eu @ inputs[index] - te >= 0).astype(float)
        y = (initial.w_ie @ old_x - initial.t_i >= 0).astype(float)
        if config.learn_on:
            delta = config.eta_stdp * (np.outer(x, old_x) - np.outer(old_x, x))
            weights = np.where(mask, weights + delta, 0)
            mask &= weights > 0
            weights = np.where(mask, weights, 0)
            totals = weights.sum(axis=1)
            for row in range(initial.n_e):
                if totals[row] > 0 and initial.c_e[row] > 0:
                    weights[row] *= initial.c_e[row] / totals[row]
            te += config.eta_ip * (x - config.H_ip)
    outputs = np.array([x[selection].mean() if selection.any() else 0
                        for selection in initial.output_mask])
    return x, y, weights, mask, te, outputs


@pytest.mark.parametrize("dtype,tolerance", [("float64", 1e-13), ("float32", 2e-6)])
def test_equations_against_independent_numpy(dtype, tolerance):
    initial = construct(SORNConfig(eta_stdp=0.07, eta_ip=0.03, p_ee=0.4),
                        8, 2, 3, np.random.default_rng(13))
    initial = replace(initial, x=np.array([1, 0, 1, 0, 0, 1, 0.]), y=np.ones(1))
    inputs = np.random.default_rng(29).uniform(-0.3, 1.7, size=(12, 2))
    batch = ModelBatch([initial], dtype=dtype)
    for frame, values in enumerate(inputs):
        step(batch, [values])
        x, y, weights, mask, te, outputs = equation(initial, inputs, frame + 1)
        state = batch.snapshot()
        np.testing.assert_array_equal(state["activity"][0], np.concatenate((x, y)))
        np.testing.assert_allclose(state["w_ee"][0], weights, atol=tolerance, rtol=tolerance)
        np.testing.assert_array_equal(state["ee_mask"][0], mask)
        np.testing.assert_allclose(state["t_e"][0], te, atol=tolerance, rtol=tolerance)
        np.testing.assert_allclose(state["effectors"][0], outputs, atol=tolerance)
        np.testing.assert_array_equal(state["w_ei"][0], initial.w_ei.astype(dtype))
        np.testing.assert_array_equal(state["w_ie"][0], initial.w_ie.astype(dtype))
        np.testing.assert_array_equal(state["t_i"][0], initial.t_i.astype(dtype))
        assert state["finite"][0] == 1


def test_threshold_equality_and_synchronous_old_populations():
    initial = construct(SORNConfig(learn_on=False), 3, 1, 1, np.random.default_rng(1))
    initial = replace(initial, w_ee=np.zeros((2, 2)), w_ei=np.ones((2, 1)),
                      w_ie=np.array([[1., 0.]]), w_eu=np.ones((2, 1)),
                      x=np.array([1., 0.]), y=np.array([0.]),
                      t_e=np.array([1., 1.]), t_i=np.array([1.]))
    batch = ModelBatch([initial])
    step(batch, [[1.]])
    # All drives equal thresholds. New inhibition must not affect this E update.
    np.testing.assert_array_equal(batch.activity.to_numpy(), [[1., 1., 1.]])


def test_pruning_is_permanent_zero_rows_stay_zero_and_reset_restores_mask():
    config = SORNConfig(inhibitory_fraction=0, eta_stdp=0.001, eta_ip=0)
    initial = construct(config, 2, 1, 1, np.random.default_rng(4))
    initial = replace(initial, w_ee=np.array([[0., 0.0005], [0.2, 0.]]),
                      ee_mask=np.array([[False, True], [True, False]]),
                      c_e=np.array([0.0005, 0.2]), w_eu=np.array([[1.], [0.]]),
                      t_e=np.array([2., -1.]), x=np.array([1., 0.]))
    batch = ModelBatch([initial])
    step(batch, [[0.]])
    first = batch.snapshot()
    assert first["w_ee"][0, 0, 1] == 0
    assert first["ee_mask"][0, 0, 1] == 0
    assert first["finite"][0] == 1  # No zero-row division.
    step(batch, [[3.]])  # This transition would potentiate the deleted edge.
    assert batch.snapshot()["w_ee"][0, 0, 1] == 0
    assert batch.snapshot()["ee_mask"][0, 0, 1] == 0
    batch.reset(device([1], integer=True))
    np.testing.assert_array_equal(batch.snapshot()["w_ee"][0], initial.w_ee)
    np.testing.assert_array_equal(batch.snapshot()["ee_mask"][0], initial.ee_mask)


def test_zero_original_normalisation_target_skips_scaling():
    initial = construct(SORNConfig(inhibitory_fraction=0, eta_stdp=0.1, eta_ip=0),
                        2, 1, 1, np.random.default_rng(4))
    initial = replace(initial, w_ee=np.array([[0., 0.2], [0.2, 0.]]),
                      c_e=np.zeros(2), x=np.array([1., 0.]),
                      t_e=np.array([2., -1.]))
    batch = ModelBatch([initial])
    step(batch, [[0.]])
    np.testing.assert_allclose(batch.snapshot()["w_ee"][0], [[0., 0.1], [0.3, 0.]])


def test_freeze_modes_reset_and_owned_storage():
    initial = construct(SORNConfig(eta_ip=0.04, eta_stdp=0.08),
                        5, 1, 2, np.random.default_rng(10))
    batch = ModelBatch([initial, initial, initial])
    original = batch.snapshot()
    batch.freeze_weights(device([1, 0, 0], integer=True))
    batch.freeze_plasticity(device([0, 1, 0], integer=True))
    for _ in range(4):
        step(batch, [[1.], [1.], [1.]])
    after = batch.snapshot()
    for index in (0, 1):
        np.testing.assert_array_equal(after["w_ee"][index], original["w_ee"][index])
        np.testing.assert_array_equal(after["ee_mask"][index], original["ee_mask"][index])
    assert np.any(after["t_e"][0] != original["t_e"][0])
    np.testing.assert_array_equal(after["t_e"][1], original["t_e"][1])
    assert np.any(after["t_e"][2] != original["t_e"][2])
    # Host snapshots and constructor arrays do not alias device or reset storage.
    after["w_ee"][:] = -100
    initial.w_ee[:] = -200
    batch.reset(device([1, 1, 0], integer=True))
    restored = batch.snapshot()
    for key in original:
        np.testing.assert_array_equal(restored[key][:2], original[key][:2])
    np.testing.assert_array_equal(restored["plasticity"][2], [1, 1])


def test_inactive_batch_members_are_unchanged_and_batching_matches_single():
    initials = [construct(SORNConfig(), 8, 2, 2, np.random.default_rng(seed)) for seed in (4, 5)]
    batch = ModelBatch(initials)
    single = ModelBatch(initials[:1])
    before = batch.snapshot()
    for inputs in ([[0.2, 1.]], [[0.8, 0.4]], [[0., 0.]]):
        step(single, inputs)
        step(batch, [inputs[0], [999., 999.]], active=[1, 0])
    for key, values in batch.snapshot().items():
        np.testing.assert_array_equal(values[0], single.snapshot()[key][0])
        np.testing.assert_array_equal(values[1], before[key][1])


def test_construction_ratio_fanout_no_self_and_determinism():
    initial = construct(SORNConfig(), 200, 8, 2, np.random.default_rng(6))
    same = construct(SORNConfig(), 200, 8, 2, np.random.default_rng(6))
    assert initial.n_e == 167
    assert initial.w_ie.shape == (33, 167)
    assert not np.diag(initial.ee_mask).any()
    assert np.all(initial.ee_mask.sum(axis=1) >= 1)
    np.testing.assert_array_equal((initial.w_eu > 0).sum(axis=0), np.full(8, 8))
    np.testing.assert_array_equal(initial.output_mask.sum(axis=1), [8, 8])
    np.testing.assert_allclose(initial.w_ee.sum(axis=1), 1)
    for name in ("w_ee", "ee_mask", "w_ei", "w_ie", "w_eu", "output_mask", "t_e", "t_i"):
        np.testing.assert_array_equal(getattr(initial, name), getattr(same, name))
        assert not np.shares_memory(getattr(initial, name), getattr(same, name))
    # I/E=1 with 5 nodes gives round(2.5)=2 excitatory units (ties to even).
    assert construct(SORNConfig(inhibitory_fraction=1), 5, 1, 1, np.random.default_rng(1)).n_e == 2


def test_one_node_no_inhibitory_population_and_initial_learning_disabled():
    initial = construct(SORNConfig(learn_on=False), 1, 1, 1, np.random.default_rng(3))
    batch = ModelBatch([initial])
    before = batch.snapshot()
    for _ in range(3):
        step(batch, [[1.]])
    after = batch.snapshot()
    assert after["y"].shape == (1, 0)
    assert after["w_ei"].shape == (1, 1, 0)
    assert after["w_ie"].shape == (1, 0, 1)
    np.testing.assert_array_equal(after["activity"], [[1.]])
    np.testing.assert_array_equal(after["effectors"], [[1.]])
    np.testing.assert_array_equal(after["t_e"], before["t_e"])
    np.testing.assert_array_equal(after["w_ee"], before["w_ee"])
    batch.reset(device([1], integer=True))
    np.testing.assert_array_equal(batch.snapshot()["plasticity"], [[0, 0]])


@pytest.mark.parametrize("parameters", [{"inhibitory_fraction": 1.01}, {"p_ee": -0.1},
                                       {"eta_ip": np.inf}, {"H_ip": np.nan}, {"learn_on": 1}])
def test_invalid_config_rejected(parameters):
    with pytest.raises((ValueError, TypeError)):
        SORNConfig(**parameters)


def test_incompatible_batch_and_ports_rejected():
    a = construct(SORNConfig(), 5, 1, 1, np.random.default_rng(1))
    b = construct(SORNConfig(), 6, 1, 1, np.random.default_rng(1))
    with pytest.raises(ValueError, match="dimensions"):
        ModelBatch([a, b])
    with pytest.raises(ValueError, match="w_ee"):
        ModelBatch([replace(a, w_ee=np.ones((2, 2)))])
    batch = ModelBatch([a])
    with pytest.raises(ValueError, match="inputs"):
        batch.step(device([[1., 2.]]), device(np.zeros((1, 5))), device([1], integer=True))


def test_nonfinite_drive_is_reported_even_when_threshold_output_is_binary():
    initial = construct(SORNConfig(learn_on=False), 1, 1, 1, np.random.default_rng(1))
    batch = ModelBatch([initial])
    step(batch, [[np.inf]])
    np.testing.assert_array_equal(batch.activity.to_numpy(), [[1.]])
    np.testing.assert_array_equal(batch.finite.to_numpy(), [0])
