import SwiftUI
import UIKit

/// Werkzeugsymbol: Namen mit „sc.“ sind SolidCraft-Vektorbilder im Asset-Katalog (Assets.xcassets/sc),
/// alle anderen SF Symbols. `Label(_, systemImage:)`, `Button(_, systemImage:)` und
/// `UIImage(systemName:)` kennen nur SF Symbols – Werkzeugsymbole laufen deshalb immer über ToolIcon, ToolLabel
/// bzw. `ToolIcon.uiImage`.
struct ToolIcon: View {
    let name: String
    /// Kantenlänge eigener Bilder; SF Symbols folgen weiter der Schrift des Aufrufers (.font)
    var size: CGFloat

    init(_ name: String, size: CGFloat = 20) {
        self.name = name
        self.size = size
    }

    static func isCustom(_ name: String) -> Bool { name.hasPrefix("sc.") }

    /// Der Asset-Katalog verwendet die Namespace-Schreibweise „sc/name“.
    static func assetName(_ name: String) -> String {
        guard isCustom(name) else { return name }
        return "sc/" + String(name.dropFirst(3))
    }

    static var customNames: [String] { fallbackSymbols.keys.map { "sc." + $0 } }

    /// SF-Symbol als Ersatz, wenn die SolidCraft-Assets nicht mitgeliefert wurden.
    private static let fallbackSymbols: [String: String] = [
        "align": "align.horizontal.center",
        "appearance": "paintpalette",
        "arc3": "point.topleft.down.to.point.bottomright.curvepath",
        "arc_center": "point.topleft.down.to.point.bottomright.curvepath",
        "arc_tangent": "point.topleft.down.to.point.bottomright.curvepath",
        "axis": "line.diagonal",
        "axis_normal_to_face": "line.diagonal",
        "bendtable": "tablecells",
        "box": "cube",
        "c_coincident": "point.2.filled.connected.trianglepath.dotted",
        "c_collinear": "line.diagonal",
        "c_concentric": "circle.circle",
        "c_equal": "equal",
        "c_fix": "lock",
        "c_hv": "arrow.up.and.down.and.arrow.left.and.right",
        "c_midpoint": "circle.dotted",
        "c_parallel": "line.3.horizontal",
        "c_perpendicular": "plus",
        "c_symmetry": "arrow.left.and.right.righttriangle.left.righttriangle.right",
        "c_tangent": "circle",
        "canvas": "photo",
        "chamfer": "square.on.circle",
        "circle": "circle",
        "circle2": "circle.dotted",
        "circle3": "circle.circle",
        "circle_tt": "circle",
        "circle_ttt": "circle",
        "coil": "hurricane",
        "combine": "square.on.square",
        "cone": "triangle",
        "construction": "line.diagonal",
        "convert_sheet": "square.on.square",
        "copy": "square.on.square",
        "cylinder": "cylinder.split.1x2",
        "delete": "trash",
        "dimension": "ruler",
        "draft": "triangle",
        "dxf": "doc",
        "ellipse": "oval",
        "emboss": "square.stack.3d.up",
        "extend": "arrow.up.left.and.arrow.down.right",
        "extrude": "cube.transparent",
        "fastener": "wrench.and.screwdriver",
        "fillet": "circle.lefthalf.filled",
        "flange": "rectangle.portrait",
        "flat": "rectangle",
        "fold": "arrow.uturn.down",
        "hem": "rectangle",
        "hole": "circle.dotted.circle",
        "import": "square.and.arrow.down",
        "intersect": "square.on.square",
        "library": "books.vertical",
        "line": "line.diagonal",
        "loft": "square.stack.3d.up",
        "measure": "ruler",
        "mirror": "square.on.square.dashed",
        "move": "arrow.up.and.down.and.arrow.left.and.right",
        "offset": "square.on.square",
        "offset_face": "square.on.square",
        "params": "slider.horizontal.3",
        "path_flange": "point.topleft.down.to.point.bottomright.curvepath",
        "pattern_circ": "circle.grid.2x2",
        "pattern_rect": "square.grid.3x3",
        "perforate": "circle.grid.3x3",
        "plane": "square.dashed",
        "point": "circle.fill",
        "polygon": "hexagon",
        "presspull": "arrow.up.and.down",
        "project": "square.and.arrow.down",
        "project_surface": "square.and.arrow.down",
        "rect": "rectangle",
        "rect3": "rectangle.dashed",
        "rect_center": "rectangle.center.inset.filled",
        "rect_rounded": "rectangle.roundedtop",
        "refold": "arrow.uturn.down",
        "replace_face": "square.on.square",
        "revolve": "arrow.triangle.2.circlepath",
        "rib": "line.diagonal",
        "scale": "arrow.up.left.and.arrow.down.right",
        "section": "square.split.2x2",
        "select": "cursorarrow",
        "sheet": "square.on.square",
        "sheet_rules": "list.bullet.rectangle",
        "shell": "cube.transparent",
        "sketch": "pencil.tip",
        "sketch_break": "scissors",
        "sketch_chamfer": "square.on.circle",
        "sketch_circ_pattern": "circle.grid.2x2",
        "sketch_fillet": "circle.lefthalf.filled",
        "sketch_mirror": "square.on.square.dashed",
        "sketch_rect_pattern": "square.grid.3x3",
        "sketch_scale": "arrow.up.left.and.arrow.down.right",
        "sketch_text": "textformat",
        "slot": "capsule",
        "slot_center": "capsule",
        "slot_overall": "capsule",
        "sphere": "circle",
        "spline": "scribble.variable",
        "spline_cv": "point.3.connected.trianglepath.dotted",
        "split_body": "square.split.2x1",
        "svg": "doc",
        "sweep": "arrow.triangle.turn.up.right.diamond",
        "text": "textformat",
        "thread": "screwdriver",
        "torus": "circle.circle",
        "trim": "scissors",
        "unfold": "arrow.uturn.up",
    ]

    static func resolvedSymbol(_ name: String) -> String {
        guard isCustom(name) else { return name }
        return fallbackSymbols[String(name.dropFirst(3))] ?? "square.grid.2x2"
    }

    static func uiImage(_ name: String) -> UIImage? {
        if isCustom(name), let custom = UIImage(named: assetName(name)) {
            return custom.withRenderingMode(.alwaysOriginal)
        }
        return UIImage(systemName: resolvedSymbol(name)) ?? UIImage(systemName: "square")
    }

    var body: some View {
        Group {
            if Self.isCustom(name), UIImage(named: Self.assetName(name)) != nil {
                Image(Self.assetName(name))
                    .resizable()
                    .renderingMode(.original)
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: Self.resolvedSymbol(name))
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.82, height: size * 0.82)
                    .foregroundStyle(.primary)
            }
        }
    }
}

/// Ersatz für `Label(title, systemImage:)`, der auch SolidCraft-Bilder zeigt.
struct ToolLabel: View {
    let title: String
    let icon: String
    var size: CGFloat = 20

    init(_ title: String, icon: String, size: CGFloat = 20) {
        self.title = title
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            ToolIcon(icon, size: size)
        }
    }
}
