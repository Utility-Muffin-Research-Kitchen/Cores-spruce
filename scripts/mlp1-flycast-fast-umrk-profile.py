#!/usr/bin/env python3
"""Validate, freeze and extract the MLP1 PGO profile dataset for flycast_fast_umrk.

The dataset is a flat gzip/tar archive of GCC ``.gcda`` files plus the manifest
in this directory. The manifest binds the profile data to the source commit,
managed patch, recipe flags, canonical container paths, toolchain image and
training record, so a stale or foreign dataset cannot be used silently.
"""

from __future__ import annotations

import argparse
import fnmatch
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from datetime import datetime, timezone


PROFILE_DIR_NAME = "flycast_fast_umrk"
MANIFEST_NAME = "manifest.json"
REPO_ROOT = Path(__file__).resolve().parents[1]
RECIPE_INPUT_FILES = ("scripts/mlp1-flycast-fast-umrk-recipe.sh",)


class ProfileError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ProfileError(f"cannot read {label} {path}: {error}") from error
    if not isinstance(value, dict):
        raise ProfileError(f"{label} root must be an object")
    return value


def require_str(mapping: dict, field: str, label: str) -> str:
    value = mapping.get(field)
    if not isinstance(value, str) or not value:
        raise ProfileError(f"{label}.{field} must be a non-empty string")
    return value


def require_int(mapping: dict, field: str, label: str) -> int:
    value = mapping.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProfileError(f"{label}.{field} must be a non-negative integer")
    return value


def manifest_path(profile_dir: Path) -> Path:
    if profile_dir.name == MANIFEST_NAME:
        return profile_dir
    return profile_dir / MANIFEST_NAME


def load_manifest(profile_dir: Path) -> tuple[dict, Path]:
    path = manifest_path(profile_dir)
    if not path.is_file():
        raise ProfileError(
            f"missing profile manifest {path}; the frozen PGO contract has not been created"
        )
    manifest = load_json(path, "profile manifest")
    if manifest.get("version") != 1:
        raise ProfileError("profile manifest must be version 1")
    if manifest.get("core") != PROFILE_DIR_NAME:
        raise ProfileError(f"profile manifest core must be {PROFILE_DIR_NAME}")
    require_str(manifest, "recipe", "manifest")
    require_str(manifest, "status", "manifest")
    if manifest["status"] not in ("pending-training", "frozen"):
        raise ProfileError("profile manifest status must be pending-training or frozen")
    return manifest, path


def archive_path(manifest: dict, manifest_file: Path) -> Path:
    archive = manifest.get("archive")
    if not isinstance(archive, dict):
        raise ProfileError("manifest.archive must be an object")
    relative = require_str(archive, "path", "manifest.archive")
    resolved = (manifest_file.parent / relative).resolve()
    if manifest_file.parent.resolve() not in resolved.parents:
        raise ProfileError("manifest.archive.path must stay inside the profile directory")
    return resolved


def lock_entry(lock: dict, core: str) -> dict:
    if lock.get("version") != 1 or lock.get("platform") != "mlp1":
        raise ProfileError("core lock must be version 1 for platform mlp1")
    entries = lock.get("cores")
    if not isinstance(entries, dict) or not isinstance(entries.get(core), dict):
        raise ProfileError(f"core lock has no {core} entry")
    return entries[core]


def verify_contract(
    manifest: dict,
    *,
    lock_path: Path,
    patch_path: Path,
    toolchain_id: str,
    canonical_source_dir: str = "",
    canonical_profile_dir: str = "",
    source_dir: Path | None = None,
) -> list[str]:
    """Return the contract mismatches between the manifest and the current inputs."""
    mismatches: list[str] = []
    entry = lock_entry(load_json(lock_path, "core lock"), PROFILE_DIR_NAME)

    source = manifest.get("source")
    if not isinstance(source, dict):
        raise ProfileError("manifest.source must be an object")
    if source.get("commit") != entry.get("commit"):
        mismatches.append(
            f"source commit: manifest {source.get('commit')} != lock {entry.get('commit')}"
        )
    if source.get("url") != entry.get("url"):
        mismatches.append("source url differs from the core lock")
    recorded_tree = source.get("patched_tree_sha256")
    require_sha256(
        recorded_tree if isinstance(recorded_tree, str) else "",
        "manifest.source.patched_tree_sha256",
    )
    if source_dir is not None:
        actual_tree = patched_tree_identity(source_dir)
        if actual_tree != recorded_tree:
            mismatches.append(
                f"patched source identity: manifest {recorded_tree} != tree {actual_tree}"
            )
    if manifest.get("recipe") != entry.get("recipe"):
        mismatches.append("recipe identity differs from the core lock")

    recipe_input = manifest.get("recipe_input")
    if not isinstance(recipe_input, dict):
        raise ProfileError("manifest.recipe_input must be an object")
    require_str(recipe_input, "file", "manifest.recipe_input")
    require_str(recipe_input, "function", "manifest.recipe_input")
    require_str(recipe_input, "sha256", "manifest.recipe_input")
    actual_recipe = recipe_input_digest(REPO_ROOT)
    if actual_recipe != recipe_input["sha256"]:
        mismatches.append(
            "managed recipe input hash: manifest "
            f"{recipe_input['sha256']} != dedicated recipe {actual_recipe}"
        )

    patch = manifest.get("patch")
    if not isinstance(patch, dict):
        raise ProfileError("manifest.patch must be an object")
    require_str(patch, "path", "manifest.patch")
    if not patch_path.is_file():
        mismatches.append(f"managed patch is missing: {patch_path}")
    elif sha256_file(patch_path) != patch.get("sha256"):
        mismatches.append("managed patch hash differs from the manifest")

    toolchain = manifest.get("toolchain")
    if not isinstance(toolchain, dict):
        raise ProfileError("manifest.toolchain must be an object")
    require_str(toolchain, "image", "manifest.toolchain")
    require_str(toolchain, "image_id", "manifest.toolchain")
    require_str(toolchain, "compiler", "manifest.toolchain")
    if toolchain_id and toolchain["image_id"] != toolchain_id:
        mismatches.append(
            f"toolchain image: manifest {toolchain['image_id']} != current {toolchain_id}"
        )

    canonical = manifest.get("canonical")
    if not isinstance(canonical, dict):
        raise ProfileError("manifest.canonical must be an object")
    require_str(canonical, "source_dir", "manifest.canonical")
    require_str(canonical, "profile_dir", "manifest.canonical")
    if canonical.get("profile_layout") != "flat":
        mismatches.append("the profile contract must use a flat .gcda layout")
    if canonical_source_dir and canonical["source_dir"] != canonical_source_dir:
        mismatches.append(
            "canonical source path: manifest "
            f"{canonical['source_dir']} != build {canonical_source_dir}"
        )
    if canonical_profile_dir and canonical["profile_dir"] != canonical_profile_dir:
        mismatches.append(
            "canonical profile path: manifest "
            f"{canonical['profile_dir']} != build {canonical_profile_dir}"
        )
    return mismatches


def requirements(manifest: dict) -> dict:
    value = manifest.get("requirements")
    if not isinstance(value, dict):
        raise ProfileError("manifest.requirements must be an object")
    require_int(value, "min_gcda_files", "manifest.requirements")
    require_int(value, "min_renderer_profiles", "manifest.requirements")
    require_str(value, "renderer_profile_glob", "manifest.requirements")
    suffixes = value.get("forbidden_member_suffixes")
    if not isinstance(suffixes, list) or not all(
        isinstance(item, str) for item in suffixes
    ):
        raise ProfileError("manifest.requirements.forbidden_member_suffixes must be strings")
    return value


def verify_member_name(name: str, manifest: dict) -> None:
    rules = requirements(manifest)
    if name.startswith("/") or name.startswith("../") or "/" in name.rstrip("/"):
        raise ProfileError(f"profile archive member must be a flat basename: {name}")
    if not name.endswith(".gcda"):
        raise ProfileError(f"profile archive member must be a .gcda file: {name}")
    lowered = name.lower()
    for suffix in rules["forbidden_member_suffixes"]:
        if lowered.endswith(str(suffix).lower()):
            raise ProfileError(f"profile archive member {name} matches forbidden {suffix}")


def settings_contract(manifest: dict) -> dict[str, str]:
    settings = manifest.get("settings")
    if not isinstance(settings, dict) or not settings:
        raise ProfileError("manifest.settings must list the requested reicast_* values")
    for key, value in settings.items():
        if not isinstance(key, str) or not key.startswith("reicast_"):
            raise ProfileError(f"manifest.settings key must be a reicast_* name: {key!r}")
        if not isinstance(value, str) or not value:
            raise ProfileError(f"manifest.settings.{key} must be a non-empty string")
    return settings


def training_contract(manifest: dict) -> dict:
    contract = manifest.get("training_contract")
    if not isinstance(contract, dict):
        raise ProfileError("manifest.training_contract must be an object")
    games = contract.get("games")
    if not isinstance(games, list) or not games or not all(
        isinstance(game, str) and game for game in games
    ):
        raise ProfileError("manifest.training_contract.games must be a non-empty list")
    seconds = contract.get("seconds_per_game")
    if isinstance(seconds, bool) or not isinstance(seconds, int) or seconds <= 0:
        raise ProfileError("manifest.training_contract.seconds_per_game must be positive")
    return contract


def parse_options_file(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise ProfileError(f"options template is missing: {path}")
    parsed: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith(";") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"')
        parsed[key] = value
    return parsed


def verify_options_file(manifest: dict, path: Path) -> dict[str, str]:
    """Bind the training record to the exact requested option template."""
    expected = settings_contract(manifest)
    parsed = parse_options_file(path)
    missing = sorted(key for key in expected if key not in parsed)
    if missing:
        raise ProfileError(f"options template is missing requested settings: {missing}")
    wrong = sorted(
        key for key, value in expected.items() if parsed.get(key) != value
    )
    if wrong:
        raise ProfileError(f"options template has unexpected values for: {wrong}")
    extra = sorted(
        key
        for key in parsed
        if key.startswith("reicast_") and key not in expected
    )
    if extra:
        raise ProfileError(f"options template has settings outside the contract: {extra}")
    return parsed


def require_sha256(value: str, label: str) -> str:
    if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise ProfileError(f"{label} must be a lowercase 64-character sha256")
    return value


def git(source_dir: Path, *args: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            ["git", "-C", str(source_dir), *args],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ProfileError(f"cannot run git in {source_dir}: {error}") from error


def patched_tree_identity(source_dir: Path) -> str:
    """Deterministic identity of the clean checkout with the managed patch applied.

    The identity is the hash of the full-index binary diff of the tracked tree,
    so it depends only on the pinned commit plus the applied patch. Untracked
    non-ignored files (which an apply that added files would leave behind) and
    build output that git ignores do not enter the hash, but untracked files are
    rejected outright so the contract cannot silently drift.
    """
    if not (source_dir / ".git").exists():
        raise ProfileError(f"patched source checkout is not a git tree: {source_dir}")
    status = git(source_dir, "status", "--porcelain")
    if status.returncode != 0:
        raise ProfileError(f"cannot read the source status in {source_dir}: {status.stderr.strip()}")
    untracked = [line for line in status.stdout.splitlines() if line.startswith("??")]
    if untracked:
        raise ProfileError(
            f"patched source tree has untracked files: {', '.join(untracked[:5])}"
        )
    diff = git(source_dir, "diff", "--full-index", "--binary", "--no-color", "--no-ext-diff")
    if diff.returncode != 0:
        raise ProfileError(f"cannot diff the patched source in {source_dir}: {diff.stderr.strip()}")
    return hashlib.sha256(diff.stdout.encode("utf-8")).hexdigest()


def recipe_input_digest(repo_root: Path) -> str:
    """Hash the repository-owned build recipe source that drives both phases."""
    digest = hashlib.sha256()
    for relative in RECIPE_INPUT_FILES:
        path = repo_root / relative
        if not path.is_file():
            raise ProfileError(f"managed recipe input is missing: {path}")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def parse_game_hashes(values: list[str], label: str, games: list[str]) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for item in values:
        game, separator, digest = item.partition("=")
        if not separator or not game:
            raise ProfileError(f"{label} must be given as game=sha256, got {item!r}")
        parsed[game] = require_sha256(digest, f"{label}[{game}]")
    if sorted(parsed) != sorted(games):
        raise ProfileError(
            f"{label} covers {sorted(parsed)} instead of the training games {sorted(games)}"
        )
    return parsed


def training_record(manifest: dict) -> dict:
    """Validate the frozen training provenance bound into the manifest."""
    training = manifest.get("training")
    if not isinstance(training, dict):
        raise ProfileError("manifest.training must be an object")
    contract = training_contract(manifest)
    games = contract["games"]
    recorded_games = training.get("games")
    if not isinstance(recorded_games, list) or sorted(recorded_games) != sorted(games):
        raise ProfileError(f"manifest.training.games must be {games}")
    if training.get("seconds_per_game") != contract["seconds_per_game"]:
        raise ProfileError("manifest.training.seconds_per_game does not match the contract")
    if training.get("successful_exits") != len(games):
        raise ProfileError("manifest.training.successful_exits must equal the training game count")
    for field in ("options_sha256", "generation_core_sha256"):
        value = training.get(field)
        require_sha256(value if isinstance(value, str) else "", f"manifest.training.{field}")
    for field in ("device", "completed_utc", "qualification", "options_file"):
        value = training.get(field)
        if not isinstance(value, str) or not value.strip():
            raise ProfileError(f"manifest.training.{field} must not be empty")
    for label in ("state_sha256", "input_sha256"):
        recorded = training.get(label)
        if not isinstance(recorded, dict) or sorted(recorded) != sorted(games):
            raise ProfileError(f"manifest.training.{label} must cover exactly {sorted(games)}")
        for game, digest in recorded.items():
            require_sha256(
                digest if isinstance(digest, str) else "",
                f"manifest.training.{label}[{game}]",
            )
    return training


def read_archive(path: Path) -> dict[str, bytes]:
    if not path.is_file():
        raise ProfileError(f"profile archive is missing: {path}")
    try:
        with tarfile.open(path, "r:gz") as archive:
            members: dict[str, bytes] = {}
            for member in archive.getmembers():
                if not member.isfile():
                    raise ProfileError(
                        f"profile archive contains a non-file member: {member.name}"
                    )
                if member.name in members:
                    raise ProfileError(f"profile archive repeats member: {member.name}")
                stream = archive.extractfile(member)
                if stream is None:
                    raise ProfileError(f"profile archive member is unreadable: {member.name}")
                members[member.name] = stream.read()
    except (tarfile.TarError, OSError, EOFError) as error:
        raise ProfileError(f"cannot read profile archive {path}: {error}") from error
    return members


def verify_archive(manifest: dict, manifest_file: Path) -> tuple[Path, dict[str, bytes]]:
    archive = manifest.get("archive")
    if not isinstance(archive, dict):
        raise ProfileError("manifest.archive must be an object")
    recorded = archive.get("sha256")
    if not isinstance(recorded, str) or len(recorded) != 64:
        raise ProfileError("profile archive has no recorded sha256; run the freeze command")
    files = archive.get("files")
    if not isinstance(files, dict):
        raise ProfileError("manifest.archive.files must be an object")

    path = archive_path(manifest, manifest_file)
    if sha256_file(path) != archive["sha256"]:
        raise ProfileError(f"profile archive checksum does not match the manifest: {path}")

    members = read_archive(path)
    if set(members) != set(files):
        missing = sorted(set(files) - set(members))
        extra = sorted(set(members) - set(files))
        raise ProfileError(
            "profile archive member list differs from the manifest: "
            f"missing={missing} extra={extra}"
        )

    for name, payload in members.items():
        verify_member_name(name, manifest)
        if not payload:
            raise ProfileError(f"profile archive member is empty: {name}")
        if hashlib.sha256(payload).hexdigest() != files[name]:
            raise ProfileError(f"profile archive member checksum does not match: {name}")

    rules = requirements(manifest)
    if require_int(archive, "file_count", "manifest.archive") != len(members):
        raise ProfileError("manifest.archive.file_count does not match the archive")
    if len(members) < rules["min_gcda_files"]:
        raise ProfileError(
            f"profile archive holds {len(members)} .gcda files, below the "
            f"required {rules['min_gcda_files']}"
        )
    renderer = [
        name for name in members if fnmatch.fnmatch(name, rules["renderer_profile_glob"])
    ]
    if len(renderer) < rules["min_renderer_profiles"]:
        raise ProfileError(
            f"profile archive holds {len(renderer)} renderer profiles, below the "
            f"required {rules['min_renderer_profiles']}"
        )
    return path, members


def contract_mismatches(args: argparse.Namespace, manifest: dict) -> list[str]:
    return verify_contract(
        manifest,
        lock_path=args.lock,
        patch_path=args.patch,
        toolchain_id=args.toolchain_id,
        canonical_source_dir=args.canonical_source_dir,
        canonical_profile_dir=args.canonical_profile_dir,
        source_dir=Path(args.source_dir) if args.source_dir else None,
    )


def frozen_manifest(
    args: argparse.Namespace,
) -> tuple[dict, Path]:
    manifest, manifest_file = load_manifest(args.profile_dir)
    mismatches = contract_mismatches(args, manifest)
    if mismatches:
        raise ProfileError("profile contract is stale: " + "; ".join(mismatches))
    if manifest["status"] != "frozen":
        raise ProfileError(
            "profile dataset is not frozen (status "
            f"{manifest['status']}); build the generation core with "
            "build-mlp1.sh --flycast-fast-umrk-profile-gen, train on the device and run "
            "the freeze command before building this core"
        )
    training_record(manifest)
    return manifest, manifest_file


def command_check(args: argparse.Namespace) -> None:
    """Contract-only check, used before a maintainer generation (training) build."""
    manifest, _ = load_manifest(args.profile_dir)
    mismatches = contract_mismatches(args, manifest)
    if mismatches:
        raise ProfileError("profile contract is stale: " + "; ".join(mismatches))
    settings_contract(manifest)
    training_contract(manifest)
    print(
        f"profile contract ok: status {manifest['status']}, "
        f"toolchain {manifest['toolchain']['image_id']}"
    )


def command_validate(args: argparse.Namespace) -> None:
    manifest, manifest_file = frozen_manifest(args)
    path, members = verify_archive(manifest, manifest_file)
    renderer = [
        name
        for name in members
        if fnmatch.fnmatch(name, requirements(manifest)["renderer_profile_glob"])
    ]
    print(
        f"profile ok: {len(members)} .gcda files, {len(renderer)} renderer profiles, "
        f"{path.name} {manifest['archive']['sha256']}"
    )


def command_extract(args: argparse.Namespace) -> None:
    manifest, manifest_file = frozen_manifest(args)
    _, members = verify_archive(manifest, manifest_file)

    dest = args.dest
    if dest.exists() and any(dest.iterdir()):
        raise ProfileError(f"profile destination is not empty: {dest}")
    dest.mkdir(parents=True, exist_ok=True)
    for name, payload in sorted(members.items()):
        with tempfile.NamedTemporaryFile(
            dir=dest, prefix=f".{name}.", delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, dest / name)
    print(f"profile extracted: {len(members)} .gcda files to {dest}")


def collect_gcda(raw_dir: Path) -> dict[str, Path]:
    if not raw_dir.is_dir():
        raise ProfileError(f"generation profile source is not a directory: {raw_dir}")
    collected: dict[str, Path] = {}
    for path in sorted(raw_dir.rglob("*.gcda")):
        if not path.is_file():
            continue
        name = path.name
        existing = collected.get(name)
        if existing is not None and existing.read_bytes() != path.read_bytes():
            raise ProfileError(f"generation profiles collide on basename {name}")
        collected[name] = path
    return collected


def write_archive(path: Path, members: dict[str, Path]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as raw:
        temporary = Path(raw.name)
    try:
        with temporary.open("wb") as file_stream:
            with gzip.GzipFile(fileobj=file_stream, mode="wb", mtime=0) as gzip_stream:
                with tarfile.open(fileobj=gzip_stream, mode="w") as archive:
                    for name in sorted(members):
                        payload = members[name].read_bytes()
                        info = tarfile.TarInfo(name)
                        info.size = len(payload)
                        info.mtime = 0
                        info.mode = 0o644
                        info.uid = 0
                        info.gid = 0
                        info.uname = ""
                        info.gname = ""
                        archive.addfile(info, io.BytesIO(payload))
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def command_freeze(args: argparse.Namespace) -> None:
    manifest, manifest_file = load_manifest(args.profile_dir)
    if not args.source_dir:
        raise ProfileError(
            "--source-dir is required to freeze: the dataset must bind the patched source identity"
        )
    mismatches = contract_mismatches(args, manifest)
    if mismatches:
        raise ProfileError(
            "profile contract is stale, refusing to freeze: " + "; ".join(mismatches)
        )
    if args.compiler:
        manifest["toolchain"]["compiler"] = args.compiler

    # The training record has to match the production contract exactly, so a
    # short or single-game run cannot be frozen as the shipped dataset.
    contract = training_contract(manifest)
    if sorted(args.game) != sorted(contract["games"]):
        raise ProfileError(
            "training games "
            f"{sorted(args.game)} do not match the contract {sorted(contract['games'])}"
        )
    if args.seconds_per_game != contract["seconds_per_game"]:
        raise ProfileError(
            f"training duration {args.seconds_per_game}s does not match the contract "
            f"{contract['seconds_per_game']}s"
        )
    require_sha256(args.generation_core_sha256, "generation core hash")
    if not args.device.strip():
        raise ProfileError("the training device serial must not be empty")
    if not args.qualification.strip():
        raise ProfileError("a qualification record is required to freeze the dataset")
    state_hashes = parse_game_hashes(args.state, "state hashes", contract["games"])
    input_hashes = parse_game_hashes(args.input, "input hashes", contract["games"])
    completed_utc = args.completed_utc.strip() or datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    if not completed_utc.endswith("Z") or "T" not in completed_utc:
        raise ProfileError(f"completion timestamp must be ISO-8601 UTC: {completed_utc}")
    options = verify_options_file(manifest, args.options_file)

    members = collect_gcda(args.gcda_dir)
    rules = requirements(manifest)
    renderer = [
        name for name in members if fnmatch.fnmatch(name, rules["renderer_profile_glob"])
    ]
    if len(members) < rules["min_gcda_files"]:
        raise ProfileError(
            f"generation profiles hold {len(members)} .gcda files, below the "
            f"required {rules['min_gcda_files']}"
        )
    if len(renderer) < rules["min_renderer_profiles"]:
        raise ProfileError(
            f"generation profiles hold {len(renderer)} renderer profiles, below the "
            f"required {rules['min_renderer_profiles']}"
        )
    for name in members:
        verify_member_name(name, manifest)

    archive = archive_path(manifest, manifest_file)
    write_archive(archive, members)
    manifest["archive"] = {
        "path": manifest["archive"]["path"],
        "format": "tar.gz-flat-gcda",
        "sha256": sha256_file(archive),
        "file_count": len(members),
        "files": {
            name: hashlib.sha256(members[name].read_bytes()).hexdigest()
            for name in sorted(members)
        },
    }
    manifest["training"] = {
        "games": list(args.game),
        "seconds_per_game": args.seconds_per_game,
        "successful_exits": len(args.game),
        "options_file": args.options_file.name,
        "options_count": len(options),
        "options_sha256": sha256_file(args.options_file),
        "generation_core_sha256": args.generation_core_sha256,
        "state_sha256": state_hashes,
        "input_sha256": input_hashes,
        "device": args.device,
        "completed_utc": completed_utc,
        "qualification": args.qualification,
    }
    manifest["status"] = "frozen"
    manifest_file.write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )
    verify_archive(*load_manifest(args.profile_dir))
    print(
        f"profile frozen: {len(members)} .gcda files, {len(renderer)} renderer profiles, "
        f"{archive.name} {manifest['archive']['sha256']}"
    )


def add_contract_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--profile-dir", type=Path, required=True)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--toolchain-id", default="")
    parser.add_argument("--canonical-source-dir", default="")
    parser.add_argument("--canonical-profile-dir", default="")
    parser.add_argument("--source-dir", default="")


def command_toolchain(args: argparse.Namespace) -> None:
    """Resolve the qualified image without depending on any local Docker tag."""
    manifest = load_json(args.profile_dir / MANIFEST_NAME, "profile manifest")
    toolchain = manifest["toolchain"]
    image_ref = require_str(toolchain, "image_ref", "manifest.toolchain")
    digest = image_ref.rsplit("@sha256:", 1)
    if len(digest) != 2 or not digest[0]:
        raise ProfileError("toolchain.image_ref must be an immutable repository@sha256 reference")
    require_sha256(digest[1], "toolchain.image_ref digest")
    image_id = require_str(toolchain, "image_id", "manifest.toolchain")
    if not image_id.startswith("sha256:"):
        raise ProfileError("toolchain.image_id must start with sha256:")
    require_sha256(image_id.removeprefix("sha256:"), "toolchain.image_id")
    print(f"{image_ref}\t{image_id}")


def command_tree_identity(args: argparse.Namespace) -> None:
    print(patched_tree_identity(Path(args.source_dir)))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    toolchain = subparsers.add_parser("toolchain")
    toolchain.add_argument("--profile-dir", type=Path, required=True)
    toolchain.set_defaults(handler=command_toolchain)

    validate = subparsers.add_parser("validate")
    add_contract_args(validate)
    validate.set_defaults(handler=command_validate)

    check = subparsers.add_parser("check")
    add_contract_args(check)
    check.set_defaults(handler=command_check)

    tree = subparsers.add_parser("tree-identity")
    tree.add_argument("--source-dir", required=True)
    tree.set_defaults(handler=command_tree_identity)

    extract = subparsers.add_parser("extract")
    add_contract_args(extract)
    extract.add_argument("--dest", type=Path, required=True)
    extract.set_defaults(handler=command_extract)

    freeze = subparsers.add_parser("freeze")
    add_contract_args(freeze)
    freeze.add_argument("--gcda-dir", type=Path, required=True)
    freeze.add_argument("--game", action="append", required=True)
    freeze.add_argument("--seconds-per-game", type=int, required=True)
    freeze.add_argument("--options-file", type=Path, required=True)
    freeze.add_argument("--generation-core-sha256", required=True)
    freeze.add_argument("--state", action="append", required=True)
    freeze.add_argument("--input", action="append", required=True)
    freeze.add_argument("--device", required=True)
    freeze.add_argument("--completed-utc", default="")
    freeze.add_argument("--qualification", default="")
    freeze.add_argument("--compiler", default="")
    freeze.set_defaults(handler=command_freeze)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        args.handler(args)
    except ProfileError as error:
        print(f"mlp1-flycast-fast-umrk-profile: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
