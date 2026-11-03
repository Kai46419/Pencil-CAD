import SwiftUI
import simd

// Sweep und Loft nach SolidCraft (MIT, dialogs.rs Sweep/Loft): Profil · Pfad (Körperkanten antippen oder Skizze mit
// offenen Kurven aus der Liste) · Operation bzw. Querschnitte in Tipp-Reihenfolge über mehrere Skizzen · Führungen
// (höchstens zwei) · Tangential · Operation. Gerechnet wird mit ModelStore.previewSweep bzw. previewLoft.

enum SweepCommand: ModelCommandDriver {
    static let id: ModelCommandID = .sweep
    static let title = "Sweep"
    static let icon = "sc.sweep"
    static var explanation: String? {
        "Profil (Skizzenbereich) antippen, dann den Pfad: Körperkanten antippen (wie „Folge mir“) oder eine Skizze "
            + "mit offenen Kurven aus der Liste wählen. Der Pfad sollte am Profil beginnen."
    }

    static func profilesInput() -> PickInput {
        PickInput(id: "profiles", title: "Profil", accepts: [.regions], multiple: true,
                  hint: "Skizzenbereiche antippen, die entlang des Pfads gezogen werden")
    }

    static func pathInput() -> PickInput {
        PickInput(id: "path", title: "Pfad", accepts: [.edges], multiple: true,
                  hint: "Zusammenhängende Körperkanten antippen – oder unten eine Pfad-Skizze wählen", isOptional: true)
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        var profiles = profilesInput()
        if let first = model.selectedRegions.first {
            profiles.items = model.selectedRegions.filter { $0.sketch == first.sketch }.map { Pick.region($0) }
        }
        let cmd = ModelCommand(.sweep, inputs: [profiles, pathInput()])
        cmd.choices["operation"] = ExtrudeMode.newBody.rawValue
        cmd.autoOperation = false
        defaultPath(cmd, model)
        ws.parts.sweepEdges = []
        ws.parts.sweepEdgeLines = []
        // Altes Werkzeug für die Anzeige der Pfadkanten und gegen den Extrudieren-Pfeil der Auswahl
        ws.tool = .sweep
        return cmd
    }

    /// Pfad-Skizze vorschlagen: die erste Skizze mit offenen Kurven außer der Profilskizze.
    static func defaultPath(_ cmd: ModelCommand, _ model: ModelStore) {
        guard cmd.choices["pathSketch"] == nil else { return }
        let profileSketch = ExtrudeCommand.regionRefs(cmd).first?.sketch
        if let index = model.pathSketches.first(where: { $0 != profileSketch }) {
            cmd.choices["pathSketch"] = String(index)
        }
    }

    static func pathSketch(_ cmd: ModelCommand) -> Int? {
        cmd.choices["pathSketch"].flatMap { Int($0) }
    }

    static func edges(_ cmd: ModelCommand) -> [EdgeRef] {
        cmd.items("path").compactMap { pick -> EdgeRef? in
            if case .edge(let edge) = pick { return edge }
            return nil
        }
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let regions = ExtrudeCommand.regionRefs(cmd)
        guard !regions.isEmpty else {
            model.dropPreview()
            model.resetSelection()
            return nil
        }
        model.selectRegions(regions)
        let edges = Self.edges(cmd)
        ws.parts.sweepEdges = edges
        ws.parts.sweepEdgeLines = edges.flatMap { model.edgePolylines($0) }
        let mode = CommandOperation.mode(cmd)
        model.message = nil
        if !edges.isEmpty {
            model.previewSweep(alongEdges: edges, mode: mode)
        } else if let path = pathSketch(cmd), model.sketches.indices.contains(path) {
            model.previewSweep(pathSketch: path, mode: mode)
        } else {
            model.dropPreview()
            return nil
        }
        return model.hasPreview ? nil : (model.message ?? "Sweep nicht möglich.")
    }

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        let model = ws.model
        if let region = tap.region {
            CommandGeometry.toggleRegion(region, in: cmd, inputID: "profiles")
            if pathSketch(cmd) == region.sketch { cmd.choices["pathSketch"] = nil }
            defaultPath(cmd, model)
            cmd.error = nil
            ws.refreshCommandPreview()
            return true
        }
        guard let edge = tap.edge, let index = cmd.inputIndex("path") else { return false }
        if model.hasPreview, CommandOperation.mode(cmd) != .newBody {
            // Die Vorschau hat den Körper verändert (andere Kantennummern): erst ohne Vorschau wählen
            model.dropPreview()
            model.message = "Kante bitte noch einmal antippen."
            return true
        }
        var items = cmd.inputs[index].items
        if let first = edges(cmd).first, first.body != edge.body { items = [] }
        if let existing = items.firstIndex(of: .edge(edge)) {
            items.remove(at: existing)
        } else {
            items.append(.edge(edge))
        }
        cmd.inputs[index].items = items
        cmd.activeInput = index
        cmd.error = nil
        ws.refreshCommandPreview()
        return true
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.commitPreview()
        clearEdges(ws)
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        clearEdges(ws)
    }

    private static func clearEdges(_ ws: Workspace) {
        ws.parts.sweepEdges = []
        ws.parts.sweepEdgeLines = []
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SweepRows(cmd: cmd, ws: ws, model: ws.model))
    }
}

private struct SweepRows: View {
    @ObservedObject var cmd: ModelCommand
    let ws: Workspace
    @ObservedObject var model: ModelStore

    private var pathTitle: String {
        if !SweepCommand.edges(cmd).isEmpty { return "Körperkanten" }
        guard let index = SweepCommand.pathSketch(cmd), model.sketches.indices.contains(index) else { return "Keine" }
        return model.sketches[index].name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelMenuRow(title: "Pfad-Skizze", value: pathTitle) {
                ForEach(model.pathSketches, id: \.self) { index in
                    Button(model.sketches[index].name) {
                        cmd.choices["pathSketch"] = String(index)
                        cmd.setItems("path", [])
                        ws.refreshCommandPreview()
                    }
                }
                Button("Keine") {
                    cmd.choices["pathSketch"] = ""
                    ws.refreshCommandPreview()
                }
            }
            if model.pathSketches.isEmpty, SweepCommand.edges(cmd).isEmpty {
                PaletteHint(text: "Keine Skizze mit offenen Kurven – Pfad als Körperkanten antippen oder skizzieren.")
            }
            CommandOperation.row(cmd, ws)
        }
    }
}

// MARK: - Loft

enum LoftCommand: ModelCommandDriver {
    static let id: ModelCommandID = .loft
    static let title = "Loft"
    static let icon = "sc.loft"
    static var explanation: String? {
        "Querschnitte nacheinander antippen, je Skizze einen – die Reihenfolge bestimmt den Verlauf. Führungen "
            + "(offene Skizzenkurven) leiten den Loft, die zweite steuert die Verdrehung."
    }

    static func profilesInput() -> PickInput {
        PickInput(id: "profiles", title: "Querschnitte", accepts: [.regions], multiple: true,
                  hint: "Querschnitte nacheinander antippen (mindestens zwei, je Skizze einen)")
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        var profiles = profilesInput()
        profiles.items = ws.model.selectedRegions.map { Pick.region($0) }
        let cmd = ModelCommand(.loft, inputs: [profiles])
        cmd.choices["operation"] = ExtrudeMode.newBody.rawValue
        cmd.autoOperation = false
        // Führungen gelten nur für einen Loft (Skizzennummern können sich inzwischen verschoben haben)
        ws.loft.guides = []
        ws.tool = .loft
        return cmd
    }

    /// Querschnitte in Tipp-Reihenfolge (über mehrere Skizzen)
    static func sections(_ cmd: ModelCommand) -> [RegionRef] {
        cmd.items("profiles").compactMap { pick -> RegionRef? in
            if case .region(let ref) = pick { return ref }
            return nil
        }
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let sections = Self.sections(cmd)
        guard !sections.isEmpty else {
            model.dropPreview()
            model.resetSelection()
            return nil
        }
        model.selectRegions(sections)
        guard sections.count >= 2 else {
            model.dropPreview()
            return nil
        }
        model.message = nil
        model.previewLoft(mode: CommandOperation.mode(cmd), settings: ws.loft)
        guard model.hasPreview else { return model.message ?? "Loft nicht möglich." }
        // Hinweise des Lofts (z. B. „ohne Führung berechnet“) bleiben als Meldung stehen
        return nil
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        sections(cmd).count >= 2 && cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.commitPreview()
        ws.loft.guides = []
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.loft.guides = []
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(LoftRows(cmd: cmd, ws: ws, model: ws.model))
    }
}

private struct LoftRows: View {
    @ObservedObject var cmd: ModelCommand
    @ObservedObject var ws: Workspace
    @ObservedObject var model: ModelStore

    private static let guideSymbol = "point.topleft.down.to.point.bottomright.curvepath"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let count = LoftCommand.sections(cmd).count
            if count == 1 {
                PaletteHint(text: "Noch mindestens einen Querschnitt in einer anderen Skizze antippen.")
            }
            Text("Führungen")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(ws.loft.guides.enumerated()), id: \.element.id) { number, guide in
                guideRow(guide, number: number)
            }
            if ws.loft.guides.count < LoftSettings.maxGuides, !model.pathSketches.isEmpty {
                addMenu
            } else if model.pathSketches.isEmpty {
                PaletteHint(text: "Für Führungen eine Skizze mit offenen Kurven anlegen.")
            }
            CheckRow(title: "Start tangential", isOn: loftBinding(\.tangentStart))
            CheckRow(title: "Ende tangential", isOn: loftBinding(\.tangentEnd))
            CommandOperation.row(cmd, ws)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(model.pathSketches, id: \.self) { index in
                Section(model.sketches[index].name) {
                    Button("Alle offenen Kurven", systemImage: Self.guideSymbol) {
                        add(LoftGuide(sketch: index))
                    }
                    ForEach(model.loftGuideCandidates(inSketch: index)) { candidate in
                        Button(candidate.title) {
                            add(LoftGuide(sketch: index, entities: [candidate.entity]))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Text("Führung hinzufügen")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(SketchTheme.accent)
            .frame(maxWidth: .infinity, minHeight: PaletteStyle.touch, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private func guideRow(_ guide: LoftGuide, number: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: number == 0 ? Self.guideSymbol : "arrow.triangle.2.circlepath")
                .foregroundStyle(SketchTheme.accent)
            Text(model.loftGuideTitle(guide))
                .font(.callout)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Button {
                ws.loft.guides.removeAll { $0 == guide }
                ws.refreshCommandPreview()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: PaletteStyle.touch, height: PaletteStyle.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Führung entfernen")
        }
        .padding(.leading, 10)
        .frame(minHeight: PaletteStyle.touch)
        .background(PaletteStyle.field, in: RoundedRectangle(cornerRadius: PaletteStyle.controlRadius, style: .continuous))
        .hoverTip(number == 0 ? "Leitkurve" : "Hilfsleitkurve (Verdrehung)")
    }

    private func add(_ guide: LoftGuide) {
        guard !ws.loft.guides.contains(guide), ws.loft.guides.count < LoftSettings.maxGuides else { return }
        ws.loft.guides.append(guide)
        ws.refreshCommandPreview()
    }

    private func loftBinding(_ keyPath: WritableKeyPath<LoftSettings, Bool>) -> Binding<Bool> {
        Binding(get: { ws.loft[keyPath: keyPath] }, set: { value in
            ws.loft[keyPath: keyPath] = value
            ws.refreshCommandPreview()
        })
    }
}
