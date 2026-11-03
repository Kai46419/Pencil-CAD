import SwiftUI
import simd

// Grundkörper nach SolidCraft (MIT, dialogs.rs Box/Cylinder/Sphere/Torus/Cone): Maße · Position X/Y/Z (Antippen einer
// Fläche, Ecke oder Kante setzt den Punkt, „×“ = Ursprung) · Operation. „Neuer Körper“ rechnet
// ModelStore.previewInsert (mit Nachbau im Verlauf), die anderen Operationen und ein Kegelstumpf werden als fester
// Stand gespeichert. Dazu Helix und Dünn extrudieren über die vorhandenen Werkzeuge (PartTools.swift).

/// Gemeinsamer Treiber der fünf Grundkörper; die Typen unten legen nur Grundkörper, Titel und Symbol fest.
@MainActor
protocol PrimitiveDriver: ModelCommandDriver {
    static var primitive: Primitive { get }
}

enum PrimitiveKey {
    static let x = "x"
    static let y = "y"
    static let z = "z"
    static let top = "top"
    static let px = "px"
    static let py = "py"
    static let pz = "pz"
}

@MainActor
extension PrimitiveDriver {
    static var title: String { primitive.rawValue }
    static var icon: String { primitive.systemImage }
    static var explanation: String? {
        "Maße eingeben oder am Pfeil ziehen. Eine Fläche, Ecke oder Kante antippen setzt den Fußpunkt, „×“ im Feld "
            + "setzt ihn zurück in den Ursprung."
    }

    /// Startmaße nach SolidCraft: 20 mm (Torus 20/5, Kegel Ø 20 auf Ø 0)
    static func make(_ ws: Workspace) -> ModelCommand {
        let input = PickInput(id: "position", title: "Position", accepts: [.points], multiple: false,
                              hint: "Fläche, Ecke oder Kante antippen – dort steht der Fußpunkt", isOptional: true)
        let cmd = ModelCommand(id, inputs: [input])
        cmd.setNumber(PrimitiveKey.x, 20)
        cmd.setNumber(PrimitiveKey.y, 20)
        cmd.setNumber(PrimitiveKey.z, primitive == .torus ? 5 : 20)
        cmd.setNumber(PrimitiveKey.top, 0)
        cmd.setNumber(PrimitiveKey.px, 0)
        cmd.setNumber(PrimitiveKey.py, 0)
        cmd.setNumber(PrimitiveKey.pz, 0)
        cmd.choices["operation"] = ExtrudeMode.newBody.rawValue
        cmd.autoOperation = false
        ws.model.resetSelection()
        ws.tool = .insert(primitive)
        return cmd
    }

    static func primaryValueKey(_ cmd: ModelCommand) -> String? {
        primitive == .sphere || primitive == .torus ? PrimitiveKey.x : PrimitiveKey.z
    }

    static func base(_ cmd: ModelCommand) -> SIMD3<Double> {
        SIMD3<Double>(cmd.number(PrimitiveKey.px, default: 0), cmd.number(PrimitiveKey.py, default: 0),
                      cmd.number(PrimitiveKey.pz, default: 0))
    }

    static func size(_ cmd: ModelCommand) -> SIMD3<Double> {
        let x = cmd.number(PrimitiveKey.x, default: 20)
        let y = primitive == .box ? cmd.number(PrimitiveKey.y, default: 20) : x
        let z = primitive == .sphere ? x : cmd.number(PrimitiveKey.z, default: 20)
        return SIMD3<Double>(x, y, z)
    }

    /// Eigene Form (Kegelstumpf, andere Operation als „Neuer Körper“): wie ModelStore.previewInsert
    static func shape(_ cmd: ModelCommand) -> PCKShape? {
        let size = Self.size(cmd)
        let base = Self.base(cmd)
        switch primitive {
        case .box:
            return PCKShape.box(width: size.x, depth: size.y, height: size.z).translated(by: base)
        case .cylinder:
            return PCKShape.cylinder(base: base, axis: [0, 0, 1], radius: size.x / 2, height: size.z)
        case .sphere:
            let center: SIMD3<Double> = base + SIMD3<Double>(0, 0, size.x / 2)
            return PCKShape.sphere(center: center, radius: size.x / 2)
        case .cone:
            let top = max(0, cmd.number(PrimitiveKey.top, default: 0))
            return PCKShape.cone(base: base, axis: [0, 0, 1], bottomRadius: size.x / 2, topRadius: top / 2, height: size.z)
        case .torus:
            guard size.z < size.x else { return nil }
            let center: SIMD3<Double> = base + SIMD3<Double>(0, 0, size.z / 2)
            return PCKShape.torus(center: center, axis: [0, 0, 1], majorRadius: size.x / 2, minorRadius: size.z / 2)
        }
    }

    static func preview(_ cmd: ModelCommand, _ ws: Workspace) -> String? {
        let model = ws.model
        // Bearbeiten aus dem Verlauf: gerechnet wird bei OK mit dem Nachbau
        if cmd.editing != nil { return nil }
        if cmd.items("position").isEmpty, cmd.choices["positionSet"] == "1" {
            // „×“ im Feld: zurück in den Ursprung
            cmd.setNumber(PrimitiveKey.px, 0)
            cmd.setNumber(PrimitiveKey.py, 0)
            cmd.setNumber(PrimitiveKey.pz, 0)
            cmd.choices["positionSet"] = nil
        }
        let size = Self.size(cmd)
        guard size.x > 0, size.y > 0, size.z > 0 else {
            model.dropPreview()
            return "Maße müssen größer als 0 sein."
        }
        if primitive == .torus, size.z >= size.x {
            model.dropPreview()
            return "Der Rohr-Ø muss kleiner als der Ø sein."
        }
        let mode = CommandOperation.mode(cmd)
        let frustum = primitive == .cone && cmd.number(PrimitiveKey.top, default: 0) > 0
        model.message = nil
        if mode == .newBody, !frustum {
            model.previewInsert(primitive, size: size, at: base(cmd))
            return model.hasPreview ? nil : (model.message ?? "Maße ungültig.")
        }
        guard model.requireKernel() else { return model.message }
        guard let solid = shape(cmd), let result = model.extrusionResult(solid, sourceBody: nil, mode: mode) else {
            model.dropPreview()
            return mode == .newBody ? "Maße ungültig." : "Mit den vorhandenen Körpern nicht möglich."
        }
        // Ohne Feature-Notiz: wird beim OK als fester Stand gespeichert
        model.showPreview(result, name: "\(primitive.rawValue) einfügen")
        return nil
    }

    static func tapped(_ tap: CommandTap, _ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        guard let p = tap.point, !tap.isEmpty else { return false }
        let snapped = ws.model.snappedModelPoint(p, tolerance: ws.pickTolerance)
        cmd.setNumber(PrimitiveKey.px, (snapped.x * 1000).rounded() / 1000)
        cmd.setNumber(PrimitiveKey.py, (snapped.y * 1000).rounded() / 1000)
        cmd.setNumber(PrimitiveKey.pz, (snapped.z * 1000).rounded() / 1000)
        cmd.setItems("position", [.point(snapped)])
        cmd.choices["positionSet"] = "1"
        cmd.error = nil
        ws.refreshCommandPreview()
        return true
    }

    static func handles(_ cmd: ModelCommand, _ ws: Workspace) -> [DragHandle] {
        guard ws.model.hasPreview, primitive != .torus else { return [] }
        let key = primaryValueKey(cmd) ?? PrimitiveKey.z
        let value = cmd.number(key, default: 20)
        return [DragHandle(kind: .command(key), axisOrigin: SIMD3<Float>(base(cmd)), direction: SIMD3<Float>(0, 0, 1),
                           value: value, color: Workspace.handleBlue)]
    }

    static func apply(handle: HandleKind, value: Double, _ cmd: ModelCommand, _ ws: Workspace) {
        guard case .command(let key) = handle else { return }
        let rounded = (value * 100).rounded() / 100
        guard rounded > 0.01, rounded != cmd.number(key, default: 20) else { return }
        cmd.setNumber(key, rounded)
        ws.refreshCommandPreview()
    }

    static func valueText(handle: HandleKind, value: Double, _ cmd: ModelCommand) -> String? {
        primitive == .sphere ? "Ø " + LengthUnit.current.format(value) : nil
    }

    static func commit(_ cmd: ModelCommand, _ ws: Workspace) {
        if let id = cmd.editing {
            PrimitiveEdit.commit(id, cmd, ws, primitive: primitive)
        } else {
            ws.model.commitPreview()
        }
    }

    static func load(_ feature: Feature, into ws: Workspace) -> ModelCommand? {
        guard feature.kind == .primitive, feature.data.primitive == primitive.rawValue else { return nil }
        let cmd = make(ws)
        let x = feature.value("x") ?? 20
        cmd.setNumber(PrimitiveKey.x, x)
        cmd.setNumber(PrimitiveKey.y, feature.value("y") ?? x)
        cmd.setNumber(PrimitiveKey.z, feature.value("z") ?? x)
        let base = feature.data.origin ?? .zero
        cmd.setNumber(PrimitiveKey.px, base.x)
        cmd.setNumber(PrimitiveKey.py, base.y)
        cmd.setNumber(PrimitiveKey.pz, base.z)
        cmd.editing = feature.id
        return cmd
    }

    /// Bearbeiten: keine Vorschau auf dem jetzigen Stand, OK schreibt die Maße ins Feature und baut nach.
    static func canCommit(_ cmd: ModelCommand, _ ws: Workspace) -> Bool {
        if cmd.editing != nil { return cmd.error == nil }
        return cmd.error == nil && ws.model.hasPreview
    }

    static func rows(_ cmd: ModelCommand, _ ws: Workspace) -> AnyView {
        AnyView(PrimitiveRows(cmd: cmd, ws: ws, primitive: primitive))
    }
}

/// Bearbeiten eines Grundkörpers aus dem Verlauf (gemeinsam für alle fünf).
@MainActor
enum PrimitiveEdit {
    static func commit(_ id: UUID, _ cmd: ModelCommand, _ ws: Workspace, primitive: Primitive) {
        let model = ws.model
        guard let index = model.features.firstIndex(where: { $0.id == id }) else { return }
        var list = model.features
        var feature = list[index]
        let x = cmd.number(PrimitiveKey.x, default: 20)
        ExtrudeCommand.setParameter(&feature, .length("x", primitive == .box ? "Breite" : "Durchmesser", x))
        if primitive == .box {
            ExtrudeCommand.setParameter(&feature, .length("y", "Tiefe", cmd.number(PrimitiveKey.y, default: 20)))
        }
        if primitive != .sphere {
            let title = primitive == .torus ? "Rohr-Ø" : "Höhe"
            ExtrudeCommand.setParameter(&feature, .length("z", title, cmd.number(PrimitiveKey.z, default: 20)))
        }
        feature.data.origin = SIMD3<Double>(cmd.number(PrimitiveKey.px, default: 0), cmd.number(PrimitiveKey.py, default: 0),
                                            cmd.number(PrimitiveKey.pz, default: 0))
        list[index] = feature
        model.replayFeatures(from: index, features: list, sketches: nil, name: "„\(feature.name)“ ändern")
    }
}

enum BoxCommand: PrimitiveDriver {
    static let id: ModelCommandID = .box
    static let primitive: Primitive = .box
}

enum CylinderCommand: PrimitiveDriver {
    static let id: ModelCommandID = .cylinder
    static let primitive: Primitive = .cylinder
}

enum SphereCommand: PrimitiveDriver {
    static let id: ModelCommandID = .sphere
    static let primitive: Primitive = .sphere
}

enum TorusCommand: PrimitiveDriver {
    static let id: ModelCommandID = .torus
    static let primitive: Primitive = .torus
}

enum ConeCommand: PrimitiveDriver {
    static let id: ModelCommandID = .cone
    static let primitive: Primitive = .cone
}

private struct PrimitiveRows: View {
    @ObservedObject var cmd: ModelCommand
    let ws: Workspace
    let primitive: Primitive

    private typealias Key = PrimitiveKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sizeRows
            Text("Position")
                .font(.caption)
                .foregroundStyle(.secondary)
            value("X", Key.px, default: 0)
            value("Y", Key.py, default: 0)
            value("Z", Key.pz, default: 0)
            if cmd.editing == nil {
                CommandOperation.row(cmd, ws)
                if CommandOperation.mode(cmd) != .newBody
                    || (primitive == .cone && cmd.number(Key.top, default: 0) > 0) {
                    PaletteHint(text: "Wird als fester Stand gespeichert (Maße später nicht im Verlauf änderbar).")
                }
            }
        }
    }

    @ViewBuilder private var sizeRows: some View {
        switch primitive {
        case .box:
            value("Breite", Key.x, default: 20)
            value("Tiefe", Key.y, default: 20)
            value("Höhe", Key.z, default: 20)
        case .cylinder:
            value("Durchmesser", Key.x, default: 20)
            value("Höhe", Key.z, default: 20)
        case .sphere:
            value("Durchmesser", Key.x, default: 20)
        case .torus:
            value("Durchmesser", Key.x, default: 20)
            value("Rohr-Ø", Key.z, default: 5)
        case .cone:
            value("Ø unten", Key.x, default: 20)
            if cmd.editing == nil {
                value("Ø oben", Key.top, default: 0)
            }
            value("Höhe", Key.z, default: 20)
        }
    }

    private func value(_ title: String, _ key: String, default fallback: Double) -> some View {
        CommandValueRow(title: title, key: key, command: cmd, value: cmd.number(key, default: fallback)) { newValue in
            cmd.setNumber(key, newValue)
            ws.refreshCommandPreview()
        }
    }
}
