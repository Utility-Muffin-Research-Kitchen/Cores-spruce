"""Focused fixtures for the FlyCast Fast UMRK MLP1 lane."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_TOOL = REPO_ROOT / "scripts" / "mlp1-core-cache.py"
PROFILE_TOOL = REPO_ROOT / "scripts" / "mlp1-flycast-fast-umrk-profile.py"
BUILD_SCRIPT = REPO_ROOT / "build-mlp1.sh"
RECIPE_SCRIPT = REPO_ROOT / "scripts/mlp1-flycast-fast-umrk-recipe.sh"
LOCK_PATH = REPO_ROOT / "config" / "mlp1-core-lock.json"
PATCH_PATH = REPO_ROOT / "patches" / "mlp1" / "flycast_fast_umrk.patch"
INFO_PATH = REPO_ROOT / "info" / "mlp1" / "flycast_fast_umrk_libretro.info"
PROFILE_DIR = REPO_ROOT / "profiles" / "mlp1" / "flycast_fast_umrk"
MANIFEST_PATH = PROFILE_DIR / "manifest.json"

PINNED_COMMIT = "4c293f306bc16a265c2d768af5d0cea138426054"
TOOLCHAIN_IMAGE_ID = (
    "sha256:66aac16fb8b07e663c9b4d66970f272df195a6eba98dfad8286eabbaa617faf9"
)
UNRETRIEVABLE_IMAGE_ID = (
    "sha256:62a4bb50611693a33bda2c0ed9f0e98b9ccc03db75cc9e744774c7f3dea726b3"
)
CANONICAL_SOURCE_DIR = "/workspace/workdir/src/flycast-fast-umrk"
CANONICAL_PROFILE_DIR = "/workspace/workdir/pgo/flycast-fast-umrk"

VALID_EXTENSIONS = "chd|cdi|elf|cue|gdi|lst|bin|dat|zip|7z|m3u"

REQUESTED_SETTINGS = {
    "reicast_internal_resolution": "640x480",
    "reicast_threaded_rendering": "enabled",
    "reicast_synchronous_rendering": "disabled",
    "reicast_alpha_sorting": "per-strip (fast, least accurate)",
    "reicast_enable_dsp": "disabled",
    "reicast_anisotropic_filtering": "disabled",
    "reicast_pvr2_filtering": "disabled",
    "reicast_texupscale": "1",
    "reicast_render_to_texture_upscaling": "1x",
    "reicast_enable_rttb": "disabled",
    "reicast_delay_frame_swapping": "disabled",
    "reicast_frame_skipping": "disabled",
    "reicast_framerate": "fullspeed",
    "reicast_div_matching": "auto",
    "reicast_mipmapping": "enabled",
    "reicast_fog": "enabled",
    "reicast_volume_modifier_enable": "enabled",
    "reicast_gdrom_fast_loading": "enabled",
    "reicast_digital_triggers": "disabled",
    "reicast_cable_type": "TV (Composite)",
}

PATCHED_FILES = {
    "Makefile",
    "core/hw/arm7/arm7.cpp",
    "core/libretro-common/glsm/glsm.c",
    "core/libretro/libretro.cpp",
    "core/libretro/libretro_core_options.h",
    "core/libretro/libretro_core_options_intl.h",
    "core/rend/gles/glcache.h",
    "core/rend/gles/gldraw.cpp",
    "core/rend/gles/gles.cpp",
    "core/rend/gles/gles.h",
}

RENDERER_GLOB = "*#core#rend#*.gcda"


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def build_script() -> str:
    return read_text(BUILD_SCRIPT) + "\n" + read_text(RECIPE_SCRIPT)


def manifest() -> dict:
    return json.loads(read_text(MANIFEST_PATH))


def lock() -> dict:
    return json.loads(read_text(LOCK_PATH))


def stock_parity_cores() -> list[str]:
    script = build_script()
    start = script.index("STOCK_PARITY_CORES=(")
    body = script[start:].split(")", 1)[0]
    return [line.strip() for line in body.splitlines()[1:] if line.strip()]


def patch_added_lines() -> list[str]:
    return [
        line[1:]
        for line in read_text(PATCH_PATH).splitlines()
        if line.startswith("+") and not line.startswith("+++")
    ]


def patch_body() -> str:
    """The applied diff only, without the provenance comment header."""
    text = read_text(PATCH_PATH)
    return text[text.index("diff --git a/") :]


class LockAndParityTest(unittest.TestCase):
    def test_lock_entry_matches_the_planned_identity(self) -> None:
        entry = lock()["cores"]["flycast_fast_umrk"]
        self.assertEqual(entry["url"], "https://github.com/flyinghead/flycast")
        self.assertEqual(entry["commit"], PINNED_COMMIT)
        self.assertEqual(entry["checkout"], "flycast-fast-umrk")
        self.assertEqual(entry["recipe"], "flycast-2022-fast-umrk-pgo-v1")
        self.assertEqual(
            entry["build_recipe"],
            {"source": "scripts/mlp1-flycast-fast-umrk-recipe.sh", "function": "build_flycast_fast_umrk_core"},
        )
        # The standard Flycast pin keeps its own checkout and recipe.
        standard = lock()["cores"]["flycast"]
        self.assertEqual(standard["checkout"], "libretro-super/libretro-flycast")
        self.assertEqual(standard["recipe"], "flycast-cmake-v1")

    def test_stock_parity_covers_exactly_the_locked_cores(self) -> None:
        cores = stock_parity_cores()
        self.assertEqual(sorted(cores), sorted(lock()["cores"]))
        self.assertIn("flycast_fast_umrk", cores)
        self.assertEqual(len(cores), 31)
        self.assertEqual(len(set(cores)), len(cores))

    def test_dedicated_lane_is_dispatched_by_the_builder(self) -> None:
        script = build_script()
        self.assertIn("build_flycast_fast_umrk_core && build_status=0", script)
        self.assertIn("printf 'custom-flycast-2022-pgo'", script)
        self.assertIn("printf 'a55-pgo-contract'", script)
        self.assertIn("--flycast-fast-umrk-profile-gen", script)


class PatchContractTest(unittest.TestCase):
    def test_patch_is_source_only_for_the_expected_files(self) -> None:
        text = patch_body()
        touched = {
            line.split(" b/", 1)[1].strip()
            for line in text.splitlines()
            if line.startswith("diff --git a/")
        }
        self.assertEqual(touched, PATCHED_FILES)
        for forbidden in ("/Volumes/", "/Users/", "/src/src", "Makefile.orig", "GIT binary patch"):
            self.assertNotIn(forbidden, text)
        # The provenance header may name the evidence experiment, but never an
        # absolute host path.
        header = read_text(PATCH_PATH)[: read_text(PATCH_PATH).index("diff --git a/")]
        for forbidden in ("/Volumes/", "/Users/", "/private/tmp"):
            self.assertNotIn(forbidden, header)

    def test_patch_carries_no_diagnostic_or_test_seams(self) -> None:
        text = patch_body()
        self.assertNotIn("FLYCAST_LAZY_UNIFORM_DIAG", text)
        self.assertNotIn("GLES_UNIFORM_LIGHT", text)
        self.assertNotIn("lazy_diag", text)
        self.assertNotIn("stub_uniform_write_count", text)

    def test_patch_contains_identity_and_texture_token_compatibility(self) -> None:
        text = read_text(PATCH_PATH)
        self.assertIn('info->library_name = "FlyCast Fast UMRK";', text)
        self.assertIn(
            'if (!strcmp("1", var.value) || !strcmp("disabled", var.value) || !strcmp("off", var.value))',
            text,
        )

    def test_patch_contains_the_three_performance_changes(self) -> None:
        text = patch_body()
        self.assertIn("if (cur_params._max_anisotropy == param)", text)
        self.assertIn("GLfloat _max_anisotropy;", text)
        self.assertIn(
            "bool aniso = gl.max_anisotropy > 1.f && settings.rend.AnisotropicFiltering > 1;",
            text,
        )
        self.assertIn(
            "mipmapped ? (aniso ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR_MIPMAP_NEAREST) : GL_LINEAR);",
            text,
        )
        self.assertIn("u64 shader_uniform_serial = 1;", text)
        self.assertIn("if (shader->common_uniforms_stale())", text)
        # The RPI4 branch keeps its unconditional refresh: both the RPI4 arm and
        # the ordinary arm mark the program current.
        self.assertIn("RPI4_SET_UNIFORM_ATTRIBUTES_BUG", read_text(PATCH_PATH))
        added = patch_added_lines()
        self.assertEqual(
            sum(1 for line in added if "shader->mark_common_uniforms_current();" in line), 2
        )
        self.assertIn("glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT", text)
        self.assertIn("glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_MAX_ANISOTROPY_EXT", text)

    def test_patch_contains_the_build_prerequisites(self) -> None:
        text = read_text(PATCH_PATH)
        self.assertIn("else ifeq ($(platform), mlp1)", text)
        self.assertIn("HAVE_OPENMP = 0", text)
        self.assertNotIn("TARGET_NO_THREADS", text)
        self.assertIn("ifneq ($(NOPROF_FILTER),)", text)
        self.assertIn(
            "core/rec-ARM64/%.o core/hw/sh4/dyna/%.o core/hw/mem/%.o core/hw/arm7/%.o core/libretro/vmem_utils.o: CXXFLAGS := $(filter-out $(NOPROF_FILTER),$(CXXFLAGS))",
            text,
        )
        self.assertIn("return glGetString(name);", text)
        self.assertIn("__attribute__((used, externally_visible, noinline))", text)

    def test_patch_advertises_the_no_upscale_token_everywhere(self) -> None:
        added = patch_added_lines()
        self.assertEqual(
            sum(1 for line in added if '{ "1",  "Disabled (1x)" },' in line), 40
        )
        self.assertEqual(len([line for line in added if line == '      "1",']), 40)
        # Every rewritten table keeps the upstream terminator and 2x/4x/6x rows.
        self.assertEqual(patch_body().count("{ NULL, NULL },"), 40)
        self.assertEqual(patch_body().count('{ "2x",'), 40)

    def test_patch_never_suppresses_missing_profile_warnings(self) -> None:
        self.assertNotIn("-Wno-missing-profile", read_text(PATCH_PATH))


class ManifestContractTest(unittest.TestCase):
    def test_manifest_binds_the_planned_identity(self) -> None:
        data = manifest()
        self.assertEqual(data["core"], "flycast_fast_umrk")
        self.assertEqual(data["recipe"], "flycast-2022-fast-umrk-pgo-v1")
        self.assertEqual(data["source"]["commit"], PINNED_COMMIT)
        self.assertEqual(data["patch"]["path"], "patches/mlp1/flycast_fast_umrk.patch")
        self.assertEqual(data["patch"]["sha256"], sha256_file(PATCH_PATH))
        self.assertEqual(data["status"], "frozen")

    def test_manifest_pins_the_retrievable_toolchain_and_canonical_paths(self) -> None:
        toolchain = manifest()["toolchain"]
        self.assertEqual(toolchain["image_id"], TOOLCHAIN_IMAGE_ID)
        self.assertNotEqual(toolchain["image_id"], UNRETRIEVABLE_IMAGE_ID)
        self.assertIn("12.3.0", toolchain["compiler"])
        canonical = manifest()["canonical"]
        self.assertEqual(canonical["source_dir"], CANONICAL_SOURCE_DIR)
        self.assertEqual(canonical["profile_dir"], CANONICAL_PROFILE_DIR)
        self.assertEqual(canonical["profile_layout"], "flat")

    def test_manifest_settings_match_the_requested_profile(self) -> None:
        self.assertEqual(manifest()["settings"], REQUESTED_SETTINGS)
        self.assertEqual(len(REQUESTED_SETTINGS), 20)

    def test_manifest_training_contract_is_two_games_at_ninety_seconds(self) -> None:
        contract = manifest()["training_contract"]
        self.assertEqual(contract["games"], ["crazy-taxi", "sa2"])
        self.assertEqual(contract["seconds_per_game"], 90)

    def test_manifest_flags_exclude_the_missing_profile_suppression(self) -> None:
        flags = manifest()["flags"]
        self.assertNotIn("-Wno-missing-profile", flags["use"])
        self.assertIn("-fprofile-correction", flags["use"])
        self.assertIn("-fprofile-partial-training", flags["use"])
        self.assertIn("-fprofile-use=", flags["use"])
        self.assertNotIn("-fprofile-generate", flags["use"])
        self.assertEqual(flags["noprof_filter"], "-fprofile-generate -fprofile-generate=% -pg -fprofile-use -fprofile-use=%")
        self.assertEqual(flags["optimization"], "-O2")
        self.assertEqual(flags["tuning"], "-mcpu=cortex-a55 -mtune=cortex-a55")
        self.assertEqual(manifest()["excluded_units"], [
            "core/rec-ARM64/",
            "core/hw/sh4/dyna/",
            "core/hw/mem/",
            "core/hw/arm7/",
            "core/libretro/vmem_utils.o",
        ])

    def test_manifest_requires_real_renderer_profiles(self) -> None:
        rules = manifest()["requirements"]
        self.assertTrue(rules["flat_root"])
        self.assertGreaterEqual(rules["min_gcda_files"], 50)
        self.assertEqual(rules["renderer_profile_glob"], RENDERER_GLOB)
        self.assertGreaterEqual(rules["min_renderer_profiles"], 1)
        self.assertIn(".bin", rules["forbidden_member_suffixes"])
        self.assertIn(".state", rules["forbidden_member_suffixes"])

    def test_manifest_records_the_completed_training(self) -> None:
        training = manifest()["training"]
        self.assertEqual(training["games"], ["crazy-taxi", "sa2"])
        self.assertEqual(training["seconds_per_game"], 90)
        self.assertEqual(training["successful_exits"], 2)
        self.assertEqual(training["options_count"], 20)
        expected_options = "".join(
            f'{key} = "{value}"\n' for key, value in REQUESTED_SETTINGS.items()
        ).encode()
        self.assertEqual(
            training["options_sha256"], hashlib.sha256(expected_options).hexdigest()
        )
        self.assertEqual(sorted(training["state_sha256"]), ["crazy-taxi", "sa2"])
        self.assertEqual(sorted(training["input_sha256"]), ["crazy-taxi", "sa2"])
        self.assertEqual(len(training["generation_core_sha256"]), 64)
        self.assertTrue(training["qualification"])


class InfoAndBuilderTest(unittest.TestCase):
    def test_info_file_names_the_core_and_its_real_features(self) -> None:
        info = read_text(INFO_PATH)
        self.assertIn('display_name = "FlyCast Fast UMRK"', info)
        self.assertIn('corename = "FlyCast Fast UMRK"', info)
        self.assertIn(f'supported_extensions = "{VALID_EXTENSIONS}"', info)
        self.assertIn('hw_render = "true"', info)
        self.assertIn('required_hw_api = "OpenGL ES >= 2.0"', info)
        self.assertIn('savestate_features = "serialized"', info)
        self.assertIn('supports_no_game = "false"', info)
        # This AArch64 GLES build must not claim Vulkan or desktop-only APIs.
        self.assertNotIn("Vulkan", info)
        self.assertNotIn("Direct3D", info)

    def test_builder_uses_the_repo_owned_info_file(self) -> None:
        script = build_script()
        self.assertIn('FLYCAST_FAST_UMRK_INFO_DIR="$REPO_ROOT/info/mlp1"', script)
        self.assertIn('if [[ -f "$FLYCAST_FAST_UMRK_INFO_DIR/$info_file" ]]; then', script)
        self.assertIn('source_info="$FLYCAST_FAST_UMRK_INFO_DIR/$info_file"', script)

    def test_builder_recipe_flags_match_the_manifest_contract(self) -> None:
        script = build_script()
        self.assertIn('FLYCAST_FAST_UMRK_PGO_DIR="$CORES_WORKDIR/pgo/flycast-fast-umrk"', script)
        self.assertIn('FLYCAST_FAST_UMRK_PROFILE_DIR="$REPO_ROOT/profiles/mlp1/flycast_fast_umrk"', script)
        self.assertIn('FLYCAST_FAST_UMRK_GIT_VERSION=" 4c293f3"', script)
        self.assertIn("-flto=auto -ffat-lto-objects -fuse-linker-plugin", script)
        self.assertIn(
            'FLYCAST_FAST_UMRK_NOPROF_FILTER="-fprofile-generate -fprofile-generate=% -pg -fprofile-use -fprofile-use=%"',
            script,
        )
        self.assertIn("WITH_DYNAREC=arm64 HAVE_GENERIC_JIT=0 FORCE_GLES=1 DEBUG=0 V=1 MFLAGS=", script)
        self.assertIn('MLP1_OPT=-O2 MLP1_TUNE="-mcpu=cortex-a55 -mtune=cortex-a55"', script)
        self.assertIn('AR="$(cross_prefix)-gcc-ar"', script)
        self.assertIn('NM="$(cross_prefix)-gcc-nm"', script)
        self.assertIn('"$make_bin" platform=mlp1 clean', script)
        self.assertIn("-fprofile-use=$FLYCAST_FAST_UMRK_PGO_DIR -fprofile-correction -fprofile-partial-training", script)
        self.assertIn("-fprofile-generate=$FLYCAST_FAST_UMRK_PGO_DIR", script)
        self.assertNotIn("-Wno-missing-profile", script)

    def test_builder_verifies_the_dataset_before_any_object_file(self) -> None:
        script = build_script()
        extract = script.index('python3 "$MLP1_PROFILE_TOOL" extract')
        clean = script.index('"$make_bin" platform=mlp1 clean', extract)
        self.assertLess(extract, clean)
        self.assertIn("--canonical-source-dir \"$src_dir\"", script)
        self.assertIn("--canonical-profile-dir \"$pgo_dir\"", script)

    def test_generation_mode_cannot_seed_the_core_cache(self) -> None:
        script = build_script()
        self.assertIn('--flycast-fast-umrk-profile-gen)', script)
        self.assertIn('REPORT_PATH="$OUTPUT_DIR/profile-gen/flycast_fast_umrk-generation.txt"', script)
        self.assertIn('if [[ "$build_mode" != "flycast-profile-gen" ]]; then', script)
        guard = script.index('if [[ "$build_mode" != "flycast-profile-gen" ]]; then')
        self.assertIn('"$MLP1_CORE_CACHE_TOOL" update', script[guard:])


def extract_shell_function(name: str) -> str:
    script = build_script()
    start = script.index(f"{name}() {{")
    end = script.index("\n}\n", start) + len("\n}\n")
    return script[start:end]


def recipe_input_digest() -> str:
    digest = hashlib.sha256()
    for relative in ("scripts/mlp1-flycast-fast-umrk-recipe.sh",):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update((REPO_ROOT / relative).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


class SourceIdentityTest(unittest.TestCase):
    """The manifest must bind the patched tree and the managed recipe source."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.repo = self.root / "checkout"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / "Makefile").write_text("all:\n\ttrue\n", encoding="utf-8")
        self.git("add", "Makefile")
        self.git("commit", "-qm", "base")

    def git(self, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.repo), *args], check=False, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def identity(self) -> str:
        result = subprocess.run(
            [sys.executable, str(PROFILE_TOOL), "tree-identity", "--source-dir", str(self.repo)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_manifest_records_tree_and_recipe_identity(self) -> None:
        source = manifest()["source"]
        self.assertEqual(len(source["patched_tree_sha256"]), 64)
        recipe_input = manifest()["recipe_input"]
        self.assertEqual(recipe_input["file"], "scripts/mlp1-flycast-fast-umrk-recipe.sh")
        self.assertEqual(recipe_input["sha256"], recipe_input_digest())
        self.assertIn(f'{recipe_input["function"]}() {{', build_script())

    def test_tree_identity_is_stable_and_content_bound(self) -> None:
        baseline = self.identity()
        self.assertEqual(self.identity(), baseline)
        (self.repo / "Makefile").write_text("all:\n\techo patched\n", encoding="utf-8")
        self.assertNotEqual(self.identity(), baseline)

    def test_tree_identity_rejects_untracked_files(self) -> None:
        (self.repo / "extra.c").write_text("int x;\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(PROFILE_TOOL), "tree-identity", "--source-dir", str(self.repo)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("untracked", result.stderr)

    def test_contract_check_rejects_a_different_patched_tree(self) -> None:
        profile_dir = self.root / "profile"
        profile_dir.mkdir()
        data = manifest()
        data["source"]["patched_tree_sha256"] = "0" * 64
        (profile_dir / "manifest.json").write_text(json.dumps(data), encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable, str(PROFILE_TOOL), "check",
                "--profile-dir", str(profile_dir),
                "--lock", str(LOCK_PATH),
                "--patch", str(PATCH_PATH),
                "--toolchain-id", TOOLCHAIN_IMAGE_ID,
                "--canonical-source-dir", CANONICAL_SOURCE_DIR,
                "--canonical-profile-dir", CANONICAL_PROFILE_DIR,
                "--source-dir", str(self.repo),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("patched source identity", result.stderr)

    def test_lanes_and_trainer_pass_the_source_tree_to_the_contract_check(self) -> None:
        script = build_script()
        self.assertEqual(script.count('--source-dir "$src_dir"'), 2)
        trainer = read_text(REPO_ROOT / "scripts" / "mlp1-flycast-fast-umrk-train.sh")
        self.assertIn('SOURCE_ARGS=(--source-dir "$SOURCE_DIR")', trainer)
        self.assertIn('"${SOURCE_ARGS[@]}"', trainer)


class CacheFingerprintTest(unittest.TestCase):
    """The dedicated core follows its curated inputs; generic cores do not."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        for relative in ("config", "patches/mlp1", "profiles/mlp1/flycast_fast_umrk", "info/mlp1"):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        self.copy("config/mlp1-core-lock.json")
        self.copy("patches/mlp1/flycast_fast_umrk.patch")
        self.copy("profiles/mlp1/flycast_fast_umrk/manifest.json")
        self.copy("info/mlp1/flycast_fast_umrk_libretro.info")
        self.copy("build-mlp1.sh")
        self.copy("scripts/mlp1-flycast-fast-umrk-recipe.sh")
        self.cores = sorted(json.loads(read_text(LOCK_PATH))["cores"])

    def copy(self, relative: str) -> None:
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((REPO_ROOT / relative).read_bytes())

    def fingerprint(self, core: str) -> str:
        command = [
            sys.executable, str(CACHE_TOOL), "fingerprint",
            "--lock", str(self.root / "config/mlp1-core-lock.json"),
            "--cache", str(self.root / "cache.json"),
            "--cores-dir", str(self.root / "cores"),
            "--info-dir", str(self.root / "info"),
            "--patch-dir", str(self.root / "patches/mlp1"),
            "--profile-dir", str(self.root / "profiles/mlp1"),
            "--info-source-dir", str(self.root / "info/mlp1"),
            "--recipe-root", str(self.root),
            "--libretro-super-url", "https://example.invalid/libretro-super.git",
            "--libretro-super-commit", "c" * 40,
            "--toolchain-id", TOOLCHAIN_IMAGE_ID,
            "--target-soc", "rk3566",
            "--target-cpu", "cortex-a55",
            "--build-profile", "release",
            "--cflags=-O2 -mcpu=cortex-a55 -mtune=cortex-a55",
            "--cxxflags=-O2 -mcpu=cortex-a55 -mtune=cortex-a55",
            "--ldflags=-Wl,--gc-sections",
            "--selected-core", core,
        ]
        for name in self.cores:
            command.extend(("--core", name))
        result = subprocess.run(command, check=False, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_curated_inputs_do_not_touch_generic_cores(self) -> None:
        baseline = self.fingerprint("genesis_plus_gx")
        (self.root / "profiles/mlp1/flycast_fast_umrk/manifest.json").write_text("{}", encoding="utf-8")
        (self.root / "info/mlp1/flycast_fast_umrk_libretro.info").write_text("changed\n", encoding="utf-8")
        (self.root / "build-mlp1.sh").write_text(read_text(BUILD_SCRIPT) + "\n# changed\n", encoding="utf-8")
        self.assertEqual(self.fingerprint("genesis_plus_gx"), baseline)

    def test_every_dedicated_input_invalidates_the_core(self) -> None:
        baseline = self.fingerprint("flycast_fast_umrk")
        cases = {
            "manifest": lambda: (
                self.root / "profiles/mlp1/flycast_fast_umrk/manifest.json"
            ).write_text(read_text(MANIFEST_PATH).replace('"version": 1', '"version": 1 '), encoding="utf-8"),
            "info": lambda: (self.root / "info/mlp1/flycast_fast_umrk_libretro.info").write_text(
                read_text(INFO_PATH) + "\n", encoding="utf-8"
            ),
            "recipe": lambda: (self.root / "scripts/mlp1-flycast-fast-umrk-recipe.sh").write_text(
                read_text(RECIPE_SCRIPT) + "\n# recipe edit\n", encoding="utf-8"
            ),
            "patch": lambda: (self.root / "patches/mlp1/flycast_fast_umrk.patch").write_text(
                read_text(PATCH_PATH) + "\n# patch edit\n", encoding="utf-8"
            ),
        }
        for label, mutate in cases.items():
            with self.subTest(label):
                self.copy("profiles/mlp1/flycast_fast_umrk/manifest.json")
                self.copy("info/mlp1/flycast_fast_umrk_libretro.info")
                self.copy("build-mlp1.sh")
                self.copy("scripts/mlp1-flycast-fast-umrk-recipe.sh")
                self.copy("patches/mlp1/flycast_fast_umrk.patch")
                mutate()
                self.assertNotEqual(self.fingerprint("flycast_fast_umrk"), baseline)

    def test_recipe_source_hash_is_the_whole_file(self) -> None:
        cache_tool = read_text(CACHE_TOOL)
        start = cache_tool.index("def recipe_source_sha256")
        body = cache_tool[start : cache_tool.index("\ndef ", start + 1)]
        self.assertIn("hashlib.sha256(text.encode(", body)
        self.assertIn("hexdigest()", body)
        self.assertIn("not in text", body)
        self.assertNotIn("def shell_function_sha256", cache_tool)


class TrainingScriptTest(unittest.TestCase):
    SCRIPT = REPO_ROOT / "scripts" / "mlp1-flycast-fast-umrk-train.sh"

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.options = self.root / "FlyCast Fast UMRK.opt"
        self.options.write_text(
            "".join(f'{key} = "{value}"\n' for key, value in REQUESTED_SETTINGS.items()),
            encoding="utf-8",
        )
        for name in ("core.so", "ct.gdi", "ct.state", "ct.input", "sa2.gdi", "sa2.state", "sa2.input"):
            (self.root / name).write_bytes(b"fixture")

    def run_script(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(self.SCRIPT),
                "--core", str(self.root / "core.so"),
                "--options-file", str(self.options),
                "--rom", f"crazy-taxi={self.root / 'ct.gdi'}",
                "--state", f"crazy-taxi={self.root / 'ct.state'}",
                "--input", f"crazy-taxi={self.root / 'ct.input'}",
                "--rom", f"sa2={self.root / 'sa2.gdi'}",
                "--state", f"sa2={self.root / 'sa2.state'}",
                "--input", f"sa2={self.root / 'sa2.input'}",
                "--runner", "crazy-taxi=tool --input %INPUT% --evidence %EVIDENCE%",
                "--runner", "sa2=tool --input %INPUT% --evidence %EVIDENCE%",
                "--base-config", "/mnt/sdcard/.config/retroarch/retroarch.cfg",
                "--launcher-stop", "stop-launcher",
                "--launcher-start", "start-launcher",
                "--toolchain-id", TOOLCHAIN_IMAGE_ID,
                "--qualification", "host fixture",
                "--pull-dir", str(self.root / "pull"),
                "--allow-missing-source-check",
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_dry_run_plans_the_contracted_run(self) -> None:
        result = self.run_script("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        planned = result.stdout
        for expected in (
            "stop-launcher",
            "/userdata/flycast-fast-umrk-train",
            "GCOV_PREFIX='/userdata/flycast-fast-umrk-train/gcda'",
            "setsid timeout 90 tool --input /userdata/flycast-fast-umrk-train/crazy-taxi.input",
            "setsid timeout 90 tool --input /userdata/flycast-fast-umrk-train/sa2.input",
            "cd '/userdata/flycast-fast-umrk-train' || exit 1; GCOV_PREFIX=",
            "setsid 'retroarch'",
            "2>&1 </dev/null & echo",
            ".pid'; exit 0",
            "--appendconfig '/userdata/flycast-fast-umrk-train/appendconfig.cfg'",
            "+ write overlay /userdata/flycast-fast-umrk-train/appendconfig.cfg",
            "for path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor",
            "echo performance",
            "printf 'QUIT\\n' | nc -u 127.0.0.1 5535",
            "adb pull /userdata/flycast-fast-umrk-train/gcda",
        ):
            self.assertIn(expected, planned)
        self.assertEqual(
            planned.count("GCOV_PREFIX='/userdata/flycast-fast-umrk-train/gcda'"),
            2,
        )
        # The options template lands in the per-core path RetroArch reads.
        self.assertIn(
            "adb push "
            f"{self.options} "
            "/mnt/sdcard/.config/retroarch/flycast_fast_umrk_train/flycast_fast_umrk_train.opt",
            planned,
        )
        # The per-core option file wins over the device's shared options.
        self.assertIn('global_core_options = "false"', read_text(self.SCRIPT))
        self.assertNotIn("core_options_path", read_text(self.SCRIPT))
        self.assertIn("*.runner.pid", read_text(self.SCRIPT))
        self.assertIn("kill -TERM -- -\\$pid", read_text(self.SCRIPT))
        self.assertIn("kill -KILL -- -\\$pid", read_text(self.SCRIPT))

    def test_dry_run_accepts_a_device_resident_rom(self) -> None:
        result = subprocess.run(
            [
                "bash", str(self.SCRIPT),
                "--dry-run",
                "--core", str(self.root / "core.so"),
                "--options-file", str(self.options),
                "--rom", "crazy-taxi=device:/mnt/sdcard/Roms/DC/CrazyTaxi.gdi",
                "--state", f"crazy-taxi={self.root / 'ct.state'}",
                "--input", f"crazy-taxi={self.root / 'ct.input'}",
                "--rom", f"sa2={self.root / 'sa2.gdi'}",
                "--state", f"sa2={self.root / 'sa2.state'}",
                "--input", f"sa2={self.root / 'sa2.input'}",
                "--runner", "crazy-taxi=tool --evidence %EVIDENCE%",
                "--runner", "sa2=tool --evidence %EVIDENCE%",
                "--base-config", "/mnt/sdcard/.config/retroarch/retroarch.cfg",
                "--launcher-stop", "stop-launcher",
                "--launcher-start", "start-launcher",
                "--toolchain-id", TOOLCHAIN_IMAGE_ID,
                "--qualification", "host fixture",
                "--pull-dir", str(self.root / "pull"),
                "--allow-missing-source-check",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("'/mnt/sdcard/Roms/DC/CrazyTaxi.gdi'", result.stdout)
        self.assertNotIn(f"adb push {self.root}/ct.gdi", result.stdout)

    def test_dry_run_uses_retroarchctl_for_a_clean_quit_when_provided(self) -> None:
        result = self.run_script(
            "--dry-run", "--retroarchctl", "/device/bin/jawaka-retroarchctl"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "'/device/bin/jawaka-retroarchctl' --timeout-ms 3000 --port 5535 quit",
            result.stdout,
        )
        self.assertNotIn("nc -u 127.0.0.1 5535", result.stdout)

    def test_requires_private_game_inputs(self) -> None:
        result = subprocess.run(
            ["bash", str(self.SCRIPT), "--dry-run", "--core", str(self.root / "core.so")],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--rom GAME=PATH", result.stderr)

    def test_requires_an_explicit_launcher_decision(self) -> None:
        args = self.run_script_args()
        args = [arg for arg in args if arg not in ("--launcher-stop", "stop-launcher", "--launcher-start", "start-launcher")]
        result = subprocess.run(args + ["--dry-run", "--allow-missing-source-check"], check=False, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--launcher-stop", result.stderr)

    def run_script_args(self) -> list[str]:
        return [
            "bash", str(self.SCRIPT),
            "--core", str(self.root / "core.so"),
            "--options-file", str(self.options),
            "--rom", f"crazy-taxi={self.root / 'ct.gdi'}",
            "--state", f"crazy-taxi={self.root / 'ct.state'}",
            "--input", f"crazy-taxi={self.root / 'ct.input'}",
            "--rom", f"sa2={self.root / 'sa2.gdi'}",
            "--state", f"sa2={self.root / 'sa2.state'}",
            "--input", f"sa2={self.root / 'sa2.input'}",
            "--runner", "crazy-taxi=tool --evidence %EVIDENCE%",
            "--runner", "sa2=tool --evidence %EVIDENCE%",
            "--base-config", "/mnt/sdcard/.config/retroarch/retroarch.cfg",
            "--launcher-stop", "stop-launcher",
            "--launcher-start", "start-launcher",
            "--toolchain-id", TOOLCHAIN_IMAGE_ID,
            "--qualification", "host fixture",
            "--pull-dir", str(self.root / "pull"),
            "--allow-missing-source-check",
        ]

    def test_script_embeds_no_private_or_scratch_paths(self) -> None:
        text = read_text(self.SCRIPT)
        for forbidden in ("/Volumes/", "/Users/", "/private/tmp", "tmp/dc-core-bench", "/src/src"):
            self.assertNotIn(forbidden, text)
        # Game data and runner details only ever arrive as arguments.
        self.assertNotIn("CrazyTaxi.gdi", text)


class ProfileToolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.profile_dir = self.root / "profile"
        self.profile_dir.mkdir()
        self.manifest_path = self.profile_dir / "manifest.json"
        # A synthetic patched checkout stands in for the real pinned tree, so
        # the source identity contract can be exercised without a network fetch.
        self.source_repo = self.root / "checkout"
        self.source_repo.mkdir()
        subprocess.run(["git", "-C", str(self.source_repo), "init", "-q"], check=True)
        for key, value in (("user.email", "fixture@example.invalid"), ("user.name", "Fixture")):
            subprocess.run(["git", "-C", str(self.source_repo), "config", key, value], check=True)
        (self.source_repo / "Makefile").write_text("all:\n\ttrue\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(self.source_repo), "add", "Makefile"], check=True)
        subprocess.run(
            ["git", "-C", str(self.source_repo), "commit", "-qm", "base"], check=True
        )
        identity = subprocess.run(
            [sys.executable, str(PROFILE_TOOL), "tree-identity", "--source-dir", str(self.source_repo)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        data = manifest()
        data["source"]["patched_tree_sha256"] = identity
        data["status"] = "pending-training"
        data["archive"].update(sha256=None, file_count=0, files={})
        data["training"] = {
            "games": [],
            "seconds_per_game": 0,
            "successful_exits": 0,
            "options_file": "",
            "options_count": 0,
            "options_sha256": "",
            "generation_core_sha256": "",
            "state_sha256": {},
            "input_sha256": {},
            "device": "",
            "completed_utc": "",
            "qualification": "",
        }
        self.manifest_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        self.gcda_dir = self.root / "gcda"
        self.gcda_dir.mkdir()
        for index in range(50):
            if index < 7:
                name = (
                    "#workspace#workdir#src#flycast-fast-umrk#core#rend#gles"
                    f"#unit{index}.gcda"
                )
            else:
                name = f"#workspace#workdir#src#flycast-fast-umrk#core#unit{index}.gcda"
            (self.gcda_dir / name).write_bytes(f"counters{index}".encode())
        self.options = self.root / "FlyCast Fast UMRK.opt"
        self.write_options(REQUESTED_SETTINGS)

    def write_options(self, settings: dict[str, str]) -> None:
        self.options.write_text(
            "".join(f'{key} = "{value}"\n' for key, value in settings.items()),
            encoding="utf-8",
        )

    def tool(self, command: str, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable, str(PROFILE_TOOL), command,
                "--profile-dir", str(self.profile_dir),
                "--lock", str(LOCK_PATH),
                "--patch", str(PATCH_PATH),
                "--toolchain-id", TOOLCHAIN_IMAGE_ID,
                "--canonical-source-dir", CANONICAL_SOURCE_DIR,
                "--canonical-profile-dir", CANONICAL_PROFILE_DIR,
                "--source-dir", str(self.source_repo),
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def freeze(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return self.tool(
            "freeze",
            "--gcda-dir", str(self.gcda_dir),
            "--game", "crazy-taxi",
            "--game", "sa2",
            "--seconds-per-game", "90",
            "--options-file", str(self.options),
            "--generation-core-sha256", "a" * 64,
            "--state", "crazy-taxi=" + "b" * 64,
            "--state", "sa2=" + "c" * 64,
            "--input", "crazy-taxi=" + "d" * 64,
            "--input", "sa2=" + "e" * 64,
            "--device", "fixture-device",
            "--completed-utc", "2026-09-22T00:00:00Z",
            "--qualification", "fixture qualification record",
            *extra,
        )

    def test_freeze_records_provenance_and_round_trips(self) -> None:
        frozen = self.freeze()
        self.assertEqual(frozen.returncode, 0, frozen.stderr)
        data = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(data["status"], "frozen")
        self.assertEqual(data["archive"]["file_count"], 50)
        self.assertEqual(len(data["archive"]["files"]), 50)
        self.assertEqual(data["archive"]["sha256"], sha256_file(self.profile_dir / "profiles.tar.gz"))
        training = data["training"]
        self.assertEqual(sorted(training["state_sha256"]), ["crazy-taxi", "sa2"])
        self.assertEqual(training["state_sha256"]["crazy-taxi"], "b" * 64)
        self.assertEqual(training["input_sha256"]["sa2"], "e" * 64)
        self.assertEqual(training["options_sha256"], sha256_file(self.options))
        self.assertEqual(training["successful_exits"], 2)
        self.assertEqual(training["device"], "fixture-device")

        validated = self.tool("validate")
        self.assertEqual(validated.returncode, 0, validated.stderr)
        self.assertIn("7 renderer profiles", validated.stdout)

        dest = self.root / "extracted"
        extracted = self.tool("extract", "--dest", str(dest))
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        self.assertEqual(len(list(dest.glob("*.gcda"))), 50)

    def test_validate_rejects_the_unfrozen_contract(self) -> None:
        result = self.tool("validate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not frozen", result.stderr)

    def test_freeze_rejects_wrong_games_or_duration(self) -> None:
        wrong_games = self.freeze("--game", "sa2")
        self.assertNotEqual(wrong_games.returncode, 0)
        self.assertIn("training games", wrong_games.stderr)
        wrong_seconds = self.freeze("--seconds-per-game", "5")
        self.assertNotEqual(wrong_seconds.returncode, 0)
        self.assertIn("duration", wrong_seconds.stderr)

    def test_freeze_requires_per_game_state_and_input_hashes(self) -> None:
        missing = self.freeze("--state", "sa2=")
        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("sha256", missing.stderr)
        extra_key = self.freeze("--input", "other=" + "f" * 64)
        self.assertNotEqual(extra_key.returncode, 0)
        self.assertIn("input hashes", extra_key.stderr)
        bad_hash = self.freeze("--state", "crazy-taxi=not-a-hash")
        self.assertNotEqual(bad_hash.returncode, 0)
        self.assertIn("sha256", bad_hash.stderr)

    def test_freeze_requires_qualification_and_device(self) -> None:
        for extra, expected in (
            (("--qualification", "   "), "qualification"),
            (("--device", ""), "device"),
            (("--generation-core-sha256", "xyz"), "sha256"),
        ):
            result = self.freeze(*extra)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stderr)

    def test_freeze_rejects_thin_or_corrupt_profiles(self) -> None:
        for name in sorted(self.gcda_dir.glob("*#core#rend#*")):
            name.unlink()
        for index in range(7):
            (self.gcda_dir / f"#workspace#workdir#src#flycast-fast-umrk#core#filler{index}.gcda").write_bytes(
                f"filler{index}".encode()
            )
        thin = self.freeze()
        self.assertNotEqual(thin.returncode, 0)
        self.assertIn("renderer profiles", thin.stderr)

    def test_validate_rejects_a_tampered_archive(self) -> None:
        self.assertEqual(self.freeze().returncode, 0)
        archive = self.profile_dir / "profiles.tar.gz"
        archive.write_bytes(archive.read_bytes() + b"tampered")
        result = self.tool("validate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr)

    def test_validate_rejects_a_stale_patch_contract(self) -> None:
        self.assertEqual(self.freeze().returncode, 0)
        data = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        data["patch"]["sha256"] = "0" * 64
        self.manifest_path.write_text(json.dumps(data), encoding="utf-8")
        result = self.tool("validate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("managed patch hash", result.stderr)

    def test_freeze_requires_the_exact_twenty_setting_template(self) -> None:
        extra_key = dict(REQUESTED_SETTINGS)
        extra_key["reicast_not_ours"] = "enabled"
        self.write_options(extra_key)
        result = self.freeze()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the contract", result.stderr)

        wrong_value = dict(REQUESTED_SETTINGS)
        wrong_value["reicast_texupscale"] = "2x"
        self.write_options(wrong_value)
        result = self.freeze()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected values", result.stderr)


class CompileLogAuditTest(unittest.TestCase):
    """Drive the real audit functions from build-mlp1.sh against fake logs."""

    PGO_DIR = "/workspace/workdir/pgo/flycast-fast-umrk"

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        harness = [
            "set -uo pipefail",
            extract_shell_function("verify_a55_compile_log"),
            extract_shell_function("flycast_fast_umrk_audit_compile_log"),
            f'FLYCAST_FAST_UMRK_PGO_DIR="{self.PGO_DIR}"',
            'verify_a55_compile_log flycast_fast_umrk "$1" || exit 1',
            'flycast_fast_umrk_audit_compile_log "$2" "$1"',
        ]
        self.harness = self.root / "audit.sh"
        self.harness.write_text("\n".join(harness) + "\n", encoding="utf-8")

    def run_audit(self, log: str, phase: str) -> subprocess.CompletedProcess[str]:
        log_path = self.root / f"{phase}.log"
        log_path.write_text(log, encoding="utf-8")
        return subprocess.run(
            ["bash", str(self.harness), str(log_path), phase],
            check=False,
            capture_output=True,
            text=True,
        )

    def compile_line(self, source: str, flag: str, compiler: str = "g++") -> str:
        return (
            f"/opt/mlp1-toolchain/bin/aarch64-buildroot-linux-gnu-{compiler} "
            f"-I./core -O2 -mcpu=cortex-a55 -mtune=cortex-a55 "
            f"-DHOST_CPU=0x20000006 -DTARGET_LINUX_ARMv8 -DNOSSE -D__NEON_OPT "
            f"-DLOW_END {flag} -c -fPIC {source} -o {source.rsplit('.', 1)[0]}.o\n"
        )

    def generate_log(self, *, renderer: bool = True, extra: str = "") -> str:
        flag = f"-fprofile-generate={self.PGO_DIR}"
        lines = [
            self.compile_line("core/libretro/libretro.cpp", flag),
            self.compile_line("core/hw/mem/_vmem.cpp", ""),
            self.compile_line("core/hw/arm7/arm7.cpp", ""),
            self.compile_line("core/rec-ARM64/rec_arm64.cpp", ""),
            self.compile_line("core/rec-ARM64/ngen_arm64.S", flag, compiler="gcc"),
        ]
        if renderer:
            lines.append(self.compile_line("core/rend/gles/gles.cpp", flag))
        lines.append(extra)
        return "".join(lines)

    def test_accepts_a_real_shaped_generation_log(self) -> None:
        result = self.run_audit(self.generate_log(), "generate")
        self.assertEqual(result.returncode, 0, result.stderr)

    def use_flag(self) -> str:
        return f"-fprofile-use={self.PGO_DIR} -fprofile-correction -fprofile-partial-training"

    def use_log(
        self,
        *,
        renderer_flag: str | None = None,
        excluded_extra: bool = False,
        openmp: bool = False,
        assembly: bool = True,
        extra: str = "",
    ) -> str:
        flag = self.use_flag()
        renderer = flag if renderer_flag is None else renderer_flag
        if openmp:
            renderer = f"{renderer} -fopenmp"
        lines = [
            self.compile_line("core/libretro/libretro.cpp", flag),
            self.compile_line("core/hw/sh4/dyna/driver.cpp", ""),
            self.compile_line("core/hw/mem/_vmem.cpp", ""),
            self.compile_line("core/hw/arm7/arm7.cpp", flag if excluded_extra else ""),
            self.compile_line("core/rec-ARM64/rec_arm64.cpp", ""),
            self.compile_line("core/rend/gles/gles.cpp", renderer),
        ]
        if assembly:
            lines.append(self.compile_line("core/rec-ARM64/ngen_arm64.S", flag, compiler="gcc"))
        lines.append(extra)
        return "".join(lines)

    def test_accepts_a_real_shaped_use_log(self) -> None:
        log = self.use_log(
            extra="core/libretro/libretro.cpp: warning: profile data file '/x/y.gcda' is missing\n"
        )
        result = self.run_audit(log, "use")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_a_renderer_without_the_phase_flag(self) -> None:
        result = self.run_audit(self.use_log(renderer_flag=""), "use")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without -fprofile-use", result.stderr)

    def test_rejects_an_instrumented_excluded_unit(self) -> None:
        result = self.run_audit(self.use_log(excluded_extra=True), "use")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("assembly-sensitive", result.stderr)

    def test_rejects_generation_instrumentation_in_a_use_log(self) -> None:
        log = self.generate_log()
        result = self.run_audit(log, "use")
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_missing_renderer_profile_data(self) -> None:
        log = self.use_log(
            extra="#workspace#workdir#src#flycast-fast-umrk#core#rend#gles#gles.gcda: not found\n"
        )
        result = self.run_audit(log, "use")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("renderer profile data", result.stderr)

    def test_rejects_openmp_and_missing_assembly_compiles(self) -> None:
        self.assertNotEqual(self.run_audit(self.use_log(openmp=True), "use").returncode, 0)
        self.assertNotEqual(self.run_audit(self.use_log(assembly=False), "use").returncode, 0)
