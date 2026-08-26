#!/usr/bin/env python3
"""Fail if lib/ references a Material icon the shipped release didn't bundle.

Flutter tree-shakes MaterialIcons-Regular.otf down to the glyphs a build
actually references, and a Shorebird patch carries Dart code only — never
assets. So an icon added after the release was cut has no glyph on the
device: it renders as an empty box on every patched kiosk, and nothing in
`shorebird patch` or `flutter analyze` warns about it.

Run this against the release APK the fleet is actually running, before
publishing a patch:

    python3 tool/check_patch_icons.py apks_1.2.0_67/app-release.apk

Exits non-zero and lists the offenders if any are missing. A missing icon
means either pick a glyph already in the release, or ship a full release
instead of a patch.

When something is flagged, list what the release *does* have so you can
substitute rather than pay for a full release:

    python3 tool/check_patch_icons.py apks_1.2.0_67/app-release.apk --list
    python3 tool/check_patch_icons.py apks_1.2.0_67/app-release.apk --list time

The optional filter matches substrings of the icon name, so `--list time`
surfaces the clock-ish glyphs, `--list person` the people-ish ones.

Requires fonttools (pip3 install fonttools).
"""

import re
import subprocess
import sys
import zipfile
from pathlib import Path

FONT_IN_APK = "assets/flutter_assets/fonts/MaterialIcons-Regular.otf"


def flutter_icons_dart() -> Path:
    """Locate the Flutter SDK's icons.dart, the name -> codepoint mapping."""
    root = subprocess.run(
        ["flutter", "--version", "--machine"],
        capture_output=True, text=True, check=True,
    ).stdout
    import json

    sdk = Path(json.loads(root)["flutterRoot"])
    return sdk / "packages/flutter/lib/src/material/icons.dart"


def codepoints_by_name(icons_dart: Path) -> dict[str, int]:
    src = icons_dart.read_text()
    return {
        m.group(1): int(m.group(2), 16)
        for m in re.finditer(
            r"static const IconData (\w+) = IconData\(\s*(0x[0-9a-fA-F]+)", src
        )
    }


def bundled_codepoints(apk: Path) -> set[int]:
    from fontTools.ttLib import TTFont

    with zipfile.ZipFile(apk) as z:
        with z.open(FONT_IN_APK) as f:
            font = TTFont(f)

    cps: set[int] = set()
    for table in font["cmap"].tables:
        cps.update(table.cmap.keys())
    return cps


def referenced_icons(lib: Path) -> set[str]:
    out = subprocess.run(
        ["grep", "-rhoE", r"Icons\.[a-zA-Z0-9_]+", str(lib)],
        capture_output=True, text=True,
    ).stdout
    return {token.split(".", 1)[1] for token in out.split()}


def list_bundled(codepoints: dict[str, int], bundled: set[int], needle: str) -> int:
    """Print the icon names the release font can actually render.

    This is what makes a flagged icon cheap to fix: the substitute has to
    come from this set, and eyeballing 80 names beats guessing and
    rebuilding.
    """
    by_cp: dict[int, list[str]] = {}
    for name, cp in codepoints.items():
        by_cp.setdefault(cp, []).append(name)

    names = sorted(
        name
        for cp in bundled
        for name in by_cp.get(cp, [])
        if needle in name
    )
    if not names:
        print(f"no bundled glyph matches {needle!r}")
        return 1

    label = f"matching {needle!r}" if needle else "in this release"
    print(f"{len(names)} icon names {label}:")
    for name in names:
        print(f"  Icons.{name}")
    return 0


def main() -> int:
    args = [a for a in sys.argv[1:]]
    if not args:
        print(__doc__)
        return 2

    listing = False
    if "--list" in args:
        listing = True
        args.remove("--list")

    apk = Path(args[0]) if args else None
    needle = args[1] if len(args) > 1 else ""

    if apk is None or not apk.exists():
        print(f"error: no such APK: {apk}")
        return 2

    lib = Path(__file__).resolve().parent.parent / "lib"
    codepoints = codepoints_by_name(flutter_icons_dart())
    bundled = bundled_codepoints(apk)

    if listing:
        return list_bundled(codepoints, bundled, needle)

    used = sorted(referenced_icons(lib))

    missing = []
    unknown = []
    for name in used:
        cp = codepoints.get(name)
        if cp is None:
            unknown.append(name)
        elif cp not in bundled:
            missing.append((name, cp))

    print(f"referenced in lib/ : {len(used)}")
    print(f"bundled in {apk.name} : {len(bundled)}")

    for name in unknown:
        print(f"warning: Icons.{name} not found in icons.dart (renamed?)")

    if missing:
        print()
        print("NOT IN THE RELEASE FONT — these render as empty boxes under a patch:")
        for name, cp in missing:
            print(f"  Icons.{name}  (U+{cp:04X})")
        print()
        print("Fix: use a glyph already in the release, or ship a full release.")
        return 1

    print("OK — every referenced icon has a glyph in this release.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
