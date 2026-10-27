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
        // Vorauswahl: Kanten, sonst Flächen (= alle ihre Kanten)
        let items: [Pick] = pre.edges.isEmpty ? pre.facePicks : pre.edges.map { Pick.edge($0) }
        let input = PickInput(id: "edges", title: "Kanten", accepts: [.edges, .faces], multiple: true, items: items,
                              hint: "Kanten antippen (eine Fläche nimmt alle ihre Kanten). Eine vorhandene "
                                  + (operation == .fillet ? "Rundung" : "Fase") + " antippen übernimmt ihren Wert.")
        let cmd = ModelCommand(id, inputs: [input])
        let current = model.edgeOperation == operation && model.edgeValue > 0 ? model.edgeValue : nil
        cmd.putNumber(valueKey(operation), current ?? (operation == .fillet ? 2 : 1))
        if operation == .fillet {
            cmd.flags["variable"] = false
            cmd.choices["continuity"] = "g1"
        } else {
            cmd.choices["type"] = "equal"
            cmd.putNumber("angle", 45)
        }
        return cmd
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
        model.message = "\(operation == .fillet ? "Radius" : "Fase") übernommen: \(LengthUnit.current.format(adopted))"
    }

    static func refresh(_ operation: EdgeOperation, _ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
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
        let value = cmd.number(valueKey(operation), default: 1)
        guard value > 0 else { return "Der Wert muss größer als 0 sein." }
        if operation == .fillet {
            let end: Double? = cmd.isOn("variable", default: false) ? cmd.number("end", default: value * 2) : nil
            if model.edgeEndValue != end { model.setEdgeEndValue(end) }
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
            if model.edgeSecondValue != second { model.setEdgeSecondValue(second) }
            model.setEdgeValue(first)
        }
        if sameBody.count < edges.count, model.hasPreview {
            model.message = "Kanten eines Körpers zugleich – die übrigen bleiben unverändert."
        }
        return model.hasPreview ? nil : (model.message ?? "\(operation.rawValue) an diesen Kanten nicht möglich.")
    }

    static func finish(_ operation: EdgeOperation, _ cmd: ModelCommand, _ ws: Workspace) {
        if !ws.model.hasPreview {
            cmd.previewEnabled = true
            _ = refresh(operation, cmd, ws)
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
        cmd.putNumber(valueKey(operation), max(0, value))
        _ = refresh(operation, cmd, ws)
    }
}

enum FilletDriver: MainCommandDriver {
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

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        EdgeBlendCommand.finish(.fillet, cmd, ws)
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

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        EdgeBlendCommand.finish(.chamfer, cmd, ws)
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

    private var isVariable: Bool { cmd.isOn("variable", default: false) }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandNumberRow(title: isVariable ? "Anfang" : "Radius", cmd: cmd, key: "radius", fallback: 2,
                            workspace: workspace) { max(0, $0) }
            CommandSegmentRow(title: "Typ", options: [CommandChoice(id: "constant", title: "Konstant"),
                                                      CommandChoice(id: "variable", title: "Variabel")],
                              selected: isVariable ? "variable" : "constant") { id in
                cmd.flags["variable"] = id == "variable"
                if id == "variable", cmd.values["end"] == nil {
                    cmd.putNumber("end", max(cmd.number("radius", default: 2) * 2, 1))
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
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
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
