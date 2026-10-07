"""Check, execute and inspect the same versioned operation plans."""

from __future__ import annotations

import argparse
import json
import secrets
import sys
from contextlib import redirect_stdout
from datetime import UTC, datetime
from pathlib import Path

from .plans import read_plan, resolve
from .records import fail_record, inspect_record, read_calibration, reserve_record, write_record
from .specs import ExecutionSpec, plain


def _parser():
    parser = argparse.ArgumentParser(
        prog="brainlesslab",
        description=(
            "Execute fresh Python v4 plans; inspect historical records without replaying them."
        ),
    )
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser(
        "check", help="validate and resolve a plan without initialising a backend"
    )
    check.add_argument("plan", type=Path)
    run = commands.add_parser("run", help="execute a plan and write one new checksummed record")
    run.add_argument("plan", type=Path)
    run.add_argument("--root", type=Path, default=Path("records"))
    run.add_argument("--backend", choices=("cpu", "metal"), default="cpu")
    run.add_argument("--batch-size", type=int, default=32)
    run.add_argument("--memory-budget-mib", type=int, default=256)
    run.add_argument(
        "--recording", choices=("summary", "probe_events", "replay"), default="summary"
    )
    run.add_argument("--recording-budget-mib", type=int, default=32)
    run.add_argument("--cpu-threads", type=int, default=1)
    run.add_argument("--calibration", type=Path, action="append", default=[])
    inspect = commands.add_parser(
        "inspect", help="read v1/v2 record metadata and verify artifact checksums"
    )
    inspect.add_argument("record", type=Path)
    return parser


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    reservation = None
    try:
        if args.command == "inspect":
            inspection = inspect_record(args.record)
            print(json.dumps(inspection, ensure_ascii=False, sort_keys=True))
            return 0 if inspection["complete"] else 1
        with redirect_stdout(sys.stderr):
            resolved = resolve(read_plan(args.plan))
        if args.command == "check":
            print(json.dumps(plain(resolved), ensure_ascii=False, sort_keys=True, allow_nan=False))
            return 0
        execution = ExecutionSpec(
            backend=args.backend,
            batch_size=args.batch_size,
            memory_budget_bytes=args.memory_budget_mib * 1024 * 1024,
            recording=args.recording,
            recording_budget_bytes=args.recording_budget_mib * 1024 * 1024,
            cpu_threads=args.cpu_threads,
        )
        if execution.backend == "metal" and resolved.request.numerics.dtype != "float32":
            raise ValueError("Metal requires an explicit Float32 plan")
        calibrations = tuple(
            record for path in args.calibration for record in read_calibration(path)
        )
        identity = resolved.request.id
        if Path(identity).name != identity or identity in (".", "..") or "\\" in identity:
            raise ValueError("plan id must be a portable record-name component")
        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        reservation = reserve_record(args.root / f"{identity}-{stamp}-{secrets.token_hex(4)}")
        # Execution is deliberately imported after parsing/help and preflight.
        with redirect_stdout(sys.stderr):
            from .evaluation import execute

            result = execute(resolved, execution=execution, calibrations=calibrations)
        destination = write_record(result, reservation.path, reservation=reservation)
        status = inspect_record(destination)["status"]
        print(json.dumps({"record": str(destination), "status": status}, ensure_ascii=False))
        return 0 if status == "complete" else 1
    except (Exception, KeyboardInterrupt) as error:
        if reservation is not None and (reservation.path / ".RESERVED").exists():
            fail_record(reservation, error)
        print(f"brainlesslab: {type(error).__name__}: {error}", file=sys.stderr)
        return 130 if isinstance(error, KeyboardInterrupt) else 1


if __name__ == "__main__":
    raise SystemExit(main())
