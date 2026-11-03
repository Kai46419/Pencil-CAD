import SwiftUI
import simd

// Drehen nach SolidCraft (MIT, dialogs.rs Revolve, dialogs_dense.rs): Profil (Skizzenbereiche) · Achse (Skizzenlinie,
// gerade Kante, runde Kante, Zylinderfläche, X/Y/Z, Konstruktionsachse) · Typ Winkel/Bis Objekt · Richtung · Winkel ·
// Winkel 2 · Operation. Eine Seite rechnet ModelStore.previewRevolve (mit Nachbau im Verlauf); Symmetrisch und Zwei
// Seiten drehen das Profil vorher um den Startwinkel und werden als fester Stand gespeichert.

/// Geometrie-Hilfen der Modellbefehle (Achsen aus Picks, Bereiche umschalten).
@MainActor
enum CommandGeometry {
    /// Achse aus einem Pick: Bezugsachse, gerade Kante, Kreiskante (Mitte + Normale) oder Zylinderfläche.
    static func axis(_ pick: Pick, sketch: Int?, model: ModelStore) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        switch pick {
        case .axis(let reference):
            return model.resolve(reference, sketch: sketch)
        case .edge(let edge):
            return edgeAxis(edge, model: model)
        case .face(let face):
            guard let cylinder = model.cylinder(of: face) else { return nil }
            return (cylinder.origin, cylinder.axis)
        default:
            return nil
        }
    }

    static func edgeAxis(_ edge: EdgeRef, model: ModelStore) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        guard let line = model.edgePolylines(edge).first, line.count >= 2 else { return nil }
        if let center = ModelStore.circleCenter(line) {
            let a: SIMD3<Double> = line[0] - center
            let b: SIMD3<Double> = line[line.count / 4] - center
            let normal: SIMD3<Double> = simd_cross(a, b)
            guard simd_length(normal) > 1e-12 else { return nil }
            return (center, simd_normalize(normal))
        }
        let start = line[0]
        let end = line[line.count - 1]
        let length = simd_distance(start, end)
        guard length > 1e-9 else { return nil }
        let direction: SIMD3<Double> = (end - start) / length
        // Nur gerade Kanten taugen als Achse
        for p in line {
            let offset: SIMD3<Double> = p - start
            let along: Double = simd_dot(offset, direction)
            let off: Double = simd_length(offset - direction * along)
            if off > max(1e-3, length * 1e-3) { return nil }
        }
        return (start, direction)
    }

    /// Bereich im Feld umschalten; ein Bereich einer anderen Skizze beginnt neu (Profile liegen in einer Skizze).
    static func toggleRegion(_ region: RegionRef, in cmd: ModelCommand, inputID: String) {
        guard let index = cmd.inputIndex(inputID) else { return }
        let current = cmd.inputs[index].items
        let sameSketch = current.allSatisfy { pick in
            if case .region(let ref) = pick { return ref.sketch == region.sketch }
            return false
        }
        if !sameSketch {
            cmd.inputs[index].items = [.region(region)]
        } else if let existing = current.firstIndex(of: .region(region)) {
            cmd.inputs[index].items.remove(at: existing)
        } else {
            cmd.inputs[index].items.append(.region(region))
        }
        cmd.activeInput = index
        cmd.advance()
    }

    /// Mitte der Bereiche (Mittel der Polygonpunkte) in Weltkoordinaten.
    static func center(of regions: [RegionRef], model: ModelStore) -> SIMD3<Double>? {
        var sum = SIMD3<Double>(repeating: 0)
        var count = 0
        for ref in regions where model.sketches.indices.contains(ref.sketch) {
            let sketch = model.sketches[ref.sketch]
            guard sketch.regions.indices.contains(ref.region) else { continue }
            for p in sketch.regions[ref.region].polygon {
                sum += sketch.plane.world(p)
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// Ebene um eine Achse gedreht (Startwinkel beim symmetrischen Drehen).
    static func rotated(_ plane: SketchPlane, origin: SIMD3<Double>, axis: SIMD3<Double>, degrees: Double) -> SketchPlane {
        let q = simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis))
        var result = plane
        result.origin = origin + q.act(plane.origin - origin)
        result.anchor = origin + q.act(plane.anchor - origin)
        result.u = q.act(plane.u)
        result.v = q.act(plane.v)
        result.normal = q.act(plane.normal)
        result.base = nil
        return result
    }
}

enum RevolveCommand: ModelCommandDriver {
    static let id: ModelCommandID = .revolve
    static let title = "Drehen"
    static let icon = "sc.revolve"
    static var explanation: String? {
        "Skizzenbereich antippen, dann die Achse: eine Linie der Skizze (Liste), eine gerade oder runde Kante, eine "
            + "Zylinderfläche oder X/Y/Z. Die Achse darf das Profil nicht schneiden."
    }

    enum Key {
        static let angle = "angle"
        static let angle2 = "angle2"
    }

    static func profilesInput() -> PickInput {
        PickInput(id: "profiles", title: "Profil", accepts: [.regions], multiple: true,
                  hint: "Skizzenbereiche antippen, die gedreht werden")
    }

    static func axisInput() -> PickInput {
        PickInput(id: "axis", title: "Achse", accepts: [.axes], multiple: false,
                  hint: "Gerade oder runde Kante, Zylinderfläche antippen – oder eine Achse aus der Liste")
    }

    static func targetInput() -> PickInput {
        PickInput(id: "toObject", title: "Bis Objekt", accepts: [.points], multiple: false,
                  hint: "Stelle antippen, bis zu der gedreht wird")
    }

    // MARK: Anlegen

    static func make(_ ws: Workspace) -> ModelCommand {
        let model = ws.model
        var profiles = profilesInput()
        let selected = model.selectedRegions
        if let first = selected.first {
            profiles.items = selected.filter { $0.sketch == first.sketch }.map { Pick.region($0) }
        }
        var axis = axisInput()
        if let first = selected.first, let line = model.sketchLines(first.sketch).first {
            // Wie Shapr3D: eine Linie der Skizze als Achse vorschlagen
            axis.items = [.axis(.sketchLine(line.index))]
        }
        let cmd = ModelCommand(.revolve, inputs: [profiles, axis])
        cmd.setNumber(Key.angle, 360)
        cmd.setNumber(Key.angle2, 90)
        cmd.choices["direction"] = ExtrudeDirection.oneSide.rawValue
        cmd.choices["extent"] = "angle"
        cmd.choices["operation"] = ExtrudeMode.newBody.rawValue
        cmd.autoOperation = false
        // Altes Werkzeug für Overlays und gegen den Extrudieren-Pfeil der Auswahl
        ws.tool = .revolve
        return cmd
    }

    static func primaryValueKey(_ cmd: ModelCommand) -> String? { Key.angle }

    static func syncInputs(_ cmd: ModelCommand) {
        if cmd.choice("extent", default: "angle") == "toObject" {
            cmd.ensureInput(targetInput(), after: "axis")
        } else {
            cmd.removeInput("toObject")
        }
        cmd.advance()
    }

    static func resolvedAxis(_ cmd: ModelCommand, _ model: ModelStore) -> (origin: SIMD3<Double>, direction: SIMD3<Double>)? {
        guard let pick = cmd.items("axis").first else { return nil }
        let sketch = ExtrudeCommand.regionRefs(cmd).first?.sketch
        return CommandGeometry.axis(pick, sketch: sketch, model: model)
    }

    /// Winkel aus dem Feld bzw. bis zur angetippten Stelle (um die Achse, von der Profilmitte aus).
    static func angle(_ cmd: ModelCommand, _ model: ModelStore, axis: (origin: SIMD3<Double>, direction: SIMD3<Double>))
        -> Double? {
        guard cmd.choice("extent", default: "angle") == "toObject" else { return cmd.number(Key.angle, default: 360) }
        guard let pick = cmd.items("toObject").first, case .point(let target) = pick,
              let center = CommandGeometry.center(of: ExtrudeCommand.regionRefs(cmd), model: model) else { return nil }
        let d = simd_normalize(axis.direction)
        var from: SIMD3<Double> = center - axis.origin
        from -= d * simd_dot(from, d)
        var to: SIMD3<Double> = target - axis.origin
        to -= d * simd_dot(to, d)
        guard simd_length(from) > 1e-9, simd_length(to) > 1e-9 else { return nil }
        var degrees: Double = atan2(simd_dot(simd_cross(from, to), d), simd_dot(from, to)) * 180 / .pi
        if degrees <= 0.01 { degrees += 360 }
        return (degrees * 100).rounded() / 100
    }

    // MARK: Vorschau

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        if cmd.editing != nil { return nil }
        let regions = ExtrudeCommand.regionRefs(cmd)
        guard !regions.isEmpty else {
            model.dropPreview()
            model.resetSelection()
            return nil
        }
        model.selectRegions(regions)
        guard !cmd.items("axis").isEmpty else {
            model.dropPreview()
            return nil
        }
        guard let axis = resolvedAxis(cmd, model) else {
            model.dropPreview()
            return "Diese Achse lässt sich nicht verwenden (gerade oder runde Kante, Zylinderfläche, Linie)."
        }
        guard let degrees = angle(cmd, model, axis: axis) else {
            model.dropPreview()
            return nil
        }
        guard degrees != 0 else {
            model.dropPreview()
            return "Winkel 0 ergibt keinen Körper."
        }
        let mode = CommandOperation.mode(cmd)
        let flip = cmd.flag("flip")
        let direction = CommandDirection.direction(cmd)
        model.message = nil
        if direction == .oneSide || cmd.choice("extent", default: "angle") == "toObject" {
            model.previewRevolve(axisOrigin: axis.origin, axis: axis.direction, degrees: flip ? -degrees : degrees, mode: mode)
            guard model.hasPreview else { return model.message ?? "Drehen nicht möglich." }
            let target: SIMD3<Double>?
            if let pick = cmd.items("toObject").first, case .point(let p) = pick { target = p } else { target = nil }
            model.notePanelData(extent: cmd.choice("extent", default: "angle"), toObject: target, fromObject: nil,
                                operationAuto: false, flipped: flip)
            return nil
        }
        // Symmetrisch bzw. zwei Seiten: Profil um den Startwinkel zurückdrehen, dann über den Gesamtwinkel drehen
        let first = min(360, abs(degrees))
        let second = direction == .twoSides ? min(360, abs(cmd.number(Key.angle2, default: 90))) : 0
        let start: Double = direction == .symmetric ? -first / 2 : -second
        let total: Double = min(360, direction == .symmetric ? first : first + second)
        let sign: Double = flip ? -1 : 1
        guard model.requireKernel() else { return model.message }
        var shapes: [PCKShape] = []
        for entry in model.regions(regions) {
            let plane = CommandGeometry.rotated(entry.plane, origin: axis.origin, axis: axis.direction, degrees: start * sign)
            guard let shape = PCKShape.revolve(profileWires: profileWires(entry.region, plane: plane),
                                               axisOrigin: axis.origin, axisDirection: simd_normalize(axis.direction),
                                               angle: total * sign * .pi / 180) else {
                model.dropPreview()
                return "Drehen nicht möglich (Achse darf das Profil nicht schneiden)."
            }
            shapes.append(shape)
        }
        let source = model.regions(regions).first?.plane.sourceBody
        // Ohne Feature-Notiz: wird beim OK als fester Stand gespeichert
        model.showSolid(shapes, sourceBody: source, mode: mode, name: "Drehen")
        return model.hasPreview ? nil : (model.message ?? "Drehen nicht möglich.")
    }

    // MARK: Antippen

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil {
            ws.model.message = "Beim Bearbeiten bleiben Profil und Achse; Werte im Panel ändern."
            return true
        }
        let activeID: String = cmd.inputs.indices.contains(cmd.activeInput) ? cmd.inputs[cmd.activeInput].id : "profiles"
        if activeID == "toObject", let p = tap.point {
            cmd.setItems("toObject", [.point(ws.model.snappedModelPoint(p, tolerance: ws.pickTolerance))])
            cmd.advance()
            ws.refreshCommandPreview()
            return true
        }
        if let region = tap.region {
            CommandGeometry.toggleRegion(region, in: cmd, inputID: "profiles")
            if cmd.items("axis").isEmpty, let line = ws.model.sketchLines(region.sketch).first {
                cmd.setItems("axis", [.axis(.sketchLine(line.index))])
            }
            cmd.error = nil
            ws.refreshCommandPreview()
            return true
        }
        return false
    }

    // MARK: Pfeil

    /// Tangentialer Pfeil an der Profilmitte; Länge = Winkel/90° × Abstand zur Achse.
    private static func arrow(_ cmd: ModelCommand, _ ws: Workspace)
        -> (origin: SIMD3<Double>, direction: SIMD3<Double>, radius: Double)? {
        let model = ws.model
        guard let axis = resolvedAxis(cmd, model),
              let center = CommandGeometry.center(of: ExtrudeCommand.regionRefs(cmd), model: model) else { return nil }
        let d = simd_normalize(axis.direction)
        var radial: SIMD3<Double> = center - axis.origin
        radial -= d * simd_dot(radial, d)
        let radius = simd_length(radial)
        guard radius > 1e-6 else { return nil }
        let tangent: SIMD3<Double> = simd_normalize(simd_cross(d, radial))
        return (center, cmd.flag("flip") ? -tangent : tangent, radius)
    }

    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard cmd.editing == nil, ws.model.hasPreview, cmd.choice("extent", default: "angle") == "angle",
              let arrow = Self.arrow(cmd, ws) else { return [] }
        let degrees = cmd.number(Key.angle, default: 360)
        return [DragHandle(kind: .command(Key.angle), axisOrigin: SIMD3<Float>(arrow.origin),
                           direction: SIMD3<Float>(arrow.direction), value: degrees / 90 * arrow.radius,
                           color: Workspace.handleBlue)]
    }

    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .command(let key) = handle, key == Key.angle, let arrow = Self.arrow(cmd, ws) else { return }
        var degrees: Double = (value / arrow.radius * 90).rounded()
        degrees = max(-360, min(360, degrees))
        guard degrees != 0, degrees != cmd.number(Key.angle, default: 360) else { return }
        cmd.setNumber(Key.angle, degrees)
        ws.refreshCommandPreview()
    }

    static func valueText(handle: HandleKind, value: Double, _ cmd: ModelCommand) -> String? {
        let degrees = cmd.number(Key.angle, default: 360)
        return "∠ " + degrees.formatted(.number.precision(.fractionLength(0...1))) + "°"
    }

    // MARK: OK, Bearbeiten

    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil && cmd.number(Key.angle, default: 0) != 0 }
        return cmd.isReady && cmd.error == nil && ws.model.hasPreview
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        guard let id = cmd.editing else {
            ws.model.commitPreview()
            return
        }
        let model = ws.model
        guard let index = model.features.firstIndex(where: { $0.id == id }) else { return }
        var list = model.features
        var feature = list[index]
        var degrees = max(-360, min(360, cmd.number(Key.angle, default: 360)))
        if cmd.flag("flip") { degrees = -degrees }
        ExtrudeCommand.setParameter(&feature, .angle("angle", "Winkel", degrees))
        let mode = CommandOperation.mode(cmd)
        feature.data.mode = mode.rawValue
        feature.data.flipped = nil
        if feature.name.hasPrefix("Drehen") {
            feature.name = mode == .newBody ? "Drehen" : "Drehen (\(mode.rawValue))"
        }
        list[index] = feature
        model.replayFeatures(from: index, features: list, sketches: nil, name: "„\(feature.name)“ ändern")
    }

    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        guard feature.kind == .revolve else { return nil }
        let model = ws.model
        var profiles = profilesInput()
        profiles.isOptional = true
        profiles.hint = "Beim Bearbeiten bleiben Profil und Achse des Features"
        profiles.items = (feature.data.regions ?? []).compactMap { probe -> Pick? in
            guard let index = model.sketches.firstIndex(where: { $0.id == probe.sketchID }) else { return nil }
            let region = model.sketches[index].region(containing: probe.point) ?? probe.index
            guard model.sketches[index].regions.indices.contains(region) else { return nil }
            return .region(RegionRef(sketch: index, region: region))
        }
        var axis = axisInput()
        axis.isOptional = true
        let cmd = ModelCommand(.revolve, inputs: [profiles, axis])
        let degrees = feature.value("angle") ?? 360
        cmd.setNumber(Key.angle, abs(degrees))
        cmd.setNumber(Key.angle2, 90)
        cmd.flags["flip"] = degrees < 0
        cmd.choices["direction"] = ExtrudeDirection.oneSide.rawValue
        cmd.choices["extent"] = "angle"
        cmd.choices["operation"] = feature.data.mode ?? ExtrudeMode.newBody.rawValue
        cmd.autoOperation = false
        cmd.editing = feature.id
        return cmd
    }

    // MARK: Panel

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(RevolveRows(cmd: cmd, ws: ws, model: ws.model))
    }
}

private struct RevolveRows: View {
    @ObservedObject var cmd: ModelCommand
    let ws: Workspace
    @ObservedObject var model: ModelStore

    private typealias Key = RevolveCommand.Key

    private static let extentOptions: [SegmentOption] = [
        SegmentOption(id: "angle", label: "Winkel"),
        SegmentOption(id: "toObject", label: "Bis Objekt"),
    ]

    private var editing: Bool { cmd.editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !editing {
                axisMenu
                PanelSegmentRow(title: "Typ", options: Self.extentOptions,
                                selected: cmd.choice("extent", default: "angle")) { id in
                    cmd.choices["extent"] = id
                    RevolveCommand.syncInputs(cmd)
                    ws.refreshCommandPreview()
                }
            }
            let isAngle = cmd.choice("extent", default: "angle") == "angle"
            if isAngle {
                if !editing {
                    PanelSegmentRow(title: "Richtung", options: CommandDirection.options,
                                    selected: CommandDirection.direction(cmd).rawValue) { id in
                        cmd.choices["direction"] = id
                        ws.refreshCommandPreview()
                    }
                }
                value("Winkel", Key.angle, default: 360)
                if CommandDirection.direction(cmd) == .twoSides, !editing {
                    value("Winkel 2", Key.angle2, default: 90)
                }
            }
            CommandOperation.row(cmd, ws)
            CheckRow(title: "Richtung umkehren", isOn: commandFlag("flip", cmd, ws))
            if !editing, CommandDirection.direction(cmd) != .oneSide, isAngle {
                PaletteHint(text: "Symmetrisch und zwei Seiten werden als fester Stand gespeichert.")
            }
        }
    }

    private var axisName: String {
        guard let pick = cmd.items("axis").first else { return "Wählen" }
        if case .axis(.sketchLine(let index)) = pick,
           let sketch = ExtrudeCommand.regionRefs(cmd).first?.sketch,
           let line = model.sketchLines(sketch).first(where: { $0.index == index }) {
            return line.name
        }
        return PickNames.name(pick, model: model)
    }

    private var axisMenu: some View {
        PanelMenuRow(title: "Achse", value: axisName) {
            Button("X-Achse") { setAxis(.world(0)) }
            Button("Y-Achse") { setAxis(.world(1)) }
            Button("Z-Achse") { setAxis(.world(2)) }
            if let sketch = ExtrudeCommand.regionRefs(cmd).first?.sketch {
                ForEach(model.sketchLines(sketch)) { line in
                    Button(line.name) { setAxis(.sketchLine(line.index)) }
                }
            }
            ForEach(model.constructions.filter { $0.kind == .axis }) { item in
                Button(item.name) { setAxis(.construction(item.id)) }
            }
        }
    }

    private func setAxis(_ axis: ReferenceAxis) {
        cmd.setItems("axis", [.axis(axis)])
        cmd.advance()
        ws.refreshCommandPreview()
    }

    private func value(_ title: String, _ key: String, default fallback: Double) -> some View {
        CommandValueRow(title: title, key: key, command: cmd, unit: "°", value: cmd.number(key, default: fallback)) { newValue in
            cmd.setNumber(key, newValue)
            ws.refreshCommandPreview()
        }
    }
}
