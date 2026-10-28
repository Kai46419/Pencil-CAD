import SwiftUI
import simd

// Blech-Assistent „Kasten aus Maßen“ (Punkt 10): fertiges Außen- bzw. Innenmaß L × B, Laschenhöhe (eine für alle oder
// je Seite, Seiten einzeln an/aus), Blechdicke und Biegeradius → gekantetes Teil aus Boden und Laschen mit
// Eckfreischnitten, als ein Verlaufsschritt „Blech: Kasten“.
//
// Umsetzung mit vorhandenen SolidCraft-Befehlen (SheetKit/COMMANDS.md): Blechregel (Dicke, Radius; K-Faktor und
// Freischnitte aus der aktiven Regel) → Skizze „XY“ mit dem Bodenrechteck (Mitte im Ursprung) → Grundflansch →
// ein Kantenflansch an allen gewählten Bodenkanten (oben, Laschen nach +Z). Der Flansch steht mit
// position „inside“ (äußerer virtueller Scheitel auf der Kante) innerhalb des Bodens, die Außenmaße bleiben also die
// des Bodens; die Höhe misst ab dem äußeren (Außenmaß) bzw. inneren (Innenmaß, height_from „inner“) Scheitel.
// Ecken, an denen zwei Laschen zusammenstoßen, schneidet SolidCraft mit Form und Spalt der Regel frei.

// MARK: - Maße

/// Eingaben des Assistenten (mm).
struct SheetBoxSpec: Hashable {
    var length: Double
    var width: Double
    var thickness: Double
    var radius: Double
    /// true = Außenmaß (L, B, Höhen außen), false = Innenmaß
    var outer: Bool
    /// Laschenhöhe je Seite: vorne (−Y), rechts (+X), hinten (+Y), links (−X); nil = keine Lasche
    var heights: [Double?]

    static let sideTitles = ["Vorne", "Rechts", "Hinten", "Links"]
}

extension ModelStore {
    /// Gekanteten Kasten als neuen Blechkörper (ein Verlaufsschritt). preview = nur Vorschau.
    @discardableResult
    func createSheetBox(_ spec: SheetBoxSpec, preview: Bool = false) -> Bool {
        sheetRun(preview: preview) { try self.sheetBoxPlan(spec) }
    }

    /// Rezept des Kastens: Regel, Bodenskizze, Grundflansch, Kantenflansch an den gewählten Seiten.
    func sheetBoxPlan(_ spec: SheetBoxSpec) throws -> SheetPlan {
        guard spec.thickness > 0, spec.radius >= 0 else { throw SheetKernelError("Dicke und Radius prüfen.") }
        let heights = (0..<4).map { spec.heights.indices.contains($0) ? spec.heights[$0] : nil }
        // Innenmaß: je Lasche an einem Ende kommt die Dicke dazu (der Boden reicht bis unter die Außenfläche)
        let extraX = spec.outer ? 0 : spec.thickness * Double((heights[1] != nil ? 1 : 0) + (heights[3] != nil ? 1 : 0))
        let extraY = spec.outer ? 0 : spec.thickness * Double((heights[0] != nil ? 1 : 0) + (heights[2] != nil ? 1 : 0))
        let length = spec.length + extraX
        let width = spec.width + extraY
        guard length > 2 * spec.thickness, width > 2 * spec.thickness else {
            throw SheetKernelError("Der Kasten ist zu klein für diese Blechdicke.")
        }
        // Regel: aktive Regel (K-Faktor, Freischnitte, Spalt) mit Dicke und Radius des Assistenten; eigene Regel nur im
        // Rezept, wenn die Werte abweichen
        let active = sheetDocument.activeRule
        var rule = active
        if abs(active.thickness - spec.thickness) > 1e-9 || abs(active.effectiveBendRadius - spec.radius) > 1e-9 {
            rule.name = "\(active.name) · \(Self.sheetNumberText(spec.thickness)) mm R\(Self.sheetNumberText(spec.radius))"
            rule.thickness = spec.thickness
            rule.bendRadius = spec.radius
        }
        let sketch = Self.sheetSketchName()
        let (hx, hy) = (length / 2, width / 2)
        var steps = [SheetStep("Kasten", rule.command(active: true))]
        steps.append(SheetStep("Skizze", SheetCommand("sketch.create", ["name": .string(sketch), "plane": "XY"])))
        steps.append(SheetStep("Skizze", SheetCommand("sketch.line", [
            "points": [SheetJSON(SIMD2(-hx, -hy)), SheetJSON(SIMD2(hx, -hy)), SheetJSON(SIMD2(hx, hy)),
                       SheetJSON(SIMD2(-hx, hy))],
            "closed": true,
        ])))
        steps.append(Self.sheetSketchFinish())
        let kernelBody = "Blech"
        steps.append(SheetStep("Grundflansch", SheetCommand("sheet.flange", [
            "type": "base", "sketch": .string(sketch), "rule": .string(rule.name), "body_name": .string(kernelBody),
        ])))
        // Oberkanten des Bodens (Dicke wächst nach +Z): Laschen stehen nach oben
        let t = spec.thickness
        let points = [SIMD3(0, -hy, t), SIMD3(hx, 0, t), SIMD3(0, hy, t), SIMD3(-hx, 0, t)]
        var edges: [SheetJSON] = []
        var common: Double?
        for side in 0..<4 {
            guard let height = heights[side] else { continue }
            guard height > 0 else { throw SheetKernelError("Laschenhöhe \(SheetBoxSpec.sideTitles[side]) muss größer als 0 sein.") }
            edges.append(["point": SheetJSON(points[side]), "height": .number(height)])
            if common == nil { common = height }
        }
        if let common {
            var params: SheetJSON = [
                "type": "edge", "edges": .array(edges), "height": .number(common), "angle": SheetCommand.degrees(90),
                "position": "inside",
            ]
            if !spec.outer { params["height_from"] = "inner" }
            steps.append(SheetStep("Laschen", SheetCommand("sheet.flange", params)))
        }
        let info = SheetBodyInfo(steps: steps, kernelBody: kernelBody, rule: rule.name)
        let built = try sheetBuild(info, base: nil, name: "Kasten")
        let data = SheetFeatureData(mode: "create", steps: steps, bodyName: built.body.name, kernelBody: kernelBody,
                                    rule: rule.name, sketchID: nil)
        let feature = Self.sheetFeature("Blech: Kasten", data: data, target: nil)
        return SheetPlan(bodies: bodies + [built.body], feature: feature, name: "Kasten", warnings: built.warnings)
    }
}

// MARK: - Treiber

enum SheetBoxDriver: MainCommandDriver {
    static let id = ModelCommandID.sheetBox
    static let title = "Kasten aus Maßen"
    static let icon = "shippingbox"
    static var explanation: String? {
        "Fertige Maße eingeben: Länge × Breite, Laschenhöhe (für alle oder je Seite), Blechdicke und Biegeradius. "
            + "Daraus wird ein gekanteter Kasten mit Boden, Laschen und Eckfreischnitten. „Abwicklung zeigen“ öffnet "
            + "danach den Zuschnitt."
    }

    static let sideKeys = ["front", "right", "back", "left"]
    static let measures = [CommandChoice(id: "outer", title: "Außenmaß"), CommandChoice(id: "inner", title: "Innenmaß")]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let rule = ws.model.sheetDocument.activeRule
        let cmd = ModelCommand(id, inputs: [])
        cmd.putNumber("length", 300)
        cmd.putNumber("width", 200)
        cmd.putNumber("height", 40)
        cmd.putNumber("thickness", rule.thickness)
        cmd.putNumber("radius", rule.effectiveBendRadius)
        cmd.choices["measure"] = "outer"
        cmd.flags["perSide"] = false
        for key in sideKeys {
            cmd.flags["side.\(key)"] = true
            cmd.putNumber("height.\(key)", 40)
        }
        ws.model.resetSelection()
        return cmd
    }

    @MainActor static func spec(_ cmd: ModelCommand) -> SheetBoxSpec {
        let perSide = cmd.isOn("perSide", default: false)
        let common = cmd.number("height", default: 40)
        let heights: [Double?] = sideKeys.map { key in
            guard cmd.isOn("side.\(key)", default: true) else { return nil }
            return perSide ? cmd.number("height.\(key)", default: common) : common
        }
        return SheetBoxSpec(length: cmd.number("length", default: 300), width: cmd.number("width", default: 200),
                            thickness: cmd.number("thickness", default: 2), radius: cmd.number("radius", default: 2),
                            outer: cmd.option("measure", default: "outer") == "outer", heights: heights)
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        guard model.sheetAvailable else {
            model.dropPreview()
            return model.sheetUnavailableReason
        }
        let box = spec(cmd)
        guard box.length > 0, box.width > 0 else {
            model.dropPreview()
            return "Länge und Breite müssen größer als 0 sein."
        }
        guard box.thickness > 0 else {
            model.dropPreview()
            return "Die Blechdicke muss größer als 0 sein."
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        if model.createSheetBox(box, preview: true) { return nil }
        return SheetPick.failure(model, "Kasten mit diesen Maßen nicht möglich.")
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil && ws.model.hasPreview
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.commit(ws)
    }

    @MainActor static func abort(_ cmd: ModelCommand, _ ws: Workspace) {
        SheetCommandState.forget(cmd)
        LegacyFinish.cancel(ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "height" }

    /// OK und gleich den Zuschnitt zeigen (vorhandenes „Flachmuster erstellen“ mit dem neuen, letzten Blechkörper)
    @MainActor static func commitAndShowFlat(_ ws: Workspace) {
        ws.confirmCommand()
        guard ws.command == nil else { return }
        SheetUI.start(.sheetFlatPattern, ws)
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(SheetBoxRows(cmd: cmd, workspace: ws, model: ws.model, document: ws.model.sheetDocument))
    }
}

// MARK: - Panel

private struct SheetBoxRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var document: SheetDocument

    var body: some View {
        let outer = cmd.option("measure", default: "outer") == "outer"
        let perSide = cmd.isOn("perSide", default: false)
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            SheetUnavailableRow(model: model)
            SheetToolPreview(sketch: .box)
            CommandOptionRow(title: "Maßbezug", cmd: cmd, key: "measure", options: SheetBoxDriver.measures,
                             fallback: "outer", workspace: workspace)
            value(outer ? "Länge außen" : "Länge innen", "length", fallback: 300)
            value(outer ? "Breite außen" : "Breite innen", "width", fallback: 200)
            PaletteSection("Laschen") {
                CommandFlagRow(title: "Je Seite eigene Höhe", icon: "square.split.2x2", cmd: cmd, key: "perSide",
                               workspace: workspace)
                if !perSide {
                    value(outer ? "Laschenhöhe außen" : "Laschenhöhe innen", "height", fallback: 40)
                }
                ForEach(SheetBoxDriver.sideKeys.indices, id: \.self) { index in
                    let key = SheetBoxDriver.sideKeys[index]
                    CommandFlagRow(title: SheetBoxSpec.sideTitles[index], icon: "rectangle.portrait", cmd: cmd,
                                   key: "side.\(key)", fallback: true, workspace: workspace)
                    if perSide, cmd.isOn("side.\(key)", default: true) {
                        value("Höhe \(SheetBoxSpec.sideTitles[index].lowercased())", "height.\(key)",
                              fallback: cmd.number("height", default: 40))
                    }
                }
            }
            PaletteSection("Blech") {
                value("Blechdicke", "thickness", fallback: 2)
                value("Biegeradius (innen)", "radius", fallback: 2, minimum: 0)
                SheetInfoRow(title: "K-Faktor, Freischnitte", text: "aus Regel „\(document.activeRule.name)“ (K "
                    + document.activeRule.kFactor.formatted(.number.precision(.fractionLength(0...3))) + ")",
                             color: .secondary)
            }
            PrimaryWideButton(title: "OK und Abwicklung zeigen", systemImage: "rectangle.dashed", isPrimary: false) {
                SheetBoxDriver.commitAndShowFlat(workspace)
            }
            .disabled(cmd.error != nil || !model.hasPreview)
            .accessibilityLabel("Kasten übernehmen und Abwicklung zeigen")
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }

    private func value(_ title: String, _ key: String, fallback: Double, minimum: Double = 0.01) -> some View {
        CommandValueRow(title: title, key: key, command: cmd, value: cmd.number(key, default: fallback)) {
            cmd.putNumber(key, max(minimum, $0))
            CommandCache.refreshNow(cmd, workspace)
        }
    }
}
