from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class Mlp1PuaePatchTest(unittest.TestCase):
    def test_patch_uses_only_the_puae_system_subdirectory(self) -> None:
        for core in ("puae", "puae2021"):
            patch = (REPO_ROOT / f"patches/mlp1/{core}.patch").read_text(encoding="utf-8")
            self.assertIn('+            "puae");', patch)
            self.assertIn("+         path_mkdir(retro_system_directory);", patch)
            self.assertNotIn("BIOS/PUAE", patch)
            self.assertNotIn("BIOS/AMIGA", patch)

    def test_patch_links_the_unix_math_dependency(self) -> None:
        for core in ("puae", "puae2021"):
            patch = (REPO_ROOT / f"patches/mlp1/{core}.patch").read_text(encoding="utf-8")
            self.assertIn("+   LDFLAGS += -lm -lpthread", patch)

    def test_build_normalizes_pinned_core_info_for_raw_images(self) -> None:
        build = (REPO_ROOT / "build-mlp1.sh").read_text(encoding="utf-8")
        self.assertIn("s/fdi|ipf/fdi|raw|ipf/", build)


if __name__ == "__main__":
    unittest.main()
