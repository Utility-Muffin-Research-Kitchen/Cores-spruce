#!/usr/bin/env python3
"""Generate arcade_names.txt (romname<TAB>Title) from the libretro core DATs.

Maps cryptic arcade romset names (mslug, 1942, dkong) to friendly titles for the
Leaf launcher's arcade name map. Reads the FBNeo Arcade + Neo Geo ClrMamePro XML
DATs and the MAME2003-Plus XML; on a romname collision MAME2003-Plus wins (it
matches the `mame` core the MAME folder uses). Titles are trimmed at the first
" - " subtitle ("Metal Slug - Super Vehicle-001" -> "Metal Slug"); region/rev
parens are kept and stripped by the launcher at display time.

Run from the Cores-spruce checkout after fetch-libretro-super.sh. Output goes to
the path given as argv[1] (default: ./output/mlp1/arcade_names.txt), and should be
shipped in the platform defaults payload next to systems.json.
"""
import os, sys, xml.etree.ElementTree as ET

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "workdir", "src", "libretro-super")

# (path, label) in ascending precedence — later sources overwrite earlier on a
# romname collision, so MAME2003-Plus (last) wins.
DATS = [
    (os.path.join(SRC, "libretro-fbneo", "dats",
                  "FinalBurn Neo (ClrMame Pro XML, Neogeo only).dat"), "fbneo-neogeo"),
    (os.path.join(SRC, "libretro-fbneo", "dats",
                  "FinalBurn Neo (ClrMame Pro XML, Arcade only).dat"), "fbneo-arcade"),
    (os.path.join(SRC, "libretro-mame2003_plus", "metadata",
                  "mame2003-plus.xml"), "mame2003-plus"),
]


def trim_title(desc):
    """Trim a trailing ' - <subtitle>' and squeeze whitespace."""
    title = desc.split(" - ", 1)[0]
    return " ".join(title.split()).strip()


def parse_dat(path):
    """Yield (romname_lower, title) for every <game>/<machine> with a description."""
    for _event, elem in ET.iterparse(path, events=("end",)):
        tag = elem.tag.rsplit("}", 1)[-1]  # ignore any namespace
        if tag in ("game", "machine"):
            name = elem.get("name")
            desc = elem.findtext("description")
            if name and desc:
                title = trim_title(desc)
                if title:
                    yield name.strip().lower(), title
            elem.clear()


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "output", "mlp1", "arcade_names.txt")

    names = {}
    for path, label in DATS:
        if not os.path.isfile(path):
            sys.stderr.write("skip (missing): %s\n" % path)
            continue
        n0 = len(names)
        for rom, title in parse_dat(path):
            names[rom] = title  # later DATs win
        sys.stderr.write("%-14s %6d entries (total %d)\n" % (label, len(names) - n0 + 0, len(names)))

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        for rom in sorted(names):
            fh.write("%s\t%s\n" % (rom, names[rom]))
    sys.stderr.write("wrote %d entries -> %s\n" % (len(names), out_path))


if __name__ == "__main__":
    main()
