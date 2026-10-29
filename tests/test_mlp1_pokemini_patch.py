from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class Mlp1PokeminiPatchTest(unittest.TestCase):
    def test_patch_names_archive_saves_after_the_archive(self) -> None:
        patch = (REPO_ROOT / "patches/mlp1/pokemini.patch").read_text(encoding="utf-8")
        self.assertIn("+#include <file/file_path.h>", patch)
        self.assertIn("+\tdelim = (char*)path_get_archive_delim(archive_path);", patch)
        self.assertIn("+\t\t*delim = '\\0';", patch)

    def test_build_reports_the_pokemini_tuning(self) -> None:
        build = (REPO_ROOT / "build-mlp1.sh").read_text(encoding="utf-8")
        self.assertIn("printf 'mlp1-archive-save-name'", build)


if __name__ == "__main__":
    unittest.main()
