from dataclasses import replace

import numpy as np
import pytest

from brainlesslab.analysis import ProbeEvent, ProbeTrial, decode
from brainlesslab.random import generator
from brainlesslab.specs import plain


OPTIONS = dict(fit_trials=128, validation_trials=64, evaluation_trials=128,
               split_seed=412, permutation_seed=413)


def observations(n=320):
    rng = np.random.default_rng(411)
    events, trials = [], []
    for index in range(n):
        label = 1 + index % 2
        features = np.r_[1. if label == 1 else -1., rng.normal(size=2), 4.]
        trials.append(ProbeTrial("condition", "delayed_cue", 1, index, index % 2,
                                 "fixed-wiring", f"world-{index}", "node-hash", "interface-hash"))
        for point in ("cue_end", "delay_end", "response"):
            # Coincident timestamps remain distinct semantic observation points.
            events.append(ProbeEvent("condition", "delayed_cue", 1, index, "entity-a",
                                     ("n1", "n2", "n3", "n4"), point, 10, 1, label, features))
    return events, trials


def test_equations_shared_whole_trial_splits_and_portable_metadata():
    events, trials = observations()
    results = decode(events, trials, **OPTIONS)
    first = results[0]
    assert all(r.fit_trial_ids == first.fit_trial_ids and
               r.validation_trial_ids == first.validation_trial_ids and
               r.evaluation_trial_ids == first.evaluation_trial_ids for r in results)
    fit, valid, test = map(set, (first.fit_trial_ids, first.validation_trial_ids, first.evaluation_trial_ids))
    assert not fit & valid and not fit & test and not valid & test
    assert fit | valid | test == set(range(320))
    assert first.accuracy == 1
    assert first.fitted.regularisation == 1e-4
    assert 0.35 <= first.permutation_accuracy <= 0.65
    assert first.native_accuracy == np.mean([trials[i].native_score for i in first.evaluation_trial_ids])
    assert first.fitted.scale[3] == 1
    x = np.stack([e.features for e in events if e.point == "cue_end"])
    np.testing.assert_allclose(first.fitted.centre, x[list(first.fit_trial_ids)].mean(axis=0))
    np.testing.assert_allclose(first.fitted.scale[:3], x[list(first.fit_trial_ids), :3].std(axis=0, ddof=0))
    target = np.where(np.array(first.labels)[list(first.fit_trial_ids)] == 1, 1., -1.)
    assert first.fitted.intercept == target.mean()
    serial = plain(first)
    assert isinstance(serial["fitted"]["weights"], list)
    assert serial["channel"] == "emitted_activity"


def test_evaluation_features_and_labels_do_not_change_fit_scaling_or_tuning():
    events, trials = observations()
    original = decode(events, trials, **OPTIONS)[0]
    evaluation = set(original.evaluation_trial_ids)
    changed = [replace(e, features=e.features + 10000, label=3-e.label)
               if e.trial_id in evaluation else e for e in events]
    current = decode(changed, trials, **OPTIONS)[0]
    for name in ("weights", "centre", "scale", "regularisation", "intercept", "validation_accuracy"):
        assert getattr(current.fitted, name) == getattr(original.fitted, name)
        assert getattr(current.permutation, name) == getattr(original.permutation, name)


def test_null_permutes_fit_and_validation_separately_never_evaluation():
    events, trials = observations()
    result = decode(events, trials, **OPTIONS)[0]
    y, permuted = np.array(result.labels), np.array(result.permutation_labels)
    order = generator(412, "analysis", "probe-split").permutation(320)
    fit, valid, evaluation = order[:128], order[128:192], order[192:]
    rng = generator(413, "analysis", "probe-label-permutation")
    np.testing.assert_array_equal(permuted[fit], rng.permutation(y[fit]))
    np.testing.assert_array_equal(permuted[valid], rng.permutation(y[valid]))
    np.testing.assert_array_equal(permuted[evaluation], y[evaluation])
    assert sorted(permuted[fit]) == sorted(y[fit])
    assert sorted(permuted[valid]) == sorted(y[valid])


def test_observation_features_own_storage():
    values = np.array([1., 2.])
    event = ProbeEvent("a", "delayed_cue", 1, 1, "e", ("x", "y"), "response", 0, 1, 1, values)
    values[:] = 999
    np.testing.assert_array_equal(event.features, [1., 2.])
    assert not event.features.flags.writeable
    assert not np.shares_memory(values, event.features)


@pytest.mark.parametrize("mutation,message", [
    ("duplicate_event", "one observation"), ("missing_event", "missing observation"),
    ("duplicate_trial", "duplicate"), ("wiring", "fixed wiring"),
    ("world", "distinct seeds"), ("feature", "feature IDs"),
    ("entity", "entity"), ("channel", "emitted activity"),
    ("reset", "full reset"), ("task", "six stimulus"),
])
def test_invalid_data_rejected(mutation, message):
    events, trials = observations()
    if mutation == "duplicate_event":
        events.append(events[0])
    elif mutation == "missing_event":
        events.pop(0)
    elif mutation == "duplicate_trial":
        trials.append(trials[0])
    elif mutation == "wiring":
        trials[0] = replace(trials[0], wiring_id="different")
    elif mutation == "world":
        trials[0] = replace(trials[0], world_seed=trials[1].world_seed)
    elif mutation == "feature":
        events[0] = replace(events[0], feature_ids=("changed", "n2", "n3", "n4"))
    elif mutation == "entity":
        events[0] = replace(events[0], entity_id="other")
    elif mutation == "channel":
        events[0] = replace(events[0], channel="rate")
    elif mutation == "reset":
        trials[0] = replace(trials[0], reset="state_only")
    elif mutation == "task":
        trials[0] = replace(trials[0], task="reversal_adaptation")
    with pytest.raises(ValueError, match=message):
        decode(events, trials, **OPTIONS)


def test_trial_counts_classes_options_and_memory_budget():
    events, trials = observations()
    with pytest.raises(ValueError, match="exactly"):
        decode(events, trials)
    with pytest.raises(ValueError, match="positive"):
        decode(events, trials, **OPTIONS, lambdas=(0,))
    with pytest.raises(ValueError, match="distinct"):
        decode(events, trials, **OPTIONS, points=("response", "response"))
    with pytest.raises(MemoryError, match="budget"):
        decode(events, trials, **OPTIONS, memory_budget_bytes=10)
    with pytest.raises(ValueError, match="both classes"):
        decode([replace(e, label=1) for e in events], trials, **OPTIONS)


def test_exact_lambda_tie_keeps_smallest_even_for_unsorted_duplicate_grid():
    events, trials = observations()
    result = decode(events, trials, **OPTIONS, lambdas=(100., 1., 0.01, 0.0001, 0.01))[0]
    assert result.fitted.regularisation == 0.0001
