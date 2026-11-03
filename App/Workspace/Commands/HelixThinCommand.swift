import SwiftUI
import simd

// Helix und Dünn extrudieren im Eigenschaften-Panel: beide nutzen die vorhandenen Werkzeuge (PartTools.swift,
// tool = .part(...)), das Panel zeigt deren Einstellungen senkrecht wie SolidCraft.

// MARK: - Helix

/// Helix (Feder, Vierkantfeder, Gewinde); eine Zylinderfläche antippen schneidet ein Gewinde hinein.
enum HelixCommand: ModelCommandDriver {
    static let id: ModelCommandID = .helix
    static let title = "Helix"
    static let icon = "sc.coil"
    static var explanation: String? {
        "Maße eingeben – die Helix steht im Ursprung entlang Z. Eine Zylinderfläche (Bolzen oder Bohrung) antippen "
            + "schneidet ein Gewinde in die Fläche."
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        let input = PickInput(id: "cylinder", title: "Zylinder", accepts: [.faces], multiple: false,
                              hint: "Zylinderfläche antippen, um ein Gewinde hineinzuschneiden", isOptional: true)
        let cmd = ModelCommand(.helix, inputs: [input])
        ws.tool = .part(.helix)
        ws.startPart(.helix)
        return cmd
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        if cmd.items("cylinder").isEmpty, ws.parts.helix.onCylinder {
            // „×“ im Feld: wieder frei im Ursprung
            ws.startPart(.helix)
        }
        ws.model.message = nil
        ws.updatePartPreview()
        return ws.model.hasPreview ? nil : ws.model.message
    }

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard let face = tap.face else { return tap.edge != nil }
        ws.partTapped(.helix, face: face, point: tap.point.map { SIMD3<Float>($0) })
        cmd.setItems("cylinder", ws.parts.helix.onCylinder ? [.face(face)] : [])
        cmd.error = ws.model.hasPreview ? nil : ws.model.message
        return true
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.commitPreview()
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(HelixRows(cmd: cmd, ws: ws, parts: ws.parts))
    }
}

private struct HelixRows: View {
    @ObservedObject var cmd: ModelCommand
    let ws: Workspace
    @ObservedObject var parts: PartSettings

    private static let profileOptions: [SegmentOption] = HelixProfile.allCases.map { profile in
        SegmentOption(id: profile.rawValue, label: profile.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelSegmentRow(title: "Profil", options: Self.profileOptions, selected: parts.helix.profile.rawValue) { id in
                guard let profile = HelixProfile(rawValue: id) else { return }
                parts.helix.profile = profile
                ws.refreshCommandPreview()
            }
            if parts.helix.onCylinder {
                PaletteHint(text: parts.helix.convex ? "Gewinde auf dem Bolzen" : "Gewinde in der Bohrung")
            }
            value("Durchmesser", "diameter", \.diameter)
            value("Steigung", "pitch", \.pitch)
            value("Höhe", "height", \.height)
            CommandValueRow(title: "Windungen", key: "turns", command: cmd, unit: "",
                            value: (parts.helix.turns * 100).rounded() / 100) { turns in
                guard turns > 0 else { return }
                parts.helix.height = turns * parts.helix.pitch
                ws.refreshCommandPreview()
            }
            if parts.helix.profile != .thread {
                value("Draht", "wire", \.wire)
            }
            CheckRow(title: "Linksgängig", isOn: Binding(get: { parts.helix.leftHanded }, set: { on in
                parts.helix.leftHanded = on
                ws.refreshCommandPreview()
            }))
            if !parts.helix.onCylinder {
                PanelSegmentRow(title: "Operation", options: CommandOperation.options,
                                selected: parts.helix.mode.rawValue) { id in
                    guard let mode = ExtrudeMode(rawValue: id) else { return }
                    parts.helix.mode = mode
                    ws.refreshCommandPreview()
                }
            }
        }
    }

    private func value(_ title: String, _ key: String, _ keyPath: WritableKeyPath<HelixSpec, Double>) -> some View {
        CommandValueRow(title: title, key: key, command: cmd, value: parts.helix[keyPath: keyPath]) { newValue in
            guard newValue > 0 else { return }
            parts.helix[keyPath: keyPath] = newValue
            ws.refreshCommandPreview()
        }
    }
}

// MARK: - Dünn extrudieren (Linien)

/// Linien einer Skizze (auch offene) als Wand (ModelStore.previewThinLines).
enum ThinExtrudeCommand: ModelCommandDriver {
    static let id: ModelCommandID = .thinExtrude
    static let title = "Dünn extrudieren"
    static let icon = "sc.rib"
    static var explanation: String? {
        "Die Linien einer Skizze werden zu Wänden – auch offene Linienzüge. Skizze in der Liste wählen oder einen "
            + "Bereich der Skizze antippen."
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        let input = PickInput(id: "sketch", title: "Skizze", accepts: [.sketches], multiple: false,
                              hint: "Bereich der Skizze antippen oder unten wählen")
        let cmd = ModelCommand(.thinExtrude, inputs: [input])
        if let first = ws.model.selectedRegions.first { ws.parts.thinSketch = first.sketch }
        ws.tool = .part(.thinLines)
        ws.startPart(.thinLines)
        if let sketch = ws.parts.thinSketch { cmd.setItems("sketch", [.sketch(sketch)]) }
        cmd.advance()
        return cmd
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        if let pick = cmd.items("sketch").first, case .sketch(let index) = pick {
            ws.parts.thinSketch = index
        } else {
            ws.parts.thinSketch = nil
        }
        ws.model.message = nil
        ws.updatePartPreview()
        guard ws.parts.thinSketch != nil else { return nil }
        return ws.model.hasPreview ? nil : (ws.model.message ?? "Diese Skizze hat keine Linien.")
    }

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        ws.model.commitPreview()
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ThinExtrudeRows(cmd: cmd, ws: ws, model: ws.model, parts: ws.parts))
    }
}

private struct ThinExtrudeRows: View {
    @ObservedObject var cmd: ModelCommand
    let ws: Workspace
    @ObservedObject var model: ModelStore
    @ObservedObject var parts: PartSettings

    private static let sideOptions: [SegmentOption] = ThinSide.allCases.map { side in
        SegmentOption(id: side.rawValue, label: side.lineTitle)
    }

    private var sketchName: String {
        guard let index = parts.thinSketch, model.sketches.indices.contains(index) else { return "Wählen" }
        return model.sketches[index].name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelMenuRow(title: "Skizze", value: sketchName) {
                ForEach(model.sketches.indices, id: \.self) { index in
                    Button(model.sketches[index].name) {
                        cmd.setItems("sketch", [.sketch(index)])
                        cmd.advance()
                        ws.refreshCommandPreview()
                    }
                }
            }
            PanelSegmentRow(title: "Seite", options: Self.sideOptions, selected: parts.thinSide.rawValue) { id in
                guard let side = ThinSide(rawValue: id) else { return }
                parts.thinSide = side
                ws.refreshCommandPreview()
            }
            CommandValueRow(title: "Stärke", key: "thickness", command: cmd, value: parts.thinThickness) { value in
                guard value > 0 else { return }
                parts.thinThickness = value
                ws.refreshCommandPreview()
            }
            CommandValueRow(title: parts.thinSymmetric ? "Je Seite" : "Höhe", key: "height", command: cmd,
                            value: parts.thinHeight) { value in
                guard value != 0 else { return }
                parts.thinHeight = value
                ws.refreshCommandPreview()
            }
            CheckRow(title: "Symmetrisch", isOn: Binding(get: { parts.thinSymmetric }, set: { on in
                parts.thinSymmetric = on
                ws.refreshCommandPreview()
            }))
            PanelSegmentRow(title: "Operation", options: CommandOperation.options, selected: parts.thinMode.rawValue) { id in
                guard let mode = ExtrudeMode(rawValue: id) else { return }
                parts.thinMode = mode
                ws.refreshCommandPreview()
            }
        }
    }
}
