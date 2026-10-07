"""Task conformance and observation-only controls on development worlds."""

from dataclasses import fields, replace
from pathlib import Path
import hashlib
import math
import numpy as np
import pytest
import quadrants as qd

from brainlesslab.specs import TaskSpec, TASKS
from brainlesslab.tasks import TaskBatch, capacity_probe_presets, definition, prepare, resolve, validate_controller
from brainlesslab.tasks._runtime import _Controller, _SensoryController


@pytest.fixture(scope="module", autouse=True)
def runtime():
    try:
        qd.lang.impl.get_runtime().prog
    except qd.lang.exception.QuadrantsRuntimeError:
        qd.init(arch=qd.cpu, default_fp=qd.f64, fast_math=False, enable_fallback=False,
                cpu_max_num_threads=1, raise_on_templated_floats=True, debug=True,
                offline_cache_file_path="/private/tmp/brainlesslab-tasks-qd-cache")


def upload(values, dtype=qd.f64):
    host = np.array(values, dtype=np.int32 if dtype == qd.i32 else np.float32 if dtype == qd.f32 else np.float64)
    array = qd.ndarray(dtype, host.shape)
    array.from_numpy(host)
    return array


def run_control(initials, policy="oracle", horizon=None):
    batch = TaskBatch(initials)
    active = upload(np.ones(len(initials)), qd.i32)
    randoms = upload(np.full(len(initials), 0.6))
    for _ in range(horizon or max(v.definition.default_horizon for v in initials)):
        for frame in range(1, batch.definition.neural_frames + 1):
            batch.encode(frame, active)
            effectors = batch.control(policy, randoms, active)
            batch.accumulate(effectors, frame, active)
        batch.advance(effectors, active)
    return batch


def test_ten_families_and_all_64_named_presets():
    assert tuple(resolve(TaskSpec(kind)) and kind for kind in TASKS) == TASKS
    presets = capacity_probe_presets()
    assert len(presets) == len({c.id for c in presets}) == 64
    assert presets[0].id == "delayed_cue__delay_0"
    assert presets[-1].id == "reversal_adaptation__single_reversal"
    assert sum(c.task == "context_integration" for c in presets) == 36
    for kind in dict.fromkeys(c.task for c in presets):
        selected = [c for c in presets if c.task == kind]
        initials = [prepare(TaskSpec(c.task, c.task_options), np.random.default_rng(100 + i))
                    for i, c in enumerate(selected)]
        batch = run_control(initials, horizon=max(c.horizon for c in selected))
        snapshot = batch.snapshot()
        np.testing.assert_array_equal(snapshot["done"], np.ones(len(selected)))
        np.testing.assert_array_equal(snapshot["finite"], np.ones(len(selected)))
        np.testing.assert_array_equal(snapshot["outcome"], np.full(len(selected), 15 / 16 if kind == "reversal_adaptation" else 1))
        np.testing.assert_array_equal(snapshot["ticks"], [v.stimuli.shape[0] for v in initials])


@pytest.mark.parametrize("kind,policy,options", [
    ("context_integration", "irrelevant", {"congruency": "conflicting"}),
    ("temporal_order", "bag", {}),
    ("delayed_cue", "memoryless", {}),
])
def test_negative_controls_answer_different_questions(kind, policy, options):
    initials = [prepare(TaskSpec(kind, options), np.random.default_rng(i)) for i in range(48)]
    actual = run_control(initials, policy).snapshot()["outcome"]
    if policy == "irrelevant":
        np.testing.assert_array_equal(actual, np.zeros(48))
    else:
        # Both these controls choose left on the response observation. Their
        # finite bank result is checked against actual episode labels, not a
        # claim that every development bank must be exactly at chance.
        np.testing.assert_array_equal(actual, [v.labels[0] == 1 for v in initials])


def test_controllers_cannot_read_labels_and_construction_is_owned():
    names = {f.name for f in fields(_Controller)}
    assert not names & {"labels", "stimuli", "draws", "metadata", "response_start", "reversal"}
    initial = prepare(TaskSpec("delayed_xor"), np.random.default_rng(41))
    altered = replace(initial, labels=3 - initial.labels)
    original = run_control([initial]).snapshot()
    changed = run_control([altered]).snapshot()
    np.testing.assert_array_equal(original["decisions"], changed["decisions"])
    assert original["outcome"][0] == 1 and changed["outcome"][0] == 0
    assert not np.shares_memory(initial.labels, altered.labels)
    assert not initial.stimuli.flags.writeable


@pytest.mark.parametrize("kind", ["tracking", "pong"])
def test_physical_oracle_uses_only_declared_receptor_observations(kind):
    assert {f.name for f in fields(_SensoryController)} == {"kind", "inputs", "angles", "movement_amp", "effectors"}
    original = prepare(TaskSpec(kind), np.random.default_rng(17))
    physical = original.physical.copy()
    physical[:] = np.arange(8) * 987.0
    changed = replace(original, physical=physical)
    batch = TaskBatch([original, changed])
    observations = np.zeros((2, batch.definition.n_inputs))
    observations[:, 10] = 1
    batch.inputs.from_numpy(observations)
    output = batch.control("oracle", upload([0.1, 0.9])).to_numpy()
    np.testing.assert_array_equal(output[0], output[1])
    assert validate_controller(TaskSpec(kind), "oracle") == "oracle"
    with pytest.raises(ValueError):
        validate_controller(TaskSpec(kind), "irrelevant")


@pytest.mark.parametrize("kind,option,hidden", [
    ("delayed_cue", "cue_mode", "hidden"),
    ("recall_interference", "cue_mode", "hidden"),
    ("delayed_xor", "cue_mode", "hidden"),
    ("evidence_accumulation", "input_mode", "hidden"),
    ("context_integration", "context_mode", "hidden"),
    ("temporal_order", "input_mode", "hidden"),
    ("reversal_adaptation", "feedback_mode", "hidden"),
])
def test_visibility_controls_preserve_random_world_and_schedules(kind, option, hidden):
    a = prepare(TaskSpec(kind), np.random.default_rng(91))
    b = prepare(TaskSpec(kind, {option: hidden}), np.random.default_rng(91))
    for name in ("labels", "response_start", "response_end", "cue_ends", "round_bounds"):
        np.testing.assert_array_equal(getattr(a, name), getattr(b, name))
    assert a.metadata == b.metadata


def test_delayed_cue_pre_response_discard_ties_left_incomplete_and_early_stop():
    initial = prepare(TaskSpec("delayed_cue", {"cue_ticks": 2, "delays": (3,), "response_ticks": 2}), np.random.default_rng(2))
    batch = TaskBatch([initial, initial])
    active = upload([1, 0], qd.i32)
    output = upload([[0, 1], [1, 0]])
    for _ in range(5):
        batch.encode(1, active)
        batch.advance(output, active)
    actual = batch.snapshot()
    assert math.isnan(actual["outcome"][0]) and actual["done"][0] == 0
    np.testing.assert_array_equal(actual["evidence"], [[0, 0], [0, 0]])
    for _ in range(4):
        batch.advance(upload([[0, 0], [0, 0]]), active)
    actual = batch.snapshot()
    np.testing.assert_array_equal(actual["ticks"], [7, 0])
    np.testing.assert_array_equal(actual["decisions"], [[1], [0]])
    np.testing.assert_array_equal(actual["ties"], [[1], [0]])
    batch.encode(1, active)
    np.testing.assert_array_equal(batch.inputs.to_numpy(), np.zeros((2, 3)))


def test_uniform_signed_physical_null_and_fair_choice_hold_scopes():
    for kind in ("tracking", "pong"):
        initials = [prepare(TaskSpec(kind), np.random.default_rng(i)) for i in range(3)]
        batch = TaskBatch(initials)
        active = upload([1, 1, 1], qd.i32)
        result = batch.control("reference_null", upload([0, 0.5, 1]), active).to_numpy()
        np.testing.assert_array_equal(result, [[0, 1], [0, 0], [1, 0]])
    batch = TaskBatch([prepare(TaskSpec("cartpole_plank_easy"), np.random.default_rng(1))])
    active = upload([1], qd.i32)
    np.testing.assert_array_equal(batch.control("reference_null", upload([0.6]), active).to_numpy(), [[0, 1]])
    np.testing.assert_array_equal(batch.control("reference_null", upload([0.1]), active).to_numpy(), [[0, 1]])
    initial = prepare(TaskSpec("delayed_cue"), np.random.default_rng(1))
    batch = TaskBatch([initial])
    first = batch.control("reference_null", upload([0.1]), active).to_numpy()
    batch.advance(upload([[1, 0]]), active)
    np.testing.assert_array_equal(batch.control("reference_null", upload([0.9]), active).to_numpy(), first)


@pytest.mark.parametrize("kind", ["tracking", "pong"])
def test_physical_current_contract_with_archival_input_sequence(kind):
    # These fixtures supply actions, not current world-output ground truth.
    # Julia deliberately disables their old environment replay: its Tracking
    # plateau includes the exact four-degree edge and Pong starts at x=995,
    # whereas these older worlds exclude that edge and start at x=985.
    fixture_dir = Path(__file__).resolve().parents[2] / "test" / "fixtures"
    hashes = {"tracking": "f03a56f72761da5ec0e6d527a2f2e31645187ee18db0c3f80dd85b074ce9dc7f",
              "pong": "b662a85d940c32a3f1fb80888be0c3e441e289360e03cc79f4f03a7a5d1b5d37"}
    path = fixture_dir / f"env_{kind}.npz"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == hashes[kind]
    data = dict(np.load(path))
    initial = prepare(TaskSpec(kind, {"randomize_start": False} if kind == "tracking" else {}), np.random.default_rng(1))
    batch = TaskBatch([initial])
    active = upload([1], qd.i32)
    physical = initial.physical.copy()
    scores = []
    hits, misses = 0, 0
    for tick, effectors in enumerate(data["effs"]):
        batch.encode(1, active)
        if kind == "tracking":
            angles = np.array([eye + offset for eye in (30, -30) for offset in range(-60, 61, 4)])
            delta = (physical[0] * 180 / np.pi + angles - physical[1] * 180 / np.pi + 180) % 360 - 180
            observed = np.where(np.abs(delta) <= 4, 1.0, np.exp(-delta * delta / 10))
        else:
            bearing = np.arctan2(physical[1] - physical[2], physical[0] - 100) * 180 / np.pi
            delta = (bearing - np.arange(-90, 91, 4) + 180) % 360 - 180
            observed = ((-90 <= bearing <= 90) & (np.abs(delta) <= 2)).astype(float)
        np.testing.assert_allclose(batch.inputs.to_numpy()[0], observed, atol=1e-9, rtol=0)
        batch.advance(upload([effectors]), active)
        actual = batch.snapshot()
        if kind == "tracking":
            physical[0] = (physical[0] + np.pi / 180 * 10 * (effectors[0] - effectors[1]) + np.pi) % (2 * np.pi) - np.pi
            physical[1] = (physical[1] + physical[2] * np.pi / 180 + np.pi) % (2 * np.pi) - np.pi
            scores.append(np.cos((physical[0] - physical[1] + np.pi) % (2 * np.pi) - np.pi))
            np.testing.assert_allclose(actual["physical"][0], physical, atol=1e-9, rtol=0)
        else:
            physical[2] = np.clip(physical[2] + 100 * (effectors[0] - effectors[1]), 50, 450)
            physical[0] += physical[3]
            physical[1] += physical[4]
            if physical[1] <= 5:
                physical[1], physical[4] = 5, abs(physical[4])
            elif physical[1] >= 495:
                physical[1], physical[4] = 495, -abs(physical[4])
            if physical[0] >= 995:
                physical[0], physical[3], physical[5] = 995, -abs(physical[3]), 0
            if physical[3] < 0 and physical[5] == 0 and physical[0] <= 115:
                if abs(physical[1] - physical[2]) <= 65:
                    physical[0], physical[3] = 115, abs(physical[3])
                    hits += 1
                else:
                    physical[5] = 1
            if physical[0] < 0:
                misses += 1
                physical[6] += 1
                draw = initial.draws[int(physical[6])]
                physical[0], physical[1], physical[3], physical[4], physical[5] = 995, 1 + 498 * draw[0], -5, 5 if draw[1] >= 0.5 else -5, 0
            np.testing.assert_allclose(actual["physical"][0], physical, atol=1e-9, rtol=0)
            assert actual["hits"][0] == hits and actual["misses"][0] == misses
    expected = np.mean(scores) if kind == "tracking" else hits / (hits + misses) if hits + misses else 0
    np.testing.assert_allclose(batch.outcome.to_numpy(), [expected], atol=1e-9, rtol=0)


def test_tracking_reversal_and_warmup_score_exclusion():
    initial = prepare(TaskSpec("tracking", {"randomize_start": False}), np.random.default_rng(1))
    batch = TaskBatch([initial], warmup=2)
    active = upload([1], qd.i32)
    output = upload([[0, 0]])
    reference = []
    theta, phi, direction = initial.physical[:3]
    for tick in range(720):
        batch.advance(output, active)
        phi = (phi + direction * math.pi / 180 + math.pi) % (2 * math.pi) - math.pi
        reference.append(math.cos((theta - phi + math.pi) % (2 * math.pi) - math.pi))
    actual = batch.snapshot()
    assert actual["physical"][0, 2] == -1 and actual["scored"][0] == 718
    np.testing.assert_allclose(actual["outcome"], [np.mean(reference[2:])], atol=1e-12)


def cartpole_reference(state, force):
    x, xd, theta, td = state
    cosine, sine = np.cos(theta), np.sin(theta)
    temp = (force + 0.1 * 0.5 * td ** 2 * sine) / 1.1
    ta = (9.8 * sine - cosine * temp) / (0.5 * (4 / 3 - 0.1 * cosine ** 2 / 1.1))
    xa = temp - 0.1 * 0.5 * ta * cosine / 1.1
    return np.array([x + 0.02 * xd, xd + 0.02 * xa, theta + 0.02 * td, td + 0.02 * ta])


def test_spike_ff2_24_frame_schedule_explicit_euler_votes_and_tie():
    initial = prepare(TaskSpec("cartpole_plank_easy"), np.random.default_rng(1))
    physical = initial.physical.copy()
    physical[:4] = [0.852, -0.007, 0.018, -0.659]
    initial = replace(initial, physical=physical)
    batch = TaskBatch([initial, initial])
    active = upload([1, 1], qd.i32)
    total = np.zeros(8)
    for frame in range(1, 25):
        batch.encode(frame, active)
        observed = batch.inputs.to_numpy()[0]
        if frame not in (1, 4, 7, 10, 13, 16, 19, 22):
            np.testing.assert_array_equal(observed, np.zeros(8))
        total += observed
        # Slot zero ties its full votes; slot one wins right cumulatively.
        batch.accumulate(upload([[0.5, 0.5], [0, 1]]), frame, active)
    np.testing.assert_array_equal(total, [0, 3, 1, 0, 0, 1, 3, 0])
    batch.advance(upload([[1, 0], [1, 0]]), active)
    actual = batch.snapshot()
    np.testing.assert_allclose(actual["physical"][0, :4], cartpole_reference(physical[:4], -10), atol=1e-12)
    np.testing.assert_allclose(actual["physical"][1, :4], cartpole_reference(physical[:4], 10), atol=1e-12)
    np.testing.assert_array_equal(actual["outcome"], [1, 1])


def test_pong_boundary_miss_reset_and_warmup_diagnostics():
    initial = prepare(TaskSpec("pong"), np.random.default_rng(3), horizon=200)
    physical = initial.physical.copy()
    physical[:7] = [2, 4, 450, -5, -5, 1, 0]
    batch = TaskBatch([replace(initial, physical=physical)], warmup=1)
    active = upload([1], qd.i32)
    batch.advance(upload([[0, 0]]), active)
    actual = batch.snapshot()
    assert actual["misses"][0] == 0 and actual["scored"][0] == 0
    np.testing.assert_array_equal(actual["physical"][0, [0, 3, 5, 6]], [995, -5, 0, 1])
    np.testing.assert_allclose(actual["physical"][0, 1], 1 + 498 * initial.draws[1, 0])


def test_nonfinite_effectors_rejected_on_device_and_float32_task_storage():
    initial = prepare(TaskSpec("delayed_cue"), np.random.default_rng(1))
    batch = TaskBatch([initial], dtype="float32")
    active = upload([1], qd.i32)
    batch.encode(1, active)
    assert batch.inputs.to_numpy().dtype == np.float32
    batch.advance(upload([[np.nan, 0]], qd.f32), active)
    np.testing.assert_array_equal(batch.finite.to_numpy(), [0])
    np.testing.assert_array_equal(batch.ticks.to_numpy(), [0])


@pytest.mark.parametrize("kind,options", [
    ("delayed_cue", {"cue_ticks": 0}), ("delayed_cue", {"delays": (1, 1)}),
    ("recall_interference", {"delay": 8}), ("recall_interference", {"distractors": 20}),
    ("delayed_xor", {"gap": -1}), ("evidence_accumulation", {"pulse_count": 17}),
    ("evidence_accumulation", {"evidence_fraction": 1}), ("temporal_order", {"terminal_ticks": 0}),
    ("reversal_adaptation", {"reversal_range": (90, 95)}), ("pong", {"unknown": 2}),
    ("tracking", {"sensor_offsets_deg": ()}), ("cartpole_plank_easy", {"initial_ranges": ((1, 0),) * 4}),
])
def test_task_option_validation(kind, options):
    with pytest.raises(ValueError):
        definition(TaskSpec(kind, options))


def test_probe_and_easy_warmup_contract():
    for kind in ("delayed_cue", "context_integration", "cartpole_plank_easy"):
        initial = prepare(TaskSpec(kind), np.random.default_rng(1))
        with pytest.raises(ValueError):
            TaskBatch([initial], warmup=1)
