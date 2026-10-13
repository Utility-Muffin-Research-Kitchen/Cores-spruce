from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PATCH = REPO_ROOT / "patches/mlp1/yabasanshiro.patch"

# Saturn button -> RetroPad button. Y, B and A (left, bottom, right) are the
# Saturn's A, B and C row; L1, X and R1 are its X, Y and Z row. Yabadabadoo-pak
# patches its core to the same layout.
LAYOUT = {"A": "Y", "B": "B", "C": "A", "X": "L", "Y": "X", "Z": "R"}
PORTS = 12


class Mlp1YabasanshiroPatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.patch = PATCH.read_text(encoding="utf-8")

    def test_poll_reads_each_saturn_button_from_its_retropad_button(self) -> None:
        # Upstream already reads Saturn Y from X and Z from R; the patch moves
        # the other four.
        for saturn in ("A", "B", "C", "X"):
            pattern = (
                rf"\n\+ +if \(input_state_cb_wrapper\(i, RETRO_DEVICE_JOYPAD, 0, "
                rf"RETRO_DEVICE_ID_JOYPAD_{LAYOUT[saturn]}\)\)\n"
                rf" +PerKeyDown\(\(i << 8\) \+ PERPAD_{saturn}\);"
            )
            self.assertRegex(self.patch, pattern, saturn)

    def test_every_port_labels_the_buttons_it_reads(self) -> None:
        for saturn in ("A", "B", "C", "X"):
            added = re.findall(
                rf'^\+ +\{{ \d+, RETRO_DEVICE_JOYPAD, 0, '
                rf'RETRO_DEVICE_ID_JOYPAD_{LAYOUT[saturn]}, +"{saturn}" \}},$',
                self.patch,
                re.M,
            )
            self.assertEqual(len(added), PORTS, saturn)
        for saturn in ("Y", "Z"):
            # Unchanged rows stay as context, never as additions.
            self.assertNotRegex(self.patch, rf'(?m)^\+.*"{saturn}" \}},$')

    def test_no_descriptor_keeps_the_upstream_layout(self) -> None:
        upstream = {"A": "B", "B": "A", "C": "L", "X": "Y"}
        for saturn, pad in upstream.items():
            removed = re.findall(
                rf'^- +\{{ \d+, RETRO_DEVICE_JOYPAD, 0, '
                rf'RETRO_DEVICE_ID_JOYPAD_{pad}, +"{saturn}" \}},$',
                self.patch,
                re.M,
            )
            self.assertEqual(len(removed), PORTS, saturn)


if __name__ == "__main__":
    unittest.main()
