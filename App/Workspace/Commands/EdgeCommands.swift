import SwiftUI
import simd

// ÄNDERN › KANTEN: Abrunden und Fasen nach SolidCraft (dialogs_dense.rs:344-483). Rechnen über
// ModelStore.setEdgeValue/setEdgeSecondValue/setEdgeEndValue; ★ eine vorhandene Rundung bzw. Fase antippen
// übernimmt ihren Wert (statt ihre Kanten zu wählen).

/// Gemeinsamer Ablauf von Abrunden und Fasen.
@MainActor
enum EdgeBlendCommand {
    static func valueKey(_ operation: EdgeOperation) -> String {
        operation == .fillet ? "radius" : "distance"
    }

    static func build(_ operation: EdgeOperation, id: ModelCommandID, _ ws: Workspace) -> ModelCommand {
        let model = ws.model
        let pre = Preselection(model)
        ws.startEdgeOperation(operation)
        // Eine Fläche darf nur im ausdrücklich gewählten Flächenmodus alle Kanten liefern.
        let items: [Pick] = pre.edges.isEmpty ? pre.facePicks : pre.edges.map { Pick.edge($0) }
        let initialScope = operation == .fillet && pre.edges.isEmpty && !pre.facePicks.isEmpty ? "face" : "edge"
        let accepts: PickKinds = operation == .fillet ? pickKinds(for: initialScope) : [.edges, .faces]
        let input = PickInput(id: "edges", title: "Kanten", accepts: accepts, multiple: true, items: items,
                              hint: "Kanten antippen (im Modus Fläche nimmt eine Fläche alle ihre Kanten). Eine vorhandene "
                                  + (operation == .fillet ? "Rundung" : "Fase") + " antippen übernimmt ihren Wert.")
        let cmd = ModelCommand(id, inputs: [input])
        let current = model.edgeOperation == operation && model.edgeValue > 0 ? model.edgeValue : nil
        cmd.putNumber(valueKey(operation), current ?? (operation == .fillet ? 2 : 1))
        if operation == .fillet {
            // Ein Antippen verändert zunächst nur die getroffene Kante. Die ganze
            // Flächenkontur kann im Panel ausdrücklich gewählt werden.
            cmd.choices["selectionScope"] = initialScope
            cmd.flags["variable"] = false
            cmd.flags["partial"] = false
            cmd.putNumber("startPercent", 20)
            cmd.putNumber("stopPercent", 80)
            cmd.choices["continuity"] = "g1"
            cmd.choices["measurement"] = "radius"
        } else {
            cmd.choices["selectionScope"] = "edge"
            cmd.choices["type"] = "equal"
            cmd.putNumber("angle", 45)
        }
        return cmd
    }

    private static func pickKinds(for scope: String) -> PickKinds {
        scope == "face" ? [.faces] : [.edges]
    }

    static func setFilletSelectionScope(_ scope: String, _ cmd: ModelCommand, _ ws: Workspace) {
        cmd.choices["selectionScope"] = scope
        if let index = cmd.inputs.firstIndex(where: { $0.id == "edges" }) {
            cmd.inputs[index].accepts = pickKinds(for: scope)
        }
        CommandPicks.setItems([], cmd, "edges")
        ws.model.dropPreview()
        CommandCache.refreshNow(cmd, ws)
    }

    /// Wählt die tangentiale Kantenkette oder den zusammenhängenden Rand einer Körperfläche.
    /// Beides verwendet BRep-Kanten und keine darüberliegende Skizzenlinie.
    static func tapped(_ operation: EdgeOperation, _ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        let scope = cmd.choice("selectionScope", default: "edge")
        guard let edge = tap.edge,
              scope == "tangent" || scope == "contour",
              ws.model.bodies.indices.contains(edge.body) else { return false }
        let shape = ws.model.bodies[edge.body].shape
        let numbers: [NSNumber]
        if scope == "tangent" {
            numbers = shape.tangentEdges(startingAt: edge.edge)
        } else {
            let preferred = tap.face.flatMap { face -> Int? in
                guard face.body == edge.body, ws.model.plane(of: face) != nil,
                      shape.edgeNumbers(ofFace: face.face).contains(where: { $0.intValue == edge.edge }) else { return nil }
                return face.face
            }
            let face: Int? = preferred ?? {
                guard shape.faceCount > 0, shape.faceCount < 5000 else { return nil }
                return (1...shape.faceCount).filter { number in
                    ws.model.plane(of: FaceRef(body: edge.body, face: number)) != nil
                        && shape.edgeNumbers(ofFace: number).contains(where: { $0.intValue == edge.edge })
                }.max { shape.area(ofFace: $0) < shape.area(ofFace: $1) }
            }()
            guard let face else { return false }
            numbers = shape.connectedEdges(ofFace: face, startingAt: edge.edge)
        }
        let group = numbers.map { EdgeRef(body: edge.body, edge: $0.intValue) }
        guard !group.isEmpty else { return false }
        var selected = cmd.items("edges").compactMap { pick -> EdgeRef? in
            if case .edge(let item) = pick, item.body == edge.body { return item }
            return nil
        }
        if group.allSatisfy(selected.contains) {
            selected.removeAll { group.contains($0) }
        } else {
            for item in group where !selected.contains(item) { selected.append(item) }
        }
        CommandPicks.setItems(selected.map(Pick.edge), cmd, "edges")
        cmd.error = nil
        ws.refreshCommandPreview()
        return true
    }

    /// Wert einer angetippten Rundungs- bzw. Fasenfläche (nil = keine solche Fläche bzw. andere Art).
    private static func blendValue(_ face: FaceRef, _ operation: EdgeOperation, _ model: ModelStore) -> Double? {
        let shown = model.shownBodies
        guard shown.indices.contains(face.body),
              let values = shown[face.body].shape.blend(ofFace: face.face)?.map(\.doubleValue),
              values.count == 2, values[1] > 1e-6 else { return nil }
        let isFillet = values[0] == 1
        guard isFillet == (operation == .fillet) else { return nil }
        return (values[1] * 100).rounded() / 100
    }

    /// ★ Angetippte Rundung übernehmen: Wert setzen, Fläche aus dem Kantenfeld nehmen.
    private static func adoptBlends(_ operation: EdgeOperation, _ cmd: ModelCommand, _ model: ModelStore) {
        var kept: [Pick] = []
        var adopted: Double?
        for pick in cmd.items("edges") {
            if case .face(let face) = pick, let value = blendValue(face, operation, model) {
                adopted = value
            } else {
                kept.append(pick)
            }
        }
        guard let adopted else { return }
        CommandPicks.setItems(kept, cmd, "edges")
        cmd.putNumber(valueKey(operation), adopted)
        if operation == .fillet { cmd.choices["measurement"] = "radius" }
        model.message = "\(operation == .fillet ? "Radius" : "Fase") übernommen: \(LengthUnit.current.format(adopted))"
    }

    /// Sehnenbreite einer kreisförmigen Rundung zwischen zwei ebenen Flächen.
    /// Für gekrümmte Nachbarflächen gibt es keinen eindeutigen Normalenwinkel.
    static func chordFactor(_ edges: [EdgeRef], model: ModelStore) -> Double? {
        guard !edges.isEmpty else { return nil }
        let grouped = Dictionary(grouping: edges, by: \.body)
        var common: Double?
        for (body, bodyEdges) in grouped {
            guard model.bodies.indices.contains(body) else { return nil }
            let shape = model.bodies[body].shape
            guard shape.faceCount > 0 else { return nil }
            let wanted = Set(bodyEdges.map(\.edge))
            var normalsByEdge: [Int: [SIMD3<Double>]] = [:]
            for faceNumber in 1...shape.faceCount {
                let matches = Set(shape.edgeNumbers(ofFace: faceNumber).map(\.intValue)).intersection(wanted)
                guard !matches.isEmpty else { continue }
                guard let plane = model.plane(of: FaceRef(body: body, face: faceNumber)) else { return nil }
                for edgeNumber in matches { normalsByEdge[edgeNumber, default: []].append(plane.normal) }
            }
            for edge in bodyEdges {
                guard let normals = normalsByEdge[edge.edge], normals.count == 2 else { return nil }
                let cosine = max(-1.0, min(1.0, simd_dot(normals[0], normals[1])))
                let factor = 2 * sin(acos(cosine) / 2)
                guard factor.isFinite, factor > 1e-4 else { return nil }
                if let common, abs(common - factor) > 1e-4 { return nil }
                common = factor
            }
        }
        return common
    }

    /// Beim Ziehen des Pfeils bleibt die Geometrie unverändert; der Flächenwinkel muss nur
    /// nach einer neuen Kantenauswahl erneut gelesen werden.
    static func cachedChordFactor(_ edges: [EdgeRef], _ cmd: ModelCommand, model: ModelStore) -> Double? {
        guard !edges.isEmpty else { return nil }
        let key = edges.map { edge in
            let shape = model.bodies.indices.contains(edge.body) ? String(describing: ObjectIdentifier(model.bodies[edge.body].shape)) : "?"
            return "\(edge.body):\(edge.edge):\(shape)"
        }.sorted().joined(separator: "|")
        if cmd.choice("chordSelection", default: "") == key,
           let saved = Double(cmd.values["chordFactor"] ?? ""), saved > 0 { return saved }
        let factor = chordFactor(edges, model: model)
        cmd.choices["chordSelection"] = key
        if let factor { cmd.putNumber("chordFactor", factor) }
        else { cmd.values.removeValue(forKey: "chordFactor") }
        return factor
    }

    static func setFilletMeasurement(_ measurement: String, _ cmd: ModelCommand, _ ws: Workspace) {
        if measurement == "chord" {
            let edges = CommandPicks.edges(cmd, "edges", model: ws.model)
            guard let factor = cachedChordFactor(edges, cmd, model: ws.model) else {
                cmd.error = "Sehnenbreite braucht eine Kante zwischen zwei ebenen Flächen."
                return
            }
            cmd.putNumber("chordWidth", cmd.number("radius", default: 2) * factor)
        }
        cmd.choices["measurement"] = measurement
        CommandCache.refreshNow(cmd, ws)
    }

    static func refresh(_ operation: EdgeOperation, _ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        model.completesEdgeChain = cmd.choice("selectionScope", default: "edge") == "contour"
        adoptBlends(operation, cmd, model)
        let edges = CommandPicks.edges(cmd, "edges", model: model)
        guard let body = edges.first?.body else {
            if !model.selectedEdges.isEmpty { CommandSync.edges([], model) }
            return nil
        }
        // Wie bisher: Kanten eines Körpers zugleich
        let sameBody = edges.filter { $0.body == body }
        CommandSync.edges(sameBody, model)
        if model.edgeOperation != operation { model.edgeOperation = operation }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        let value: Double
        if operation == .fillet && cmd.choice("measurement", default: "radius") == "chord" {
            guard let factor = cachedChordFactor(sameBody, cmd, model: model) else {
                model.dropPreview()
                return "Sehnenbreite braucht Kanten zwischen ebenen Flächen mit gleichem Winkel."
            }
            value = cmd.number("chordWidth", default: 2 * factor) / factor
            if abs(cmd.number("radius", default: 0) - value) > 1e-9 { cmd.putNumber("radius", value) }
        } else {
            value = cmd.number(valueKey(operation), default: 1)
        }
        guard value > 0 else { return "Der Wert muss größer als 0 sein." }
        // Ergebnis aus dem Hintergrund (BlendJobs.swift): Fehlertext im Panel nachtragen
        model.blendJobs.finished = { [weak ws, weak cmd] in
            guard let ws, let cmd, let open = ws.command, open === cmd, open.editing == nil else { return }
            let model = ws.model
            let error: String? = model.hasPreview || model.isBlendComputing ? nil
                : (model.message ?? "\(operation.rawValue) an diesen Kanten nicht möglich.")
            open.error = error
            CommandCache.mark(open, error: error)
        }
        if operation == .fillet {
            let partial = cmd.isOn("partial", default: false)
            if partial {
                let start = cmd.number("startPercent", default: 20)
                let stop = cmd.number("stopPercent", default: 80)
                guard sameBody.count == 1, start >= 0, stop <= 100, stop - start >= 5 else {
                    model.dropPreview()
                    return "Teilabrundung: eine Kante und mindestens 5 % Abschnitt wählen."
                }
                model.setEdgePartialRange((start / 100)...(stop / 100), update: false)
            } else {
                model.setEdgePartialRange(nil, update: false)
            }
            let end: Double? = !partial && cmd.isOn("variable", default: false)
                ? cmd.number("end", default: value * 2) : nil
            // Nur setzen: gerechnet wird einmal mit setEdgeValue (vorher zweimal)
            if model.edgeEndValue != end { model.setEdgeEndValue(end, update: false) }
            model.setEdgeValue(value)
        } else {
            var first = value
            var second: Double?
            switch cmd.option("type", default: "equal") {
            case "two":
                second = cmd.number("distance2", default: value)
            case "angle":
                let angle = cmd.number("angle", default: 45)
                guard angle > 0, angle < 90 else { return "Der Winkel muss zwischen 0° und 90° liegen." }
                second = value * tan(angle * .pi / 180)
            default:
                second = nil
            }
            if cmd.isOn("flip", default: false), let other = second {
                second = first
                first = other
            }
            if model.edgeSecondValue != second { model.setEdgeSecondValue(second, update: false) }
            model.setEdgeValue(first)
        }
        if sameBody.count < edges.count, model.hasPreview {
            model.message = "Kanten eines Körpers zugleich – die übrigen bleiben unverändert."
        }
        // Rechnet noch im Hintergrund: (noch) kein Fehler
        if model.isBlendComputing { return nil }
        return model.hasPreview ? nil : (model.message ?? "\(operation.rawValue) an diesen Kanten nicht möglich.")
    }

    static func finish(_ operation: EdgeOperation, _ cmd: ModelCommand, _ ws: Workspace) {
        if !ws.model.hasPreview {
            cmd.previewEnabled = true
            _ = refresh(operation, cmd, ws)
        }
        if operation == .fillet && cmd.choice("measurement", default: "radius") == "chord",
           let factor = cachedChordFactor(CommandPicks.edges(cmd, "edges", model: ws.model), cmd, model: ws.model) {
            ws.model.noteBlendChord(width: cmd.number("chordWidth", default: 0), factor: factor)
        }
        LegacyFinish.commit(ws)
    }

    static func arrows(_ operation: EdgeOperation, _ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard !ws.model.selectedEdges.isEmpty, let handle = ws.model.edgeHandle else { return [] }
        // Wie bisher: kleiner Pfeil an der Kantenmitte, aus dem Material heraus
        return [DragHandle(kind: .edge, axisOrigin: SIMD3<Float>(handle.origin),
                           direction: -simd_normalize(SIMD3<Float>(handle.direction)),
                           value: cmd.number(valueKey(operation), default: ws.model.edgeValue),
                           color: Workspace.handleBlue, scale: 0.7)]
    }

    static func drag(_ operation: EdgeOperation, _ kind: HandleKind, _ value: Double, _ cmd: ModelCommand,
                     _ ws: Workspace) {
        guard kind == .edge else { return }
        let key = valueKey(operation)
        let displayed = CommandFormat.plain(max(0, value))
        guard cmd.values[key] != displayed else { return }
        cmd.values[key] = displayed
        if operation == .fillet && cmd.choice("measurement", default: "radius") == "chord",
           let factor = cachedChordFactor(CommandPicks.edges(cmd, "edges", model: ws.model), cmd, model: ws.model) {
            cmd.putNumber("chordWidth", max(0, value) * factor)
        }
        _ = refresh(operation, cmd, ws)
    }
}

enum FilletDriver: MainCommandDriver {
    /// Während die Rundung im Hintergrund rechnet, gilt die angezeigte Vorschau noch nicht (BlendJobs.swift)
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview && !ws.model.isBlendComputing
    }

    static let id = ModelCommandID.fillet
    static let title = "Abrunden"
    static let icon = "sc.fillet"
    static let featureKinds: [FeatureKind] = [.fillet]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        EdgeBlendCommand.build(.fillet, id: id, ws)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        EdgeBlendCommand.refresh(.fillet, cmd, ws)
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        EdgeBlendCommand.tapped(.fillet, tap, cmd, ws)
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        EdgeBlendCommand.finish(.fillet, cmd, ws)
        ws.model.completesEdgeChain = true
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.completesEdgeChain = true
        LegacyFinish.cancel(ws)
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        EdgeBlendCommand.arrows(.fillet, cmd, ws)
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        EdgeBlendCommand.drag(.fillet, kind, value, cmd, ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "radius" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(FilletRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

enum ChamferDriver: MainCommandDriver {
    /// Während die Rundung im Hintergrund rechnet, gilt die angezeigte Vorschau noch nicht (BlendJobs.swift)
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview && !ws.model.isBlendComputing
    }

    static let id = ModelCommandID.chamfer
    static let title = "Fasen"
    static let icon = "sc.chamfer"
    static let featureKinds: [FeatureKind] = [.chamfer]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        EdgeBlendCommand.build(.chamfer, id: id, ws)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        EdgeBlendCommand.refresh(.chamfer, cmd, ws)
    }

    @MainActor static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        EdgeBlendCommand.tapped(.chamfer, tap, cmd, ws)
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        EdgeBlendCommand.finish(.chamfer, cmd, ws)
        ws.model.completesEdgeChain = true
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.completesEdgeChain = true
        LegacyFinish.cancel(ws)
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        EdgeBlendCommand.arrows(.chamfer, cmd, ws)
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        EdgeBlendCommand.drag(.chamfer, kind, value, cmd, ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "distance" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ChamferRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

// MARK: - Panelzeilen

/// Abrunden wie im Bild model-floating.png: Radius, Typ, Stetigkeit, OPTIONEN, VARIABLER RADIUS.
private struct FilletRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @AppStorage("PencilCAD.filletFloatingWindow") private var floatingWindow = true

    private var isVariable: Bool { cmd.isOn("variable", default: false) }
    private var isPartial: Bool { cmd.isOn("partial", default: false) }
    private var usesChord: Bool { cmd.choice("measurement", default: "radius") == "chord" }

    private func step(_ direction: Double) {
        let key = usesChord ? "chordWidth" : "radius"
        let current = cmd.number(key, default: 2)
        let amount = max(0.001, min(0.1, workspace.sketch.gridStep))
        cmd.putNumber(key, max(0.001, current + direction * amount))
        CommandCache.refreshNow(cmd, workspace)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandSegmentRow(title: "Auswahl", options: [CommandChoice(id: "edge", title: "Einzelkante"),
                                                        CommandChoice(id: "tangent", title: "Tangential"),
                                                        CommandChoice(id: "contour", title: "Kontur"),
                                                        CommandChoice(id: "face", title: "Fläche")],
                              selected: cmd.choice("selectionScope", default: "edge")) { id in
                EdgeBlendCommand.setFilletSelectionScope(id, cmd, workspace)
            }
            if !isVariable && !isPartial {
                CommandSegmentRow(title: "Maß", options: [CommandChoice(id: "radius", title: "Radius"),
                                                          CommandChoice(id: "chord", title: "Sehnenbreite")],
                                  selected: cmd.choice("measurement", default: "radius")) { id in
                    EdgeBlendCommand.setFilletMeasurement(id, cmd, workspace)
                }
            }
            HStack(alignment: .bottom, spacing: 5) {
                if floatingWindow && !isVariable && !isPartial {
                    Button { step(-1) } label: { Image(systemName: "minus").frame(width: 36, height: 36) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Maß verringern")
                }
                CommandNumberRow(title: isVariable ? "Anfang" : usesChord && !isPartial ? "Sehnenbreite" : "Radius",
                                 cmd: cmd, key: usesChord && !isVariable && !isPartial ? "chordWidth" : "radius",
                                 fallback: 2, workspace: workspace) { max(0, $0) }
                if floatingWindow && !isVariable && !isPartial {
                    Button { step(1) } label: { Image(systemName: "plus").frame(width: 36, height: 36) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Maß erhöhen")
                }
            }
            if !isVariable && !isPartial {
                PrimaryWideButton(title: model.isBlendMaximumComputing ? "Radius wird geprüft …" : "Maximal gültigen Radius finden",
                                  systemImage: "arrow.up.to.line", isPrimary: false) {
                    model.searchLargestFillet { value in
                        cmd.putNumber("radius", value)
                        CommandCache.refreshNow(cmd, workspace)
                    }
                }
                .disabled(usesChord || model.selectedEdges.count != 1 || model.isBlendComputing || model.isBlendMaximumComputing)
            }
            CommandSegmentRow(title: "Typ", options: [CommandChoice(id: "constant", title: "Konstant"),
                                                      CommandChoice(id: "variable", title: "Variabel"),
                                                      CommandChoice(id: "partial", title: "Teilweise")],
                              selected: isPartial ? "partial" : isVariable ? "variable" : "constant") { id in
                cmd.flags["variable"] = id == "variable"
                cmd.flags["partial"] = id == "partial"
                if id != "constant" { cmd.choices["measurement"] = "radius" }
                if id == "variable", cmd.values["end"] == nil {
                    cmd.putNumber("end", max(cmd.number("radius", default: 2) * 2, 1))
                }
                if id == "partial" {
                    if cmd.values["startPercent"] == nil { cmd.putNumber("startPercent", 20) }
                    if cmd.values["stopPercent"] == nil { cmd.putNumber("stopPercent", 80) }
                }
                CommandCache.refreshNow(cmd, workspace)
            }
            // G2 braucht eine Kernel-Funktion, die es noch nicht gibt (SolidCraft: Krümmungsstetig)
            CommandSegmentRow(title: "Stetigkeit", options: [CommandChoice(id: "g1", title: "G1"),
                                                             CommandChoice(id: "g2", title: "G2", isEnabled: false)],
                              selected: "g1") { _ in }
            if isVariable {
                PaletteSection("Variabler Radius") {
                    CommandNumberRow(title: "Ende", cmd: cmd, key: "end", fallback: 4, workspace: workspace) { max(0.01, $0) }
                    PrimaryWideButton(title: "Enden tauschen", systemImage: "arrow.left.arrow.right", isPrimary: false) {
                        let start = cmd.number("radius", default: 2)
                        cmd.putNumber("radius", cmd.number("end", default: 4))
                        cmd.putNumber("end", start)
                        CommandCache.refreshNow(cmd, workspace)
                    }
                }
            }
            if isPartial {
                PaletteSection("Kantenabschnitt") {
                    CommandNumberRow(title: "Start", cmd: cmd, key: "startPercent", fallback: 20,
                                     unit: "%", workspace: workspace) { min(100, max(0, $0)) }
                    CommandNumberRow(title: "Ende", cmd: cmd, key: "stopPercent", fallback: 80,
                                     unit: "%", workspace: workspace) { min(100, max(0, $0)) }
                }
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            if floatingWindow {
                Text("G2, alternative Eckübergänge und Y-Blend erfordern zusätzliche Kernel-Geometrie.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EdgeStatus(model: model)
        }
    }
}

/// Fasen: Art, Abstand, Abstand 2 bzw. Winkel, Umkehren.
private struct ChamferRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    private static let types = [CommandChoice(id: "equal", title: "Gleich"), CommandChoice(id: "two", title: "Zwei"),
                                CommandChoice(id: "angle", title: "Winkel")]

    var body: some View {
        let type = cmd.option("type", default: "equal")
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandSegmentRow(title: "Auswahl", options: [CommandChoice(id: "edge", title: "Einzelkante"),
                                                        CommandChoice(id: "tangent", title: "Tangential"),
                                                        CommandChoice(id: "contour", title: "Kontur")],
                              selected: cmd.choice("selectionScope", default: "edge")) { id in
                cmd.choices["selectionScope"] = id
                CommandPicks.setItems([], cmd, "edges")
                model.dropPreview()
                CommandCache.refreshNow(cmd, workspace)
            }
            CommandOptionRow(title: "Fasenart", cmd: cmd, key: "type", options: Self.types, fallback: "equal",
                             workspace: workspace) { id in
                if id == "two", cmd.values["distance2"] == nil {
                    cmd.putNumber("distance2", cmd.number("distance", default: 1))
                }
            }
            CommandNumberRow(title: "Abstand", cmd: cmd, key: "distance", fallback: 1, workspace: workspace) { max(0, $0) }
            if type == "two" {
                CommandNumberRow(title: "Abstand 2", cmd: cmd, key: "distance2", fallback: 1, workspace: workspace) {
                    max(0.01, $0)
                }
            }
            if type == "angle" {
                CommandNumberRow(title: "Winkel", cmd: cmd, key: "angle", fallback: 45, unit: "°", workspace: workspace)
            }
            if type != "equal" {
                CommandFlagRow(title: "Umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "flip",
                               workspace: workspace)
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            EdgeStatus(model: model)
        }
    }
}

/// Zahl der gewählten Kanten bzw. Hinweis.
private struct EdgeStatus: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        let count = model.selectedEdges.count
        CommandStatusRow(title: "Auswahl", text: count == 0 ? "Kanten antippen"
                         : count == 1 ? "1 Kante" : "\(count) Kanten", isDone: count > 0)
    }
}
