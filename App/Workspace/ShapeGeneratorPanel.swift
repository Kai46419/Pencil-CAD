import SwiftUI

// Formgenerator rechts in der Skizzenpalette: Bibliothek als Vorschau-Kacheln, eigene Formen (Kontextmenü:
// Umbenennen, Löschen), Werte der Form und „Auswahl als Form speichern“. Ersetzt den Abschnitt „Werkzeug“,
// solange der Formgenerator aktiv ist (SketchToolSection).

struct ShapeGeneratorSection: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var library: ShapeLibrary

    @State private var isNaming = false
    @State private var newName = ""
    @State private var renaming: UUID?
    @State private var renameText = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        PaletteSection("Formen", detail: sketch.generatedShape?.title, collapsible: false) {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                builtInGrid
                customGrid
                ShapeParameterFields(sketch: sketch)
                saveButton
                PaletteHint(text: hint)
            }
        }
        .alert("Eigene Form speichern", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Abbrechen", role: .cancel) {}
            Button("Speichern") { _ = sketch.saveSelectionAsShape(name: newName) }
        } message: {
            Text("Die gewählten Elemente erscheinen in der Bibliothek unter „Eigene“.")
        }
        .alert("Form umbenennen", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Abbrechen", role: .cancel) {}
            Button("Umbenennen") {
                if let id = renaming { library.rename(id, to: renameText) }
            }
        }
    }

    private var hint: String {
        if sketch.canEditPlacedShape {
            return "Die Werte ändern die gerade gesetzte Form. Nächste Form: wieder Mitte setzen und aufziehen."
        }
        return "Form antippen, dann im Viewport die Mitte setzen und aufziehen: Abstand = Größe, Richtung = Drehung."
    }

    // MARK: Bibliothek

    private var builtInGrid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(ShapePreset.all) { preset in
                ShapeTile(lines: ShapeGeometry.previewLines(preset), title: preset.title,
                          isSelected: sketch.generatedShape?.presetID == preset.id
                              && sketch.generatedShape?.kind == preset.kind) {
                    sketch.chooseShape(preset)
                }
            }
        }
    }

    @ViewBuilder private var customGrid: some View {
        Text("EIGENE")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
        if library.custom.isEmpty {
            Text("Noch keine – Elemente wählen und unten speichern.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(library.custom) { custom in
                    customTile(custom)
                }
            }
        }
    }

    private func customTile(_ custom: CustomShape) -> some View {
        ShapeTile(lines: ShapeGeometry.previewLines(custom), title: custom.name,
                  isSelected: sketch.generatedShape?.customID == custom.id) {
            sketch.chooseCustomShape(custom.id)
        }
        .contextMenu {
            Button {
                renameText = custom.name
                renaming = custom.id
            } label: {
                Label("Umbenennen", systemImage: "pencil")
            }
            Button(role: .destructive) {
                sketch.deleteCustomShape(custom.id)
            } label: {
                Label("Löschen", systemImage: "trash")
            }
        }
    }

    // MARK: Speichern

    private var saveButton: some View {
        let count = sketch.shapeSaveCandidates.count
        return VStack(alignment: .leading, spacing: 3) {
            PrimaryWideButton(title: "Als Form speichern", systemImage: "square.and.arrow.down", isPrimary: false) {
                newName = "Form \(library.custom.count + 1)"
                isNaming = true
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.45 : 1)
            Text(count == 0 ? "Erst mit dem Pfeil Elemente wählen." : "\(count) Elemente gewählt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Werte der gewählten Form: Größe, Zacken/Ecken, Innenradius bzw. Breite, Drehung.
private struct ShapeParameterFields: View {
    @ObservedObject var sketch: SketchController

    var body: some View {
        if let shape = sketch.generatedShape {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                PaletteNumberRow(title: "Größe (Ø)", value: shape.params.size) { value in
                    if value > 0 { sketch.updateGeneratedShape { $0.size = value } }
                }
                if let kind = shape.kind, let title = kind.countTitle {
                    CountRow(title: title, value: countBinding(kind), range: kind.countRange)
                }
                if let kind = shape.kind, let title = kind.innerTitle {
                    innerRow(kind, title: title, value: shape.params.inner)
                }
                PaletteNumberRow(title: "Drehung", value: shape.params.rotation, unit: "°") { value in
                    sketch.updateGeneratedShape { $0.rotation = value }
                }
            }
        }
    }

    private func countBinding(_ kind: ShapeKind) -> Binding<Int> {
        Binding(get: {
            let count = sketch.generatedShape?.params.count ?? kind.countRange.lowerBound
            return min(max(count, kind.countRange.lowerBound), kind.countRange.upperBound)
        }, set: { value in
            sketch.updateGeneratedShape { $0.count = value }
        })
    }

    private func innerRow(_ kind: ShapeKind, title: String, value: Double) -> some View {
        let range = kind.innerRange
        return PaletteNumberRow(title: title, value: (value * 1000).rounded() / 10, unit: "%") { percent in
            let ratio = min(max(percent / 100, range.lowerBound), range.upperBound)
            sketch.updateGeneratedShape { $0.inner = ratio }
        }
    }
}

/// Vorschau-Kachel einer Form (Umriss in der Kachel, gewählt mit Akzentrahmen).
private struct ShapeTile: View {
    let lines: [[Point2]]
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
        Button(action: action) {
            ShapeOutline(lines: lines)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .padding(7)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? PaletteStyle.activeFill : PaletteStyle.field, in: shape)
                .overlay {
                    shape.strokeBorder(isSelected ? Color.accentColor : PaletteStyle.controlBorder, lineWidth: 1)
                }
                .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(title)
    }
}

/// Umriss aus Polylinien mit Umkreisradius ≈ 1, eingepasst in das Rechteck (y nach oben).
private struct ShapeOutline: Shape {
    let lines: [[Point2]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = lines.flatMap { $0 }
        guard let first = points.first else { return path }
        var lo = first, hi = first
        for p in points {
            lo = Point2(min(lo.x, p.x), min(lo.y, p.y))
            hi = Point2(max(hi.x, p.x), max(hi.y, p.y))
        }
        let span = max(hi.x - lo.x, hi.y - lo.y, 1e-9)
        let scale = Double(min(rect.width, rect.height)) / span
        let center = (lo + hi) / 2
        func cg(_ p: Point2) -> CGPoint {
            CGPoint(x: rect.midX + CGFloat((p.x - center.x) * scale), y: rect.midY - CGFloat((p.y - center.y) * scale))
        }
        for line in lines where line.count >= 2 {
            path.move(to: cg(line[0]))
            for p in line.dropFirst() { path.addLine(to: cg(p)) }
        }
        return path
    }
}
