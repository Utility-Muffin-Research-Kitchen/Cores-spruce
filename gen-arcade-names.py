#!/usr/bin/env python3
"""Generate arcade_names.txt (romname<TAB>Title) from emulator metadata.

Maps cryptic arcade romset names (mslug, 1942, dkong) to friendly titles for the
Leaf launcher's arcade name map. Reads the FBNeo Arcade + Neo Geo ClrMamePro XML
DATs and the MAME2003-Plus XML; on a romname collision MAME2003-Plus wins (it
matches the `mame` core the MAME folder uses). Titles are trimmed at the first
" - " subtitle ("Metal Slug - Super Vehicle-001" -> "Metal Slug"); region/rev
parens are kept and stripped by the launcher at display time.

Pass the pinned Flycast naomi_roms.cpp with --flycast-roms to add Atomiswave,
Naomi, Naomi GD-ROM, and Naomi 2 names. System SP is intentionally excluded.
Output goes to the positional path (default: ./output/mlp1/arcade_names.txt) and
should be shipped in the platform defaults payload next to systems.json.
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET

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

FLYCAST_GAME_RE = re.compile(
    r'''^\s*\{\s*
        "(?P<name>[^"]+)"\s*,\s*
        (?:nullptr|"[^"]+")\s*,\s*
        "(?P<title>[^"]+)"\s*,\s*
        [^,]+,\s*
        [^,]+,\s*
        (?P<bios>nullptr|"[^"]+")\s*,\s*
        (?P<cart>M1|M2|M4|AW|GD)\s*,
    ''',
    re.MULTILINE | re.VERBOSE,
)


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


def parse_flycast(path):
    """Return in-scope Flycast arcade shortnames and friendly titles."""
    with open(path, encoding="utf-8") as source:
        text = source.read()
    names = {}
    systems = {"atomiswave": set(), "naomi": set()}
    for match in FLYCAST_GAME_RE.finditer(text):
        cart = match.group("cart")
        bios = match.group("bios").strip('"')
        if cart == "AW":
            system = "atomiswave"
        elif bios == "segasp":
            continue
        else:
            system = "naomi"
        rom = match.group("name").strip().lower()
        title = trim_title(match.group("title"))
        previous = names.get(rom)
        if previous and previous != title:
            raise ValueError("conflicting Flycast title for %s" % rom)
        if rom and title:
            names[rom] = title
            systems[system].add(rom)
    if not systems["atomiswave"] or not systems["naomi"]:
        raise ValueError("no Atomiswave/Naomi games found in %s" % path)
    return names, {key: len(value) for key, value in systems.items()}


def merge_flycast(names, flycast_names):
    """Add Flycast rows without changing an existing arcade system's title."""
    conflicts = sorted(
        rom for rom, title in flycast_names.items()
        if rom in names and names[rom] != title
    )
    if conflicts:
        raise ValueError("Flycast shortname collision: %s" % ", ".join(conflicts))
    before = len(names)
    names.update(flycast_names)
    return len(names) - before


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "output",
        nargs="?",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "output", "mlp1", "arcade_names.txt"),
    )
    parser.add_argument(
        "--flycast-roms",
        metavar="NAOMI_ROMS_CPP",
        help="pinned Flycast core/hw/naomi/naomi_roms.cpp",
    )
    parser.add_argument(
        "--flycast-only",
        action="store_true",
        help="emit only Flycast rows (requires --flycast-roms)",
    )
    args = parser.parse_args()
    if args.flycast_only and not args.flycast_roms:
        parser.error("--flycast-only requires --flycast-roms")

    names = {}
    if not args.flycast_only:
        for path, label in DATS:
            if not os.path.isfile(path):
                sys.stderr.write("skip (missing): %s\n" % path)
                continue
            n0 = len(names)
            for rom, title in parse_dat(path):
                names[rom] = title  # later DATs win
            sys.stderr.write("%-14s %6d entries (total %d)\n" %
                             (label, len(names) - n0, len(names)))

    if args.flycast_roms:
        if not os.path.isfile(args.flycast_roms):
            parser.error("missing Flycast ROM table: %s" % args.flycast_roms)
        flycast_names, counts = parse_flycast(args.flycast_roms)
        added = merge_flycast(names, flycast_names)
        sys.stderr.write(
            "flycast       %6d entries (%d Atomiswave, %d Naomi family; total %d)\n"
            % (added, counts["atomiswave"], counts["naomi"], len(names))
        )

    output_dir = os.path.dirname(args.output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as fh:
        for rom in sorted(names):
            fh.write("%s\t%s\n" % (rom, names[rom]))
    sys.stderr.write("wrote %d entries -> %s\n" % (len(names), args.output))


if __name__ == "__main__":
    main()
