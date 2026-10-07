import subprocess
import sys
from pathlib import Path

from brainlesslab.cli import main
from brainlesslab.plans import read_plan, resolve

PLANS = Path(__file__).resolve().parents[1] / "plans"


def test_help_does_not_import_or_initialise_quadrants():
    code = (
        "from brainlesslab.cli import main; import sys; "
        "assert 'quadrants' not in sys.modules; main(['--help'])"
    )
    run = subprocess.run([sys.executable, "-c", code], text=True, capture_output=True, check=False)
    assert run.returncode == 0 and "check" in run.stdout and "[Quadrants]" not in run.stdout


def test_check_does_not_initialise_backend(capsys):
    assert main(["check", str(PLANS / "delayed-cue.toml")]) == 0
    output = capsys.readouterr().out
    # Model discovery may import Quadrants, but must not select an architecture.
    assert "Starting on arch" not in output
    assert '"contract_hash"' in output and '"recall_accuracy"' in output


def test_all_checked_in_plans_validate():
    plans = list(PLANS.glob("*.toml"))
    assert len(plans) >= 6
    for path in plans:
        result = resolve(read_plan(path))
        assert result.targets and result.request.evidence == "exploratory"
        if result.request.operation == "calibrate":
            assert result.request.evaluation.blocks == 1024
            assert result.request.evaluation.trials_per_block == 1
            assert result.request.evaluation.seed_partition == "calibration"


def test_run_preflight_does_not_allocate_failed_metal_record(tmp_path, capsys):
    root = tmp_path / "records"
    assert (
        main(["run", str(PLANS / "delayed-cue.toml"), "--root", str(root), "--backend", "metal"])
        == 1
    )
    assert not root.exists()
    assert "Float32" in capsys.readouterr().err


def test_execution_exception_creates_failed_reserved_record(tmp_path, monkeypatch, capsys):
    import types

    module = types.ModuleType("brainlesslab.evaluation")

    def failed(*args, **kwargs):
        raise RuntimeError("injected execution failure")

    module.execute = failed
    monkeypatch.setitem(sys.modules, "brainlesslab.evaluation", module)
    root = tmp_path / "records"
    assert main(["run", str(PLANS / "delayed-cue.toml"), "--root", str(root)]) == 1
    records = list(root.iterdir())
    assert len(records) == 1
    assert (records[0] / "FAILED").exists() and not (records[0] / "DONE").exists()
    assert "injected execution failure" in capsys.readouterr().err


def test_inspect_reports_bad_record_without_execution(tmp_path, capsys):
    assert main(["inspect", str(tmp_path / "missing")]) == 1
    assert "record must be" in capsys.readouterr().err
