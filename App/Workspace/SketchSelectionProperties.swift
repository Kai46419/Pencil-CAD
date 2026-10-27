import SwiftUI

// Abschnitt „Auswahl“ der Skizzenpalette: Maße der gewählten Elemente (Ändern legt eine Bemaßung an bzw.
// ändert die vorhandene), passende Bedingungen, Verankern, Trennen, Löschen; bei einem Text der Texteditor.

/// Eigenschaften der Auswahl im Auswählen-Werkzeug.
struct SketchSelectionSection: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        PaletteSection("Auswahl", detail: summary) {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                if let index = sketch.selectedTextIndex {
                    // Gewählter Text: Inhalt, Schrift, Höhe, Winkel ändern (SketchTextPanel.swift)
                    SketchTextEditor(sketch: sketch, index: index)
                } else {
                    SelectionDimensionRows(sketch: sketch)
                }
                SelectionConstraintButtons(sketch: sketch)
                SelectionActions(sketch: sketch)
            }
        }
    }

    /// „2 Linien, 1 Punkt“
    private var summary: String {
        var counts: [(name: String, count: Int)] = []
        for ref in sketch.selection {
            let name = Self.name(of: ref, in: sketch.entities)
            if let index = counts.firstIndex(where: { $0.name == name }) {
                counts[index].count += 1
            } else {
                counts.append((name: name, count: 1))
            }
        }
        return counts.map { "\($0.count) \($0.count == 1 ? $0.name : Self.plural($0.name))" }.joined(separator: ", ")
    }

    private static func name(of ref: SketchRef, in entities: [SketchEntity]) -> String {
        guard case .curve(let curve) = ref else { return "Punkt" }
        guard entities.indices.contains(curve.entity) else { return "Element" }
        switch entities[curve.entity] {
        case .line, .rectangle, .polyline, .regularPolygon: return "Linie"
        case .arc: return "Bogen"
        case .circle: return "Kreis"
        case .ellipse: return "Ellipse"
        case .spline: return "Spline"
        case .text: return "Text"
        default: return "Element"
        }
    }

    private static func plural(_ name: String) -> String {
        switch name {
        case "Linie": "Linien"
        case "Punkt": "Punkte"
        case "Bogen": "Bögen"
        case "Kreis": "Kreise"
        case "Ellipse": "Ellipsen"
        case "Spline": "Splines"
        case "Text": "Texte"
        default: "Elemente"
        }
    }
}

/// Maße der Auswahl als Wertzeilen: Länge, Durchmesser, Radius, Abstand, Winkel. Eine Eingabe ändert das Element
/// bzw. legt das treibende Maß an (wie das Maßfeld im Viewport, `setDimension`).
private struct SelectionDimensionRows: View {
    @ObservedObject var sketch: SketchController

    private var rows: [SketchDimension] {
        let chosen = sketch.selectedEntities
        let constraints = sketch.constraints
        return sketch.dimensions.filter { dimension in
            guard dimension.isEditable else { return false }
            switch dimension.target {
            case .display:
                return false
            case .constraint(let index):
                return constraints.indices.contains(index) && !chosen.isDisjoint(with: constraints[index].entities)
            case .entity, .create:
                // Maße zur Auswahl tragen die Kennung „s…“ (selectionDimensions)
                return dimension.id.hasPrefix("s")
            }
        }
    }

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                ForEach(rows) { dimension in
                    SelectionDimensionRow(sketch: sketch, dimension: dimension)
                }
            }
        }
    }
}

private struct SelectionDimensionRow: View {
    @ObservedObject var sketch: SketchController
    let dimension: SketchDimension

    var body: some View {
        HStack(spacing: 2) {
            PaletteNumberRow(title: title, value: dimension.value, unit: dimension.kind == .angle ? "°" : "mm") { value in
                sketch.setDimension(id: dimension.id, to: value)
            }
            if let locked = dimension.lockState {
                Button {
                    sketch.toggleDimensionLock(id: dimension.id)
                } label: {
                    Image(systemName: locked ? "lock.fill" : "lock.open")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(locked ? Color.green : Color.secondary)
                        .frame(width: 32, height: PaletteStyle.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(locked ? "Maß lösen" : "Maß festlegen")
                .hoverTip(locked ? "Maß lösen" : "Maß festlegen",
                          locked ? "Das Element lässt sich danach frei verschieben." : "Hält den aktuellen Wert als Bemaßung fest.")
            }
        }
    }

    private var title: String {
        switch dimension.kind {
        case .width: "Breite"
        case .height: "Höhe"
        case .diameter: "Durchmesser"
        case .radius: "Radius"
        case .length: "Länge"
        case .distance: "Abstand"
        case .angle: "Winkel"
        }
    }
}

/// Bedingungen, die zur Auswahl passen (wie die blauen Symbole der Bedingungsspalte); Antippen setzt sie sofort.
private struct SelectionConstraintButtons: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        let kinds = ConstraintKind.allCases.filter { $0 != .dimension && $0 != .lock && sketch.canApply($0) }
        if !kinds.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Passende Bedingungen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                IconSegment(choices: kinds.map { IconChoice(id: $0.rawValue, title: $0.rawValue, icon: $0.systemImage) },
                            selected: []) { id in
                    if let kind = ConstraintKind(rawValue: id) { sketch.start(.constraint(kind)) }
                }
            }
        }
    }
}

/// Verankern/Lösen, Trennen, Konstruktion, Löschen.
private struct SelectionActions: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        VStack(spacing: PaletteStyle.spacing) {
            HStack(spacing: PaletteStyle.spacing) {
                PrimaryWideButton(title: sketch.isSelectionAnchored ? "Lösen" : "Fixieren",
                                  systemImage: sketch.isSelectionAnchored ? "lock.open" : "lock", isPrimary: false,
                                  isActive: sketch.isSelectionAnchored, action: sketch.toggleAnchor)
                    .hoverTip("Fixieren", "Gewählte Punkte bzw. Kurven bleiben stehen, wenn du Maße änderst. Sind sie schon fixiert, löst der Knopf sie wieder.")
                if sketch.selectionHasConstraints {
                    PrimaryWideButton(title: "Trennen", systemImage: "link.badge.plus", isPrimary: false) {
                        sketch.start(.detach)
                    }
                    .hoverTip("Trennen", "Bedingungen an der Auswahl lösen.")
                }
            }
            PrimaryWideButton(title: "Löschen", systemImage: "trash", isPrimary: false, action: sketch.deleteSelection)
        }
    }
}
