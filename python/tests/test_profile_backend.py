"""Profiler contract tests use synthetic clocks and execution, never timing jobs."""

import importlib.util
import itertools
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "examples/profile_backend.py"


@pytest.fixture
def profiler():
    spec = importlib.util.spec_from_file_location("profile_backend_contract", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def args_for(profiler, tmp_path, *flags):
    parser = profiler.parser_for()
    args = parser.parse_args([str(tmp_path / "profile"), "--dtype", "float32", *flags])
    profiler.validate_args(parser, args)
    return args


def result_for(*statuses, raw=0.5):
    trials = tuple(
        SimpleNamespace(
            target_id="baseline",
            block_id=i // 2,
            trial_id=i % 2,
            world_seed=f"world-{i}",
            wiring_id=f"wiring-{i // 2}",
            status=status,
            outcome=SimpleNamespace(raw=raw),
            completed_ticks=10 + i,
            neural_frames=24 * (10 + i),
        )
        for i, status in enumerate(statuses)
    )
    return SimpleNamespace(
        trials=trials, metadata={"batch_capacities": [2]}, timings={"total": 1.0}
    )


def test_batch_capacity_preserves_scientific_protocol(profiler, tmp_path):
    plans = [
        profiler.make_plan(
            args_for(
                profiler, tmp_path, "--trials", "128", "--blocks", "4", "--batch-size", str(batch)
            )
        )
        for batch in (1, 4, 32, 256)
    ]
    assert all(p == plans[0] for p in plans)
    assert plans[0].evaluation.blocks * plans[0].evaluation.trials_per_block == 128


def test_sync_boundaries_actual_work_and_separate_record_cost(profiler):
    events = []
    values = iter((10.0, 12.0, 15.0, 18.0))

    def clock():
        events.append("clock")
        return next(values)

    def execute():
        events.append("execute")
        return result_for("completed", "completed")

    def writer(result):
        events.append("record")
        return "records/sample"

    row, _ = profiler.measure(
        execute,
        lambda: events.append("sync"),
        requested=2,
        writer=writer,
        clock=clock,
        entry_started=4.0,
    )
    assert events == ["sync", "clock", "execute", "sync", "clock", "clock", "record", "clock"]
    assert row["execute_wall_seconds"] == row["wall_seconds"] == 2
    assert row["record_wall_seconds"] == 3 and row["combined_wall_seconds"] == 5
    assert row["entry_to_result_seconds"] == 8
    assert row["completed_world_ticks"] == 21 and row["completed_neural_frames"] == 504
    assert row["world_ticks_per_second"] == 10.5 and row["neural_frames_per_second"] == 252
    assert row["admitted_batch_capacities"] == [2]
    assert not row["isolated_kernel_time"]
    assert "construction" in row["timing_boundary"] and "transfer" in row["record_timing_boundary"]


@pytest.mark.parametrize(
    "statuses,raw",
    [
        (("failed", "completed"), 0.5),
        (("incomplete", "completed"), 0.5),
        (("completed",), 0.5),
        (("completed", "completed"), float("nan")),
        (("completed", "completed"), None),
    ],
)
def test_invalid_trials_cannot_be_fast_success(profiler, statuses, raw):
    row, _ = profiler.measure(
        lambda: result_for(*statuses, raw=raw),
        lambda: None,
        requested=2,
        clock=iter((0.0, 1.0)).__next__,
    )
    assert row["status"] == "failed" and row["world_ticks_per_second"] is None
    json.dumps(row, allow_nan=False)


def test_record_failure_retains_raws_and_fails(profiler):
    def writer(result):
        raise FileExistsError("exclusive destination already exists")

    row, _ = profiler.measure(
        lambda: result_for("completed", "completed"),
        lambda: None,
        requested=2,
        writer=writer,
        clock=iter((0.0, 1.0, 2.0, 3.0)).__next__,
    )
    assert row["status"] == "failed" and row["raw_outcomes"] == [0.5, 0.5]
    assert "FileExistsError" in row["error"] and row["world_ticks_per_second"] is None


def test_statistics_use_multiple_samples_and_keep_boundaries(profiler):
    summary = profiler.statistics_for([4.0, 1.0, 3.0, 2.0])
    assert summary["count"] == 4 and summary["median"] == 2.5
    assert summary["p25"] == 1.75 and summary["p75"] == 3.25
    assert profiler.statistics_for([2.0])["standard_deviation"] == 0


@pytest.mark.parametrize(
    "flags",
    [
        [],
        ["--dtype", "float32", "--count", "0"],
        ["--dtype", "float32", "--batch-size", "0"],
        ["--dtype", "float32", "--trials", "3"],
        ["--dtype", "float32", "--samples", "0"],
        ["--dtype", "float32", "--warmups", "-1"],
        ["--dtype", "float32", "--cpu-threads", "0"],
        ["--dtype", "float32", "--horizon", "0"],
        ["--dtype", "float64", "--backends", "cpu", "metal"],
        ["--dtype", "float32", "--activity-cpu-threshold", "nan"],
    ],
)
def test_invalid_cli_preflight_creates_no_output(profiler, tmp_path, monkeypatch, flags):
    monkeypatch.setattr(
        profiler, "background_activity", lambda *a: pytest.fail("activity before preflight")
    )
    with pytest.raises(SystemExit) as error:
        profiler.main([str(tmp_path / "profile"), *flags])
    assert error.value.code == 2 and not (tmp_path / "profile").exists()


def test_short_physical_horizon_requires_explicit_diagnostic(profiler, tmp_path, monkeypatch):
    monkeypatch.setattr(
        profiler, "background_activity", lambda *a: pytest.fail("activity before horizon check")
    )
    with pytest.raises(SystemExit):
        profiler.main(
            [
                str(tmp_path / "profile"),
                "--dtype",
                "float32",
                "--task",
                "tracking",
                "--horizon",
                "50",
            ]
        )
    from brainlesslab.plans import resolve

    resolved = resolve(
        profiler.make_plan(
            args_for(profiler, tmp_path, "--task", "tracking", "--horizon", "50", "--diagnostic")
        )
    )
    assert resolved.request.diagnostic and resolved.targets[0].horizon == 50


def test_background_captures_busy_non_compute_processes(profiler, monkeypatch):
    monkeypatch.setattr(profiler.sys, "platform", "linux")
    monkeypatch.setattr(
        profiler.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(
            stdout="999991 85.0 /System/fseventsd\n999992 0.0 /bin/python\n999993 0.1 /bin/quiet\n"
        ),
    )
    telemetry = profiler.background_activity()
    assert telemetry["status"] == "available"
    assert [p["executable"] for p in telemetry["processes"]] == ["fseventsd", "python"]
    assert telemetry["processes"][0]["cpu_percent"] == 85
    assert "snapshot" in telemetry["method"]


def test_unavailable_telemetry_is_unknown_and_requires_opt_in(profiler, tmp_path, monkeypatch):
    monkeypatch.setattr(profiler.sys, "platform", "linux")

    def unavailable(*a, **k):
        raise PermissionError("ps blocked")

    monkeypatch.setattr(profiler.subprocess, "run", unavailable)
    assert profiler.background_activity()["status"] == "unavailable"
    with pytest.raises(SystemExit) as error:
        profiler.main([str(tmp_path / "profile"), "--dtype", "float32"])
    assert error.value.code == 2 and not (tmp_path / "profile").exists()
    monkeypatch.setattr(profiler.sys, "platform", "win32")
    assert profiler.background_activity()["status"] == "unsupported"


def test_parent_rejects_failed_samples_even_when_worker_exits_zero(profiler, tmp_path, monkeypatch):
    monkeypatch.setattr(
        profiler, "background_activity", lambda *a: {"status": "available", "processes": []}
    )
    receipt = {
        "status": "complete",
        "samples": [{"status": "failed", "trial_statuses": ["failed"]}],
    }
    monkeypatch.setattr(
        profiler.subprocess,
        "run",
        lambda *a, **k: SimpleNamespace(
            returncode=0, stdout="PROFILE_RECEIPT=" + json.dumps(receipt), stderr=""
        ),
    )
    assert (
        profiler.main(
            [str(tmp_path / "profile"), "--dtype", "float32", "--samples", "1", "--warmups", "0"]
        )
        == 1
    )
    document = json.loads((tmp_path / "profile/receipt.json").read_text())
    assert document["measurements"][0]["status"] == "failed"
    assert "full worker" in document["measurements"][0]["process_timing_boundary"]


def test_worker_repeated_samples_fail_on_changed_work_without_running_runtime(
    profiler, tmp_path, monkeypatch, capsys
):
    import brainlesslab.backend
    import brainlesslab.evaluation
    import brainlesslab.plans

    args = args_for(
        profiler,
        tmp_path,
        "--worker-backend",
        "cpu",
        "--samples",
        "1",
        "--warmups",
        "0",
        "--trials",
        "2",
    )
    plan = profiler.make_plan(args)
    resolved = SimpleNamespace(
        request=plan, contract_hash="hash", targets=[SimpleNamespace(horizon=144)]
    )
    monkeypatch.setattr(brainlesslab.plans, "resolve", lambda p: resolved)
    monkeypatch.setattr(brainlesslab.backend, "initialise", lambda *a: {})
    results = iter(
        (result_for("completed", "completed"), result_for("completed", "completed", raw=0.7))
    )
    monkeypatch.setattr(brainlesslab.evaluation, "execute", lambda *a, **k: next(results))
    fake = SimpleNamespace(
        sync=lambda: None,
        lang=SimpleNamespace(
            impl=SimpleNamespace(
                current_cfg=lambda: SimpleNamespace(arch="fake"),
                get_runtime=lambda: SimpleNamespace(get_num_compiled_functions=lambda: 3),
            )
        ),
    )
    monkeypatch.setitem(sys.modules, "quadrants", fake)
    monkeypatch.setattr(profiler, "source_metadata", lambda: {})
    monkeypatch.setattr(profiler.time, "perf_counter", itertools.count().__next__)
    monkeypatch.setattr(
        profiler, "typed_cache_check", lambda *a: pytest.fail("must stop on changed outcomes")
    )
    assert profiler.worker(args) == 1
    receipt = json.loads(capsys.readouterr().out.removeprefix("PROFILE_RECEIPT="))
    assert receipt["status"] == "failed" and "changed" in receipt["error"]
    assert receipt["samples"][0]["raw_outcomes"] == [0.5, 0.5]
    assert receipt["samples"][1]["raw_outcomes"] == [0.7, 0.7]
    assert receipt["worker_entry_to_first_result_seconds"] > receipt["samples"][0]["wall_seconds"]


def test_parent_serial_cache_phases_preserve_fixed_trials(profiler, tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(
        profiler, "background_activity", lambda *a: {"status": "available", "processes": []}
    )

    def run(command, **options):
        backend = command[command.index("--worker-backend") + 1]
        phase = command[command.index("--process-phase") + 1]
        calls.append((backend, phase))
        assert command[command.index("--trials") + 1] == "2"
        assert command[command.index("--batch-size") + 1] == "32"
        cache = Path(options["env"]["BRAINLESSLAB_CACHE_DIR"])
        if phase == "cold_cache_new_process":
            assert not list(cache.iterdir())
        else:
            assert (cache / "cache-entry").is_file()
        (cache / "cache-entry").write_text("mock cache")
        row = {
            "status": "complete",
            "trial_statuses": ["completed"] * 2,
            "work_signature": "work",
            "outcome_signature": "outcomes",
        }
        receipt = {
            "status": "complete",
            "samples": [row, row],
            "warmups": [],
            "protocol_signature": "protocol",
            "typed_bundle_compiled_counts": [4, 4, 4, 5],
        }
        return SimpleNamespace(
            returncode=0, stdout="PROFILE_RECEIPT=" + json.dumps(receipt), stderr=""
        )

    monkeypatch.setattr(profiler.subprocess, "run", run)
    assert (
        profiler.main(
            [
                str(tmp_path / "profile"),
                "--dtype",
                "float32",
                "--backends",
                "cpu",
                "metal",
                "--samples",
                "1",
                "--warmups",
                "0",
                "--trials",
                "2",
                "--batch-size",
                "32",
            ]
        )
        == 0
    )
    assert calls == [
        ("cpu", "cold_cache_new_process"),
        ("cpu", "warm_cache_new_process"),
        ("metal", "cold_cache_new_process"),
        ("metal", "warm_cache_new_process"),
    ]
    receipt = json.loads((tmp_path / "profile/receipt.json").read_text())
    assert receipt["format"] == "brainlesslab-backend-profile" and receipt["version"] == 1
    assert receipt["measurements"][1]["cache_files_before"] == ["cache-entry"]
    assert "uncontrolled" in receipt["cache_scope"]


def test_worker_success_excludes_first_and_warmups_from_statistics(
    profiler, tmp_path, monkeypatch, capsys
):
    import brainlesslab.backend
    import brainlesslab.evaluation
    import brainlesslab.plans

    args = args_for(
        profiler,
        tmp_path,
        "--worker-backend",
        "cpu",
        "--samples",
        "3",
        "--warmups",
        "2",
        "--trials",
        "2",
    )
    plan = profiler.make_plan(args)
    resolved = SimpleNamespace(
        request=plan, contract_hash="hash", targets=[SimpleNamespace(horizon=144)]
    )
    monkeypatch.setattr(brainlesslab.plans, "resolve", lambda p: resolved)
    monkeypatch.setattr(brainlesslab.backend, "initialise", lambda *a: {})
    calls = []

    def execute(*a, **k):
        calls.append(k["execution"])
        return result_for("completed", "completed")

    monkeypatch.setattr(brainlesslab.evaluation, "execute", execute)
    fake = SimpleNamespace(
        sync=lambda: None,
        lang=SimpleNamespace(
            impl=SimpleNamespace(
                current_cfg=lambda: SimpleNamespace(arch="fake"),
                get_runtime=lambda: SimpleNamespace(get_num_compiled_functions=lambda: 3),
            )
        ),
    )
    monkeypatch.setitem(sys.modules, "quadrants", fake)
    monkeypatch.setattr(profiler, "source_metadata", lambda: {"profile_script_sha256": "source"})
    monkeypatch.setattr(profiler.time, "perf_counter", itertools.count().__next__)
    monkeypatch.setattr(profiler, "typed_cache_check", lambda *a: [3, 3, 3, 4])
    rss = {"status": "unsupported", "diagnostic": "ImportError"}
    monkeypatch.setattr(profiler, "peak_rss", lambda: rss)
    assert profiler.worker(args) == 0
    receipt = json.loads(capsys.readouterr().out.removeprefix("PROFILE_RECEIPT="))
    assert len(calls) == 6 and len(receipt["samples"]) == 4 and len(receipt["warmups"]) == 2
    assert receipt["statistics"]["execute_wall_seconds"]["count"] == 3
    assert receipt["statistics"]["world_ticks_per_second"]["median"] == 21
    assert receipt["statistics"]["record_wall_seconds"]["count"] == 0
    assert receipt["typed_bundle_compiled_counts"] == [3, 3, 3, 4]
    assert receipt["source"]["profile_script_sha256"] == "source"
    assert receipt["peak_rss"] == rss


@pytest.mark.parametrize(
    "system,units,bytes_", [("darwin", "bytes", 4096), ("linux", "KiB", 4194304)]
)
def test_peak_rss_records_platform_units_not_vram(profiler, monkeypatch, system, units, bytes_):
    monkeypatch.setitem(
        sys.modules,
        "resource",
        SimpleNamespace(RUSAGE_SELF=0, getrusage=lambda _: SimpleNamespace(ru_maxrss=4096)),
    )
    monkeypatch.setattr(profiler.sys, "platform", system)
    receipt = profiler.peak_rss()
    assert receipt["value"] == 4096 and receipt["units"] == units and receipt["bytes"] == bytes_
    assert "all stages" in receipt["scope"] and "not VRAM" in receipt["scope"]


def test_missing_resource_reports_unsupported_rss(profiler, monkeypatch):
    monkeypatch.setitem(sys.modules, "resource", None)
    assert profiler.peak_rss() == {"status": "unsupported", "diagnostic": "ModuleNotFoundError"}


def test_identity_is_separate_from_early_ending_work(profiler):
    result = result_for("completed", "completed")
    before = profiler._result_work(result, 2, horizon=11)
    result.trials[0].completed_ticks = 12
    result.trials[0].neural_frames = 288
    after = profiler._result_work(result, 2, horizon=11)
    assert before["identity_signature"] == after["identity_signature"]
    assert before["work_signature"] != after["work_signature"]
    assert before["early_ending_trials"] == 1 and after["early_ending_trials"] == 0
    assert after["trial_work"][0]["completed_world_ticks"] == 12
    assert after["trial_work"][0]["completed_neural_frames"] == 288


def test_source_metadata_retains_exact_lock_and_numpy(profiler):
    import hashlib
    import importlib.metadata

    metadata = profiler.source_metadata()
    lock = SCRIPT.parents[2] / "uv.lock"
    assert metadata["uv_lock_status"] == "captured"
    assert metadata["uv_lock_sha256"] == hashlib.sha256(lock.read_bytes()).hexdigest()
    assert metadata["numpy_version"] == importlib.metadata.version("numpy")
    assert metadata["package_source_sha256"]["evaluation.py"]


def test_empty_cache_cannot_be_labelled_warm(profiler, tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(
        profiler, "background_activity", lambda *a: {"status": "available", "processes": []}
    )

    def run(command, **options):
        calls.append(command)
        row = {
            "status": "complete",
            "trial_statuses": ["completed"] * 2,
            "work_signature": "work",
            "outcome_signature": "outcomes",
        }
        receipt = {
            "status": "complete",
            "samples": [row, row],
            "warmups": [],
            "protocol_signature": "protocol",
            "typed_bundle_compiled_counts": [4, 4, 4, 5],
        }
        return SimpleNamespace(
            returncode=0, stdout="PROFILE_RECEIPT=" + json.dumps(receipt), stderr=""
        )

    monkeypatch.setattr(profiler.subprocess, "run", run)
    assert (
        profiler.main(
            [
                str(tmp_path / "profile"),
                "--dtype",
                "float32",
                "--samples",
                "1",
                "--warmups",
                "0",
                "--trials",
                "2",
            ]
        )
        == 1
    )
    assert len(calls) == 1
    receipt = json.loads((tmp_path / "profile/receipt.json").read_text())
    assert receipt["measurements"][1]["status"] == "failed"
    assert "cache remains empty" in receipt["measurements"][1]["error"]
