from dataclasses import replace

import numpy as np
import pytest
import quadrants as qd
from brainlesslab.backend import initialise
from brainlesslab.models import falandays, sorn
from brainlesslab.specs import ExecutionSpec, NumericalPolicy


@pytest.fixture(scope="module", autouse=True)
def cpu():
    initialise(ExecutionSpec(), NumericalPolicy())


def upload(values, integer=False):
    host = np.asarray(values, dtype=np.int32 if integer else np.float32)
    result = qd.ndarray(qd.i32 if integer else qd.f32, host.shape)
    result.from_numpy(host)
    return result


@pytest.mark.parametrize(
    "module,config",
    [
        (falandays, falandays.FalandaysConfig(lrate_wmat=1e40)),
        (sorn, sorn.SORNConfig(eta_stdp=1e40)),
    ],
)
def test_precision_overflow_rejected_before_upload(module, config):
    state = module.construct(config, 2, 1, 1, np.random.default_rng(0))
    with pytest.raises(ValueError, match="after casting"):
        module.ModelBatch([state], dtype="float32")


def test_dale_clamp_cannot_hide_learning_overflow():
    config = falandays.FalandaysConfig(axis="dale", leak=0, lrate_wmat=1e38, lrate_targ=0)
    initial = falandays.construct(config, 2, 1, 1, np.random.default_rng(0))
    initial = replace(
        initial,
        weights=np.array([[0.0, 1.0], [1.0, 0.0]]),
        recurrent_mask=np.array([[0, 1], [1, 0]]),
        signs=np.ones(2),
        spikes=np.ones(2),
        input_weights=np.ones((2, 1)),
    )
    batch = falandays.ModelBatch([initial], dtype="float32")
    batch.step(upload([[1e38]]), upload([[0, 0]]), upload([1], True))
    assert batch.finite.to_numpy()[0] == 0


def test_sorn_row_sum_overflow_cannot_be_normalised_away():
    initial = sorn.construct(
        sorn.SORNConfig(inhibitory_fraction=0, eta_stdp=0, eta_ip=0),
        3,
        1,
        1,
        np.random.default_rng(0),
    )
    initial = replace(
        initial,
        w_ee=np.full((3, 3), 2e38),
        ee_mask=np.ones((3, 3)),
        c_e=np.ones(3),
        x=np.zeros(3),
        w_eu=np.zeros((3, 1)),
        t_e=np.ones(3),
    )
    batch = sorn.ModelBatch([initial], dtype="float32")
    batch.step(upload([[0]]), upload([[0, 0, 0]]), upload([1], True))
    assert batch.finite.to_numpy()[0] == 0


def test_full_falandays_reset_matches_initial_snapshot():
    initial = falandays.construct(falandays.FalandaysConfig(), 4, 1, 2, np.random.default_rng(1))
    initial = replace(initial, spikes=np.ones(4), output_mask=np.ones((4, 2)))
    batch = falandays.ModelBatch([initial], dtype="float32")
    before = batch.snapshot()
    batch.step(upload([[1]]), upload([[0, 0, 0, 0]]), upload([1], True))
    batch.freeze_plasticity(upload([1], True))
    batch.reset(upload([1], True))
    for name, value in before.items():
        np.testing.assert_array_equal(batch.snapshot()[name], value, err_msg=name)


def test_target_floor_cannot_hide_overflow():
    initial = falandays.construct(
        falandays.FalandaysConfig(lrate_wmat=0, lrate_targ=1e38, leak=0),
        2,
        1,
        1,
        np.random.default_rng(0),
    )
    initial = replace(initial, input_weights=np.ones((2, 1)))
    batch = falandays.ModelBatch([initial], dtype="float32")
    batch.step(upload([[-1e38]]), upload([[0, 0]]), upload([1], True))
    assert batch.finite.to_numpy()[0] == 0


def test_required_positive_values_cannot_underflow():
    initial = falandays.construct(
        falandays.FalandaysConfig(targ_min=1e-50), 2, 1, 1, np.random.default_rng(0)
    )
    with pytest.raises(ValueError, match="positive after casting"):
        falandays.ModelBatch([initial], dtype="float32")


def test_lossy_mask_casts_are_rejected():
    initial = falandays.construct(falandays.FalandaysConfig(), 2, 1, 1, np.random.default_rng(0))
    with pytest.raises(ValueError, match="binary before"):
        replace(initial, recurrent_mask=np.full((2, 2), 0.1))
    other = sorn.construct(sorn.SORNConfig(), 2, 1, 1, np.random.default_rng(0))
    with pytest.raises(ValueError, match="binary before"):
        replace(other, ee_mask=np.full((2, 2), 0.1))


def test_sorn_rejects_mixed_dtypes():
    initial = sorn.construct(sorn.SORNConfig(), 2, 1, 1, np.random.default_rng(0))
    batch = sorn.ModelBatch([initial], dtype="float64")
    with pytest.raises(ValueError, match="model dtype"):
        batch.step(upload([[0]]), upload([[0, 0]]), upload([1], True))
