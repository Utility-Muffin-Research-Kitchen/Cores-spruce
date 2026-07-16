#!/usr/bin/env python3
"""Validate and complete an MLP1 core build report with probed library names."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


REPORT_VERSION = 2
ROW_STATUSES = ("built", "failed", "deferred")


class ReportError(ValueError):
    pass


def nonnegative_report_int(report: dict, field: str) -> int:
    value = report.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ReportError(f"{field} must be a non-negative integer, got {value!r}")
    return value


def validate_report_summary(report: dict) -> dict[str, list[dict]]:
    rows_by_status: dict[str, list[dict]] = {
        status: [] for status in ROW_STATUSES
    }
    seen_cores: set[str] = set()

    for index, row in enumerate(report["cores"]):
        if not isinstance(row, dict):
            raise ReportError(f"cores[{index}] must be an object")

        core = row.get("core")
        if not isinstance(core, str) or not core:
            raise ReportError(f"cores[{index}] has no core id")
        if core in seen_cores:
            raise ReportError(f"duplicate core id: {core}")
        seen_cores.add(core)

        row_status = row.get("status")
        if row_status not in rows_by_status:
            raise ReportError(
                f"{core}: row status must be one of {', '.join(ROW_STATUSES)}, "
                f"got {row_status!r}"
            )
        rows_by_status[row_status].append(row)

    counts = {
        status: len(rows_by_status[status]) for status in ROW_STATUSES
    }
    for status in ROW_STATUSES:
        field = f"{status}_count"
        reported = nonnegative_report_int(report, field)
        if reported != counts[status]:
            raise ReportError(
                f"{field} must be {counts[status]}, got {reported!r}"
            )

    requested_count = nonnegative_report_int(report, "requested_count")
    attempted_count = counts["built"] + counts["failed"]
    if requested_count != attempted_count:
        raise ReportError(
            f"requested_count must be {attempted_count}, got {requested_count!r}"
        )

    expected_status = (
        "passed"
        if counts["failed"] == 0 and counts["deferred"] == 0
        else "failed"
    )
    if report.get("status") != expected_status:
        raise ReportError(
            f"status must be {expected_status!r} for the reported row counts, "
            f"got {report.get('status')!r}"
        )

    library_name_count = nonnegative_report_int(report, "library_name_count")
    library_name_status = report.get("library_name_status")
    built_count = counts["built"]
    if built_count == 0:
        if library_name_status != "not-applicable":
            raise ReportError(
                "library_name_status must be 'not-applicable' when no cores "
                f"were built, got {library_name_status!r}"
            )
        if library_name_count != 0:
            raise ReportError(
                f"library_name_count must be 0, got {library_name_count!r}"
            )
    elif library_name_status == "pending":
        if library_name_count != 0:
            raise ReportError(
                f"library_name_count must be 0 while pending, got {library_name_count!r}"
            )
    elif library_name_status == "complete":
        if library_name_count != built_count:
            raise ReportError(
                f"library_name_count must be {built_count}, "
                f"got {library_name_count!r}"
            )
    else:
        raise ReportError(
            "library_name_status must be 'pending' or 'complete' when cores "
            f"were built, got {library_name_status!r}"
        )

    for row in rows_by_status["built"]:
        core = row["core"]
        library_name = row.get("library_name")
        if not isinstance(library_name, str):
            raise ReportError(f"{core}: library_name must be a string")
        if library_name_status == "pending":
            if library_name:
                raise ReportError(
                    f"{core}: pending report must have an empty library_name"
                )
        else:
            validate_library_name(core, library_name)

    for status in ("failed", "deferred"):
        for row in rows_by_status[status]:
            core = row["core"]
            if row.get("library_name") != "":
                raise ReportError(
                    f"{core}: {status} row must have an empty library_name"
                )

    return rows_by_status


def require_successful_build(report: dict) -> None:
    if report["status"] != "passed":
        raise ReportError(
            "build report is not probeable: "
            f"failed_count={report['failed_count']} "
            f"deferred_count={report['deferred_count']}"
        )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_report(path: Path) -> dict:
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReportError(f"cannot read {path}: {error}") from error

    if not isinstance(report, dict):
        raise ReportError("report root must be an object")
    if report.get("version") != REPORT_VERSION:
        raise ReportError(
            f"report version must be {REPORT_VERSION}, got {report.get('version')!r}"
        )
    if report.get("platform") != "mlp1":
        raise ReportError("report platform must be 'mlp1'")
    if not isinstance(report.get("cores"), list):
        raise ReportError("report cores must be an array")
    validate_report_summary(report)
    return report


def built_rows(report: dict, cores_dir: Path) -> dict[str, tuple[dict, Path]]:
    rows: dict[str, tuple[dict, Path]] = {}
    for index, row in enumerate(report["cores"]):
        if not isinstance(row, dict):
            raise ReportError(f"cores[{index}] must be an object")
        if row.get("status") != "built":
            continue

        core = row.get("core")
        core_file = row.get("core_file")
        expected_sha256 = row.get("sha256")
        if not isinstance(core, str) or not core:
            raise ReportError(f"cores[{index}] has no core id")
        if core in rows:
            raise ReportError(f"duplicate built core id: {core}")
        if (
            not isinstance(core_file, str)
            or not core_file
            or Path(core_file).name != core_file
        ):
            raise ReportError(f"{core}: invalid core_file {core_file!r}")
        if (
            not isinstance(expected_sha256, str)
            or len(expected_sha256) != 64
            or any(ch not in "0123456789abcdef" for ch in expected_sha256)
        ):
            raise ReportError(f"{core}: invalid sha256 {expected_sha256!r}")

        core_path = cores_dir / core_file
        if not core_path.is_file():
            raise ReportError(f"{core}: core file is missing: {core_path}")
        actual_sha256 = sha256_file(core_path)
        if actual_sha256 != expected_sha256:
            raise ReportError(
                f"{core}: checksum mismatch for {core_path}: "
                f"report={expected_sha256} actual={actual_sha256}"
            )
        rows[core] = (row, core_path)

    if not rows:
        raise ReportError("report contains no built cores")
    return rows


def validate_library_name(core: str, library_name: str) -> None:
    if not library_name:
        raise ReportError(f"{core}: empty library_name")
    if library_name in {".", ".."}:
        raise ReportError(f"{core}: invalid library_name {library_name!r}")
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in library_name):
        raise ReportError(f"{core}: library_name contains a control character")


def read_results(path: Path) -> dict[str, tuple[str, str, str]]:
    results: dict[str, tuple[str, str, str]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ReportError(f"cannot read probe results {path}: {error}") from error

    for line_number, line in enumerate(lines, start=1):
        fields = line.split("\t", 3)
        if len(fields) != 4:
            raise ReportError(
                f"{path}:{line_number}: expected core, file, sha256, and library_name"
            )
        core, core_file, checksum, library_name = fields
        if not core or core in results:
            raise ReportError(f"{path}:{line_number}: missing or duplicate core id")
        validate_library_name(core, library_name)
        results[core] = (core_file, checksum, library_name)
    return results


def write_report_atomic(path: Path, report: dict) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as stream:
        temp_path = Path(stream.name)
        json.dump(report, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        temp_path.chmod(mode)
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def command_manifest(args: argparse.Namespace) -> None:
    report = load_report(args.report)
    require_successful_build(report)
    rows = built_rows(report, args.cores_dir)
    for core, (row, _core_path) in rows.items():
        print(f"{core}\t{row['core_file']}\t{row['sha256']}")


def command_verify(args: argparse.Namespace) -> None:
    report = load_report(args.report)
    require_successful_build(report)
    rows = built_rows(report, args.cores_dir)
    expected_count = len(rows)
    if report.get("library_name_status") != "complete":
        raise ReportError(
            "library_name_status must be 'complete', got "
            f"{report.get('library_name_status')!r}"
        )

    print(f"complete: {expected_count} checksum-bound MLP1 core library names")


def command_apply(args: argparse.Namespace) -> None:
    report = load_report(args.report)
    require_successful_build(report)
    rows = built_rows(report, args.cores_dir)
    results = read_results(args.results)

    missing = sorted(set(rows) - set(results))
    extra = sorted(set(results) - set(rows))
    if missing or extra:
        details = []
        if missing:
            details.append(f"missing={','.join(missing)}")
        if extra:
            details.append(f"extra={','.join(extra)}")
        raise ReportError("probe result set does not match built cores: " + " ".join(details))

    for core, (row, _core_path) in rows.items():
        core_file, checksum, library_name = results[core]
        if core_file != row["core_file"]:
            raise ReportError(
                f"{core}: result core_file {core_file!r} does not match report "
                f"{row['core_file']!r}"
            )
        if checksum != row["sha256"]:
            raise ReportError(
                f"{core}: result checksum {checksum!r} does not match report checksum"
            )
        row["library_name"] = library_name

    report["built_count"] = len(rows)
    report["library_name_count"] = len(rows)
    report["library_name_status"] = "complete"
    write_report_atomic(args.report, report)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name, handler in (
        ("manifest", command_manifest),
        ("verify", command_verify),
        ("apply", command_apply),
    ):
        command = subparsers.add_parser(name)
        command.add_argument("--report", type=Path, required=True)
        command.add_argument("--cores-dir", type=Path, required=True)
        if name == "apply":
            command.add_argument("--results", type=Path, required=True)
        command.set_defaults(handler=handler)

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        args.handler(args)
    except ReportError as error:
        print(f"mlp1-core-report: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
