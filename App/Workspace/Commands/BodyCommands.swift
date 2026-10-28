import SwiftUI
import simd

// ÄNDERN › KÖRPER nach SolidCraft (A.2): Kombinieren (Ziel + Werkzeuge, Vereinigen/Abziehen/Schneiden, ★ Spiel beim
// Abziehen, ★ Werkzeuge behalten), Körper teilen (Ebene/Körper/Skizze), Skalieren (★ Pfeil, immer gleichmäßig),
// ★ Negativform (Antippen wie bisher).

@MainActor
enum BodyCommandHelpers {
    /// Mitte und Abstand Mitte–Ecke der Körper aus dem Netz (vor der Vorschau rechnen).
    static func bounds(_ bodies: [Int], _ model: ModelStore) -> (center: SIMD3<Double>, corner: SIMD3<Double>)? {
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for body in bodies {
            guard let box = model.mesh.bounds(ofBody: body) else { continue }
            low = simd_min(low, box.min)
            high = simd_max(high, box.max)
        }
        guard low.x <= high.x else { return nil }
        let center = SIMD3<Double>((low + high) / 2)
        return (center, SIMD3<Double>(high) - center)
    }

    /// Mitte der Körper merken, sobald sich die Auswahl ändert (während der Vorschau zeigt das Netz bewegte Körper).
    static func cacheCenter(_ cmd: ModelCommand, _ bodies: [Int], changed: Bool, _ model: ModelStore) {
        let key = ObjectIdentifier(cmd)
        guard changed || CommandCache.anchors[key] == nil else { return }
        if !changed { model.dropPreview() }
        if let box = bounds(bodies, model) {
            let radius = simd_length(box.corner)
            CommandCache.anchors[key] = (box.center, radius > 1e-9 ? box.corner / radius : [0, 0, 1], radius)
        } else {
            CommandCache.anchors[key] = nil
        }
    }

    static func bodyCount(_ count: Int, none: String) -> String {
        count == 0 ? none : count == 1 ? "1 Körper" : "\(count) Körper"
    }
}

// MARK: - Kombinieren

enum CombineDriver: MainCommandDriver {
    static let id = ModelCommandID.combine
    static let title = "Kombinieren"
    static let icon = "sc.combine"
    static let featureKinds: [FeatureKind] = [.boolean]

    static let operations = [CommandChoice(id: "union", title: "Vereinigen"),
                             CommandChoice(id: "subtract", title: "Abziehen"),
                             CommandChoice(id: "intersect", title: "Schneiden")]

    static func kind(_ cmd: ModelCommand) -> BooleanKind {
        switch cmd.option("op", default: "union") {
        case "subtract": return .subtract
        case "intersect": return .intersect
        default: return .union
        }
    }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        // Vorauswahl: der zuerst gewählte Körper ist das Ziel, die übrigen die Werkzeuge
        let chosen = pre.anyBodies
        ws.activate(.boolean(.union))
        let target = PickInput(id: "target", title: "Ziel", accepts: [.bodies], multiple: false,
                               items: chosen.prefix(1).map { Pick.body($0) },
                               hint: "Zielkörper antippen (bleibt bestehen).")
        let tools = PickInput(id: "tools", title: "Werkzeuge", accepts: [.bodies], multiple: true,
                              items: chosen.dropFirst().map { Pick.body($0) },
                              hint: "Werkzeugkörper antippen (mehrere möglich).")
        let cmd = ModelCommand(id, inputs: [target, tools])
        cmd.choices["op"] = "union"
        cmd.flags["keepTools"] = ws.booleanKeepsTools
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let kind = Self.kind(cmd)
        if ws.tool != .boolean(kind) { ws.tool = .boolean(kind) }
        ws.booleanKeepsTools = cmd.isOn("keepTools", default: false)
        let target = CommandPicks.bodies(cmd, "target", model: model)
        let tools = CommandPicks.bodies(cmd, "tools", model: model).filter { !target.contains($0) }
        CommandSync.bodies(target + tools, model)
        guard !target.isEmpty, !tools.isEmpty else {
            model.dropPreview()
            return nil
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        ws.updateBooleanPreview(kind)
        return model.hasPreview ? nil : (model.message ?? "\(kind.rawValue) mit diesen Körpern nicht möglich.")
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        _ = refresh(cmd, ws)
        // Wie „Fertig“ im bisherigen Werkzeug: Vorschau verwerfen und mit Verlauf und Spiel rechnen
        ws.applyBooleanTool(kind(cmd))
        ws.tool = .select
        ws.model.resetSelection()
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(CombineRows(cmd: cmd, workspace: ws, settings: ws.mold))
    }
}

private struct CombineRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var settings: MoldSettings

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandOptionRow(title: "Operation", cmd: cmd, key: "op", options: CombineDriver.operations,
                             fallback: "union", workspace: workspace)
            if CombineDriver.kind(cmd) == .subtract {
                // ★ Spiel beim Abziehen (Werkzeug vorher aufgedickt)
                PaletteNumberRow(title: "Spiel", value: settings.subtractClearance) { value in
                    settings.subtractClearance = min(max(value, 0), 5)
                    CommandCache.forget(cmd)
                    CommandCache.refreshNow(cmd, workspace)
                }
            }
            PaletteSection("Optionen") {
                // ★ Werkzeuge behalten (Fusion 360)
                CommandFlagRow(title: "Werkzeuge behalten", icon: "square.on.square", cmd: cmd, key: "keepTools",
                               workspace: workspace)
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            PaletteHint(text: "Ziel orange, Werkzeuge rot. Abziehen: Spiel 0,2 mm (FDM) bzw. 0,1 mm (Harz) lässt Teile hineinpassen.")
        }
    }
}

// MARK: - Körper teilen

enum SplitBodyDriver: MainCommandDriver {
    static let id = ModelCommandID.splitBody
    static let title = "Körper teilen"
    static let icon = "sc.split_body"

    static let modes = [CommandChoice(id: "plane", title: "Ebene"), CommandChoice(id: "body", title: "Körper"),
                        CommandChoice(id: "sketch", title: "Skizze")]

    static func inputs(_ mode: String, body: [Pick]) -> [PickInput] {
        var list = [PickInput(id: "body", title: "Körper", accepts: [.bodies], multiple: false, items: body,
                              hint: "Körper antippen, der geteilt wird.")]
        switch mode {
        case "body":
            list.append(PickInput(id: "tool", title: "Werkzeug", accepts: [.bodies], multiple: false,
                                  hint: "Körper antippen, der den ersten teilt."))
        case "sketch":
            list.append(PickInput(id: "regions", title: "Skizze", accepts: [.regions], multiple: true,
                                  hint: "Skizzenbereiche antippen: ein Prisma durch alles teilt den Körper."))
        default:
            list.append(PickInput(id: "plane", title: "Ebene", accepts: [.planes, .planarFaces], multiple: false,
                                  hint: "Optional: Ebene bzw. ebene Fläche – sonst die Achsebene durch die Körpermitte.",
                                  isOptional: true))
        }
        return list
    }

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.split)
        let cmd = ModelCommand(id, inputs: inputs("plane", body: pre.anyBodies.prefix(1).map { Pick.body($0) }))
        cmd.choices["mode"] = "plane"
        if case .world(let axis) = ws.splitPlane { cmd.choices["axis"] = String(axis) }
        cmd.putNumber("offset", ws.splitOffset)
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard let body = CommandPicks.bodies(cmd, "body", model: model).first else {
            CommandSync.bodies([], model)
            return nil
        }
        let changed = CommandSync.bodies([body], model)
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        switch cmd.option("mode", default: "plane") {
        case "body":
            guard let tool = CommandPicks.bodies(cmd, "tool", model: model).first(where: { $0 != body }) else {
                model.dropPreview()
                return nil
            }
            model.previewSplit(tool: model.bodies[tool].shape)
        case "sketch":
            let regions = CommandPicks.regions(cmd, "regions")
            guard !regions.isEmpty else {
                model.dropPreview()
                return nil
            }
            guard let prism = model.throughPrism(regions: regions) else {
                return "Aus diesen Skizzenbereichen lässt sich kein Werkzeug bilden."
            }
            model.previewSplit(tool: prism)
        default:
            let reference = CommandPicks.referencePlane(cmd, "plane")
                ?? .world(CommandAxes.index(cmd, "axis", default: 2))
            guard let plane = model.resolve(reference) else { return "Diese Ebene lässt sich nicht bestimmen." }
            let offset = cmd.number("offset", default: 0)
            ws.splitOffset = offset
            var origin = plane.origin
            // Standardebene: durch die Körpermitte (vor der Vorschau gemerkt)
            if case .world = reference {
                BodyCommandHelpers.cacheCenter(cmd, [body], changed: changed, model)
                if let center = CommandCache.anchors[ObjectIdentifier(cmd)]?.origin { origin = center }
            }
            model.previewSplit(origin: origin + plane.normal * offset, normal: plane.normal)
        }
        return model.hasPreview ? nil : (model.message ?? "Teilen hier nicht möglich.")
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SplitRows(cmd: cmd, workspace: ws))
    }
}

private struct SplitRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        let mode = cmd.option("mode", default: "plane")
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandOptionRow(title: "Teilen mit", cmd: cmd, key: "mode", options: SplitBodyDriver.modes,
                             fallback: "plane", workspace: workspace) { id in
                // Felder je Art neu, der Körper bleibt
                cmd.inputs = SplitBodyDriver.inputs(id, body: cmd.items("body"))
                cmd.advance()
                CommandCache.anchors[ObjectIdentifier(cmd)] = nil
            }
            if mode == "plane" {
                if cmd.items("plane").isEmpty {
                    CommandOptionRow(title: "Achsebene (Normale)", cmd: cmd, key: "axis", options: CommandAxes.choices,
                                     fallback: "2", workspace: workspace)
                }
                CommandNumberRow(title: "Versatz", cmd: cmd, key: "offset", fallback: 0, workspace: workspace)
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            PaletteHint(text: "Alle Teile werden eigene Körper.")
        }
    }
}

// MARK: - Skalieren

enum ScaleDriver: MainCommandDriver {
    static let id = ModelCommandID.scale
    static let title = "Skalieren"
    static let icon = "sc.scale"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.scale)
        let input = PickInput(id: "bodies", title: "Körper", accepts: [.bodies], multiple: true, items: pre.bodyPicks,
                              hint: "Körper antippen (mehrere möglich).")
        let cmd = ModelCommand(id, inputs: [input])
        cmd.putNumber("factor", 1)
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let bodies = CommandPicks.bodies(cmd, "bodies", model: model)
        let changed = CommandSync.bodies(bodies, model)
        guard !bodies.isEmpty else {
            CommandCache.anchors[ObjectIdentifier(cmd)] = nil
            return nil
        }
        // Pfeil-Bezug vor der Vorschau (danach zeigt das Netz schon die skalierten Körper)
        BodyCommandHelpers.cacheCenter(cmd, bodies, changed: changed, model)
        let factor = min(max(cmd.number("factor", default: 1), Workspace.scaleRange.lowerBound),
                         Workspace.scaleRange.upperBound)
        ws.scaleUniform = true
        ws.scaleFactors = SIMD3(repeating: factor)
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        guard factor != 1 else {
            model.dropPreview()
            return "Am Pfeil ziehen oder einen Faktor eingeben."
        }
        ws.updateToolPreview()
        return model.hasPreview ? nil : (model.message ?? "Skalieren nicht möglich.")
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard let anchor = CommandCache.anchors[ObjectIdentifier(cmd)], anchor.size > 1e-6 else { return [] }
        return [DragHandle(kind: .scale, axisOrigin: SIMD3<Float>(anchor.origin),
                           direction: SIMD3<Float>(anchor.direction),
                           value: cmd.number("factor", default: 1) * anchor.size, color: Workspace.handleBlue)]
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard kind == .scale, let radius = CommandCache.anchors[ObjectIdentifier(cmd)]?.size, radius > 1e-6,
              value.isFinite else { return }
        // Auf 0,01 gerundet, gleichmäßig (wie bisher)
        let rounded: Double = (value / radius * 100).rounded() / 100
        let factor: Double = min(max(rounded, Workspace.scaleRange.lowerBound), Workspace.scaleRange.upperBound)
        guard factor != cmd.number("factor", default: 1) else { return }
        cmd.putNumber("factor", factor)
        ws.scaleUniform = true
        ws.scaleFactors = SIMD3(repeating: factor)
        ws.updateToolPreview()
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "factor" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandNumberRow(title: "Faktor", cmd: cmd, key: "factor", fallback: 1, unit: "×", workspace: ws) { value in
                min(max(value, Workspace.scaleRange.lowerBound), Workspace.scaleRange.upperBound)
            }
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: ws)
            }
            PaletteHint(text: "Immer gleichmäßig um die Mitte der Auswahl (0,01× bis 100×).")
        })
    }
}

// MARK: - Negativform (★ PencilCAD)

enum MoldDriver: LegacyTapDriver {
    static let id = ModelCommandID.mold
    static let title = "Negativform"
    static let icon = "sc.combine"
    static let legacyTool = ModelTool.mold

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(MoldCard(workspace: ws, model: ws.model, settings: ws.mold))
    }
}
