#!/usr/bin/env python3
"""Import PencilCAD's SolidCraft tool icons as namespaced vector image assets.

Usage: python3 scripts/import-solidcraft-icons.py /path/to/solidcraft
The input checkout must be tangency-labs/solidcraft at the revision recorded in
SOLIDCRAFT_ICONS.md. This script does not fetch network resources.
"""

import json
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "App/Assets.xcassets/sc"
ALIASES = {
    "sketch_break": "break",
    "sketch_circ_pattern": "pattern_circ",
    "sketch_rect_pattern": "pattern_rect",
    "sketch_scale": "scale",
    "sketch_text": "text",
}


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: import-solidcraft-icons.py /path/to/solidcraft")
    source = Path(sys.argv[1]) / "assets/icons/ui/design/svg/model"
    if not source.is_dir():
        raise SystemExit(f"Missing SolidCraft SVG masters: {source}")
    icon_source = ROOT / "App/Workspace/ToolIcon.swift"
    names = set(re.findall(r'^\s*"([a-z0-9_]+)":', icon_source.read_text(), re.M))
    if not names:
        raise SystemExit("No sc. icon names found in ToolIcon.swift")
    DEST.mkdir(parents=True, exist_ok=True)
    (DEST / "Contents.json").write_text(json.dumps({
        "info": {"author": "xcode", "version": 1},
        "properties": {"provides-namespace": True},
    }, indent=2) + "\n")
    for name in sorted(names):
        master = source / f"{ALIASES.get(name, name)}.svg"
        if not master.is_file():
            raise SystemExit(f"Missing SolidCraft icon: {name} ({master})")
        image_set = DEST / f"{name}.imageset"
        image_set.mkdir(exist_ok=True)
        shutil.copy2(master, image_set / "icon.svg")
        (image_set / "Contents.json").write_text(json.dumps({
            "images": [{"filename": "icon.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }, indent=2) + "\n")
    print(f"Imported {len(names)} SolidCraft icons ({len(ALIASES)} semantic aliases)")


if __name__ == "__main__":
    main()
