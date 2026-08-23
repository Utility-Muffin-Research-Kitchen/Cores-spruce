from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
REPORT_TOOL = REPO_ROOT / "scripts" / "mlp1-core-report.py"


class Mlp1CoreReportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir_context = tempfile.TemporaryDirectory()
        self.temp_dir = Path(self.temp_dir_context.name)
        self.cores_dir = self.temp_dir / "cores"
        self.cores_dir.mkdir()
        self.report_path = self.temp_dir / "build-report.json"

        self.core_data = {
            "fake08": ("fake08_libretro.so", b"fake08-core"),
            "mame": ("mame_libretro.so", b"mame-core"),
        }
        rows = []
        for core, (core_file, payload) in self.core_data.items():
            (self.cores_dir / core_file).write_bytes(payload)
            rows.append(
                {
                    "core": core,
                    "status": "built",
                    "core_file": core_file,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "library_name": "",
                }
            )
        self.report = {
            "version": 2,
            "platform": "mlp1",
            "status": "passed",
            "requested_count": 2,
            "built_count": 2,
            "failed_count": 0,
            "deferred_count": 0,
            "library_name_status": "pending",
            "library_name_count": 0,
            "cores": rows,
        }
        self.write_report(self.report)

    def tearDown(self) -> None:
        self.temp_dir_context.cleanup()

    def write_report(self, report: dict) -> None:
        self.report_path.write_text(json.dumps(report), encoding="utf-8")

    def run_tool(self, command: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(REPORT_TOOL),
                command,
                "--report",
                str(self.report_path),
                "--cores-dir",
                str(self.cores_dir),
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def assert_all_commands_reject(self, message: str) -> None:
        results_path = self.temp_dir / "unused-results.tsv"
        for command in ("manifest", "verify", "apply"):
            with self.subTest(command=command):
                extra = (
                    ("--results", str(results_path))
                    if command == "apply"
                    else ()
                )
                result = self.run_tool(command, *extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def add_unbuilt_row(self, status: str) -> None:
        self.report["cores"].append(
            {
                "core": f"{status}-core",
                "status": status,
                "core_file": "",
                "sha256": "",
                "library_name": "",
            }
        )
        self.report[f"{status}_count"] = 1
        self.report["status"] = "failed"
        if status == "failed":
            self.report["requested_count"] += 1
        self.write_report(self.report)

    def test_manifest_accepts_targeted_all_built_pending_report(self) -> None:
        result = self.run_tool("manifest")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = [line.split("\t") for line in result.stdout.splitlines()]
        self.assertEqual([row[0] for row in rows], ["fake08", "mame"])
        self.assertEqual(rows[0][1], "fake08_libretro.so")
        self.assertEqual(rows[0][2], self.report["cores"][0]["sha256"])

    def test_manifest_verify_and_apply_reject_failed_report(self) -> None:
        self.add_unbuilt_row("failed")
        self.assert_all_commands_reject("build report is not probeable")

    def test_manifest_verify_and_apply_reject_deferred_report(self) -> None:
        self.add_unbuilt_row("deferred")
        self.assert_all_commands_reject("build report is not probeable")

    def test_all_commands_reject_inconsistent_summary_counts(self) -> None:
        cases = (
            ("built_count", 1, "built_count must be 2"),
            ("failed_count", 1, "failed_count must be 0"),
            ("deferred_count", 1, "deferred_count must be 0"),
            ("requested_count", 1, "requested_count must be 2"),
        )
        original = copy.deepcopy(self.report)
        for field, value, message in cases:
            with self.subTest(field=field):
                self.report = copy.deepcopy(original)
                self.report[field] = value
                self.write_report(self.report)
                self.assert_all_commands_reject(message)

    def test_all_commands_reject_status_inconsistent_with_rows(self) -> None:
        self.report["status"] = "failed"
        self.write_report(self.report)
        self.assert_all_commands_reject("status must be 'passed'")

    def test_all_commands_reject_unknown_row_status(self) -> None:
        self.report["cores"][0]["status"] = "skipped"
        self.write_report(self.report)
        self.assert_all_commands_reject("row status must be one of")

    def test_all_commands_reject_duplicate_core_ids_across_statuses(self) -> None:
        self.add_unbuilt_row("deferred")
        self.report["cores"][-1]["core"] = "fake08"
        self.write_report(self.report)
        self.assert_all_commands_reject("duplicate core id: fake08")

    def test_pending_report_rejects_stale_library_name(self) -> None:
        self.report["cores"][0]["library_name"] = "fake-08"
        self.write_report(self.report)
        self.assert_all_commands_reject(
            "pending report must have an empty library_name"
        )

    def test_incremental_summary_accepts_checksum_bound_actions(self) -> None:
        self.report.update(
            {"cache_version": 1, "compiled_count": 1, "reused_count": 1}
        )
        for row, action in zip(
            self.report["cores"], ("compiled", "reused"), strict=True
        ):
            row["build_action"] = action
            row["input_fingerprint"] = "a" * 64
        self.write_report(self.report)
        result = self.run_tool("manifest")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incremental_summary_rejects_action_count_mismatch(self) -> None:
        self.report.update(
            {"cache_version": 1, "compiled_count": 0, "reused_count": 2}
        )
        for row in self.report["cores"]:
            row["build_action"] = "compiled"
            row["input_fingerprint"] = "a" * 64
        self.write_report(self.report)
        self.assert_all_commands_reject(
            "compiled_count does not match core build_action rows"
        )

    def test_complete_report_rejects_inconsistent_library_name_count(self) -> None:
        self.report["library_name_status"] = "complete"
        self.report["library_name_count"] = 1
        self.report["cores"][0]["library_name"] = "fake-08"
        self.report["cores"][1]["library_name"] = "MAME"
        self.write_report(self.report)
        self.assert_all_commands_reject("library_name_count must be 2")

    def test_apply_updates_all_rows_atomically(self) -> None:
        results = self.temp_dir / "results.tsv"
        results.write_text(
            "fake08\tfake08_libretro.so\t"
            + self.report["cores"][0]["sha256"]
            + "\tfake-08\n"
            + "mame\tmame_libretro.so\t"
            + self.report["cores"][1]["sha256"]
            + "\tMAME 2010 & Friends\n",
            encoding="utf-8",
        )

        result = self.run_tool("apply", "--results", str(results))
        self.assertEqual(result.returncode, 0, result.stderr)
        updated = json.loads(self.report_path.read_text(encoding="utf-8"))
        self.assertEqual(updated["library_name_status"], "complete")
        self.assertEqual(updated["library_name_count"], 2)
        self.assertEqual(updated["cores"][0]["library_name"], "fake-08")
        self.assertEqual(
            updated["cores"][1]["library_name"], "MAME 2010 & Friends"
        )
        verified = self.run_tool("verify")
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertIn("complete: 2 checksum-bound", verified.stdout)

    def test_verify_rejects_pending_report(self) -> None:
        result = self.run_tool("verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("library_name_status must be 'complete'", result.stderr)

    def test_partial_results_do_not_modify_report(self) -> None:
        original = self.report_path.read_bytes()
        results = self.temp_dir / "results.tsv"
        results.write_text(
            "fake08\tfake08_libretro.so\t"
            + self.report["cores"][0]["sha256"]
            + "\tfake-08\n",
            encoding="utf-8",
        )

        result = self.run_tool("apply", "--results", str(results))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing=mame", result.stderr)
        self.assertEqual(self.report_path.read_bytes(), original)

    def test_manifest_rejects_changed_core_bytes(self) -> None:
        (self.cores_dir / "mame_libretro.so").write_bytes(b"replacement")
        result = self.run_tool("manifest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum mismatch", result.stderr)

    def test_version_one_report_is_rejected(self) -> None:
        self.report["version"] = 1
        self.write_report(self.report)
        result = self.run_tool("manifest")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("report version must be 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
