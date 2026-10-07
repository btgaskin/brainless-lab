"""Host construction boundaries; these checks never initialise a device."""

from dataclasses import replace

import numpy as np
import pytest
from brainlesslab.specs import TASKS, TaskSpec
from brainlesslab.tasks._prepare import prepare, validate_precision


def probe():
    return prepare(TaskSpec("delayed_cue", {"delays": (0,)}), np.random.default_rng(7))


@pytest.mark.parametrize("kind", TASKS)
def test_prepared_families_satisfy_structural_contract(kind):
    initial = prepare(TaskSpec(kind), np.random.default_rng(7))
    for name in ("physical", "stimuli", "draws", "labels", "round_bounds"):
        value = getattr(initial, name)
        assert value.flags.c_contiguous and not value.flags.writeable
    assert initial.round_bounds.shape == (initial.labels.size, 2)
    if not initial.definition.is_probe:
        assert all(
            getattr(initial, name).size == 0
            for name in ("labels", "response_start", "response_end", "cue_ends")
        )


@pytest.mark.parametrize(
    "name,value",
    [
        ("physical", np.zeros((1, 8))),
        ("physical", np.zeros(7)),
        ("stimuli", np.zeros((3, 4))),
        ("stimuli", np.zeros((0, 3))),
        ("draws", np.zeros((4, 3))),
        ("draws", np.zeros((0, 2))),
        ("response_start", [[8]]),
        ("response_end", []),
        ("cue_ends", [8, 9]),
        ("labels", [0]),
        ("labels", [3]),
        ("labels", [1.5]),
        ("response_start", [2**32 + 8]),
        ("round_bounds", [0, 16]),
        ("round_bounds", [[0, 17]]),
        ("round_bounds", [[8, 16]]),
        ("response_start", [7]),
        ("response_end", [8]),
        ("cue_ends", [0]),
    ],
)
def test_malformed_shapes_labels_and_schedules_fail_before_cast(name, value):
    with pytest.raises(ValueError):
        replace(probe(), **{name: value})


@pytest.mark.parametrize("name", ["physical", "stimuli", "draws", "labels", "response_start"])
def test_nonfinite_state_is_rejected(name):
    initial = probe()
    value = getattr(initial, name).astype(float)
    value.flat[0] = np.nan
    with pytest.raises(ValueError, match="finite"):
        replace(initial, **{name: value})


def test_definition_ports_and_options_must_match_specification():
    initial = probe()
    with pytest.raises(ValueError, match="definition"):
        replace(initial, definition=replace(initial.definition, n_effectors=3))
    with pytest.raises(ValueError, match="definition"):
        replace(initial, spec=TaskSpec("pong"))
    with pytest.raises(ValueError, match="options"):
        replace(initial, options=dict(initial.options) | {"cue_ticks": 12})


def test_reversal_round_order_and_post_reversal_window():
    initial = prepare(TaskSpec("reversal_adaptation"), np.random.default_rng(7))
    bounds = initial.round_bounds.copy()
    bounds[1, 0] = bounds[0, 1] - 1
    with pytest.raises(ValueError, match="ordered"):
        replace(initial, round_bounds=bounds)
    for reversal in (None, 0, 1.5, initial.labels.size - 14):
        with pytest.raises(ValueError, match="reversal"):
            replace(initial, metadata=dict(initial.metadata) | {"reversal_round": reversal})
    # One-based reversal_round=81 starts at zero-based index 80: 80+15<96.
    boundary = prepare(
        TaskSpec("reversal_adaptation", {"reversal_range": (81, 81)}), np.random.default_rng(7)
    )
    assert boundary.metadata["reversal_round"] == 81
    assert boundary.metadata["reversal_round"] - 1 + 15 < boundary.labels.size


def test_owned_arrays_and_diagnostic_labels_remain_independently_editable():
    initial = probe()
    source = initial.stimuli.copy()
    changed = replace(initial, stimuli=source, labels=3 - initial.labels)
    source[:] = 9
    np.testing.assert_array_equal(changed.stimuli, initial.stimuli)
    assert not np.shares_memory(changed.stimuli, initial.stimuli)
    assert changed.labels[0] != initial.labels[0]
    # Metadata does not overrule the canonical schedule/label arrays.
    assert changed.metadata["labels"] == initial.metadata["labels"]


def test_float32_required_positive_underflow_is_rejected_without_rejecting_valid_zero_controls():
    initial = prepare(TaskSpec("tracking", {"movement_amp": 1e-50}), np.random.default_rng(7))
    validate_precision([initial], "float64")
    with pytest.raises(ValueError, match="movement_amp.*positive.*float32"):
        validate_precision([initial], "float32")
    zero_controls = prepare(
        TaskSpec("tracking", {"stim_speed_rad": 0, "sensory_gain": 0}), np.random.default_rng(7)
    )
    validate_precision([zero_controls], "float32")
    with pytest.raises(ValueError, match="dtype"):
        validate_precision([zero_controls], "float16")
