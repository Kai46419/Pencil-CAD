import SwiftUI

// Rechte Skizzenpalette nach SolidCraft (crates/ui-egui/src/sketch_palette.rs, docs/design/ux-redesign/sketch.png):
// Kai: „Werkzeug angeklickt, und auf der rechten Seite kommen die Eigenschaften der Werkzeuge zu stehen.“
// SolidCraft verteilt Palette (rechts) und Befehlsfenster (links); auf dem iPad liegt beides in einem Panel.
// Aufbau: Kopf (Skizze, Freiheitsgrade, Balken) · Werkzeug bzw. Auswahl · Linientyp · Schalter · Mehr ·
// fester Fuß („Skizze beenden“, „Ausrichten“, „Schnitt“). Die Mitte scrollt, Kopf und Fuß bleiben stehen.

/// Das eine schlanke Fenster rechts im Skizzenmodus (Kai): oben Ansichtswürfel, Fang „U“ und die Ansichtsknöpfe
/// der früheren Säule RightRail, darunter die Eigenschaften von Werkzeug bzw. Auswahl und der feste Fuß.
struct SketchPalette: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController
    @Binding var panel: SidePanel?
    let screenshot: () -> Void

    var body: some View {
        PaletteWindow {
            PaletteViewControls(workspace: workspace, sketch: sketch, panel: $panel, screenshot: screenshot)
        } header: {
            PaletteHeader(workspace: workspace, model: model, sketch: sketch)
        } middle: {
            middle
        } footer: {
            PaletteFooter(workspace: workspace, sketch: sketch)
        }
    }

    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if sketch.isChoosingPlane {
                PlaneChoiceSection(workspace: workspace, model: model)
            } else {
                if !sketch.plane.isOnFace && sketch.isEmpty {
                    PlaneOptionsSection(workspace: workspace, sketch: sketch)
                    PaletteRule()
                }
                if sketch.pendingAction != nil || sketch.tool != .select {
                    SketchToolSection(sketch: sketch, options: sketch.options)
                    PaletteRule()
                } else if !sketch.selection.isEmpty {
                    SketchSelectionSection(sketch: sketch)
                    PaletteRule()
                }
                LineTypeSection(sketch: sketch, options: sketch.options)
                PaletteRule()
                PaletteToggles(sketch: sketch, options: sketch.options)
                PaletteRule()
                PaletteMoreSection(sketch: sketch, options: sketch.options)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Kopf

/// Skizzenname, Ebene, Freiheitsgrade mit Balken (SolidCraft `sketch_palette.rs:376-393`).
private struct PaletteHeader: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ToolIcon("sc.sketch", size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sketchName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(sketch.isChoosingPlane ? "Ebene wählen" : planeName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !sketch.isChoosingPlane {
                DegreesOfFreedomView(dof: sketch.paletteDOF)
            }
        }
    }

    private var sketchName: String {
        if let index = workspace.editingSketchIndex, model.sketches.indices.contains(index) {
            return model.sketches[index].name
        }
        return "Skizze \(model.sketches.count + 1)"
    }

    private var planeName: String {
        guard !sketch.plane.isOnFace else { return "Fläche" }
        return BasePlane.allCases.first { $0.normal == sketch.plane.normal }?.rawValue ?? "Ebene"
    }
}

/// Statuszeile und Balken: Anteil bestimmter Freiheitsgrade (6 pt hoch).
private struct DegreesOfFreedomView: View {
    let dof: (remaining: Int, total: Int, ok: Bool)

    private var color: Color {
        if !dof.ok { return .red }
        if dof.total > 0, dof.remaining == 0 { return .green }
        return .accentColor
    }

    private var status: String {
        if !dof.ok { return "Widerspruch" }
        if dof.total == 0 { return "Noch leer" }
        if dof.remaining == 0 { return "Voll bestimmt" }
        return dof.remaining == 1 ? "1 Freiheitsgrad" : "\(dof.remaining) Freiheitsgrade"
    }

    private var fraction: CGFloat {
        guard dof.total > 0 else { return 0 }
        return CGFloat(dof.total - dof.remaining) / CGFloat(dof.total)
    }

    var body: some View {
        let barWidth = PaletteStyle.contentWidth
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(dof.ok && dof.remaining == 0 && dof.total > 0 ? Color.green : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * barWidth)
            }
            .frame(width: barWidth, height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status)
    }
}

// MARK: Ebene

/// Ebenenwahl (bisher Kacheln unten in der Mitte): Standardebenen, eigene Konstruktionsebenen oder Körperfläche.
private struct PlaneChoiceSection: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        PaletteSection("Skizzieren auf", collapsible: false) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach([BasePlane.top, .front, .right]) { side in
                        tile(side.rawValue, systemImage: Self.symbol(side)) { workspace.chooseSketchPlane(side) }
                    }
                    ForEach(model.constructions.filter { $0.kind == .plane && !$0.isHidden }) { item in
                        tile(item.name, systemImage: "square.dashed") { workspace.chooseSketchPlane(item.sketchPlane) }
                    }
                }
                PaletteHint(text: "oder eine ebene Körperfläche antippen")
            }
        }
    }

    private static func symbol(_ side: BasePlane) -> String {
        switch side {
        case .top, .bottom: "square.split.bottomrightquarter"
        case .front, .back: "square.bottomhalf.filled"
        case .right, .left: "square.righthalf.filled"
        }
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous)
                    .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .hoverTip(title, "Neue Skizze auf dieser Ebene beginnen.")
    }
}

/// Leere Skizze auf einer Standardebene: Ebene wechseln und Abstand vom Ursprung.
private struct PlaneOptionsSection: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController

    var body: some View {
        PaletteSection("Ebene", detail: nil, collapsible: true, expanded: false) {
            VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
                Menu {
                    ForEach(BasePlane.allCases) { side in
                        Button(side.rawValue) { workspace.chooseSketchPlane(side) }
                    }
                } label: {
                    HStack {
                        Label(sketch.plane.name, systemImage: "square.dashed")
                            .font(.footnote)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: PaletteStyle.touch)
                    .contentShape(Rectangle())
                }
                PaletteNumberRow(title: "Abstand", value: sketch.planeOffset) { sketch.planeOffset = $0 }
            }
        }
    }
}

// MARK: Linientyp

/// Normal, Konstruktion, Mittellinie, Unendlich (SolidCraft `sketch_palette.rs:431-452`). Mit Auswahl zeigen die
/// Knöpfe die Typen der gewählten Kurven und wandeln sie um, ohne Auswahl den Zeichenmodus.
private struct LineTypeSection: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        PaletteSection("Linientyp", collapsible: false) {
            VStack(alignment: .leading, spacing: 4) {
                IconSegment(choices: choices, selected: selected, columnCount: 2, pick: pick)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasSelection: Bool { !sketch.selection.isEmpty }

    private var choices: [IconChoice] {
        let chosen = sketch.selectedEntities
        let allConstruction = chosen.isSubset(of: sketch.construction)
        return SketchLineType.allCases.map { type -> IconChoice in
            let enabled: Bool
            if hasSelection {
                // Umwandeln kann die Skizze bisher nur zwischen Normal und Konstruktion
                // Mittellinie/Unendlich gelten nur für neue Elemente
                switch type {
                case .normal: enabled = allConstruction
                case .construction: enabled = !allConstruction
                default: enabled = false
                }
            } else {
                enabled = true
            }
            return IconChoice(id: type.rawValue, title: type.rawValue, icon: Self.icon(type), isEnabled: enabled)
        }
    }

    private var selected: Set<String> {
        if hasSelection {
            var types: Set<String> = []
            for index in sketch.selectedEntities {
                types.insert(sketch.construction.contains(index) ? SketchLineType.construction.rawValue
                             : SketchLineType.normal.rawValue)
            }
            return types
        }
        return [drawingType.rawValue]
    }

    /// Zeichenmodus; der bisherige Schalter `constructionMode` bleibt maßgeblich für das Zeichnen.
    private var drawingType: SketchLineType {
        if sketch.constructionMode {
            return options.lineType == .normal ? .construction : options.lineType
        }
        return options.lineType == .construction ? .normal : options.lineType
    }

    private var caption: String {
        if hasSelection {
            return selected.sorted().joined(separator: ", ")
        }
        return "Zeichnen: \(drawingType.rawValue)"
    }

    private func pick(_ id: String) {
        guard let type = SketchLineType(rawValue: id) else { return }
        if hasSelection {
            let allConstruction = sketch.selectedEntities.isSubset(of: sketch.construction)
            if (type == .construction && !allConstruction) || (type == .normal && allConstruction) {
                sketch.toggleConstruction()
            }
        } else {
            options.lineType = type
            // Nicht-normale Linientypen zählen wie Konstruktion (kein Profil)
            sketch.constructionMode = type != .normal
        }
    }

    private static func icon(_ type: SketchLineType) -> String {
        switch type {
        case .normal: "line.diagonal"
        case .construction: "sc.construction"
        case .centerline: "line.3.horizontal"
        case .infinite: "infinity"
        }
    }
}

// MARK: Schalter

/// Häufige Schalter als kompakte Zeilen, darunter der Konstruktionsmodus (SolidCraft `:453-465`). Eine Spalte:
/// zu zweit nebeneinander brächen die Namen im schmalen Fenster um. Fang schaltet das „U“ oben.
private struct PaletteToggles: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CheckRow(title: "Bedingungen", isOn: $sketch.showsConstraintBadges)
            CheckRow(title: "Bemaßungen", isOn: $sketch.showsDimensions)
            CheckRow(title: "Punkte", isOn: $sketch.showsPoints)
            CheckRow(title: "Konstruktion (X)", icon: "sc.construction",
                     isOn: Binding(get: { sketch.constructionMode }, set: { on in
                         sketch.constructionMode = on
                         options.lineType = on ? .construction : .normal
                     }))
        }
    }
}

/// „Mehr“ (zugeklappt): Raster, Profil, Konstruktion, Schloss-Anzeige, Haptik, Eingabestil.
private struct PaletteMoreSection: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    var body: some View {
        PaletteSection("Mehr", expanded: false) {
            VStack(alignment: .leading, spacing: 0) {
                CheckRow(title: "Raster", icon: "grid", isOn: $sketch.showsGrid)
                CheckRow(title: "Raster 1-2-5", icon: "square.grid.3x3", isOn: $options.gridAuto)
                CheckRow(title: "Bereiche", icon: "square.fill.on.square", isOn: $sketch.showsProfiles)
                CheckRow(title: "Hilfslinien", icon: "square.dashed", isOn: $sketch.showsConstruction)
                CheckRow(title: "Maße als Schloss", icon: "lock", isOn: $sketch.collapsesLockedDimensions)
                CheckRow(title: "Bestimmtheit", icon: "checkmark.seal", isOn: $sketch.showsDefinition)
                CheckRow(title: "Auto-Bedingungen", icon: "wand.and.rays", isOn: $sketch.autoConstrain)
                PaletteRule()
                    .padding(.vertical, 4)
                // Haptik des Stifts bleibt (Kai); die Schalter lagen bisher im Fang-Menü
                CheckRow(title: "Haptik Zeichnen", icon: "hand.tap", isOn: $sketch.drawHaptics)
                CheckRow(title: "Haptik Fang", icon: "hand.tap.fill", isOn: $sketch.snapHaptics)
                PaletteRule()
                    .padding(.vertical, 4)
                Text("Eingabestil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                VStack(spacing: 4) {
                    ForEach(SketchInputStyle.allCases) { style in
                        PrimaryWideButton(title: style.rawValue, isPrimary: false, isActive: options.inputStyle == style) {
                            options.inputStyle = style
                        }
                    }
                }
                Text(options.isSolidCraft ? "Antippen setzt Punkte, die Vorschau folgt dem Stift."
                     : "Striche wie bisher (Shapr3D-Gesten).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: Fuß

/// Fester Fuß: „Skizze beenden“, darunter „Ausrichten“ und „Schnitt“ nur als Symbol (SolidCraft `:477-495`).
private struct PaletteFooter: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var sketch: SketchController

    var body: some View {
        VStack(spacing: PaletteStyle.spacing) {
            PrimaryWideButton(title: "Skizze beenden", systemImage: "checkmark") {
                workspace.finishSketch()
            }
            .hoverTip("Skizze beenden", "Skizze speichern und zurück in den 3D-Modus.")
            HStack(spacing: PaletteStyle.spacing) {
                PrimaryWideButton(title: "Ausrichten", systemImage: "cube.transparent", isPrimary: false, showsTitle: false) {
                    workspace.send(.alignToSketchPlane)
                }
                .disabled(sketch.isChoosingPlane)
                .opacity(sketch.isChoosingPlane ? 0.45 : 1)
                .hoverTip("Ausrichten", "Blick senkrecht auf die Skizzenebene.")
                PrimaryWideButton(title: "Schnitt", systemImage: "square.split.diagonal.2x2", isPrimary: false,
                                  isActive: workspace.sketchSection, showsTitle: false) {
                    workspace.sketchSection.toggle()
                }
                .hoverTip("Schnitt", "Körper vor der Skizzenebene ausblenden.")
            }
        }
    }
}
