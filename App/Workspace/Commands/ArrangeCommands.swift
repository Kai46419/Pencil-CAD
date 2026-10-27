import SwiftUI
import simd

// ANORDNEN nach SolidCraft (A.3): Verschieben/Drehen (★ Drehringe bleiben im Viewport, ★ Skizze verschieben),
// Kopieren (★ Reihe ×/÷), Punkt zu Punkt (Antippen wie bisher, Fangpunkte), Ausrichten, Spiegeln (Ebene durch die
// Mitte oder Bezugsebene), Rechteck- und Kreismuster.

// MARK: - Verschieben / Kopieren

@MainActor
enum MoveCommand {
    static let modes = [CommandChoice(id: "translate", title: "Verschieben"),
                        CommandChoice(id: "rotate", title: "Drehen"),
                        CommandChoice(id: "points", title: "Punkt zu Punkt")]

    static func inputs(_ mode: String, bodies: [Pick]) -> [PickInput] {
        var list = [PickInput(id: "bodies", title: "Körper", accepts: [.bodies], multiple: true, items: bodies,
                              hint: "Körper antippen (mehrere möglich).")]
        switch mode {
        case "rotate":
            list.append(PickInput(id: "axis", title: "Achse", accepts: [.axes], multiple: false,
                                  hint: "Optional: Achse, gerade Kante oder Zylinderfläche – sonst X/Y/Z durch die Mitte.",
                                  isOptional: true))
        case "points":
            list.append(PickInput(id: "from", title: "Von", accepts: [.points], multiple: false,
                                  hint: "Startpunkt antippen (Ecke, Kantenmitte, Kreismitte)."))
            list.append(PickInput(id: "to", title: "Nach", accepts: [.points], multiple: false,
                                  hint: "Zielpunkt antippen."))
        default:
            break
        }
        return list
    }

    static func build(_ id: ModelCommandID, copies: Bool, _ ws: Workspace) -> ModelCommand {
        let model = ws.model
        let pre = Preselection(model)
        // Nur Skizzenbereiche gewählt: die Skizze verschieben (wie bisher, nie kopieren)
        let movesSketch = pre.anyBodies.isEmpty && !pre.regions.isEmpty
        ws.activate(.move)
        let cmd: ModelCommand
        if movesSketch, model.movingSketch != nil {
            cmd = ModelCommand(id, inputs: [])
            cmd.flags["sketch"] = true
            model.moveCopies = false
        } else {
            cmd = ModelCommand(id, inputs: inputs("translate", bodies: pre.bodyPicks))
            cmd.flags["copy"] = copies
            model.moveCopies = copies
        }
        cmd.choices["mode"] = "translate"
        cmd.choices["axis"] = "2"
        cmd.choices["array"] = model.moveArrayDivides ? "divide" : "times"
        cmd.putNumber("count", 1)
        for key in ["x", "y", "z"] { cmd.putNumber(key, 0) }
        cmd.putNumber("angle", 90)
        return cmd
    }

    static func offset(_ cmd: ModelCommand) -> SIMD3<Double> {
        SIMD3(cmd.number("x", default: 0), cmd.number("y", default: 0), cmd.number("z", default: 0))
    }

    static func putOffset(_ offset: SIMD3<Double>, _ cmd: ModelCommand) {
        cmd.putNumber("x", offset.x)
        cmd.putNumber("y", offset.y)
        cmd.putNumber("z", offset.z)
    }

    static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        if cmd.isOn("sketch", default: false) {
            let offset = Self.offset(cmd)
            if offset != model.moveOffset { model.setMoveOffset(offset) }
            return nil
        }
        let copies = cmd.isOn("copy", default: false)
        model.moveCopies = copies
        model.moveArrayCount = copies ? min(max(Int(cmd.number("count", default: 1).rounded()), 1), 200) : 1
        model.moveArrayDivides = cmd.option("array", default: "times") == "divide"
        let bodies = CommandPicks.bodies(cmd, "bodies", model: model)
        let changed = CommandSync.bodies(bodies, model)
        guard !bodies.isEmpty else {
            CommandCache.anchors[ObjectIdentifier(cmd)] = nil
            return nil
        }
        // Mitte vor der Vorschau merken (Drehmitte, Pfeile)
        BodyCommandHelpers.cacheCenter(cmd, bodies, changed: changed, model)
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        switch cmd.option("mode", default: "translate") {
        case "rotate":
            if model.moveOffset != .zero { model.setMoveOffset(.zero) }
            let angle = cmd.number("angle", default: 90)
            var center = CommandCache.anchors[ObjectIdentifier(cmd)]?.origin ?? .zero
            var axis = unitAxis(CommandAxes.index(cmd, "axis", default: 2))
            if let line = CommandPicks.axis(cmd, "axis", model: model) {
                center = line.origin
                axis = line.direction
            }
            guard angle != 0 else {
                model.dropPreview()
                return "Winkel eingeben."
            }
            model.previewRotation(degrees: angle, center: center, axis: axis)
        case "points":
            guard let from = CommandPicks.points(cmd, "from").first, let to = CommandPicks.points(cmd, "to").first else {
                if model.moveOffset != .zero { model.setMoveOffset(.zero) }
                return nil
            }
            putOffset(to - from, cmd)
            model.setMoveOffset(to - from)
        default:
            let offset = Self.offset(cmd)
            guard offset != .zero else {
                model.setMoveOffset(.zero)
                return "An einem Pfeil ziehen oder X/Y/Z eingeben."
            }
            model.setMoveOffset(offset)
        }
        return model.hasPreview ? nil : (model.message ?? "Verschieben nicht möglich.")
    }

    static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        let model = ws.model
        if cmd.isOn("sketch", default: false) {
            // Wie „Fertig“ beim Verschieben einer Skizze
            if let index = model.movingSketch, model.moveOffset != .zero {
                model.translateSketch(index, by: model.moveOffset)
            }
            ws.tool = .select
            model.resetSelection()
            return
        }
        if !model.hasPreview {
            cmd.previewEnabled = true
            _ = refresh(cmd, ws)
        }
        LegacyFinish.commit(ws)
    }

    /// Drei Achspfeile wie das bisherige Werkzeug (Fuß wandert mit dem Versatz)
    static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        let model = ws.model
        guard cmd.option("mode", default: "translate") == "translate" else { return [] }
        let center: SIMD3<Double>
        if cmd.isOn("sketch", default: false) {
            guard let index = model.movingSketch, let found = model.center(ofSketch: index) else { return [] }
            center = found
        } else {
            guard let found = CommandCache.anchors[ObjectIdentifier(cmd)]?.origin else { return [] }
            center = found
        }
        let offset = Self.offset(cmd)
        let axes: [(SIMD3<Double>, SIMD3<Float>)] = [
            ([1, 0, 0], SIMD3(0.9, 0.25, 0.25)), ([0, 1, 0], SIMD3(0.25, 0.7, 0.3)), ([0, 0, 1], SIMD3(0.2, 0.4, 0.95)),
        ]
        return axes.enumerated().map { index, axis in
            DragHandle(kind: .move(axis: index), axisOrigin: SIMD3<Float>(center), direction: SIMD3<Float>(axis.0),
                       value: offset[index], color: axis.1)
        }
    }

    static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .move(let axis) = kind, (0..<3).contains(axis) else { return }
        var offset = Self.offset(cmd)
        guard offset[axis] != value else { return }
        offset[axis] = value
        adopt(offset, cmd, ws)
    }

    /// Gezogener Versatz (Achspfeil oder Ebenengriff im Viewport) wird der Wert des Befehls: Felder X/Y/Z zeigen
    /// ihn live, die Vorschau folgt, und der Hinweis „An einem Pfeil ziehen …“ verschwindet, damit OK aktiv wird.
    /// Vorher blieb `cmd.error` vom ersten refresh stehen (Pfeilzug rechnet ohne refresh), OK blieb grau.
    static func adopt(_ offset: SIMD3<Double>, _ cmd: ModelCommand, _ ws: Workspace) {
        let model = ws.model
        if offset != Self.offset(cmd) { putOffset(offset, cmd) }
        if offset != model.moveOffset { model.setMoveOffset(offset) }
        let error: String?
        if cmd.isOn("sketch", default: false) {
            error = nil
        } else if offset == .zero {
            error = "An einem Pfeil ziehen oder X/Y/Z eingeben."
        } else {
            error = model.hasPreview ? nil : (model.message ?? "Verschieben nicht möglich.")
        }
        if cmd.error != error { cmd.error = error }
        CommandCache.mark(cmd, error: error)
    }

    /// OK: Skizze verschieben hat keine Körpervorschau (zählt der Versatz), sonst wie üblich mit Vorschau
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        if cmd.isOn("sketch", default: false) { return ws.model.moveOffset != .zero }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }
}

extension Workspace {
    /// Ebenengriff des Verschieben-Gizmos gezogen (Viewport): bei offenem Verschieben/Kopieren in dessen Werte
    /// schreiben (Felder, OK), sonst wie bisher nur den Versatz der Vorschau setzen.
    func setGizmoMoveOffset(_ offset: SIMD3<Double>) {
        if let cmd = command, cmd.id == .move || cmd.id == .copy, cmd.editing == nil,
           cmd.option("mode", default: "translate") == "translate" {
            MoveCommand.adopt(offset, cmd, self)
        } else if offset != model.moveOffset {
            model.setMoveOffset(offset)
        }
    }
}

enum MoveDriver: MainCommandDriver {
    static let id = ModelCommandID.move
    static let title = "Verschieben"
    static let icon = "sc.move"
    static let featureKinds: [FeatureKind] = [.move, .rotate]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand { MoveCommand.build(id, copies: false, ws) }
    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? { MoveCommand.refresh(cmd, ws) }
    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) { MoveCommand.finish(cmd, ws) }
    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] { MoveCommand.arrows(cmd, ws) }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        MoveCommand.drag(kind, value, cmd, ws)
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool { MoveCommand.canCommit(cmd, ws) }

    static func mainValueKey(_ cmd: ModelCommand) -> String? {
        cmd.choices["mode"] == "rotate" ? "angle" : nil
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(MoveRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

enum CopyDriver: MainCommandDriver {
    static let id = ModelCommandID.copy
    static let title = "Kopieren"
    static let icon = "sc.copy"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand { MoveCommand.build(id, copies: true, ws) }
    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? { MoveCommand.refresh(cmd, ws) }
    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) { MoveCommand.finish(cmd, ws) }
    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] { MoveCommand.arrows(cmd, ws) }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        MoveCommand.drag(kind, value, cmd, ws)
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool { MoveCommand.canCommit(cmd, ws) }

    static func mainValueKey(_ cmd: ModelCommand) -> String? {
        cmd.choices["mode"] == "rotate" ? "angle" : nil
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(MoveRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct MoveRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        let mode = cmd.option("mode", default: "translate")
        let sketch = cmd.isOn("sketch", default: false)
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            if sketch {
                PaletteHint(text: "Skizze verschieben: an den Pfeilen ziehen oder X/Y/Z eingeben.")
            } else {
                CommandOptionRow(title: "Art", cmd: cmd, key: "mode", options: MoveCommand.modes, fallback: "translate",
                                 workspace: workspace) { id in
                    cmd.inputs = MoveCommand.inputs(id, bodies: cmd.items("bodies"))
                    cmd.advance()
                }
            }
            switch mode {
            case "rotate":
                CommandNumberRow(title: "Winkel", cmd: cmd, key: "angle", fallback: 90, unit: "°", workspace: workspace)
                if cmd.items("axis").isEmpty {
                    CommandOptionRow(title: "Achse durch die Mitte", cmd: cmd, key: "axis", options: CommandAxes.choices,
                                     fallback: "2", workspace: workspace)
                }
            case "points":
                CommandStatusRow(title: "Versatz", text: MoveRows.vectorText(MoveCommand.offset(cmd)),
                                 isDone: !cmd.items("to").isEmpty)
            default:
                CommandNumberRow(title: "X", cmd: cmd, key: "x", fallback: 0, workspace: workspace)
                CommandNumberRow(title: "Y", cmd: cmd, key: "y", fallback: 0, workspace: workspace)
                CommandNumberRow(title: "Z", cmd: cmd, key: "z", fallback: 0, workspace: workspace)
            }
            if !sketch {
                PaletteSection("Optionen") {
                    CommandFlagRow(title: "Kopie erstellen", icon: "plus.square.on.square", cmd: cmd, key: "copy",
                                   workspace: workspace)
                    if cmd.isOn("copy", default: false), mode != "rotate" {
                        // ★ Reihe kopieren wie Shapr3D „×5“ bzw. „÷5“
                        CommandCountRow(title: "Anzahl", cmd: cmd, key: "count", fallback: 1, range: 1...200,
                                        workspace: workspace)
                        CommandOptionRow(title: "Abstand", cmd: cmd, key: "array",
                                         options: [CommandChoice(id: "times", title: "× je Kopie"),
                                                   CommandChoice(id: "divide", title: "÷ aufgeteilt")],
                                         fallback: "times", workspace: workspace)
                    }
                    CommandPreviewRow(cmd: cmd, workspace: workspace)
                }
                PaletteHint(text: "Die Drehringe im Viewport drehen sofort (wie bisher).")
            }
        }
    }

    static func vectorText(_ v: SIMD3<Double>) -> String {
        [v.x, v.y, v.z].map { LengthUnit.current.format($0) }.joined(separator: " · ")
    }
}

// MARK: - Punkt zu Punkt (★ Antippen wie bisher, mit Fangpunkten)

enum TranslateDriver: LegacyTapDriver {
    static let id = ModelCommandID.translate
    static let title = "Punkt zu Punkt"
    static let icon = "sc.move"
    static let legacyTool = ModelTool.translate

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(TranslateRows(workspace: ws, model: ws.model))
    }
}

private struct TranslateRows: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandStatusRow(title: "Körper", text: BodyCommandHelpers.bodyCount(model.selectedBodies.count,
                                                                                 none: "Körper antippen"),
                             isDone: !model.selectedBodies.isEmpty)
            CommandStatusRow(title: "Von", text: workspace.translateStart == nil ? "Startpunkt antippen" : "gesetzt",
                             isDone: workspace.translateStart != nil)
            CommandStatusRow(title: "Nach", text: workspace.translateEnd == nil ? "Zielpunkt antippen" : "gesetzt",
                             isDone: workspace.translateEnd != nil)
            CheckRow(title: "Kopie erstellen", icon: "plus.square.on.square", isOn: Binding(get: { model.moveCopies },
                                                                                          set: { model.moveCopies = $0 }))
            PaletteHint(text: "Punkte rasten an Ecken, Kantenmitten und Kreismitten ein.")
        }
    }
}

// MARK: - Ausrichten

enum AlignDriver: MainCommandDriver {
    static let id = ModelCommandID.align
    static let title = "Ausrichten"
    static let icon = "sc.align"

    static let modeChoices = [CommandChoice(id: "none", title: "–"), CommandChoice(id: "min", title: "Min"),
                              CommandChoice(id: "center", title: "Mitte"), CommandChoice(id: "max", title: "Max")]

    static func mode(_ id: String) -> AlignMode {
        switch id {
        case "min": return .min
        case "center": return .center
        case "max": return .max
        default: return .none
        }
    }

    static func key(for mode: AlignMode) -> String {
        switch mode {
        case .none: return "none"
        case .min: return "min"
        case .center: return "center"
        case .max: return "max"
        }
    }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.align)
        let input = PickInput(id: "bodies", title: "Körper", accepts: [.bodies], multiple: true, items: pre.bodyPicks,
                              hint: "Zuerst den Bezugskörper antippen, dann die auszurichtenden.")
        let cmd = ModelCommand(id, inputs: [input])
        for axis in 0..<3 { cmd.choices["a\(axis)"] = key(for: ws.alignModes[axis]) }
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let bodies = CommandPicks.bodies(cmd, "bodies", model: model)
        CommandSync.bodies(bodies, model)
        let modes = (0..<3).map { mode(cmd.option("a\($0)", default: "none")) }
        ws.alignModes = modes
        guard bodies.count >= 2 else {
            model.dropPreview()
            return nil
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        // Lage aus dem echten Netz (nicht aus der vorigen Vorschau)
        model.dropPreview()
        model.previewAlign(modes)
        return model.hasPreview ? nil : (model.message ?? "Die Körper liegen schon so.")
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            ForEach(0..<3, id: \.self) { axis in
                CommandOptionRow(title: ["X", "Y", "Z"][axis], cmd: cmd, key: "a\(axis)", options: modeChoices,
                                 fallback: "none", workspace: ws)
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: ws)
            }
            PaletteHint(text: "Der zuerst gewählte Körper bleibt stehen, die übrigen richten sich an ihm aus.")
        })
    }
}

// MARK: - Spiegeln

enum MirrorDriver: MainCommandDriver {
    static let id = ModelCommandID.mirror
    static let title = "Spiegeln"
    static let icon = "sc.mirror"
    static let featureKinds: [FeatureKind] = [.mirror]

    static let planes = MirrorPlane.allCases.map { CommandChoice(id: $0.rawValue, title: $0.rawValue) }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.mirror)
        let bodies = PickInput(id: "bodies", title: "Körper", accepts: [.bodies], multiple: true, items: pre.bodyPicks,
                               hint: "Körper antippen (mehrere möglich).")
        let plane = PickInput(id: "plane", title: "Ebene", accepts: [.planes, .planarFaces], multiple: false,
                              hint: "Optional: Spiegelebene bzw. ebene Fläche – sonst eine Ebene durch die Körpermitte.",
                              isOptional: true)
        let cmd = ModelCommand(id, inputs: [bodies, plane])
        cmd.choices["plane"] = ws.mirrorPlane.rawValue
        cmd.flags["keep"] = ws.mirrorKeepsOriginal
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let bodies = CommandPicks.bodies(cmd, "bodies", model: model)
        CommandSync.bodies(bodies, model)
        let plane = MirrorPlane(rawValue: cmd.option("plane", default: MirrorPlane.yz.rawValue)) ?? .yz
        let keep = cmd.isOn("keep", default: true)
        ws.mirrorPlane = plane
        ws.mirrorKeepsOriginal = keep
        guard !bodies.isEmpty else { return nil }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        var fixed: (origin: SIMD3<Double>, normal: SIMD3<Double>)?
        if let reference = CommandPicks.referencePlane(cmd, "plane") {
            guard let found = model.resolve(reference) else { return "Diese Ebene lässt sich nicht bestimmen." }
            fixed = found
        }
        model.previewMirror(plane, keepOriginal: keep, at: fixed)
        return model.hasPreview ? nil : (model.message ?? "Spiegeln nicht möglich.")
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(MirrorRows(cmd: cmd, workspace: ws))
    }
}

private struct MirrorRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            if cmd.items("plane").isEmpty {
                CommandOptionRow(title: "Ebene durch die Mitte", cmd: cmd, key: "plane", options: MirrorDriver.planes,
                                 fallback: MirrorPlane.yz.rawValue, workspace: workspace)
            }
            PaletteSection("Optionen") {
                CommandFlagRow(title: "Original behalten", icon: "square.on.square", cmd: cmd, key: "keep",
                               fallback: true, workspace: workspace)
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

// MARK: - Muster

@MainActor
enum PatternCommand {
    static func bodiesInput(_ pre: Preselection) -> PickInput {
        PickInput(id: "bodies", title: "Körper", accepts: [.bodies], multiple: true, items: pre.bodyPicks,
                  hint: "Körper antippen (mehrere möglich).")
    }

    /// Richtung aus dem Auswahlfeld, sonst Weltachse der Wahl
    static func direction(_ cmd: ModelCommand, input: String, choice: String, fallback: Int,
                          _ model: ModelStore) -> SIMD3<Double> {
        var direction = CommandPicks.axis(cmd, input, model: model)?.direction
            ?? unitAxis(CommandAxes.index(cmd, choice, default: fallback))
        if cmd.isOn("\(input)Flip", default: false) { direction = -direction }
        return direction
    }

    static func count(_ cmd: ModelCommand, _ key: String, default fallback: Int) -> Int {
        min(max(Int(cmd.number(key, default: Double(fallback)).rounded()), 1), 500)
    }
}

enum PatternRectDriver: MainCommandDriver {
    static let id = ModelCommandID.patternRect
    static let title = "Rechteckmuster"
    static let icon = "sc.pattern_rect"
    static let featureKinds: [FeatureKind] = [.pattern]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.pattern(.linear))
        let first = PickInput(id: "dir1", title: "Richtung 1", accepts: [.axes], multiple: false,
                              hint: "Optional: Kante, Achse oder Fläche – sonst X/Y/Z.", isOptional: true)
        let second = PickInput(id: "dir2", title: "Richtung 2", accepts: [.axes], multiple: false,
                               hint: "Optional: zweite Richtung (Anzahl 2 größer als 1).", isOptional: true)
        let cmd = ModelCommand(id, inputs: [PatternCommand.bodiesInput(pre), first, second])
        cmd.putNumber("count", Double(ws.patternCount))
        cmd.putNumber("spacing", ws.patternSpacing)
        cmd.putNumber("count2", Double(ws.patternCount2))
        cmd.putNumber("spacing2", ws.patternSpacing2)
        cmd.choices["axis"] = "0"
        cmd.choices["axis2"] = "1"
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let bodies = CommandPicks.bodies(cmd, "bodies", model: model)
        CommandSync.bodies(bodies, model)
        let count = PatternCommand.count(cmd, "count", default: 4)
        let count2 = PatternCommand.count(cmd, "count2", default: 1)
        let spacing = cmd.number("spacing", default: 20)
        let spacing2 = cmd.number("spacing2", default: 20)
        ws.patternCount = count
        ws.patternSpacing = spacing
        ws.patternCount2 = count2
        ws.patternSpacing2 = spacing2
        guard !bodies.isEmpty else { return nil }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        guard count * count2 >= 2 else {
            model.dropPreview()
            return "Mindestens zwei Exemplare."
        }
        let d1 = PatternCommand.direction(cmd, input: "dir1", choice: "axis", fallback: 0, model)
        let d2 = PatternCommand.direction(cmd, input: "dir2", choice: "axis2", fallback: 1, model)
        model.previewLinearPattern(count: count, spacing: spacing, direction: d1, count2: count2, spacing2: spacing2,
                                   direction2: d2)
        return model.hasPreview ? nil : (model.message ?? "Muster nicht möglich.")
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "spacing" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        // Abstand, Anzahl, Winkel: kompakter Ziffernblock statt Bildschirmtastatur
        AnyView(PatternRectRows(cmd: cmd, workspace: ws).environment(\.usesCompactKeypad, true))
    }
}

private struct PatternRectRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteSection("Richtung 1") {
                if cmd.items("dir1").isEmpty {
                    CommandOptionRow(title: "Achse", cmd: cmd, key: "axis", options: CommandAxes.choices, fallback: "0",
                                     workspace: workspace)
                }
                CommandCountRow(title: "Anzahl", cmd: cmd, key: "count", fallback: 4, range: 1...500, workspace: workspace)
                CommandNumberRow(title: "Abstand", cmd: cmd, key: "spacing", fallback: 20, workspace: workspace)
                CommandFlagRow(title: "Umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "dir1Flip",
                               workspace: workspace)
            }
            PaletteSection("Richtung 2") {
                if cmd.items("dir2").isEmpty {
                    CommandOptionRow(title: "Achse", cmd: cmd, key: "axis2", options: CommandAxes.choices, fallback: "1",
                                     workspace: workspace)
                }
                CommandCountRow(title: "Anzahl", cmd: cmd, key: "count2", fallback: 1, range: 1...500,
                                workspace: workspace)
                CommandNumberRow(title: "Abstand", cmd: cmd, key: "spacing2", fallback: 20, workspace: workspace)
                CommandFlagRow(title: "Umkehren", icon: "arrow.left.arrow.right", cmd: cmd, key: "dir2Flip",
                               workspace: workspace)
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

enum PatternCircularDriver: MainCommandDriver {
    static let id = ModelCommandID.patternCircular
    static let title = "Kreismuster"
    static let icon = "sc.pattern_circ"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.pattern(.circular))
        let axis = PickInput(id: "axis", title: "Achse", accepts: [.axes], multiple: false,
                             hint: "Optional: Achse, Kante oder Zylinderfläche – sonst X/Y/Z durch den Ursprung.",
                             isOptional: true)
        let cmd = ModelCommand(id, inputs: [PatternCommand.bodiesInput(pre), axis])
        cmd.putNumber("count", Double(max(ws.patternCount, 2)))
        cmd.putNumber("angle", ws.patternAngle)
        cmd.choices["axis"] = "2"
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let bodies = CommandPicks.bodies(cmd, "bodies", model: model)
        CommandSync.bodies(bodies, model)
        let count = PatternCommand.count(cmd, "count", default: 6)
        let angle = cmd.number("angle", default: 360)
        ws.patternCount = count
        ws.patternAngle = angle
        guard !bodies.isEmpty else { return nil }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        guard count >= 2 else {
            model.dropPreview()
            return "Mindestens zwei Exemplare."
        }
        let line = CommandPicks.axis(cmd, "axis", model: model)
            ?? model.resolve(ReferenceAxis.world(CommandAxes.index(cmd, "axis", default: 2)))
        guard let line else { return "Diese Achse lässt sich nicht bestimmen." }
        model.previewCircularPattern(count: count, angle: angle, axisOrigin: line.origin, axis: line.direction)
        return model.hasPreview ? nil : (model.message ?? "Muster nicht möglich.")
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "angle" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        // Abstand, Anzahl, Winkel: kompakter Ziffernblock statt Bildschirmtastatur
        AnyView(PatternCircularRows(cmd: cmd, workspace: ws).environment(\.usesCompactKeypad, true))
    }
}

private struct PatternCircularRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            if cmd.items("axis").isEmpty {
                CommandOptionRow(title: "Achse", cmd: cmd, key: "axis", options: CommandAxes.choices, fallback: "2",
                                 workspace: workspace)
            }
            CommandCountRow(title: "Anzahl", cmd: cmd, key: "count", fallback: 6, range: 2...500, workspace: workspace)
            CommandNumberRow(title: "Winkel", cmd: cmd, key: "angle", fallback: 360, unit: "°", workspace: workspace)
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            PaletteHint(text: "360° verteilt die Exemplare gleichmäßig, sonst bis zum Endwinkel.")
        }
    }
}
