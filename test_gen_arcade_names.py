#!/usr/bin/env python3
"""Narrow checks for Flycast arcade-name extraction."""

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("gen-arcade-names.py")
SPEC = importlib.util.spec_from_file_location("gen_arcade_names", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FlycastNameTests(unittest.TestCase):
    def test_extracts_supported_families_and_skips_system_sp(self):
        source = '''
const Game Games[] = {
  {
    "mslug6", nullptr, "Metal Slug 6", 1, 2, "awbios", AW,
  },
  {
    "mvsc2", nullptr, "Marvel vs. Capcom 2 - New Age", 1, 2, "naomi", M1,
  },
  {
    "vf4", nullptr, "Virtua Fighter 4", 1, 2, "naomi2", GD, ROT0,
    {
    },
    "gds-0012",
    nullptr,
  },
  {
    "dinoking", nullptr, "Dinosaur King", 1, 2, "segasp", M4,
  },
};
'''
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as fixture:
            fixture.write(source)
            fixture.flush()
            names, counts = MODULE.parse_flycast(fixture.name)

        self.assertEqual(
            {
                "mslug6": "Metal Slug 6",
                "mvsc2": "Marvel vs. Capcom 2",
                "vf4": "Virtua Fighter 4",
                "gds-0012": "Virtua Fighter 4",
            },
            names,
        )
        self.assertEqual({"atomiswave": 1, "naomi": 2}, counts)

    def test_rejects_cross_emulator_shortname_collisions(self):
        with self.assertRaisesRegex(ValueError, "Flycast shortname collision: game"):
            MODULE.merge_flycast({"game": "Old title"}, {"game": "New title"})


if __name__ == "__main__":
    unittest.main()
