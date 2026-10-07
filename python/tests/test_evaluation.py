from dataclasses import replace
import json
import subprocess
import sys

import numpy as np
import pytest

from brainlesslab import (CompositionSpec, EvaluationSpec, EvaluationTarget, ExecutionSpec,
                          NodeSpec, Plan, TaskSpec, ablate, execute, profile, resolve)
from brainlesslab.evaluation import _jobs
from brainlesslab.records import inspect_record, write_record


def tiny_plan(kind="falandays", **kwargs):
    return profile(CompositionSpec(NodeSpec(kind), TaskSpec("delayed_cue", {"delays": (0, 3)}),
                                   count=8), evaluation=EvaluationSpec(blocks=2, trials_per_block=3),
                   **kwargs)


def rows(result):
    return [(t.target_id, t.block_id, t.trial_id, t.outcome, t.status, t.world_seed, t.wiring_id,
             dict(t.seeds), t.completed_ticks, t.neural_frames) for t in result.trials]


@pytest.mark.parametrize("kind", ["falandays", "sorn"])
def test_batches_and_noise_tiles_preserve_identity_and_events(kind):
    plan = tiny_plan(kind)
    one = execute(plan, ExecutionSpec(batch_size=1, noise_tile_frames=1, recording="probe_events"))
    many = execute(plan, ExecutionSpec(batch_size=4, noise_tile_frames=32, recording="probe_events"))
    assert rows(one) == rows(many)
    assert all(t.status == "completed" for t in many.trials)
    assert len(many.events) == 18
    assert len(many.probe_trials) == 6
    for a, b in zip(one.events, many.events, strict=True):
        assert (a.target_id, a.block_id, a.trial_id, a.tick, a.point) == (b.target_id, b.block_id, b.trial_id, b.tick, b.point)
        np.testing.assert_array_equal(a.features, b.features)
    assert many.summaries[0].independent_blocks == 2
    assert many.summaries[0].outcome.normalisation_status == "null_adjusted_analytic"
    assert all("drive" not in t.seeds for t in many.trials) if kind == "sorn" else all("drive" in t.seeds for t in many.trials)


def test_labels_and_target_order_are_not_random_identity():
    baseline = tiny_plan()
    first = baseline.targets[0]
    second = replace(first, id="other", label="renamed")
    plan = replace(baseline, targets=(first, second))
    a = execute(plan, ExecutionSpec(batch_size=4))
    b = execute(replace(plan, targets=(second, first)), ExecutionSpec(batch_size=3))
    by_id = lambda result: {(t.target_id, t.block_id, t.trial_id): t for t in result.trials}
    assert by_id(a) == by_id(b)
    for block in range(2):
        for trial in range(3):
            x, y = by_id(a)[("baseline", block, trial)], by_id(a)[("other", block, trial)]
            assert x.world_seed == y.world_seed and x.wiring_id == y.wiring_id
            assert x.outcome == y.outcome


def test_construction_scopes_and_paired_ablation():
    plan = tiny_plan()
    for scope, expected in (("evaluation", 1), ("block", 2), ("trial", 6)):
        resolved = resolve(replace(plan, evaluation=replace(plan.evaluation, construction_scope=scope)))
        assert len({j.wiring_id for j in _jobs(resolved)}) == expected
    ablation = ablate(plan.targets[0].composition, evaluation=plan.evaluation,
                      verbs=("freeze_weights", "blind_input", "shuffle_input"))
    result = execute(ablation, ExecutionSpec(batch_size=7))
    assert len(result.contrasts) == 3
    for target in ablation.targets:
        trials = [t for t in result.trials if t.target_id == target.id]
        assert all(t.status == "completed" for t in trials)
        assert [t.world_seed for t in trials] == [t.world_seed for t in result.trials[:6]]
    assert all("input_shuffle" in t.seeds for t in result.trials if t.target_id == "shuffle_input")


def test_memory_and_recording_reject_before_runtime():
    with pytest.raises(MemoryError, match="recording"):
        execute(tiny_plan(), ExecutionSpec(recording="replay", recording_budget_bytes=1))
    with pytest.raises(MemoryError, match="one trajectory"):
        execute(tiny_plan(), ExecutionSpec(memory_budget_bytes=1))
    with pytest.raises(ValueError, match="probe_events"):
        execute(profile(CompositionSpec(task=TaskSpec("tracking"), count=8),
                        evaluation=EvaluationSpec(horizon=5), diagnostic=True),
                ExecutionSpec(recording="probe_events"))


@pytest.mark.parametrize("task", ["tracking", "pong", "cartpole_plank_easy", "reversal_adaptation"])
def test_controls_batch_partition_and_early_done(task):
    evaluation = EvaluationSpec(blocks=2, trials_per_block=2,
                                horizon=None if task == "reversal_adaptation" else 32)
    comp = CompositionSpec(task=TaskSpec(task), count=8)
    plan = Plan("null", (EvaluationTarget("null", comp, controller="reference_null"),),
                evaluation, diagnostic=task != "reversal_adaptation")
    a = execute(plan, ExecutionSpec(batch_size=1, noise_tile_frames=24))
    b = execute(plan, ExecutionSpec(batch_size=4, noise_tile_frames=96))
    assert rows(a) == rows(b)
    assert all(t.status == "completed" for t in b.trials)
    assert all(set(t.seeds) == {"world", "control"} for t in b.trials)


def test_records_replay_and_cli_are_real(tmp_path):
    result = execute(tiny_plan(), ExecutionSpec(recording="replay"))
    path = write_record(result, tmp_path / "run")
    inspected = inspect_record(path)
    assert inspected["status"] == "complete"
    assert result.replays["baseline/0/0"][-1]["tick"] == 19
    proc = subprocess.run([sys.executable, "-m", "brainlesslab", "inspect", str(path)],
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    assert "complete" in proc.stdout


def test_incompatible_calibration_is_rejected():
    result = execute(tiny_plan())
    changed = replace(tiny_plan(), targets=(replace(tiny_plan().targets[0], composition=
                      replace(tiny_plan().targets[0].composition,
                              task=TaskSpec("delayed_cue", {"delays": (0, 4)}))),))
    with pytest.raises(ValueError, match="signature mismatch"):
        execute(changed, calibrations=result.calibrations)


def test_import_does_not_import_quadrants():
    proc = subprocess.run([sys.executable, "-c", "import sys,brainlesslab; assert 'quadrants' not in sys.modules"],
                          capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr


def test_failed_neural_frame_is_latched_and_recorded(monkeypatch, tmp_path):
    from brainlesslab.models import sorn
    original = sorn.construct

    def overflowing(*args):
        initial = original(*args)
        initial.w_ee[:] = np.finfo(np.float64).max
        initial.ee_mask[:] = True
        initial.t_e[:] = -1
        return initial

    monkeypatch.setattr(sorn, "construct", overflowing)
    composition = CompositionSpec(NodeSpec("sorn"), TaskSpec("cartpole_plank_easy"), count=8)
    result = execute(profile(composition, evaluation=EvaluationSpec(horizon=5), diagnostic=True))
    trial = result.trials[0]
    assert trial.status == "failed"
    assert trial.completed_ticks == 0 and trial.neural_frames == 1
    assert trial.outcome.raw is None and result.summaries[0].outcome.raw is None
    record = write_record(result, tmp_path / "failed")
    assert (record / "FAILED").exists() and not (record / "DONE").exists()
