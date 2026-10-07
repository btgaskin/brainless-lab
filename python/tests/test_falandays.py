"""Implementation conformance, not publication or behavioural validation.

NPZ inputs come from the immutable predecessor implementation fixtures. The
authors JLD2 files are repository transcriptions, not the authors' own data.
"""

import hashlib
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest
import quadrants as qd
from brainlesslab.models.falandays import FalandaysConfig, InitialState, ModelBatch, construct

FIXTURES = Path(__file__).resolve().parents[2] / "test" / "fixtures"
HASHES = {
    "falandays.npz": "2e9ab4482e97ae190d82c28989799480f0e750c31b86833a9cdfdbd9fd643108",
    "falandays_oosawa.npz": "3f0a785508ac18d33744dae7dd134d3a1b39333ff88564f5b6b26e9158f74aa2",
    "falandays_dale.npz": "1650b9c3627e626af4d6bbb504b21f3de0deeec76aa981d3d268378f946143ca",
}


@pytest.fixture(scope="module", autouse=True)
def runtime():
    # A repository conftest can initialise another explicitly selected backend.
    try:
        _ = qd.lang.impl.get_runtime().prog
    except qd.lang.exception.QuadrantsRuntimeError:
        qd.init(
            arch=qd.cpu,
            default_fp=qd.f64,
            fast_math=False,
            enable_fallback=False,
            cpu_max_num_threads=1,
            debug=True,
            raise_on_templated_floats=True,
            offline_cache_file_path=str(
                Path(tempfile.gettempdir()) / "brainlesslab-falandays-qd-cache"
            ),
        )


def upload(value, dtype=qd.f64):
    host = np.array(
        value, dtype=np.int32 if dtype == qd.i32 else np.float32 if dtype == qd.f32 else np.float64
    )
    array = qd.ndarray(dtype, host.shape)
    array.from_numpy(host)
    return array


def fixture_initial(name):
    path = FIXTURES / name
    assert hashlib.sha256(path.read_bytes()).hexdigest() == HASHES[name]
    data = dict(np.load(path))
    config = FalandaysConfig(
        **{
            key: float(data[key])
            for key in (
                "leak",
                "lrate_wmat",
                "lrate_targ",
                "threshold_mult",
                "targ_min",
                "input_weight",
                "weight_init_std",
                "membrane_noise",
                "noise_gain",
            )
        },
        learn_on=bool(data["learn_on"]),
        rectify=bool(data["rectify"]),
        axis="dale" if "dale" in name else "unsigned",
        drive="oosawa" if "oosawa" in name else "none",
    )
    initial = InitialState.from_source_target(
        config,
        **{
            key: data[key]
            for key in ("wmat0", "recurrent_mask", "input_wmat", "output_mask", "sign")
        },
    )
    return initial, data


def reference_step(initial, state, inputs, noise, weights_enabled=True, learning_enabled=True):
    """Independent NumPy equations; never selected as a production backend."""
    config = initial.config
    previous = state["spikes"].copy()
    acts = state["acts"] * (1 - config.leak)
    acts += initial.input_weights @ inputs
    acts += state["weights"] @ (previous * initial.signs)
    threshold = state["targets"] * config.threshold_mult
    if config.drive == "oosawa":
        acts += noise * (
            config.membrane_noise + config.noise_gain * np.maximum(0, threshold - acts)
        )
    if config.rectify:
        acts = np.maximum(0, acts)
    spikes = (acts >= threshold).astype(float)
    acts -= spikes * threshold
    errors = acts - state["targets"]
    weights = state["weights"].copy()
    targets = state["targets"].copy()
    if config.learn_on and learning_enabled:
        if weights_enabled:
            for i in range(previous.size):
                selected = (initial.recurrent_mask[i] != 0) & (previous != 0)
                count = np.count_nonzero(selected)
                if count:
                    delta = errors[i] / count * config.lrate_wmat
                    if config.axis == "dale":
                        weights[i, selected] -= delta * initial.signs[selected]
                        weights[i, selected] = np.maximum(0, weights[i, selected])
                    else:
                        weights[i, selected] -= delta
            if config.axis == "dale" and np.any(
                (initial.recurrent_mask != 0) & (previous[None, :] != 0)
            ):
                weights[initial.recurrent_mask == 0] = 0
        targets = np.maximum(config.targ_min, targets + errors * config.lrate_targ)
    denominator = initial.output_mask.sum(axis=0)
    effectors = np.divide(
        spikes @ initial.output_mask,
        denominator,
        out=np.zeros_like(denominator),
        where=denominator > 0,
    )
    return dict(
        acts=acts,
        targets=targets,
        spikes=spikes,
        previous=previous,
        errors=errors,
        weights=weights,
        effectors=effectors,
    )


def reference_initial(initial):
    return {
        name: np.array(getattr(initial, name), copy=True)
        for name in ("acts", "targets", "spikes", "weights")
    }


@pytest.mark.parametrize("name", HASHES)
def test_immutable_npz_trajectory(name):
    initial, data = fixture_initial(name)
    batch = ModelBatch([initial])
    active = upload([1], qd.i32)
    reference = reference_initial(initial)
    inputs = upload(np.zeros((1, initial.input_weights.shape[1])))
    noise = upload(np.zeros((1, initial.acts.size)))
    for tick, currents in enumerate(data["inputs"]):
        inputs.from_numpy(currents[None, :])
        noise.from_numpy(data["noise_draws"][tick][None, :])
        batch.step(inputs, noise, active)
        actual = batch.snapshot()
        np.testing.assert_allclose(actual["acts"][0], data["acts_T"][tick], atol=1e-9, rtol=0)
        np.testing.assert_allclose(actual["targets"][0], data["targets_T"][tick], atol=1e-9, rtol=0)
        certified = np.abs(data["margin_T"][tick]) > 1e-6
        np.testing.assert_array_equal(
            actual["spikes"][0][certified], data["spikes_T"][tick][certified]
        )
        reference = reference_step(initial, reference, currents, data["noise_draws"][tick])
        for key in reference:
            np.testing.assert_allclose(actual[key][0], reference[key], atol=1e-9, rtol=0)
        np.testing.assert_array_equal(batch.finite.to_numpy(), [1])
    assert np.mean(np.abs(data["margin_T"]) <= 1e-6) < 0.05


def tiny_initial(config=None, *, acts=None, spikes=None, weights=None, mask=None, output=None):
    config = config or FalandaysConfig(leak=0, lrate_wmat=1, lrate_targ=0.1, rectify=False)
    return InitialState(
        config,
        np.zeros((2, 2)) if weights is None else weights,
        np.ones((2, 2), dtype=np.int32) if mask is None else mask,
        np.eye(2),
        np.eye(2) if output is None else output,
        np.ones(2, dtype=np.int32),
        np.zeros(2) if acts is None else acts,
        np.ones(2),
        np.zeros(2) if spikes is None else spikes,
    )


def test_threshold_equality_residual_error_and_target_floor():
    initial = tiny_initial()
    batch = ModelBatch([initial])
    batch.step(upload([[2, -3]]), upload([[0, 0]]), upload([1], qd.i32))
    actual = batch.snapshot()
    np.testing.assert_array_equal(actual["spikes"], [[1, 0]])
    np.testing.assert_array_equal(actual["acts"], [[0, -3]])
    np.testing.assert_array_equal(actual["errors"], [[-1, -4]])
    np.testing.assert_array_equal(actual["targets"], [[1, 1]])
    np.testing.assert_array_equal(actual["weights"], [initial.weights])


def test_learning_uses_previous_spikes_and_destination_mask():
    initial = tiny_initial(spikes=[1, 0], weights=[[0, 7], [0, 0]], mask=[[1, 0], [1, 1]])
    batch = ModelBatch([initial])
    batch.step(upload([[0, 1.5]]), upload([[0, 0]]), upload([1], qd.i32))
    actual = batch.snapshot()
    np.testing.assert_array_equal(actual["spikes"], [[0, 0]])
    np.testing.assert_array_equal(actual["weights"], [[[1, 7], [-0.5, 0]]])
    np.testing.assert_array_equal(actual["previous"], [[1, 0]])
    np.testing.assert_allclose(actual["targets"], [[1, 1.05]])


def test_dale_signed_learning_floor_and_unmasked_clearing():
    config = FalandaysConfig(axis="dale", leak=0, lrate_targ=0)
    initial = InitialState(
        config,
        [[0.1, 0.2], [0.4, 0.1]],
        [[1, 0], [1, 1]],
        np.eye(2),
        np.eye(2),
        [-1, 1],
        [0, 0],
        [1, 1],
        [1, 0],
    )
    batch = ModelBatch([initial])
    batch.step(upload([[0, 2]]), upload([[0, 0]]), upload([1], qd.i32))
    actual = batch.snapshot()
    reference = reference_step(initial, reference_initial(initial), [0, 2], [0, 0])
    for name in reference:
        np.testing.assert_allclose(actual[name][0], reference[name], atol=1e-12, rtol=0)
    assert actual["weights"][0, 0, 0] == 0
    assert actual["weights"][0, 0, 1] == 0


def test_freeze_weights_and_freeze_plasticity_are_distinct_and_reset_restores_flags():
    initial = tiny_initial(spikes=[1, 1])
    batch = ModelBatch([initial, initial, initial])
    batch.freeze_weights(upload([0, 1, 0], qd.i32))
    batch.freeze_plasticity(upload([0, 0, 1], qd.i32))
    inputs, noise, active = (
        upload([[1.5, 1.5]] * 3),
        upload([[0, 0]] * 3),
        upload([1, 1, 1], qd.i32),
    )
    batch.step(inputs, noise, active)
    actual = batch.snapshot()
    np.testing.assert_array_equal(actual["weights"][1:], [initial.weights, initial.weights])
    assert np.any(actual["weights"][0] != initial.weights)
    np.testing.assert_allclose(actual["targets"][:2], [[1.05, 1.05]] * 2)
    np.testing.assert_array_equal(actual["targets"][2], [1, 1])
    batch.reset(upload([0, 1, 1], qd.i32))
    reset = batch.snapshot()
    for name in ("acts", "targets", "spikes", "weights"):
        np.testing.assert_array_equal(reset[name][0], actual[name][0])
        np.testing.assert_array_equal(reset[name][1:], [getattr(initial, name)] * 2)
    np.testing.assert_array_equal(reset["learning"], [1, 1, 1])
    np.testing.assert_array_equal(reset["weight_learning"], [1, 1, 1])
    batch.step(inputs, noise, active)
    reset = batch.snapshot()
    np.testing.assert_array_equal(reset["weights"][1:], [actual["weights"][0]] * 2)


def test_batched_slots_match_scalar_runs_and_inactive_slots_hold_state():
    rng = np.random.default_rng(42)
    initials = [
        construct(FalandaysConfig(drive="oosawa", noise_gain=0.1), 7, 3, 2, rng) for _ in range(3)
    ]
    batch = ModelBatch(initials)
    references = [reference_initial(v) for v in initials]
    active = upload([1, 0, 1], qd.i32)
    original = batch.snapshot()
    for _ in range(6):
        inputs, noise = rng.random((3, 3)), rng.standard_normal((3, 7))
        batch.step(upload(inputs), upload(noise), active)
        actual = batch.snapshot()
        for b in (0, 2):
            references[b] = reference_step(initials[b], references[b], inputs[b], noise[b])
            for key in references[b]:
                np.testing.assert_allclose(actual[key][b], references[b][key], atol=1e-12, rtol=0)
        for key in actual:
            np.testing.assert_array_equal(actual[key][1], original[key][1])


def test_construction_owned_deterministic_and_scale_preserves_draws_and_sensory_weights():
    config = FalandaysConfig(link_p=0.4, repair_masks=True, input_link_p=(0, 0.2, 0.8))
    a = construct(config, 8, 3, 2, np.random.default_rng(10))
    b = construct(replace(config, recurrent_init_scale=2), 8, 3, 2, np.random.default_rng(10))
    np.testing.assert_array_equal(b.weights, a.weights * 2)
    for key in ("input_weights", "output_mask", "recurrent_mask", "signs"):
        np.testing.assert_array_equal(getattr(a, key), getattr(b, key))
        assert not np.shares_memory(getattr(a, key), getattr(b, key))
    np.testing.assert_array_equal(a.input_weights[:, 0], np.zeros(8))
    assert np.all(a.output_mask.sum(axis=0) > 0)
    assert not np.diag(a.recurrent_mask).any()
    assert not a.weights.flags.writeable
    snapshot = ModelBatch([a]).snapshot()
    snapshot["acts"][:] = 9
    np.testing.assert_array_equal(a.acts, np.zeros(8))


def test_zero_effector_degree_float32_and_nonfinite_detection():
    batch = ModelBatch([tiny_initial(output=np.zeros((2, 2)))], dtype="float32")
    inputs = upload([[2, 0]], qd.f32)
    noise = upload([[0, 0]], qd.f32)
    active = upload([1], qd.i32)
    batch.step(inputs, noise, active)
    np.testing.assert_array_equal(batch.effectors.to_numpy(), [[0, 0]])
    assert batch.activity.to_numpy().dtype == np.float32
    inputs.from_numpy(np.array([[np.inf, 0]], dtype=np.float32))
    batch.step(inputs, noise, active)
    np.testing.assert_array_equal(batch.finite.to_numpy(), [0])
    batch.reset(active)
    np.testing.assert_array_equal(batch.finite.to_numpy(), [1])


@pytest.mark.parametrize(
    "kwargs",
    [
        dict(leak=1.1),
        dict(link_p=-0.1),
        dict(noise_gain=np.nan),
        dict(targ_min=0),
        dict(weight_init_mode="unknown"),
    ],
)
def test_invalid_config_rejected(kwargs):
    with pytest.raises(ValueError):
        FalandaysConfig(**kwargs)


def test_shape_and_dtype_contracts():
    with pytest.raises(ValueError):
        construct(FalandaysConfig(), 0, 2, 2, np.random.default_rng(1))
    with pytest.raises(ValueError):
        ModelBatch([])
    with pytest.raises(ValueError):
        ModelBatch([tiny_initial()], dtype="float16")
    batch = ModelBatch([tiny_initial()])
    with pytest.raises(ValueError):
        batch.step(upload([[0]]), upload([[0, 0]]), upload([1], qd.i32))
    with pytest.raises(ValueError):
        batch.step(upload([[0, 0]]), upload([[0, 0]]), upload([1]))
