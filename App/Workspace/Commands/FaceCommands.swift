import SwiftUI
import simd

// ÄNDERN › FLÄCHEN nach SolidCraft (A.2): Press Pull (Verteiler, ★ Kernel-Press-Pull ebener Flächen), Schale,
// Formschräge, Fläche versetzen (★ Abstand/Gesamt/Durchmesser), Fläche ersetzen, dazu die PencilCAD-eigenen
// Umhüllen/Prägen und Kante abdrücken (Antippen wie bisher).

@MainActor
enum FaceCommandHelpers {
    /// Ansatz und Richtung eines Pfeils an der Fläche: Normale bzw. bei Zylindern radial aus dem Material
    /// (wie Workspace.refreshOffsetFaceHandle; vor der Vorschau rechnen, weil sich dort die Flächennummern ändern).
    static func anchor(_ face: FaceRef, _ model: ModelStore) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        guard let center = model.mesh.centroid(of: face).map({ SIMD3<Double>($0) }) else { return nil }
        var direction: SIMD3<Double>
        if let plane = model.plane(of: face) {
            direction = plane.normal
        } else if let cylinder = model.cylinder(of: face) {
            direction = center - cylinder.origin
            direction -= simd_dot(direction, cylinder.axis) * cylinder.axis
            if !cylinder.convex { direction = -direction }
        } else {
            return nil
        }
        guard simd_length(direction) > 1e-9 else { return nil }
        return (center, simd_normalize(direction))
    }

    /// Flächen eines Körpers (des ersten gewählten); die übrigen bleiben außen vor.
    static func sameBody(_ faces: [FaceRef]) -> [FaceRef] {
        guard let body = faces.first?.body else { return [] }
        return faces.filter { $0.body == body }
    }

    static func faceCount(_ count: Int, none: String) -> String {
        count == 0 ? none : count == 1 ? "1 Fläche" : "\(count) Flächen"
    }
}

// MARK: - Press Pull

/// Press Pull wie SolidCraft (`lib.rs:1355-1392`): Kante → Abrunden, gekrümmte Fläche → Fläche versetzen,
/// ebene Fläche bzw. Profil → Extrudieren (M1); ohne Extrudieren-Treiber zieht der eigene Befehl ebene Flächen mit dem
/// Kernel (★ wie bisher, mehrere Flächen zugleich). Befehle anderer Treiber werden an diese weitergereicht.
enum PressPullDriver: ModelCommandDriver {
    static let id = ModelCommandID.pressPull
    static let title = "Press Pull"
    static let icon = "sc.presspull"

    /// Treiber eines weitergereichten Befehls (nil = eigener Befehl)
    private static func forwarded(_ cmd: ModelCommand) -> ModelCommandDriver.Type? {
        cmd.id == id ? nil : ModelCommands.driver(cmd.id)
    }

    static func make(_ ws: Workspace) -> ModelCommand {
        let box = MainActor.assumeIsolated { () -> UncheckedBox<ModelCommand> in
            UncheckedBox(PressPullCommand.dispatch(ws))
        }
        return box.value
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        if let other = forwarded(cmd) { return other.preview(cmd, ws) }
        return MainActor.assumeIsolated { () -> String? in
            guard cmd.editing == nil else { return nil }
            return CommandCache.run(cmd) { PressPullCommand.refresh(cmd, ws) }
        }
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        if let other = forwarded(cmd) {
            other.commit(cmd, ws)
            return
        }
        MainActor.assumeIsolated {
            if cmd.editing != nil {
                FeatureEdit.commit(cmd, ws.model)
            } else {
                PressPullCommand.finish(cmd, ws)
            }
            CommandCache.forget(cmd)
        }
    }

    static func cancel(_ cmd: ModelCommand, _ ws: Workspace) {
        if let other = forwarded(cmd) {
            other.cancel(cmd, ws)
            return
        }
        MainActor.assumeIsolated {
            if cmd.editing == nil { LegacyFinish.cancel(ws) }
            CommandCache.forget(cmd)
        }
    }

    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        if let other = forwarded(cmd) { return other.handles(cmd, ws) }
        return MainActor.assumeIsolated { () -> [DragHandle] in
            cmd.editing == nil ? PressPullCommand.arrows(cmd, ws) : []
        }
    }

    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        if let other = forwarded(cmd) {
            other.apply(handle: handle, value: value, cmd, ws)
            return
        }
        MainActor.assumeIsolated {
            guard cmd.editing == nil, handle == .face else { return }
            cmd.putNumber("distance", value)
            ws.model.setFaceValue(value)
            CommandCache.mark(cmd, error: nil)
        }
    }

    static func primaryValueKey(_ cmd: ModelCommand) -> String? {
        if let other = forwarded(cmd) { return other.primaryValueKey(cmd) }
        return cmd.editing == nil ? "distance" : nil
    }

    @MainActor static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        if let other = forwarded(cmd) { return other.rows(cmd, ws) }
        if cmd.editing != nil { return AnyView(FeatureEditRows(cmd: cmd, model: ws.model)) }
        return AnyView(PressPullRows(cmd: cmd, workspace: ws, model: ws.model))
    }

    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        feature.kind == .faceExtrude ? FeatureEdit.command(id, feature) : nil
    }
}

@MainActor
enum PressPullCommand {
    /// Verteiler nach der Vorauswahl
    static func dispatch(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        let pre = Preselection(model)
        if !pre.edges.isEmpty {
            return FilletDriver.build(ws)
        }
        if let face = pre.faces.first {
            if model.plane(of: face) == nil {
                return OffsetFaceDriver.build(ws)
            }
            if let extrude = ModelCommands.drivers[.extrude] {
                return extrude.make(ws)
            }
        } else if !pre.regions.isEmpty, let extrude = ModelCommands.drivers[.extrude] {
            return extrude.make(ws)
        }
        // Eigener Befehl: ebene Flächen ziehen (Auswahlwerkzeug, Pfeil an der Fläche)
        if ws.tool != .select || ws.sketch.isActive { ws.activate(.select) }
        let planar = pre.faces.filter { model.plane(of: $0) != nil }
        let input = PickInput(id: "faces", title: "Flächen", accepts: [.planarFaces], multiple: true,
                              items: planar.map { Pick.face($0) },
                              hint: "Ebene Flächen antippen (mehrere zugleich), dann am Pfeil ziehen.")
        let cmd = ModelCommand(PressPullDriver.id, inputs: [input])
        cmd.putNumber("distance", 0)
        return cmd
    }

    static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let faces = CommandPicks.faces(cmd, "faces").filter { model.plane(of: $0) != nil }
        // Ohne Fläche nichts anfassen (z. B. gewählte Skizzenbereiche bleiben gewählt)
        guard !faces.isEmpty else { return nil }
        CommandSync.pullFaces(faces, model)
        let distance = cmd.number("distance", default: 0)
        guard distance != 0 else {
            model.dropPreview()
            return "Am Pfeil ziehen oder einen Abstand eingeben."
        }
        model.setFaceValue(distance)
        return model.hasPreview ? nil : (model.message ?? "Diese Flächen lassen sich nicht ziehen.")
    }

    static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        if !ws.model.hasPreview { _ = refresh(cmd, ws) }
        LegacyFinish.commit(ws)
    }

    static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard ws.model.selection != nil, let handle = ws.model.faceHandle else { return [] }
        return [DragHandle(kind: .face, axisOrigin: SIMD3<Float>(handle.origin),
                           direction: simd_normalize(SIMD3<Float>(handle.direction)),
                           value: cmd.number("distance", default: ws.model.faceValue), color: Workspace.handleBlue)]
    }
}

private struct PressPullRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandValueRow(title: "Abstand", cmd: cmd, key: "distance", fallback: 0, workspace: workspace)
            // ★ Letzte Höhe wiederholen (auch Doppeltippen auf die Fläche)
            if let last = model.lastExtrudeValue {
                PrimaryWideButton(title: "Letzte Höhe \(LengthUnit.current.format(last))",
                                  systemImage: "arrow.uturn.backward", isPrimary: false) {
                    cmd.putNumber("distance", last)
                    CommandCache.refreshNow(cmd, workspace)
                }
            }
            CommandStatusRow(title: "Auswahl", text: FaceCommandHelpers.faceCount(model.selectedFaces.count,
                                                                                   none: "Ebene Fläche antippen"),
                             isDone: !model.selectedFaces.isEmpty)
            PaletteHint(text: "Kante antippen startet Abrunden, eine gekrümmte Fläche „Fläche versetzen“.")
        }
    }
}

// MARK: - Schale

enum ShellDriver: MainCommandDriver {
    static let id = ModelCommandID.shell
    static let title = "Schale"
    static let icon = "sc.shell"
    static let featureKinds: [FeatureKind] = [.shell]

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.shell)
        let items: [Pick] = pre.faces.isEmpty ? pre.bodyPicks : pre.facePicks
        let input = PickInput(id: "faces", title: "Flächen", accepts: [.faces, .bodies], multiple: true, items: items,
                              hint: "Offene Flächen antippen (mehrere eines Körpers). Ein ganzer Körper wird ein geschlossener Hohlkörper.")
        let cmd = ModelCommand(id, inputs: [input])
        cmd.putNumber("thickness", ws.shellThickness)
        cmd.flags["closed"] = ws.shellClosed
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let faces = FaceCommandHelpers.sameBody(CommandPicks.faces(cmd, "faces"))
        let bodies = CommandPicks.bodies(cmd, "faces", model: model)
        guard let body = faces.first?.body ?? bodies.first else {
            if model.selection != nil { CommandSync.faces([], model) }
            return nil
        }
        // Nur ein Körper ohne Fläche gewählt: geschlossener Hohlkörper (SolidCraft „Körper“)
        let closed = cmd.isOn("closed", default: false) || faces.isEmpty
        let thickness = cmd.number("thickness", default: 2)
        guard thickness > 0 else { return "Die Wandstärke muss größer als 0 sein." }
        ws.shellThickness = thickness
        ws.shellClosed = closed
        if closed {
            // Für den Hohlkörper zählt nur der Körper; die erste Fläche dient als Auswahl
            CommandSync.faces([faces.first ?? FaceRef(body: body, face: 1)], model)
        } else {
            CommandSync.faces(faces, model)
        }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        model.previewShell(thickness: thickness, closed: closed)
        return model.hasPreview ? nil : (model.message ?? "Schale hier nicht möglich.")
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        if !ws.model.hasPreview {
            cmd.previewEnabled = true
            _ = refresh(cmd, ws)
        }
        LegacyFinish.commit(ws)
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "thickness" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ShellRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct ShellRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandValueRow(title: "Dicke", cmd: cmd, key: "thickness", fallback: 2, workspace: workspace)
            // Der Kernel höhlt nach innen aus; Außen/Beide folgen mit einer Kernel-Funktion
            CommandSegmentRow(title: "Richtung", options: [CommandChoice(id: "inside", title: "Innen"),
                                                           CommandChoice(id: "outside", title: "Außen", isEnabled: false),
                                                           CommandChoice(id: "both", title: "Beide", isEnabled: false)],
                              selected: "inside") { _ in }
            PaletteSection("Optionen") {
                // ★ Geschlossener Hohlkörper (keine Fläche offen)
                CommandFlagRow(title: "Geschlossen (Hohlkörper)", icon: "cube", cmd: cmd, key: "closed",
                               workspace: workspace)
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            CommandStatusRow(title: "Auswahl", text: FaceCommandHelpers.faceCount(model.selectedFaces.count,
                                                                                   none: "Fläche antippen"),
                             isDone: model.selection != nil)
        }
    }
}

// MARK: - Formschräge

enum DraftDriver: MainCommandDriver {
    static let id = ModelCommandID.draft
    static let title = "Formschräge"
    static let icon = "sc.draft"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.part(.draft))
        let faces = PickInput(id: "faces", title: "Flächen", accepts: [.faces], multiple: true,
                              items: FaceCommandHelpers.sameBody(pre.faces).map { Pick.face($0) },
                              hint: "Seitenflächen antippen, die geneigt werden.")
        let plane = PickInput(id: "plane", title: "Neutral", accepts: [.planes, .planarFaces], multiple: false,
                              hint: "Optional: neutrale Ebene bzw. ebene Fläche – sonst gilt die Zugrichtung.",
                              isOptional: true)
        let cmd = ModelCommand(id, inputs: [faces, plane])
        cmd.putNumber("angle", ws.parts.draftAngle)
        cmd.choices["axis"] = String(ws.parts.draftAxis)
        cmd.flags["flip"] = ws.parts.draftFlip
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let faces = FaceCommandHelpers.sameBody(CommandPicks.faces(cmd, "faces"))
        guard !faces.isEmpty else {
            if model.selection != nil { CommandSync.faces([], model) }
            return nil
        }
        CommandSync.faces(faces, model)
        let axis = CommandAxes.index(cmd, "axis", default: 2)
        let flip = cmd.isOn("flip", default: false)
        let angle = cmd.number("angle", default: 3)
        ws.parts.draftAngle = angle
        ws.parts.draftAxis = axis
        ws.parts.draftFlip = flip
        var pull = unitAxis(axis)
        if let reference = CommandPicks.referencePlane(cmd, "plane"), let plane = model.resolve(reference) {
            pull = simd_normalize(plane.normal)
        }
        if flip { pull = -pull }
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        model.previewDraft(faces: model.selectedFaces, pull: pull, angle: angle)
        return model.hasPreview ? nil : (model.message ?? "Formschräge an diesen Flächen nicht möglich.")
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "angle" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(DraftRows(cmd: cmd, workspace: ws))
    }
}

private struct DraftRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandValueRow(title: "Winkel", cmd: cmd, key: "angle", fallback: 3, unit: "°", workspace: workspace)
            if cmd.items("plane").isEmpty {
                CommandOptionRow(title: "Zugrichtung", cmd: cmd, key: "axis", options: CommandAxes.choices,
                                 fallback: "2", workspace: workspace)
            }
            CommandFlagRow(title: "Richtung umkehren", icon: "arrow.up.arrow.down", cmd: cmd, key: "flip",
                           workspace: workspace)
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
        }
    }
}

// MARK: - Fläche versetzen

enum OffsetFaceDriver: MainCommandDriver {
    static let id = ModelCommandID.offsetFace
    static let title = "Fläche versetzen"
    static let icon = "sc.offset_face"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.offsetFace)
        let input = PickInput(id: "faces", title: "Flächen", accepts: [.faces], multiple: true, items: pre.facePicks,
                              hint: "Flächen antippen (eben oder rund, auch Bohrungen).")
        let cmd = ModelCommand(id, inputs: [input])
        cmd.choices["mode"] = ws.offsetFaceMode.rawValue
        if !pre.faces.isEmpty { cmd.putNumber("value", ws.offsetFaceValue) }
        return cmd
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let faces = CommandPicks.faces(cmd, "faces")
        ws.offsetFaceMode = OffsetFaceMode(rawValue: cmd.option("mode", default: OffsetFaceMode.distance.rawValue))
            ?? .distance
        guard let first = faces.first else {
            if model.selection != nil { CommandSync.faces([], model) }
            CommandCache.anchors[ObjectIdentifier(cmd)] = nil
            return nil
        }
        let changed = CommandSync.faces(faces, model)
        if changed || CommandCache.anchors[ObjectIdentifier(cmd)] == nil {
            // Pfeil vor der Vorschau bestimmen (danach zählen die Flächennummern der Vorschau)
            if !changed { model.dropPreview() }
            if let anchor = FaceCommandHelpers.anchor(first, model) {
                CommandCache.anchors[ObjectIdentifier(cmd)] = (anchor.origin, anchor.direction, 0)
            }
        }
        // Erste Fläche bzw. neue Art: Vorgabe wie bisher (1 mm, jetziges Gesamtmaß bzw. jetziger Ø)
        if cmd.values["value"] == nil { cmd.putNumber("value", ws.defaultOffsetFaceValue()) }
        ws.offsetFaceValue = cmd.number("value", default: 0)
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        guard ws.offsetFaceValue != 0 else {
            model.dropPreview()
            return "Am Pfeil ziehen oder einen Wert eingeben."
        }
        ws.updateOffsetFacePreview(explainsFailure: true)
        return model.hasPreview ? nil : (model.message ?? "Versetzen hier nicht möglich.")
    }

    @MainActor static func finish(_ cmd: ModelCommand, _ ws: Workspace) {
        if !ws.model.hasPreview {
            cmd.previewEnabled = true
            _ = refresh(cmd, ws)
        }
        LegacyFinish.commit(ws)
    }

    @MainActor static func arrows(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard ws.offsetFaceMode == .distance, let anchor = CommandCache.anchors[ObjectIdentifier(cmd)] else { return [] }
        return [DragHandle(kind: .offsetFace, axisOrigin: SIMD3<Float>(anchor.origin),
                           direction: SIMD3<Float>(anchor.direction), value: cmd.number("value", default: 0),
                           color: Workspace.handleBlue)]
    }

    @MainActor static func drag(_ kind: HandleKind, _ value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard kind == .offsetFace else { return }
        cmd.putNumber("value", value)
        ws.offsetFaceValue = value
        ws.updateOffsetFacePreview()
    }

    static func mainValueKey(_ cmd: ModelCommand) -> String? { "value" }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(OffsetFaceRows(cmd: cmd, workspace: ws, model: ws.model))
    }
}

private struct OffsetFaceRows: View {
    @ObservedObject var cmd: ModelCommand
    let workspace: Workspace
    @ObservedObject var model: ModelStore

    private static let modes = OffsetFaceMode.allCases.map { CommandChoice(id: $0.rawValue, title: $0.rawValue) }

    var body: some View {
        let mode = OffsetFaceMode(rawValue: cmd.option("mode", default: OffsetFaceMode.distance.rawValue)) ?? .distance
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            // ★ Wert als Versatz, Gesamtmaß des Körpers oder Durchmesser (Shapr3D)
            CommandOptionRow(title: "Art", cmd: cmd, key: "mode", options: Self.modes,
                             fallback: OffsetFaceMode.distance.rawValue, workspace: workspace) { _ in
                cmd.values["value"] = nil
            }
            CommandValueRow(title: mode.rawValue, cmd: cmd, key: "value", fallback: 0, workspace: workspace)
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: workspace)
            }
            CommandStatusRow(title: "Auswahl", text: FaceCommandHelpers.faceCount(model.selectedFaces.count,
                                                                                   none: "Flächen antippen"),
                             isDone: model.selection != nil)
            PaletteHint(text: mode == .distance ? "Plus = aus dem Material heraus, Minus = hinein."
                        : mode == .total ? "Gesamtmaß des Körpers senkrecht zur ebenen Fläche."
                        : "Durchmesser einer runden Fläche (Zapfen oder Bohrung).")
        }
    }
}

// MARK: - Fläche ersetzen

enum ReplaceFaceDriver: MainCommandDriver {
    static let id = ModelCommandID.replaceFace
    static let title = "Fläche ersetzen"
    static let icon = "sc.replace_face"

    @MainActor static func build(_ ws: Workspace) -> ModelCommand {
        let pre = Preselection(ws.model)
        ws.activate(.replaceFace)
        let faces = PickInput(id: "faces", title: "Flächen", accepts: [.faces], multiple: true, items: pre.facePicks,
                              hint: "Flächen antippen, die bis zum Ziel verlängert bzw. gekürzt werden.")
        let target = PickInput(id: "target", title: "Ziel", accepts: [.planarFaces], multiple: false,
                               hint: "Ebene Zielfläche antippen.")
        return ModelCommand(id, inputs: [faces, target])
    }

    @MainActor static func refresh(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        let faces = CommandPicks.faces(cmd, "faces")
        ws.pickingReplaceTarget = false
        guard !faces.isEmpty else {
            if model.selection != nil { CommandSync.faces([], model) }
            return nil
        }
        CommandSync.faces(faces, model)
        guard let target = CommandPicks.faces(cmd, "target").first else {
            ws.replaceTarget = nil
            return nil
        }
        guard model.plane(of: target) != nil else { return "Die Zielfläche muss eben sein." }
        ws.replaceTarget = target
        guard cmd.previewEnabled else {
            model.dropPreview()
            return nil
        }
        ws.updateReplacePreview()
        return model.hasPreview ? nil : (model.message ?? "Ersetzen bis zu dieser Fläche nicht möglich.")
    }

    @MainActor static func panel(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            PaletteSection("Optionen") {
                CommandPreviewRow(cmd: cmd, workspace: ws)
            }
            PaletteHint(text: "Die Flächen wachsen bzw. schrumpfen bis an die Zielfläche, die Nachbarflächen folgen.")
        })
    }
}

// MARK: - Umhüllen und Prägen, Kante abdrücken (★ PencilCAD, Antippen wie bisher)

enum WrapDriver: LegacyTapDriver {
    static let id = ModelCommandID.wrap
    static let title = "Umhüllen und Prägen"
    static let icon = "sc.emboss"
    static let legacyTool = ModelTool.wrap

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(WrapRows(workspace: ws, model: ws.model))
    }
}

private struct WrapRows: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandSegmentRow(title: "Art", options: [CommandChoice(id: "emboss", title: "Prägen"),
                                                      CommandChoice(id: "engrave", title: "Gravieren")],
                              selected: workspace.wrapDepth >= 0 ? "emboss" : "engrave") { id in
                let depth = abs(workspace.wrapDepth)
                workspace.wrapDepth = id == "emboss" ? depth : -depth
                workspace.updateWrapPreview()
            }
            PaletteNumberRow(title: "Tiefe", value: abs(workspace.wrapDepth)) { value in
                guard value > 0 else { return }
                workspace.wrapDepth = workspace.wrapDepth >= 0 ? value : -value
                workspace.updateWrapPreview()
            }
            PaletteNumberRow(title: "Drehung", value: workspace.wrapRotation, unit: "°") { value in
                workspace.wrapRotation = value
                workspace.updateWrapPreview()
            }
            CommandStatusRow(title: "Bereiche", text: model.selectedRegions.isEmpty ? "Skizzenbereiche antippen"
                             : "\(model.selectedRegions.count) gewählt", isDone: !model.selectedRegions.isEmpty)
            CommandStatusRow(title: "Zylinder", text: workspace.wrapFace == nil ? "Zylinderfläche antippen" : "gewählt",
                             isDone: workspace.wrapFace != nil)
        }
    }
}

enum ImprintDriver: LegacyTapDriver {
    static let id = ModelCommandID.imprint
    static let title = "Kante abdrücken"
    static let icon = "sc.project_surface"
    static let legacyTool = ModelTool.imprint

    @MainActor static func content(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(ImprintRows(model: ws.model))
    }
}

private struct ImprintRows: View {
    @ObservedObject var model: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: PaletteStyle.spacing) {
            CommandStatusRow(title: "Bereiche", text: model.selectedRegions.isEmpty ? "Skizzenbereiche antippen"
                             : "\(model.selectedRegions.count) gewählt", isDone: !model.selectedRegions.isEmpty)
            CommandStatusRow(title: "Körper", text: model.hasPreview ? "abgedrückt" : "Körper antippen",
                             isDone: model.hasPreview)
            PaletteHint(text: "Die Umrisse der Skizze werden als Kanten auf den Körper übertragen (z. B. zum Färben "
                        + "oder Ziehen einzelner Felder).")
        }
    }
}
