from dataclasses import replace
import json

import numpy as np
import pytest

from brainlesslab.calibration import (CalibrationSignature, analytic_calibration,
                                      create_empirical_calibration, adjusted_interval,
                                      null_adjusted)
from brainlesslab.random import generator
from brainlesslab.specs import NumericalPolicy, plain


def signature(task="tracking", **changes):
    values = dict(task=task, task_options={}, initialisation_policy="task-default-v1",
                  scoring_horizon=2000, warmup=0, action_cadence=1,
                  numerics=NumericalPolicy(), world_source_hashes={"world": "sha256-example"})
    values.update(changes)
    return CalibrationSignature(**values)


def empirical(scores=None):
    scores = np.tile([0.2, 0.4, 0.6, 0.8], 256) if scores is None else scores
    return create_empirical_calibration(signature(), scores, root_seed=11, repetitions=100)


def test_content_identity_ownership_signature_and_empirical_uncertainty():
    options = {"nested": [1, 2]}
    sig = signature(task_options=options)
    old_id = sig.id
    options["nested"].append(3)
    assert sig.id == old_id
    scores = np.tile([0.2, 0.4, 0.6, 0.8], 256)
    record = create_empirical_calibration(sig, scores, root_seed=11, repetitions=100)
    assert record.null_mean == pytest.approx(0.5)
    assert record.null_standard_error == pytest.approx(scores.std(ddof=1) / np.sqrt(1024))
    assert record.null_interval[0] < 0.5 < record.null_interval[1]
    scores[:] = 0
    assert record.trial_scores[1] == 0.4
    assert record.frozen
    same = create_empirical_calibration(sig, record.trial_scores, root_seed=11, repetitions=100)
    assert same.id == record.id
    assert create_empirical_calibration(sig, record.trial_scores, root_seed=12, repetitions=100).id != record.id
    json.dumps(plain(record), allow_nan=False)


def test_task_and_protocol_signature_changes_not_reservoir_design():
    sig = signature()
    for field, value in (("scoring_horizon", 2001), ("warmup", 1), ("action_cadence", 2),
                         ("world_source_hashes", {"world": "different"}),
                         ("numerics", NumericalPolicy(dtype="float32")),
                         ("null_policy", "different-policy")):
        assert replace(sig, **{field: value}).id != sig.id
    for forbidden in ("node", "input_gain", "count", "topology"):
        with pytest.raises(ValueError, match="reservoir"):
            signature(task_options={forbidden: 1})


def test_analytic_chance_and_upper_bound_are_declared_without_oracle_claim():
    cal = analytic_calibration(signature("delayed_cue"))
    assert cal.null_mean == 0.5 and cal.upper_bound == 1
    assert cal.null_standard_error == 0 and cal.trial_scores == ()
    assert cal.null_interval == (0.5, 0.5)
    with pytest.raises(ValueError, match="binary"):
        analytic_calibration(signature("pong"))
    cart = create_empirical_calibration(signature("cartpole_plank_easy"),
                                        np.full(1024, 1000.), repetitions=10)
    assert cart.upper_bound == 15000


def test_adjustment_keeps_raw_negative_values_and_calibration_identity():
    cal = analytic_calibration(signature("delayed_cue"))
    outcome = null_adjusted(0.25, cal, key="recall_accuracy", scoring_window=100)
    assert outcome.raw == 0.25 and outcome.normalised == -0.5
    assert outcome.key == "recall_accuracy" and outcome.calibration_id == cal.id
    assert outcome.scoring_window == 100
    assert null_adjusted(1.1, cal).normalised == pytest.approx(1.2)  # No clipping.
    assert null_adjusted(0.25, None).normalisation_status == "calibration_unavailable"
    assert null_adjusted(None, cal).normalisation_status == "no_scalar_outcome"


def test_bootstrap_uses_independent_model_blocks_and_null_trajectories():
    cal = empirical()
    blocks = np.array([0.6, 0.7, 0.8, 0.9])
    result = adjusted_interval(blocks, cal, seed=41, repetitions=200)
    model_rng = generator(41, "uncertainty", "model-block-bootstrap", cal.id)
    null_rng = generator(41, "uncertainty", "calibration-trajectory-bootstrap", cal.id)
    scores = np.array(cal.trial_scores)
    model_draws, null_draws = [], []
    for _ in range(200):
        model_draws.append(np.mean(blocks[model_rng.integers(0, 4, size=4)]))
        null_draws.append(np.mean(scores[null_rng.integers(0, 1024, size=1024)]))
    ratios = (np.array(model_draws) - null_draws) / (1 - np.array(null_draws))
    np.testing.assert_array_equal(result.interval, np.quantile(ratios, [.025, .975], method="linear"))
    np.testing.assert_array_equal(result.raw_interval, np.quantile(model_draws, [.025, .975], method="linear"))
    np.testing.assert_array_equal(result.null_interval, np.quantile(null_draws, [.025, .975], method="linear"))
    assert result.estimate == pytest.approx(0.5)
    assert result.status == "available"


def test_calibration_uncertainty_is_propagated_even_when_model_blocks_equal():
    result = adjusted_interval([0.8, 0.8], empirical(), seed=33, repetitions=200)
    assert result.raw_interval == (0.8, 0.8)
    assert result.interval[0] < result.estimate < result.interval[1]


def test_one_block_has_no_adjusted_or_raw_interval():
    result = adjusted_interval([0.7], empirical())
    assert result.interval is None and result.raw_interval is None
    assert result.status == "insufficient_independent_blocks"
    assert result.repetitions == 0


def test_invalid_denominator_point_and_draws_are_unavailable_never_dropped():
    cal = empirical(np.ones(1024))
    outcome = null_adjusted(0.8, cal)
    assert outcome.normalised is None
    assert outcome.normalisation_status == "invalid_calibration_denominator"
    result = adjusted_interval([0.8, 0.9], cal, repetitions=30)
    assert result.interval is None and result.invalid_denominator_draws == 30
    assert result.repetitions == 30
    assert result.raw_interval is not None and result.null_interval == (1., 1.)
    # A valid point estimate cannot rescue a draw whose sampled null equals U.
    scores = np.ones(1024)
    scores[0] = 0
    near = empirical(scores)
    result = adjusted_interval([0.8, 0.9], near, seed=0, repetitions=100)
    assert result.estimate is not None and result.interval is None
    assert 0 < result.invalid_denominator_draws < 100


def test_invalid_calibration_inputs_rejected():
    for scores in ([0.5] * 100, [np.nan] * 1024, [-1.1] * 1024, [2.] * 1024):
        with pytest.raises(ValueError):
            create_empirical_calibration(signature(), scores)
    with pytest.raises(ValueError, match="unique"):
        create_empirical_calibration(signature(), [0.5] * 1024, trajectory_ids=[1] * 1024)
    with pytest.raises(ValueError, match="finite"):
        adjusted_interval([np.nan, 0.5], empirical())
    with pytest.raises(ValueError, match="hash"):
        replace(empirical(), null_mean=0.9)
