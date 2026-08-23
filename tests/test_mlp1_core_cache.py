from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile


REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_TOOL = REPO_ROOT / "scripts" / "mlp1-core-cache.py"


class Mlp1CoreCacheTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir_context = tempfile.TemporaryDirectory()
        self.temp_dir = Path(self.temp_dir_context.name)
        self.cores_dir = self.temp_dir / "cores"
        self.info_dir = self.temp_dir / "info"
        self.patch_dir = self.temp_dir / "patches"
        self.cores_dir.mkdir()
        self.info_dir.mkdir()
        self.patch_dir.mkdir()
        self.lock_path = self.temp_dir / "lock.json"
        self.cache_path = self.temp_dir / "cache.json"
        self.report_path = self.temp_dir / "build-report.json"
        self.reference_zip = self.temp_dir / "beta.zip"
        self.cores = ("alpha", "beta")
        self.lock = {
            "version": 1,
            "platform": "mlp1",
            "cores": {
                core: {
                    "url": f"https://example.invalid/{core}.git",
                    "commit": character * 40,
                    "checkout": f"libretro-super/libretro-{core}",
                    "recipe": "generic-v1",
                }
                for core, character in zip(self.cores, ("a", "b"), strict=True)
            },
        }
        rows = []
        for core in self.cores:
            core_file = f"{core}_libretro.so"
            info_file = f"{core}_libretro.info"
            payload = f"{core}-core".encode()
            (self.cores_dir / core_file).write_bytes(payload)
            (self.info_dir / info_file).write_text(f"display_name = {core}\n", encoding="utf-8")
            rows.append(
                {
                    "core": core,
                    "status": "built",
                    "core_file": core_file,
                    "info_file": info_file,
                    "reason": "",
                    "machine": "AArch64",
                    "max_glibc": "2.38",
                    "tuning": "generic-aarch64",
                    "source_url": "",
                    "source_commit": "",
                    "build_lane": "generic-libretro-super",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "library_name": core.title(),
                }
            )
        self.report = {
            "version": 2,
            "platform": "mlp1",
            "target_soc": "rk3566",
            "target_cpu": "cortex-a55",
            "build_profile": "release",
            "cflags": "-O2 -mcpu=cortex-a55 -mtune=cortex-a55",
            "cxxflags": "-O2 -mcpu=cortex-a55 -mtune=cortex-a55",
            "ldflags": "-Wl,--gc-sections",
            "libretro_super_url": "https://example.invalid/libretro-super.git",
            "libretro_super_commit": "c" * 40,
            "status": "passed",
            "requested_count": 2,
            "built_count": 2,
            "failed_count": 0,
            "deferred_count": 0,
            "library_name_status": "complete",
            "library_name_count": 2,
            "cores": rows,
        }
        self.write_json(self.lock_path, self.lock)
        self.write_json(self.report_path, self.report)
        self.write_reference_zip(self.report)

    def tearDown(self) -> None:
        self.temp_dir_context.cleanup()

    @staticmethod
    def write_json(path: Path, value: dict) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")

    def write_reference_zip(self, report: dict) -> None:
        prefix = "leaf/.system/leaf/platforms/mlp1/cores"
        with zipfile.ZipFile(self.reference_zip, "w") as archive:
            archive.writestr(f"{prefix}/build-report.json", json.dumps(report))
            for row in report["cores"]:
                archive.write(
                    self.cores_dir / row["core_file"],
                    f"{prefix}/{row['core_file']}",
                )

    def common_args(self) -> list[str]:
        result = [
            "--lock", str(self.lock_path),
            "--cache", str(self.cache_path),
            "--cores-dir", str(self.cores_dir),
            "--info-dir", str(self.info_dir),
            "--patch-dir", str(self.patch_dir),
            "--libretro-super-url", "https://example.invalid/libretro-super.git",
            "--libretro-super-commit", "c" * 40,
            "--toolchain-id", "sha256:toolchain",
            "--target-soc", "rk3566",
            "--target-cpu", "cortex-a55",
            "--build-profile", "release",
            "--cflags=-O2 -mcpu=cortex-a55 -mtune=cortex-a55",
            "--cxxflags=-O2 -mcpu=cortex-a55 -mtune=cortex-a55",
            "--ldflags=-Wl,--gc-sections",
        ]
        for core in self.cores:
            result.extend(("--core", core))
        return result

    def run_tool(self, command: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CACHE_TOOL), command, *self.common_args(), *extra],
            check=False,
            capture_output=True,
            text=True,
        )

    def adopt(self) -> subprocess.CompletedProcess[str]:
        digest = hashlib.sha256(self.reference_zip.read_bytes()).hexdigest()
        return self.run_tool(
            "adopt",
            "--report", str(self.report_path),
            "--reference-zip", str(self.reference_zip),
            "--reference-sha256", digest,
        )

    def test_adopt_then_check_reuses_all_checksum_bound_outputs(self) -> None:
        adopted = self.adopt()
        self.assertEqual(adopted.returncode, 0, adopted.stderr)
        checked = self.run_tool("check")
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("cache: 2 reused / 0 misses", checked.stdout)
        report = json.loads(self.report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["compiled_count"], 0)
        self.assertEqual(report["reused_count"], 2)
        self.assertEqual(
            {row["build_action"] for row in report["cores"]}, {"adopted"}
        )

    def test_recipe_change_misses_only_the_changed_core(self) -> None:
        self.assertEqual(self.adopt().returncode, 0)
        self.lock["cores"]["beta"]["recipe"] = "dedicated-a55-v1"
        self.write_json(self.lock_path, self.lock)
        checked = self.run_tool("check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("hit\talpha\t", checked.stdout)
        self.assertIn("miss\tbeta\tinput fingerprint changed", checked.stdout)
        self.assertIn("cache: 1 reused / 1 misses", checked.stdout)

    def test_changed_binary_is_a_cache_miss(self) -> None:
        self.assertEqual(self.adopt().returncode, 0)
        (self.cores_dir / "alpha_libretro.so").write_bytes(b"tampered")
        checked = self.run_tool("check")
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("miss\talpha\tcore checksum changed", checked.stdout)

    def test_adoption_rejects_wrong_published_digest(self) -> None:
        adopted = self.run_tool(
            "adopt",
            "--report", str(self.report_path),
            "--reference-zip", str(self.reference_zip),
            "--reference-sha256", "0" * 64,
        )
        self.assertNotEqual(adopted.returncode, 0)
        self.assertIn("published digest", adopted.stderr)
        self.assertFalse(self.cache_path.exists())

    def test_adoption_rejects_published_core_checksum_mismatch(self) -> None:
        changed = json.loads(json.dumps(self.report))
        changed["cores"][1]["sha256"] = "0" * 64
        self.write_reference_zip(changed)
        adopted = self.adopt()
        self.assertNotEqual(adopted.returncode, 0)
        self.assertIn("local and published report checksums differ", adopted.stderr)
        self.assertFalse(self.cache_path.exists())


if __name__ == "__main__":
    unittest.main()
