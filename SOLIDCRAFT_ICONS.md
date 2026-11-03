# SolidCraft icons in PencilCAD

PencilCAD includes 107 tool icons copied from the editable SVG masters in
`assets/icons/ui/design/svg/model/` of [tangency-labs/solidcraft](https://github.com/tangency-labs/solidcraft),
revision `bd1525dcfbfbff9d0b51f64fe8c923ae6ce13e4a` (30 October 2026).
The icons were authored by SolidCraft contributors and are distributed under
the MIT license. The complete license text is in `SOLIDCRAFT_ICONS_LICENSE-MIT`.
The upstream `ATTRIBUTION.md` assigns the model icon SVG masters to SolidCraft
contributors under MIT OR Apache-2.0.

The SVG artwork is copied unchanged into `App/Assets.xcassets/sc/`. The asset
catalog provides the `sc.` image namespace used by `ToolIcon.swift`. Five
PencilCAD-specific commands reuse the corresponding SolidCraft master:

| PencilCAD | SolidCraft SVG |
| --- | --- |
| `sc.sketch_break` | `break.svg` |
| `sc.sketch_circ_pattern` | `pattern_circ.svg` |
| `sc.sketch_rect_pattern` | `pattern_rect.svg` |
| `sc.sketch_scale` | `scale.svg` |
| `sc.sketch_text` | `text.svg` |

The PencilCAD home-screen icon combines SolidCraft's `box.svg` with a PencilCAD
background; it is therefore a derived icon rather than an unchanged SVG copy.

To refresh the assets from the recorded source, run
`python3 scripts/import-solidcraft-icons.py /path/to/solidcraft`.
