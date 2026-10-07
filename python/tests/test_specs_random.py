import numpy as np
import pytest
from brainlesslab.backend import admit_batch
from brainlesslab.random import NoiseTape, generator, seed_for
from brainlesslab.specs import EvaluationSpec, ExecutionSpec, NodeSpec, NumericalPolicy, TaskSpec


def test_named_identity_and_typed_keys():
    assert seed_for(1, "development", "world", "pair", 1) == seed_for(
        1, "development", "world", "pair", 1
    )
    assert seed_for(1, "development", "world", "pair", 1) != seed_for(
        1, "development", "world", "pair", "1"
    )
    assert seed_for(1, "development", "world", 1) != seed_for(1, "calibration", "world", 1)


def test_tile_prefetch_and_partial_consumption():
    expected = generator(1, "development", "drive", "trial").standard_normal((99, 3))
    for size in (1, 8, 64):
        tape = NoiseTape(generator(1, "development", "drive", "trial"), 3, size)
        got = np.stack([tape.frame().copy() for _ in range(99)])
        np.testing.assert_array_equal(got, expected)
        assert tape.consumed == 99
    tape = NoiseTape(generator(1, "development", "drive", "trial"), 3, 64)
    tape.preview(64)
    assert tape.consumed == 0
    tape.consume(3)
    np.testing.assert_array_equal(tape.preview(8), expected[3:11])


def test_configuration_ownership_validation_and_admission():
    options = {"delays": [8, 32]}
    task = TaskSpec(options=options)
    options["delays"].append(128)
    assert task.options["delays"] == (8, 32)
    with pytest.raises(TypeError):
        task.options["delay"] = 0
    for call in (
        lambda: NodeSpec("ctrnn"),
        lambda: NumericalPolicy(fast_math=True),
        lambda: EvaluationSpec(blocks=0),
        lambda: ExecutionSpec(backend="cuda"),
    ):
        with pytest.raises(ValueError):
            call()
    execution = ExecutionSpec(memory_budget_bytes=1000, reserve_fraction=0.25, batch_size=32)
    assert admit_batch(100, execution) == 7
    with pytest.raises(MemoryError):
        admit_batch(751, execution)
