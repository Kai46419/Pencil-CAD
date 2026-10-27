import SwiftUI

// Rechte Skizzenpalette nach SolidCraft (crates/ui-egui/src/sketch_palette.rs, docs/design/ux-redesign/sketch.png):
// Kai: „Werkzeug angeklickt, und auf der rechten Seite kommen die Eigenschaften der Werkzeuge zu stehen.“
// SolidCraft verteilt Palette (rechts) und Befehlsfenster (links); auf dem iPad liegt beides in einem Panel.
// Aufbau: Kopf (Skizze, Freiheitsgrade, Balken) · Werkzeug bzw. Auswahl · Linientyp · Schalter · Mehr ·
// fester Fuß („Skizze beenden“, „Ausrichten“, „Schnitt“). Die Mitte scrollt, Kopf und Fuß bleiben stehen.

/// Eigenschaften-Panel im Skizzenmodus (rechts neben der Ansichtssäule).
struct SketchPalette: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var sketch: SketchController

    /// Höhe des scrollbaren Mittelteils; kurze Inhalte machen das Panel nicht unnötig hoch
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            PaletteHeader(workspace: workspace, model: model, sketch: sketch)
                .padding(12)
                .background(PaletteStyle.header)
            PaletteRule()
            ScrollView(showsIndicators: true) {
                middle
                    .padding(12)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: PaletteContentHeightKey.self, value: proxy.size.height)
                        }
                    }
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(maxHeight: contentHeight)
            .onPreferenceChange(PaletteContentHeightKey.self) { contentHeight = $0 }
            PaletteRule()
            PaletteFooter(workspace: workspace, sketch: sketch)
                .padding(12)
                .background(PaletteStyle.header)
        }
        .frame(width: PaletteStyle.width)
        .background(PaletteStyle.background)
        .clipShape(RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PaletteStyle.radius, style: .continuous)
                .strokeBorder(PaletteStyle.controlBorder, lineWidth: 1)
        }
        .elevationShadow(.floating)
        // Die Skizze ist dunkel (Anthrazit): Text, Systemfarben und die „sc.*-dark“-Bilder passend dazu
        .environment(\.colorScheme, .dark)
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

private struct PaletteContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
            HStack(spacing: 10) {
                ToolIcon("sc.sketch", size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sketchName)
                        .font(.headline)
                        .lineLimit(1)
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
        if !dof.ok { return "Bedingungen widersprechen sich" }
        if dof.total == 0 { return "Noch keine Geometrie" }
        if dof.remaining == 0 { return "Vollständig bestimmt" }
        return dof.remaining == 1 ? "1 Freiheitsgrad übrig" : "\(dof.remaining) Freiheitsgrade übrig"
    }

    private var fraction: CGFloat {
        guard dof.total > 0 else { return 0 }
        return CGFloat(dof.total - dof.remaining) / CGFloat(dof.total)
    }

    var body: some View {
        let barWidth = PaletteStyle.width - 24
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(status)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(dof.ok && dof.remaining == 0 && dof.total > 0 ? Color.green : Color.primary)
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        PaletteSection("Skizzieren auf", collapsible: false) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 6) {
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
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
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
                        Label("Ebene: \(sketch.plane.name)", systemImage: "square.dashed")
                            .font(.callout)
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
                IconSegment(choices: choices, selected: selected, pick: pick)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

/// Häufige Schalter in zwei Spalten, darunter der Konstruktionsmodus (SolidCraft `:453-465`).
private struct PaletteToggles: View {
    @ObservedObject var sketch: SketchController
    @ObservedObject var options: SketchToolOptions

    private let columns = [GridItem(.flexible(), spacing: 6, alignment: .leading),
                           GridItem(.flexible(), spacing: 6, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                CheckRow(title: "Bedingungen", isOn: $sketch.showsConstraintBadges)
                CheckRow(title: "Bemaßungen", isOn: $sketch.showsDimensions)
                CheckRow(title: "Punkte", isOn: $sketch.showsPoints)
                CheckRow(title: "Fang", isOn: $sketch.snapEnabled)
            }
            CheckRow(title: "Konstruktionsmodus (X)", icon: "sc.construction",
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
                CheckRow(title: "Skizzierraster", icon: "grid", isOn: $sketch.showsGrid)
                CheckRow(title: "Raster automatisch (1-2-5)", icon: "square.grid.3x3", isOn: $options.gridAuto)
                CheckRow(title: "Profil (Bereiche)", icon: "square.fill.on.square", isOn: $sketch.showsProfiles)
                CheckRow(title: "Konstruktionsgeometrie", icon: "square.dashed", isOn: $sketch.showsConstruction)
                CheckRow(title: "Feste Maße als Schloss", icon: "lock", isOn: $sketch.collapsesLockedDimensions)
                CheckRow(title: "Bestimmtheit (grün = fest)", icon: "checkmark.seal", isOn: $sketch.showsDefinition)
                CheckRow(title: "Automatisch einschränken", icon: "wand.and.rays", isOn: $sketch.autoConstrain)
                PaletteRule()
                    .padding(.vertical, 4)
                // Haptik des Stifts bleibt (Kai); die Schalter lagen bisher im Fang-Menü
                CheckRow(title: "Haptik beim Zeichnen", icon: "hand.tap", isOn: $sketch.drawHaptics)
                CheckRow(title: "Fühlbares Einrasten", icon: "hand.tap.fill", isOn: $sketch.snapHaptics)
                PaletteRule()
                    .padding(.vertical, 4)
                Text("Eingabestil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                HStack(spacing: PaletteStyle.spacing) {
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
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: Fuß

/// Fester Fuß: „Skizze beenden“, darunter „Ausrichten“ und „Schnitt“ (SolidCraft `:477-495`).
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
                PrimaryWideButton(title: "Ausrichten", systemImage: "cube.transparent", isPrimary: false) {
                    workspace.send(.alignToSketchPlane)
                }
                .disabled(sketch.isChoosingPlane)
                .opacity(sketch.isChoosingPlane ? 0.45 : 1)
                .hoverTip("Ausrichten", "Blick senkrecht auf die Skizzenebene.")
                PrimaryWideButton(title: "Schnitt", systemImage: "square.split.diagonal.2x2", isPrimary: false,
                                  isActive: workspace.sketchSection) {
                    workspace.sketchSection.toggle()
                }
                .hoverTip("Schnitt", "Körper vor der Skizzenebene ausblenden.")
            }
        }
    }
}
