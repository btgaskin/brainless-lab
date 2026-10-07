"""New-only, checksummed portable records and read-only historical inspection."""

from __future__ import annotations

import csv
import hashlib
import importlib.metadata
import json
import math
import platform
import secrets
import sys
import tomllib
import zipfile
from collections.abc import Mapping
from dataclasses import dataclass, fields, is_dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING

import numpy as np
import tomli_w

from .calibration import CalibrationRecord, CalibrationSignature
from .plans import without_none, write_plan
from .specs import NumericalPolicy

if TYPE_CHECKING:
    from .results import EvaluationResult


def _portable(value):
    if is_dataclass(value) and not isinstance(value, type):
        return {f.name: _portable(getattr(value, f.name)) for f in fields(value)}
    if isinstance(value, Mapping):
        return {str(key): _portable(item) for key, item in value.items()}
    if isinstance(value, np.ndarray):
        return _portable(value.tolist())
    if isinstance(value, np.generic):
        return _portable(value.item())
    if isinstance(value, (tuple, list)):
        return [_portable(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        raise ValueError("records require finite numbers or explicit missing values")
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise TypeError(f"nonportable record value: {type(value).__name__}")


def _json(path: Path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(
            _portable(value),
            stream,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        stream.write("\n")


def _sha(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _contained(root: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or "\\" in name or ":" in name:
        raise ValueError("artifact paths must be portable relative paths")
    relative = PurePosixPath(name)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in name.split("/")):
        raise ValueError("artifact path escapes the record")
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise ValueError("record artifacts cannot be symlinks")
    if not current.resolve().is_relative_to(root.resolve()):
        raise ValueError("artifact path escapes the record")
    return current


@dataclass(frozen=True)
class RecordReservation:
    path: Path
    token: str


def reserve_record(destination: str | Path) -> RecordReservation:
    """Exclusively reserve a new result directory before expensive execution."""
    path = Path(destination)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.mkdir(exist_ok=False)
    token = secrets.token_hex(32)
    (path / ".RESERVED").write_text(token, encoding="ascii")
    return RecordReservation(path, token)


def fail_record(reservation: RecordReservation, error: BaseException):
    """Preserve the reserved directory, with no successful completion marker."""
    marker = reservation.path / ".RESERVED"
    if (
        marker.is_symlink()
        or not marker.is_file()
        or marker.read_text(encoding="ascii") != reservation.token
    ):
        raise ValueError("record reservation is no longer owned")
    path = reservation.path / "FAILED"
    if not path.exists():
        # Exception types are portable. Tracebacks can expose machine paths.
        _json(
            path,
            {
                "status": "failed",
                "error_type": type(error).__name__,
                "message": str(error).replace(str(reservation.path), "<record>"),
            },
        )


def _claim(destination, reservation):
    if reservation is None:
        return reserve_record(destination)
    if Path(destination) != reservation.path or reservation.path.is_symlink():
        raise ValueError("reservation does not match the record destination")
    marker = reservation.path / ".RESERVED"
    if (
        marker.is_symlink()
        or not marker.is_file()
        or marker.read_text(encoding="ascii") != reservation.token
    ):
        raise ValueError("invalid record reservation")
    if {p.name for p in reservation.path.iterdir()} != {".RESERVED"}:
        raise FileExistsError("reserved record is not empty")
    return reservation


def _csv(path, rows):
    rows = tuple(_portable(row) for row in rows)
    keys = sorted({key for row in rows for key in row})
    with path.open("x", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=keys)
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    key: json.dumps(
                        value, ensure_ascii=False, allow_nan=False, separators=(",", ":")
                    )
                    if isinstance(value, (dict, list))
                    else value
                    for key, value in row.items()
                }
            )


def _source_bundle(directory):
    package = Path(__file__).resolve().parent
    workspace = package.parents[2]
    files = {
        f"python/src/brainlesslab/{path.relative_to(package).as_posix()}": path
        for path in package.rglob("*.py")
        if not path.is_symlink()
    }
    for name in ("pyproject.toml", "uv.lock", ".python-version"):
        path = workspace / name
        if path.is_file() and not path.is_symlink():
            files[name] = path
    archive = directory / "package-source.zip"
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as bundle:
        for name, path in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(entry, path.read_bytes())
    lock = workspace / "uv.lock"
    if lock.is_file() and not lock.is_symlink():
        (directory / "uv.lock").write_bytes(lock.read_bytes())
    _json(
        directory / "source.json",
        {
            "format": "brainlesslab-source-bundle",
            "version": 1,
            "sha256": _sha(archive),
            "files": sorted(files),
            "entrypoint": "python -m brainlesslab",
        },
    )


def _replay_document(result, trial_key):
    keys = tuple(result.replays)
    if trial_key is None:
        if len(keys) != 1:
            raise ValueError("select one trial_key when exporting multiple replays")
        trial_key = keys[0]
    if trial_key not in result.replays:
        raise KeyError("unknown replay trial_key")
    matching = [
        trial
        for trial in result.trials
        if f"{trial.target_id}/{trial.block_id}/{trial.trial_id}" == trial_key
    ]
    if len(matching) != 1:
        raise ValueError("replay identity does not match one recorded trial")
    trial = matching[0]
    target = next(v for v in result.resolved.targets if v.target.id == trial.target_id)
    if not result.replays[trial_key]:
        raise ValueError("a replay must contain recorded frames")
    return {
        "format": "brainlesslab-replay",
        "version": 1,
        "trial_key": trial_key,
        "task": trial.task,
        "node": target.target.composition.node.kind,
        "provenance": {
            "evidence": result.resolved.request.evidence,
            "contract_hash": result.resolved.contract_hash,
            "composition": target.target.composition,
            "evaluation": result.resolved.request.evaluation,
            "numerics": result.resolved.request.numerics,
            "trial": trial,
            "environment": result.metadata,
        },
        "frames": result.replays[trial_key],
    }


def export_replay(result: EvaluationResult, path: str | Path, *, trial_key=None) -> Path:
    """Export an immutable recorded trajectory, not a browser simulation."""
    destination = Path(path)
    document = _replay_document(result, trial_key)
    destination.parent.mkdir(parents=True, exist_ok=True)
    _json(destination, document)
    return destination


def write_record(
    result: EvaluationResult,
    destination: str | Path,
    *,
    reservation: RecordReservation | None = None,
) -> Path:
    """Write a fresh bundle and verify its complete inventory before DONE."""
    reservation = _claim(destination, reservation)
    root = reservation.path
    try:
        write_plan(result.resolved.request, root / "request.toml")
        with (root / "resolved.toml").open("x", encoding="utf-8") as stream:
            stream.write(tomli_w.dumps(without_none(_portable(result.resolved))))
        data, summary, environment = (root / name for name in ("data", "summary", "environment"))
        for directory in (data, summary, environment):
            directory.mkdir()
        trials = []
        seeds = []
        for trial in result.trials:
            row = _portable(trial)
            row.update(row.pop("outcome"))
            row.pop("seeds")
            trials.append(row)
            for stream, seed in trial.seeds.items():
                seeds.append(
                    dict(
                        target_id=trial.target_id,
                        block_id=trial.block_id,
                        trial_id=trial.trial_id,
                        stream=stream,
                        seed=seed,
                        world_seed=trial.world_seed,
                        wiring_id=trial.wiring_id,
                    )
                )
        _csv(root / "trials.csv", trials)
        _csv(root / "seeds.csv", seeds)
        _json(
            summary / "summary.json",
            {
                "summaries": result.summaries,
                "contrasts": result.contrasts,
                "timings": result.timings,
                "metadata": result.metadata,
            },
        )
        _json(
            environment / "environment.json",
            {
                "package_version": "0.4.0",
                "python_version": platform.python_version(),
                "platform": sys.platform,
                "machine": platform.machine(),
                "quadrants_version": importlib.metadata.version("quadrants"),
                "execution": result.metadata,
            },
        )
        _source_bundle(environment)
        if result.events:
            rows, features = [], {}
            for index, event in enumerate(result.events):
                row = _portable(event)
                row.pop("features")
                name = f"event_{index:08d}"
                row["feature_array"] = name
                rows.append(row)
                features[name] = event.features
            _csv(data / "probe_events.csv", rows)
            with (data / "probe_features.npz").open("xb") as stream:
                np.savez_compressed(stream, **features)
        if result.probe_trials:
            _csv(data / "probe_trials.csv", result.probe_trials)
        if result.calibrations:
            _json(
                root / "calibration.json",
                {
                    "format": "brainlesslab-calibrations",
                    "version": 1,
                    "calibrations": result.calibrations,
                },
            )
        if result.replays:
            replay_directory = root / "replays"
            replay_directory.mkdir()
            for index, key in enumerate(sorted(result.replays)):
                export_replay(result, replay_directory / f"trial_{index:08d}.json", trial_key=key)
        files = sorted(
            p.relative_to(root).as_posix()
            for p in root.rglob("*")
            if p.is_file() and p.name != ".RESERVED"
        )
        hashes = {name: _sha(_contained(root, name)) for name in files}
        manifest = {
            "format": "brainlesslab-record",
            "format_version": 2,
            "id": root.name,
            "kind": result.resolved.request.operation,
            "created_utc": datetime.now(UTC).isoformat(),
            "package_version": "0.4.0",
            "contract_hash": result.resolved.contract_hash,
            "evidence": result.resolved.request.evidence,
            "trial_status_counts": {
                status: sum(trial.status == status for trial in result.trials)
                for status in sorted({trial.status for trial in result.trials})
            },
            "artifacts": files,
            "artifact_sha256": hashes,
            "completion_marker": "DONE",
        }
        with (root / "record.toml").open("x", encoding="utf-8") as stream:
            stream.write(tomli_w.dumps(manifest))
        inspected = inspect_record(root)
        if not inspected["checksums_valid"]:
            raise ValueError("new record inventory failed checksum verification")
        if all(trial.status == "completed" for trial in result.trials):
            (root / "DONE").write_text("complete\n", encoding="ascii")
        else:
            _json(
                root / "FAILED",
                {
                    "status": "failed",
                    "reason": "one or more trials failed or remained incomplete",
                    "trial_status_counts": manifest["trial_status_counts"],
                },
            )
        (root / ".RESERVED").unlink()
        return root
    except BaseException as error:
        fail_record(reservation, error)
        raise


def inspect_record(directory: str | Path) -> dict:
    """Inspect v1/v2 metadata and bytes without executing historical code."""
    root = Path(directory)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("a record must be a real directory")
    if any(path.is_symlink() for path in root.rglob("*")):
        raise ValueError("record artifacts cannot be symlinks")
    manifest_path = _contained(root, "record.toml")
    with manifest_path.open("rb") as stream:
        manifest = tomllib.load(stream)
    if manifest.get("format") != "brainlesslab-record" or manifest.get("format_version") not in (
        1,
        2,
    ):
        raise ValueError("unsupported record format")
    hashes = manifest.get("artifact_sha256", {})
    artifacts = manifest.get("artifacts", tuple(hashes))
    if (
        not isinstance(hashes, dict)
        or len(artifacts) != len(set(artifacts))
        or set(artifacts) != set(hashes)
    ):
        raise ValueError("record artifact inventory does not match its checksums")
    invalid = []
    for name, expected in hashes.items():
        path = _contained(root, name)
        if (
            not isinstance(expected, str)
            or len(expected) != 64
            or any(c not in "0123456789abcdef" for c in expected)
        ):
            raise ValueError("artifact checksum must be a SHA-256 hexadecimal value")
        if not path.is_file() or _sha(path) != expected:
            invalid.append(name)
    for name in ("DONE", "FAILED"):
        _contained(root, name)
    actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
    extras = sorted(actual - set(artifacts) - {"record.toml", "DONE", "FAILED", ".RESERVED"})
    valid = not invalid and not extras
    complete = (root / "DONE").is_file() and not (root / "FAILED").exists() and valid
    return {
        "manifest": manifest,
        "checksums_valid": valid,
        "invalid_artifacts": invalid,
        "unlisted_artifacts": extras,
        "complete": complete,
        "status": "complete"
        if complete
        else "failed"
        if (root / "FAILED").exists()
        else "incomplete",
    }


def read_calibration(path: str | Path) -> tuple[CalibrationRecord, ...]:
    """Restore calibration content only after its frozen hash validates."""
    path = Path(path)
    if path.is_dir():
        if not inspect_record(path)["complete"]:
            raise ValueError("calibration record is incomplete or has invalid checksums")
        path = _contained(path, "calibration.json")
    if path.is_symlink():
        raise ValueError("calibration cannot be a symlink")
    with path.open(encoding="utf-8") as stream:
        document = json.load(stream)
    if document.get("format") != "brainlesslab-calibrations" or document.get("version") != 1:
        raise ValueError("unsupported calibration format")
    records = []
    for item in document["calibrations"]:
        item = dict(item)
        signature = dict(item.pop("signature"))
        signature["numerics"] = NumericalPolicy(**signature["numerics"])
        records.append(CalibrationRecord(signature=CalibrationSignature(**signature), **item))
    return tuple(records)
