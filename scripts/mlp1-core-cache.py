#!/usr/bin/env python3
"""Validate and reuse local MLP1 core artifacts by build-input fingerprint."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import zipfile


CACHE_VERSION = 1
REPORT_FIELDS = (
    "core",
    "status",
    "core_file",
    "info_file",
    "reason",
    "machine",
    "max_glibc",
    "tuning",
    "source_url",
    "source_commit",
    "build_lane",
    "sha256",
    "library_name",
)


class CacheError(ValueError):
    pass


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CacheError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise CacheError(f"{label} root must be an object")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as stream:
        temp_path = Path(stream.name)
        json.dump(value, stream, indent=2, ensure_ascii=False, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(temp_path, path)
    finally:
        temp_path.unlink(missing_ok=True)


def lock_entries(args: argparse.Namespace) -> dict[str, dict]:
    lock = load_json(args.lock, "core lock")
    if lock.get("version") != 1 or lock.get("platform") != "mlp1":
        raise CacheError("core lock must be version 1 for platform mlp1")
    entries = lock.get("cores")
    if not isinstance(entries, dict):
        raise CacheError("core lock cores must be an object")
    expected = set(args.core)
    if set(entries) != expected:
        missing = sorted(expected - set(entries))
        extra = sorted(set(entries) - expected)
        raise CacheError(f"core lock does not match stock parity: missing={missing} extra={extra}")
    for core, entry in entries.items():
        if not isinstance(entry, dict):
            raise CacheError(f"{core}: lock entry must be an object")
        for field in ("url", "commit", "checkout", "recipe"):
            if not isinstance(entry.get(field), str) or not entry[field]:
                raise CacheError(f"{core}: lock entry has invalid {field}")
        commit = entry["commit"]
        if len(commit) != 40 or any(ch not in "0123456789abcdef" for ch in commit):
            raise CacheError(f"{core}: lock commit must be a lowercase full SHA")
        checkout = Path(entry["checkout"])
        if checkout.is_absolute() or ".." in checkout.parts:
            raise CacheError(f"{core}: lock checkout must stay under the source directory")
    return entries


def input_fingerprint(args: argparse.Namespace, core: str, entry: dict) -> str:
    patch = args.patch_dir / f"{core}.patch"
    payload = {
        "version": CACHE_VERSION,
        "core": core,
        "source_url": entry["url"],
        "source_commit": entry["commit"],
        "recipe": entry["recipe"],
        "patch_sha256": sha256_file(patch) if patch.is_file() else "",
        "libretro_super_url": args.libretro_super_url,
        "libretro_super_commit": args.libretro_super_commit,
        "toolchain_id": args.toolchain_id,
        "target_soc": args.target_soc,
        "target_cpu": args.target_cpu,
        "build_profile": args.build_profile,
        "cflags": args.cflags,
        "cxxflags": args.cxxflags,
        "ldflags": args.ldflags,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def empty_cache() -> dict:
    return {"version": CACHE_VERSION, "platform": "mlp1", "entries": {}}


def load_cache(path: Path) -> dict:
    if not path.is_file():
        return empty_cache()
    cache = load_json(path, "core cache")
    if cache.get("version") != CACHE_VERSION or cache.get("platform") != "mlp1":
        raise CacheError("core cache has unsupported identity")
    if not isinstance(cache.get("entries"), dict):
        raise CacheError("core cache entries must be an object")
    return cache


def report_rows(report: dict, expected: set[str]) -> dict[str, dict]:
    if report.get("version") != 2 or report.get("platform") != "mlp1":
        raise CacheError("build report must be version 2 for platform mlp1")
    if report.get("status") != "passed":
        raise CacheError("build report did not pass")
    rows = report.get("cores")
    if not isinstance(rows, list):
        raise CacheError("build report cores must be an array")
    by_core: dict[str, dict] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("core"), str):
            raise CacheError("build report contains an invalid core row")
        core = row["core"]
        if core in by_core:
            raise CacheError(f"duplicate build report core: {core}")
        by_core[core] = row
    if set(by_core) != expected:
        raise CacheError("build report does not cover the exact stock-parity set")
    if report.get("requested_count") != len(expected) or report.get("built_count") != len(expected):
        raise CacheError("build report summary does not cover the stock-parity set")
    return by_core


def validate_report_context(args: argparse.Namespace, report: dict, label: str) -> None:
    expected = {
        "target_soc": args.target_soc,
        "target_cpu": args.target_cpu,
        "build_profile": args.build_profile,
        "cflags": args.cflags,
        "cxxflags": args.cxxflags,
        "ldflags": args.ldflags,
        "libretro_super_url": args.libretro_super_url,
        "libretro_super_commit": args.libretro_super_commit,
    }
    for field, value in expected.items():
        if report.get(field) != value:
            raise CacheError(
                f"{label} {field} does not match the current locked build input"
            )


def validated_entry(
    args: argparse.Namespace, core: str, lock_entry: dict, cache_entry: object
) -> tuple[dict | None, str]:
    if not isinstance(cache_entry, dict):
        return None, "no cache entry"
    expected_fingerprint = input_fingerprint(args, core, lock_entry)
    if cache_entry.get("input_fingerprint") != expected_fingerprint:
        return None, "input fingerprint changed"
    core_file = cache_entry.get("core_file")
    info_file = cache_entry.get("info_file")
    if not isinstance(core_file, str) or Path(core_file).name != core_file:
        return None, "invalid cached core filename"
    if not isinstance(info_file, str) or Path(info_file).name != info_file:
        return None, "invalid cached info filename"
    core_path = args.cores_dir / core_file
    info_path = args.info_dir / info_file
    if not core_path.is_file():
        return None, "core binary is missing"
    if not info_path.is_file():
        return None, "core info file is missing"
    if sha256_file(core_path) != cache_entry.get("sha256"):
        return None, "core checksum changed"
    if sha256_file(info_path) != cache_entry.get("info_sha256"):
        return None, "core info checksum changed"
    machine = cache_entry.get("machine")
    if not isinstance(machine, str) or "AArch64" not in machine:
        return None, "cached core is not recorded as AArch64"
    return cache_entry, ""


def command_check(args: argparse.Namespace) -> None:
    entries = lock_entries(args)
    cache = load_cache(args.cache)
    hits = 0
    misses = 0
    for core in args.core:
        reusable, reason = validated_entry(args, core, entries[core], cache["entries"].get(core))
        if reusable is None:
            misses += 1
            print(f"miss\t{core}\t{reason}")
        else:
            hits += 1
            print(f"hit\t{core}\t{reusable['sha256']}")
    print(f"cache: {hits} reused / {misses} misses")
    if misses:
        raise SystemExit(1)


def command_reuse(args: argparse.Namespace) -> None:
    entries = lock_entries(args)
    cache = load_cache(args.cache)
    reusable, reason = validated_entry(
        args, args.selected_core, entries[args.selected_core], cache["entries"].get(args.selected_core)
    )
    if reusable is None:
        print(f"cache miss: {args.selected_core}: {reason}", file=sys.stderr)
        raise SystemExit(1)
    row = {field: reusable.get(field, "") for field in REPORT_FIELDS}
    row["core"] = args.selected_core
    row["status"] = "built"
    row["reason"] = ""
    row["source_url"] = entries[args.selected_core]["url"]
    row["source_commit"] = entries[args.selected_core]["commit"]
    fields = [str(row[field]) for field in REPORT_FIELDS]
    fields.extend(("reused", reusable["input_fingerprint"]))
    print("\x1f".join(fields))


def row_to_entry(
    args: argparse.Namespace,
    core: str,
    lock_entry: dict,
    row: dict,
    prior: object = None,
) -> dict:
    if row.get("status") != "built":
        raise CacheError(f"{core}: cannot cache a non-built row")
    core_file = row.get("core_file")
    info_file = row.get("info_file")
    if not isinstance(core_file, str) or Path(core_file).name != core_file:
        raise CacheError(f"{core}: invalid core filename")
    if not isinstance(info_file, str) or Path(info_file).name != info_file:
        raise CacheError(f"{core}: invalid info filename")
    core_path = args.cores_dir / core_file
    info_path = args.info_dir / info_file
    if not core_path.is_file() or not info_path.is_file():
        raise CacheError(f"{core}: core or info artifact is missing")
    actual_sha = sha256_file(core_path)
    if row.get("sha256") != actual_sha:
        raise CacheError(f"{core}: report checksum does not match the local binary")
    machine = row.get("machine")
    if not isinstance(machine, str) or "AArch64" not in machine:
        raise CacheError(f"{core}: report does not identify an AArch64 binary")
    library_name = row.get("library_name") if isinstance(row.get("library_name"), str) else ""
    if not library_name and isinstance(prior, dict) and prior.get("sha256") == actual_sha:
        library_name = prior.get("library_name", "")
    entry = {field: row.get(field, "") for field in REPORT_FIELDS}
    entry.update(
        {
            "core": core,
            "status": "built",
            "reason": "",
            "source_url": lock_entry["url"],
            "source_commit": lock_entry["commit"],
            "sha256": actual_sha,
            "info_sha256": sha256_file(info_path),
            "library_name": library_name,
            "input_fingerprint": input_fingerprint(args, core, lock_entry),
        }
    )
    return entry


def command_update(args: argparse.Namespace) -> None:
    entries = lock_entries(args)
    cache = load_cache(args.cache)
    report = load_json(args.report, "build report")
    rows = report.get("cores")
    if not isinstance(rows, list):
        raise CacheError("build report cores must be an array")
    updated = 0
    for row in rows:
        if not isinstance(row, dict) or row.get("status") != "built":
            continue
        core = row.get("core")
        if core not in entries:
            continue
        cache["entries"][core] = row_to_entry(
            args, core, entries[core], row, cache["entries"].get(core)
        )
        updated += 1
    atomic_json(args.cache, cache)
    print(f"cache updated: {updated} core entr{'y' if updated == 1 else 'ies'}")


def zip_member_sha256(archive: zipfile.ZipFile, member: str) -> str:
    digest = hashlib.sha256()
    with archive.open(member) as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_adopt(args: argparse.Namespace) -> None:
    entries = lock_entries(args)
    expected = set(args.core)
    if sha256_file(args.reference_zip) != args.reference_sha256:
        raise CacheError("reference ZIP checksum does not match the published digest")
    report = load_json(args.report, "local build report")
    local_rows = report_rows(report, expected)
    validate_report_context(args, report, "local build report")
    with zipfile.ZipFile(args.reference_zip) as archive:
        candidates = [
            name for name in archive.namelist()
            if name.endswith("/platforms/mlp1/cores/build-report.json")
        ]
        if len(candidates) != 1:
            raise CacheError("reference ZIP must contain one MLP1 core build report")
        report_member = candidates[0]
        reference = json.loads(archive.read(report_member))
        reference_rows = report_rows(reference, expected)
        validate_report_context(args, reference, "published build report")
        core_prefix = report_member.rsplit("/", 1)[0]
        cache = empty_cache()
        for core in args.core:
            local_row = local_rows[core]
            reference_row = reference_rows[core]
            if local_row.get("sha256") != reference_row.get("sha256"):
                raise CacheError(f"{core}: local and published report checksums differ")
            core_file = local_row.get("core_file")
            member = f"{core_prefix}/{core_file}"
            if member not in archive.namelist():
                raise CacheError(f"{core}: published ZIP is missing {core_file}")
            if zip_member_sha256(archive, member) != local_row.get("sha256"):
                raise CacheError(f"{core}: published ZIP bytes do not match its report")
            entry = row_to_entry(args, core, entries[core], local_row)
            cache["entries"][core] = entry
            local_row.update(
                {
                    "source_url": entries[core]["url"],
                    "source_commit": entries[core]["commit"],
                    "input_fingerprint": entry["input_fingerprint"],
                    "build_action": "adopted",
                }
            )
    report["compiled_count"] = 0
    report["reused_count"] = len(expected)
    report["cache_version"] = CACHE_VERSION
    report["adopted_from"] = args.reference_zip.name
    atomic_json(args.cache, cache)
    atomic_json(args.report, report)
    print(f"adopted {len(expected)} checksum-matched cores from {args.reference_zip.name}")


def command_fingerprint(args: argparse.Namespace) -> None:
    entries = lock_entries(args)
    print(input_fingerprint(args, args.selected_core, entries[args.selected_core]))


def command_lock_value(args: argparse.Namespace) -> None:
    entries = lock_entries(args)
    print(entries[args.selected_core][args.field])


def add_common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--cores-dir", type=Path, required=True)
    parser.add_argument("--info-dir", type=Path, required=True)
    parser.add_argument("--patch-dir", type=Path, required=True)
    parser.add_argument("--libretro-super-url", required=True)
    parser.add_argument("--libretro-super-commit", required=True)
    parser.add_argument("--toolchain-id", required=True)
    parser.add_argument("--target-soc", required=True)
    parser.add_argument("--target-cpu", required=True)
    parser.add_argument("--build-profile", required=True)
    parser.add_argument("--cflags", required=True)
    parser.add_argument("--cxxflags", required=True)
    parser.add_argument("--ldflags", required=True)
    parser.add_argument("--core", action="append", required=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name, handler in (
        ("check", command_check),
        ("reuse", command_reuse),
        ("update", command_update),
        ("adopt", command_adopt),
        ("fingerprint", command_fingerprint),
        ("lock-value", command_lock_value),
    ):
        command = subparsers.add_parser(name)
        add_common(command)
        if name in {"reuse", "fingerprint", "lock-value"}:
            command.add_argument("--selected-core", required=True)
        if name == "lock-value":
            command.add_argument("--field", choices=("url", "commit", "checkout", "recipe"), required=True)
        if name == "update":
            command.add_argument("--report", type=Path, required=True)
        if name == "adopt":
            command.add_argument("--report", type=Path, required=True)
            command.add_argument("--reference-zip", type=Path, required=True)
            command.add_argument("--reference-sha256", required=True)
        command.set_defaults(handler=handler)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if len(args.libretro_super_commit) != 40 or any(
            ch not in "0123456789abcdef" for ch in args.libretro_super_commit
        ):
            raise CacheError("libretro-super commit must be a lowercase full SHA")
        args.handler(args)
    except CacheError as error:
        print(f"mlp1-core-cache: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
