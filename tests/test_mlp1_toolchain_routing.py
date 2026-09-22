"""Exercise the real host dispatcher without compiling cores or touching Docker."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import test_mlp1_flycast_fast_umrk as fast_tests

ROOT = Path(__file__).resolve().parents[1]
PIN = fast_tests.manifest()["toolchain"]["image_ref"]
PIN_ID = fast_tests.manifest()["toolchain"]["image_id"]
GENERIC = "ghcr.io/utility-muffin-research-kitchen/mlp1-toolchain:local"

DOCKER = r"""
import json, os, pathlib, sys
a = sys.argv[1:]
log = pathlib.Path(os.environ["DOCKER_TEST_LOG"])
with log.open("a") as out:
    out.write(json.dumps(a) + "\n")
pin = os.environ["DOCKER_TEST_PIN"]
state = log.with_suffix(".pulled")
if a[:2] == ["image", "inspect"]:
    if a[-1] == pin and os.environ.get("DOCKER_TEST_MISSING") and not state.exists():
        sys.exit(1)
    if "--format" in a:
        print(os.environ.get("DOCKER_TEST_WRONG_ID", os.environ["DOCKER_TEST_ID"])
              if a[-1] == pin else "sha256:" + "a" * 64)
elif a[0] == "pull":
    assert a[1] == pin
    state.touch()
elif a[0] == "run":
    env = dict(a[i + 1].split("=", 1) for i, v in enumerate(a) if v == "-e")
    mounts = [a[i + 1] for i, v in enumerate(a) if v == "-v"]
    output = next(v.rsplit(":", 1)[0] for v in mounts if v.endswith(":/workspace/output/mlp1"))
    report = pathlib.Path(output) / env["REPORT_JSON_PATH"].removeprefix("/workspace/output/mlp1/")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"cores": [{"build_action": "compiled"}]}))
else:
    sys.exit("unexpected fake docker command")
"""


class HostRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        docker = self.root / "docker"
        docker.write_text("#!" + sys.executable + "\n" + DOCKER)
        docker.chmod(0o755)
        self.log = self.root / "docker.jsonl"
        self.env = dict(os.environ,
                        PATH=str(self.root) + os.pathsep + os.environ["PATH"],
                        DOCKER_TEST_LOG=str(self.log), DOCKER_TEST_PIN=PIN,
                        DOCKER_TEST_ID=PIN_ID, OUTPUT_DIR=str(self.root / "output"),
                        TOOLCHAIN_REPO=str(self.root), TOOLCHAIN_IMAGE=GENERIC)
        for key in ("IN_MLP1_CONTAINER", "REPORT_PATH", "REPORT_JSON_PATH",
                    "MLP1_FAST_BUILD_ACTION", "MLP1_FAST_REUSE", "MLP1_TOOLCHAIN_ID"):
            self.env.pop(key, None)

    def run_builder(self, *args, success=True, **env):
        result = subprocess.run([str(ROOT / "build-mlp1.sh"), *args], cwd=ROOT,
                                env=dict(self.env, **env), capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_bare_fast_ignores_generic_tag_and_spoofed_identity(self):
        calls = self.run_builder("flycast_fast_umrk", MLP1_TOOLCHAIN_ID="forged")
        runs = [c for c in calls if c[0] == "run"]
        self.assertEqual(len(runs), 1)
        self.assertIn(PIN, runs[0])
        self.assertIn("MLP1_TOOLCHAIN_ID=" + PIN_ID, runs[0])
        self.assertNotIn(GENERIC, runs[0])

    def test_generic_only_keeps_existing_toolchain(self):
        runs = [c for c in self.run_builder("genesis_plus_gx") if c[0] == "run"]
        self.assertEqual(len(runs), 1)
        self.assertIn(GENERIC, runs[0])
        self.assertNotIn(PIN, runs[0])

    def test_no_arguments_keeps_default_core(self):
        runs = [c for c in self.run_builder() if c[0] == "run"]
        self.assertEqual(len(runs), 1)
        self.assertIn(GENERIC, runs[0])

    def test_external_fast_action_does_not_skip_pinned_build(self):
        runs = [c for c in self.run_builder("flycast_fast_umrk", MLP1_FAST_BUILD_ACTION="reused") if c[0] == "run"]
        self.assertIn("MLP1_FAST_BUILD_ACTION=", runs[0])

    def test_report_cannot_escape_output_directory(self):
        calls = self.run_builder("genesis_plus_gx", success=False,
                                 REPORT_PATH=str(self.root / "output/../escaped.txt"))
        self.assertFalse(any(c[0] == "run" for c in calls))

    def test_mixed_and_stock_parity_dispatch_fast_before_generic(self):
        for args in (("flycast_fast_umrk", "genesis_plus_gx"), ("--stock-parity",)):
            with self.subTest(args=args):
                self.log.unlink(missing_ok=True)
                runs = [c for c in self.run_builder(*args) if c[0] == "run"]
                self.assertEqual(len(runs), 2)
                self.assertIn(PIN, runs[0])
                self.assertIn(GENERIC, runs[1])
                self.assertIn("MLP1_FAST_BUILD_ACTION=compiled", runs[1])
                self.assertIn("MLP1_FAST_REUSE=" + ("1" if args[0] == "--stock-parity" else "0"), runs[0])

    def test_missing_pinned_image_is_pulled_by_digest(self):
        calls = self.run_builder("flycast_fast_umrk", DOCKER_TEST_MISSING="1")
        self.assertIn(["pull", PIN], calls)

    def test_wrong_actual_image_is_rejected_before_run(self):
        calls = self.run_builder("flycast_fast_umrk", success=False,
                                 DOCKER_TEST_WRONG_ID="sha256:" + "b" * 64)
        self.assertFalse(any(c[0] == "run" for c in calls))

    def test_training_uses_same_image_and_separate_report(self):
        runs = [c for c in self.run_builder("--flycast-fast-umrk-profile-gen") if c[0] == "run"]
        self.assertEqual(len(runs), 1)
        self.assertIn(PIN, runs[0])
        self.assertEqual(runs[0][-1], "--flycast-fast-umrk-profile-gen")


class FastCacheIsolationTests(unittest.TestCase):
    setUp = fast_tests.CacheFingerprintTest.setUp
    copy = fast_tests.CacheFingerprintTest.copy
    fingerprint = fast_tests.CacheFingerprintTest.fingerprint
    def test_shared_builder_edit_leaves_fast_fingerprint_unchanged(self):
        before = self.fingerprint("flycast_fast_umrk")
        with (self.root / "build-mlp1.sh").open("a") as out:
            out.write("\n# Unrelated orchestration edit\n")
        self.assertEqual(before, self.fingerprint("flycast_fast_umrk"))

    def test_generic_toolchain_changes_only_generic_fingerprint(self):
        import importlib.util
        from argparse import Namespace
        spec = importlib.util.spec_from_file_location("cache", ROOT / "scripts/mlp1-core-cache.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        args = Namespace(patch_dir=self.root / "patches/mlp1",
                         profile_dir=self.root / "profiles/mlp1",
                         info_source_dir=self.root / "info/mlp1", recipe_root=self.root,
                         libretro_super_url="test", libretro_super_commit="test",
                         toolchain_id="old", target_soc="rk3566", target_cpu="cortex-a55",
                         build_profile="release", cflags="-O2", cxxflags="-O2", ldflags="")
        entries = json.loads((self.root / "config/mlp1-core-lock.json").read_text())["cores"]
        fast = module.input_fingerprint(args, "flycast_fast_umrk", entries["flycast_fast_umrk"])
        generic = module.input_fingerprint(args, "genesis_plus_gx", entries["genesis_plus_gx"])
        args.toolchain_id = "new"
        self.assertEqual(fast, module.input_fingerprint(args, "flycast_fast_umrk", entries["flycast_fast_umrk"]))
        self.assertNotEqual(generic, module.input_fingerprint(args, "genesis_plus_gx", entries["genesis_plus_gx"]))


if __name__ == "__main__":
    unittest.main()
