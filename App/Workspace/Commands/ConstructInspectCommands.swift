import SwiftUI
import simd

// KONSTRUIEREN und PRÜFEN nach SolidCraft (A.4/A.5): Ebene, Achse, Punkt (Arten wie bisher, Antippen über den
// bisherigen Weg), Messen, Schnittansicht (★ Pfeil), Druckprüfung, Netz bearbeiten (★ PencilCAD).

/// Antippen läuft über den bisherigen Weg und ändert Zustand des Workspace: ohne Zwischenspeicher prüfen, ob OK möglich
/// ist (der Stand der Befehlsfelder ändert sich dabei nicht).
@MainActor
protocol LiveLegacyDriver: LegacyTapDriver {
    @MainActor static func missing(_ ws: Workspace) -> String?
}

extension LiveLegacyDriver {
    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        MainActor.assumeIsolated { () -> String? in missing(ws) }
    }
}

// MARK: - Ebene

enum ConstructPlaneDriver: LiveLegacyDriver {
    static let id = ModelCommandID.constructPlane
    static let title = "Ebene"
    static let icon = "sc.plane"
    static let legacyTool = ModelTool.construct(.plane)

    @MainActor static func missing(_ ws: Workspace) -> String? {
        ws.pendingPlane == nil ? "Noch nicht alles angetippt." : nil
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        if let plane = ws.pendingPlane {
            ws.model.addConstruction(.plane, origin: plane.origin, direction: plane.normal)
        }
        ws.tool = .select
        ws.model.resetSelection()
    }

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ConstructPlaneRows(cmd: cmd, workspace: ws))
    }
}

private struct ConstructPlaneRows: View {
    let cmd: ModelCommand
    @ObservedObject var workspace: Workspace

    /// Standardebenen: Normale Z, Y, X
    private static let worlds = [CommandChoice(id: "2", title: "XY"), CommandChoice(id: "1", title: "XZ"),
                                 CommandChoice(id: "0", title: "YZ")]

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PalettePickerRow(title: "Art", selection: Binding(get: { workspace.planeMethod }, set: { method in
                workspace.planeMethod = method
                workspace.resetConstructPicks()
                CommandCache.refreshNow(cmd, workspace)
            }), options: PlaneMethod.allCases, label: { $0.rawValue })
            switch workspace.planeMethod {
            case .offset:
                reference
                PaletteNumberRow(title: "Abstand", value: workspace.constructOffset) { value in
                    workspace.constructOffset = value
                }
            case .midplane:
                ConstructCount(count: workspace.constructPlanes.count, total: 2, noun: "Flächen")
            case .threePoints:
                ConstructCount(count: workspace.constructPoints.count, total: 3, noun: "Punkte")
            case .normalToEdge:
                ConstructCount(count: workspace.constructEdge == nil ? 0 : 1, total: 1, noun: "Kante")
                PaletteNumberRow(title: "Lage", value: workspace.constructEdgePosition, unit: "%") { value in
                    workspace.constructEdgePosition = min(max(value, 0), 100)
                }
            case .edgeAngle:
                ConstructCount(count: workspace.constructEdge == nil ? 0 : 1, total: 1, noun: "Kante")
                reference
                PaletteNumberRow(title: "Winkel", value: workspace.constructAngle, unit: "°") { value in
                    workspace.constructAngle = value
                }
            }
        }
    }

    /// Bezug: Standardebene wählen oder ebene Fläche antippen
    @ViewBuilder private var reference: some View {
        if case .world(let axis) = workspace.constructReference {
            CommandSegmentRow(title: "Bezug (oder ebene Fläche antippen)", options: Self.worlds,
                              selected: String(axis)) { id in
                workspace.constructReference = .world(Int(id) ?? 2)
            }
        } else {
            HStack(spacing: PaletteStyle.spacing) {
                CommandStatusRow(title: "Bezug", text: "Fläche bzw. Ebene", isDone: true)
                Button("Standardebene") { workspace.constructReference = .world(2) }
                    .font(.callout)
            }
        }
    }
}

/// „2 von 3 Punkten“ (grün, sobald alles angetippt ist)
private struct ConstructCount: View {
    let count: Int
    let total: Int
    let noun: String

    var body: some View {
        CommandStatusRow(title: "Angetippt", text: "\(min(count, total)) von \(total) \(noun)", isDone: count >= total)
    }
}

// MARK: - Achse

enum ConstructAxisDriver: LiveLegacyDriver {
    static let id = ModelCommandID.constructAxis
    static let title = "Achse"
    static let icon = "sc.axis"
    static let legacyTool = ModelTool.construct(.axis)

    @MainActor static func missing(_ ws: Workspace) -> String? {
        ws.pendingAxis == nil ? "Noch nicht alles angetippt." : nil
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        if let axis = ws.pendingAxis {
            ws.model.addConstruction(.axis, origin: axis.origin, direction: axis.direction)
        }
        ws.tool = .select
        ws.model.resetSelection()
    }

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ConstructAxisRows(cmd: cmd, workspace: ws))
    }
}

private struct ConstructAxisRows: View {
    let cmd: ModelCommand
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PalettePickerRow(title: "Art", selection: Binding(get: { workspace.axisMethod }, set: { method in
                workspace.axisMethod = method
                workspace.constructCustomAxis = nil
                workspace.resetConstructPicks()
                CommandCache.refreshNow(cmd, workspace)
            }), options: AxisMethod.allCases, label: { $0.rawValue })
            switch workspace.axisMethod {
            case .pick:
                if let custom = workspace.constructCustomAxis {
                    HStack(spacing: PaletteStyle.spacing) {
                        CommandStatusRow(title: "Achse", text: "Durch \(custom.name)", isDone: true)
                        Button("Andere") { workspace.constructCustomAxis = nil }
                            .font(.callout)
                    }
                } else {
                    if case .world(let axis) = workspace.constructAxis {
                        CommandSegmentRow(title: "Achse (oder Kante/Fläche antippen)", options: CommandAxes.choices,
                                          selected: String(axis)) { id in
                            workspace.constructAxis = .world(Int(id) ?? 2)
                        }
                    } else {
                        CommandStatusRow(title: "Achse", text: "gewählt", isDone: true)
                    }
                }
            case .twoPoints:
                ConstructCount(count: workspace.constructPoints.count, total: 2, noun: "Punkte")
            case .twoPlanes:
                ConstructCount(count: workspace.constructPlanes.count, total: 2, noun: "Flächen")
            case .cylinder:
                ConstructCount(count: workspace.constructCustomAxis == nil ? 0 : 1, total: 1, noun: "Zylinder")
            }
        }
    }
}

// MARK: - Punkt

enum ConstructPointDriver: LegacyTapDriver {
    static let id = ModelCommandID.constructPoint
    static let title = "Punkt"
    static let icon = "sc.point"
    static let legacyTool = ModelTool.construct(.point)

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.addConstruction(.point, origin: ws.constructPoint, direction: [0, 0, 1])
        ws.tool = .select
        ws.model.resetSelection()
    }

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ConstructPointRows(workspace: ws))
    }
}

private struct ConstructPointRows: View {
    @ObservedObject var workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            ForEach(0..<3, id: \.self) { axis in
                PaletteNumberRow(title: ["X", "Y", "Z"][axis], value: workspace.constructPoint[axis]) { value in
                    workspace.constructPoint[axis] = value
                }
            }
            PaletteHint(text: "Lage eingeben oder auf dem Modell antippen.")
        }
    }
}

// MARK: - Messen

enum MeasureDriver: LegacyTapDriver {
    static let id = ModelCommandID.measure
    static let title = "Messen"
    static let icon = "sc.measure"
    static let legacyTool = ModelTool.measure

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.clearMeasurement()
        ws.tool = .select
        ws.model.resetSelection()
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        finish(cmd, ws)
    }

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(MeasureRows(workspace: ws))
    }
}

private struct MeasureRows: View {
    @ObservedObject var workspace: Workspace

    private static let modes = MeasureMode.allCases.map { CommandChoice(id: $0.rawValue, title: $0.rawValue) }

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandSegmentRow(title: "Art", options: Self.modes, selected: workspace.measureMode.rawValue) { id in
                if let mode = MeasureMode(rawValue: id) { workspace.measureMode = mode }
            }
            if workspace.measureLines.isEmpty {
                PaletteHint(text: workspace.measureMode == .points
                            ? "Zwei Punkte antippen; der zweite rastet parallel zu X, Y, Z ein."
                            : "Kante, Fläche oder zwei Körper antippen.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(workspace.measureLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .monospacedDigit()
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
                PrimaryWideButton(title: "Neu messen", systemImage: "arrow.counterclockwise", isPrimary: false) {
                    workspace.clearMeasurement()
                }
            }
        }
    }
}

// MARK: - Schnittansicht

enum SectionDriver: MainCommandDriver {
    static let id = ModelCommandID.section
    static let title = "Schnittansicht"
    static let icon = "sc.section"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.section)
        let current = ws.section ?? SectionSettings()
        var items: [Pick] = []
        if case .world = current.plane {} else { items = [Pick.plane(current.plane)] }
        if let face = pre.faces.first, ws.model.plane(of: face) != nil { items = [Pick.face(face)] }
        let input = PickInput(id: "plane", title: "Ebene", accepts: [.planes, .planarFaces], multiple: false,
                              items: items, hint: "Optional: Ebene bzw. ebene Fläche – sonst eine Standardebene.",
                              isOptional: true)
        let cmd = ModelCommand(id, inputs: [input])
        if case .world(let axis) = current.plane { cmd.choices["axis"] = String(axis) } else { cmd.choices["axis"] = "1" }
        cmd.putNumber("offset", current.offset)
        cmd.flags["flipped"] = current.flipped
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let plane = CommandPicks.referencePlane(cmd, "plane") ?? .world(CommandAxes.index(cmd, "axis", default: 1))
        let settings = SectionSettings(plane: plane, offset: cmd.number("offset", default: 0),
                                       flipped: cmd.isOn("flipped", default: false))
        if ws.section != settings { ws.section = settings }
        return ws.model.resolve(plane) == nil ? "Diese Ebene lässt sich nicht bestimmen." : nil
    }

    /// Fertig: Schnitt bleibt an (Ausschalten über die Ansicht bzw. erneut „Schnittansicht“)
    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        _ = refresh(cmd, ws)
        ws.tool = .select
        ws.model.resetSelection()
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.section = nil
        LegacyFinish.cancel(ws)
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        ws.sectionHandle.map { [$0] } ?? []
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard kind == .section else { return }
        cmd.putNumber("offset", value)
        if ws.section?.offset != value { ws.section?.offset = value }
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "offset" }

    /// Der Schnitt ist keine Modellvorschau: OK, sobald die Ebene bestimmt ist
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SectionRows(cmd: cmd, workspace: ws))
    }
}

private struct SectionRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    private static let worlds = [CommandChoice(id: "2", title: "XY"), CommandChoice(id: "1", title: "XZ"),
                                 CommandChoice(id: "0", title: "YZ")]

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            if cmd.items("plane").isEmpty {
                CommandOptionRow(title: "Ebene", cmd: cmd, key: "axis", options: Self.worlds, fallback: "1",
                                 workspace: workspace)
            }
            CommandNumberRow(title: "Versatz", cmd: cmd, key: "offset", fallback: 0, workspace: workspace)
            CommandFlagRow(title: "Seite umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "flipped",
                           workspace: workspace)
            PaletteHint(text: "Am Pfeil ziehen führt den Schnitt durch den Körper. „Abbrechen“ schaltet ihn aus.")
        }
    }
}

// MARK: - Druckprüfung (★ PencilCAD)

enum PrintCheckDriver: LegacyTapDriver {
    static let id = ModelCommandID.printCheck
    static let title = "Druckprüfung"
    static let icon = "printer"
    static let legacyTool = ModelTool.printCheck

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(PrintCheckRows(workspace: ws, model: ws.model))
    }
}

private struct PrintCheckRows: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteNumberRow(title: "Überhang ab", value: workspace.printOverhangAngle, unit: "°") { value in
                guard value > 0, value < 90 else { return }
                workspace.printOverhangAngle = value
                workspace.runPrintCheck()
            }
            PaletteNumberRow(title: "Mindestwand", value: workspace.printMinWall) { value in
                guard value > 0 else { return }
                workspace.printMinWall = value
                workspace.runPrintCheck()
            }
            PrimaryWideButton(title: "Beste Ausrichtung", systemImage: "wand.and.stars", isPrimary: false) {
                workspace.runPrintCheck(best: true)
            }
            .disabled(workspace.printBody == nil || workspace.printBusy)
            if workspace.printUp != [0, 0, 1] {
                PrimaryWideButton(title: "Ausrichtung übernehmen", systemImage: "checkmark", isPrimary: true) {
                    workspace.applyPrintOrientation()
                }
                .disabled(workspace.printBusy)
            }
            if workspace.printBusy {
                ProgressView()
            }
            if let report = workspace.printReport {
                let material = model.weighingMaterial(ofBody: workspace.printBody)
                let gram = Double(report.volume) / 1000 * material.density
                VStack(alignment: .leading, spacing: 4) {
                    Text("Überhang: \(NumberField.format(Double(report.overhangArea))) mm²"
                         + (report.overhang.isEmpty ? " – keine Stützen nötig" : " (rot)"))
                    if let wall = report.thinnestWall {
                        Text("Dünnste Wand: \(NumberField.format(Double(wall))) mm"
                             + (report.thin.isEmpty ? "" : " – zu dünn (orange)"))
                    }
                    Text(report.openEdges == 0 ? "Netz geschlossen" : "\(report.openEdges) offene Kanten – Körper prüfen")
                    Text("Auflage \(NumberField.format(Double(report.bedContactArea))) mm² · Höhe "
                         + "\(NumberField.format(Double(report.height))) mm")
                    Text("Volumen \(NumberField.format(Double(report.volume) / 1000)) cm³ · ≈ "
                         + "\(NumberField.format(gram)) g \(material.name)")
                }
                .font(.callout)
                .monospacedDigit()
            } else if workspace.printBody == nil {
                CommandStatusRow(title: "Körper", text: "Körper antippen", isDone: false)
            }
        }
    }
}

// MARK: - Netz bearbeiten (★ PencilCAD)

enum MeshSculptDriver: LegacyTapDriver {
    static let id = ModelCommandID.meshSculpt
    static let title = "Netz bearbeiten"
    static let icon = "paintbrush.pointed"
    static let legacyTool = ModelTool.meshSculpt

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(MeshSculptCard(workspace: ws, model: ws.model, sculpt: ws.sculpt))
    }
}
