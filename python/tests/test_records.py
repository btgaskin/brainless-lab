import hashlib
import json
import zipfile
from dataclasses import replace
from pathlib import Path

import numpy as np
import pytest
import tomli_w
from brainlesslab.analysis import ProbeEvent
from brainlesslab.calibration import CalibrationSignature, analytic_calibration
from brainlesslab.plans import ResolvedPlan, ResolvedTarget, digest
from brainlesslab.records import (
    export_replay,
    fail_record,
    inspect_record,
    read_calibration,
    reserve_record,
    write_record,
)
from brainlesslab.results import EvaluationResult, TargetSummary, TrialResult
from brainlesslab.specs import (
    CompositionSpec,
    EvaluationSpec,
    EvaluationTarget,
    NumericalPolicy,
    Plan,
    TaskOutcome,
    plain,
)


def result_fixture():
    target = EvaluationTarget("baseline", CompositionSpec(count=4))
    plan = Plan(
        "records-test", (target,), EvaluationSpec(horizon=144), question="Implementation diagnostic"
    )
    resolved_target = ResolvedTarget(target, 144, {"leak": 0.25}, 3, 2, 1, "recall_accuracy", 1)
    resolved = ResolvedPlan(plan, (resolved_target,), digest(plan))
    outcome = TaskOutcome("recall_accuracy", 1.0, scoring_window=48)
    trial = TrialResult(
        "baseline",
        "delayed_cue",
        0,
        0,
        outcome,
        "completed",
        48,
        48,
        "seed-world",
        "wiring-0",
        {"world": "seed-world", "drive": "seed-drive"},
    )
    summary = TargetSummary("baseline", "delayed_cue", outcome, 1, 0, 1, "block", None)
    event = ProbeEvent(
        "baseline",
        "delayed_cue",
        0,
        0,
        "entity-1",
        ("node-1", "node-2"),
        "cue_end",
        8,
        1,
        1,
        np.array([0.1, 0.2]),
    )
    signature = CalibrationSignature(
        "delayed_cue",
        {},
        "declared-v1",
        144,
        0,
        1,
        NumericalPolicy(),
        {"tasks/_runtime.py": "abc123"},
        architecture="arm64",
    )
    calibration = analytic_calibration(signature)
    frames = (
        {
            "tick": 1,
            "activity": [1, 0],
            "effectors": [1, 0],
            "inputs": [1, 0, 0],
            "world": {"cue": 1, "response": False},
        },
    )
    return EvaluationResult(
        resolved,
        (trial,),
        (summary,),
        events=(event,),
        calibrations=(calibration,),
        replays={"baseline/0/0": frames},
        metadata={"requested_backend": "cpu", "dtype": "float64"},
        timings={"wall_seconds": 0.1},
    )


def test_fresh_bundle_inventory_source_and_authoritative_outcomes(tmp_path):
    result = result_fixture()
    root = write_record(result, tmp_path / "new-record")
    inspection = inspect_record(root)
    assert inspection["complete"] and inspection["checksums_valid"]
    assert inspection["manifest"]["format_version"] == 2
    assert not (root / ".RESERVED").exists()
    assert read_calibration(root) == result.calibrations
    summary = json.loads((root / "summary/summary.json").read_text())
    assert summary["summaries"][0]["outcome"] == plain(result.summaries[0].outcome)
    assert "normalisation_status" in (root / "trials.csv").read_text()
    assert "wiring_id" in (root / "seeds.csv").read_text()
    assert "seed-drive" in (root / "seeds.csv").read_text()
    with np.load(root / "data/probe_features.npz", allow_pickle=False) as arrays:
        np.testing.assert_array_equal(arrays["event_00000000"], result.events[0].features)
    with zipfile.ZipFile(root / "environment/package-source.zip") as archive:
        names = archive.namelist()
        assert "pyproject.toml" in names and "uv.lock" in names
        assert "python/src/brainlesslab/records.py" in names
        assert all(not Path(name).is_absolute() and ".." not in Path(name).parts for name in names)
        assert not any("__pycache__" in name for name in names)
    assert "[request]" in (root / "resolved.toml").read_text()


def test_no_overwrite_and_checksum_tampering(tmp_path):
    root = write_record(result_fixture(), tmp_path / "immutable")
    original = (root / "summary/summary.json").read_bytes()
    with pytest.raises(FileExistsError):
        write_record(result_fixture(), root)
    assert (root / "summary/summary.json").read_bytes() == original
    (root / "summary/summary.json").write_text("{}")
    inspection = inspect_record(root)
    assert not inspection["complete"] and not inspection["checksums_valid"]
    assert inspection["invalid_artifacts"] == ["summary/summary.json"]


def test_reserved_path_failure_preserves_data_without_done(tmp_path):
    reservation = reserve_record(tmp_path / "reserved")
    with pytest.raises(FileExistsError):
        reserve_record(reservation.path)
    fail_record(reservation, RuntimeError("diagnostic failure"))
    assert (reservation.path / "FAILED").is_file()
    assert not (reservation.path / "DONE").exists()
    assert (reservation.path / ".RESERVED").is_file()
    with pytest.raises(FileExistsError):
        write_record(result_fixture(), reservation.path, reservation=reservation)


def test_nonportable_numbers_leave_failed_partial_bundle(tmp_path):
    result = replace(result_fixture(), metadata={"value": float("nan")})
    with pytest.raises(ValueError, match="finite"):
        write_record(result, tmp_path / "failed")
    assert (tmp_path / "failed/FAILED").exists()
    assert not (tmp_path / "failed/DONE").exists()
    assert (tmp_path / "failed/request.toml").exists()


def test_failed_trial_preserves_inventory_without_success_marker(tmp_path):
    result = result_fixture()
    failed = replace(
        result.trials[0],
        status="failed",
        outcome=TaskOutcome("recall_accuracy", None),
        error="nonfinite state",
    )
    root = write_record(replace(result, trials=(failed,)), tmp_path / "failed-trial")
    inspection = inspect_record(root)
    assert inspection["checksums_valid"] and inspection["status"] == "failed"
    assert not inspection["complete"] and not (root / "DONE").exists()
    assert (root / "trials.csv").is_file() and (root / "summary/summary.json").is_file()


def historical_record(path, name="artifact.txt", value=b"legacy bytes"):
    path.mkdir()
    if name == "artifact.txt":
        (path / name).write_bytes(value)
    manifest = {
        "format": "brainlesslab-record",
        "format_version": 1,
        "id": "historical",
        "artifacts": [name],
        "artifact_sha256": {name: hashlib.sha256(value).hexdigest()},
    }
    (path / "record.toml").write_text(tomli_w.dumps(manifest))
    (path / "DONE").write_text("complete\n")


def test_historical_inspection_does_not_modify_or_execute(tmp_path):
    root = tmp_path / "historical"
    historical_record(root)
    before = {p.name: p.read_bytes() for p in root.iterdir()}
    assert inspect_record(root)["complete"]
    assert {p.name: p.read_bytes() for p in root.iterdir()} == before


@pytest.mark.parametrize(
    "name", ["../outside", "/tmp/outside", "C:\\outside", "folder/../../outside", "./artifact.txt"]
)
def test_manifest_path_traversal_rejected(tmp_path, name):
    root = tmp_path / "unsafe"
    historical_record(root, name)
    with pytest.raises(ValueError):
        inspect_record(root)


def test_manifest_symlink_rejected(tmp_path):
    root = tmp_path / "symlink"
    historical_record(root)
    artifact = root / "artifact.txt"
    artifact.unlink()
    outside = tmp_path / "outside.txt"
    outside.write_bytes(b"legacy bytes")
    artifact.symlink_to(outside)
    with pytest.raises(ValueError, match="symlinks"):
        inspect_record(root)


def test_calibration_content_hash_rejected_after_modification(tmp_path):
    root = write_record(result_fixture(), tmp_path / "record")
    path = root / "calibration.json"
    document = json.loads(path.read_text())
    document["calibrations"][0]["null_mean"] = 0.9
    exported = tmp_path / "changed.json"
    exported.write_text(json.dumps(document))
    with pytest.raises(ValueError, match="hash"):
        read_calibration(exported)


def test_replay_schema_identity_and_new_only_export(tmp_path):
    result = result_fixture()
    path = export_replay(result, tmp_path / "replay.json")
    replay = json.loads(path.read_text())
    assert replay["format"] == "brainlesslab-replay" and replay["version"] == 1
    assert replay["task"] == "delayed_cue" and replay["node"] == "falandays"
    assert replay["trial_key"] == "baseline/0/0"
    assert replay["frames"][0]["activity"] == [1, 0]
    assert replay["provenance"]["contract_hash"] == result.resolved.contract_hash
    with pytest.raises(FileExistsError):
        export_replay(result, path)
    with pytest.raises(ValueError, match="select"):
        export_replay(
            replace(result, replays={**result.replays, "another/1/1": ()}), tmp_path / "many.json"
        )
