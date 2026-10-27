import Foundation
import simd

// Abziehen mit Spiel und Negativform (Kai: „ein 3D-Objekt modellieren und aus einem dicken, fetten Würfel
// ausschneiden – daraus soll sich das Negative ergeben“). Das Spiel dickt den Werkzeugkörper vor dem Abziehen um
// einige Zehntel auf (PCKShape.offsetSolid), damit das Teil später in die Aussparung passt. Die Negativform legt
// automatisch einen Block um einen Körper, schneidet ihn mit Spiel heraus und teilt die Form auf Wunsch in zwei
// Hälften. Die Oberfläche dazu steht in BooleanPanel.swift.

/// Vorlagen für das Spiel (eigene Werte, unabhängig vom Druckspiel der Gewinde).
enum ClearancePreset: String, CaseIterable, Identifiable {
    case none
    case fdm
    case resin

    var id: Self { self }

    var title: String {
        switch self {
        case .none: "Ohne Spiel 0"
        case .fdm: "FDM 0,2"
        case .resin: "Harz (SLA) 0,1"
        }
    }

    /// Spiel in mm
    var clearance: Double {
        switch self {
        case .none: 0
        case .fdm: 0.2
        case .resin: 0.1
        }
    }
}

/// Lage der Trennebene einer zweiteiligen Negativform (immer durch die Körpermitte).
enum MoldParting: Int, CaseIterable, Identifiable {
    /// Waagerecht: Normale Z (oben/unten)
    case horizontal = 2
    /// Senkrecht, Normale X (links/rechts)
    case x = 0
    /// Senkrecht, Normale Y (vorn/hinten)
    case y = 1

    var id: Self { self }

    var title: String {
        switch self {
        case .horizontal: "Waagerecht"
        case .x: "Senkrecht X"
        case .y: "Senkrecht Y"
        }
    }

    var normal: SIMD3<Double> {
        switch self {
        case .horizontal: SIMD3<Double>(0, 0, 1)
        case .x: SIMD3<Double>(1, 0, 0)
        case .y: SIMD3<Double>(0, 1, 0)
        }
    }

    /// Namen der beiden Hälften (Seite in Gegen- bzw. Normalenrichtung)
    var halfNames: (low: String, high: String) {
        switch self {
        case .horizontal: ("Formhälfte unten", "Formhälfte oben")
        case .x: ("Formhälfte links", "Formhälfte rechts")
        case .y: ("Formhälfte vorn", "Formhälfte hinten")
        }
    }
}

/// Einstellungen der Negativform.
struct MoldSpec: Equatable {
    /// Wandstärke des Blocks um den Körper (je Seite), mm
    var margin: Double = 10
    /// Spiel zwischen Körper und Aussparung, mm
    var clearance: Double = 0
    /// Form an der Trennebene in zwei Hälften teilen
    var halves = false
    var parting: MoldParting = .horizontal
}

extension ModelStore {
    /// Werkzeugkörper einer booleschen Operation: beim Abziehen um das Spiel aufgedickt, sonst unverändert.
    /// nil, wenn das Aufdicken scheitert.
    static func booleanTool(_ shape: PCKShape, kind: BooleanKind, clearance: Double) -> PCKShape? {
        guard kind == .subtract, clearance > 0 else { return shape }
        return shape.offsetSolid(distance: clearance)
    }

    static func clearanceFailure(_ clearance: Double) -> String {
        "Spiel \(LengthUnit.current.format(clearance)) nicht möglich: der Werkzeugkörper ließ sich nicht aufdicken "
            + "(z. B. sehr feine Rundungen oder Spitzen). Kleineres Spiel oder 0 versuchen."
    }

    /// Vorschau einer booleschen Verknüpfung (Ändern › Vereinigen, Abziehen, Schneiden). Die Werkzeugkörper bleiben in
    /// der Liste, damit die Körpernummern beim Antippen stimmen, sind aber ausgeblendet – der Viewport zeigt sie
    /// halbtransparent rot (BooleanPanel.swift). Übernommen wird mit applyBoolean, nicht mit commitPreview.
    func previewBoolean(_ kind: BooleanKind, target: Int, tools: [Int], clearance: Double) {
        guard requireKernel(), bodies.indices.contains(target) else { return }
        let used: [Int] = tools.filter { bodies.indices.contains($0) && $0 != target }
        guard !used.isEmpty else {
            dropPreview()
            return
        }
        var shape = bodies[target].shape
        for tool in used {
            guard let other = Self.booleanTool(bodies[tool].shape, kind: kind, clearance: clearance) else {
                message = Self.clearanceFailure(clearance)
                dropPreview()
                return
            }
            let combined: PCKShape?
            switch kind {
            case .union: combined = shape.fusing(other)
            case .subtract: combined = shape.cutting(other)
            case .intersect: combined = shape.intersecting(other)
            }
            guard let combined else {
                message = "\(kind.rawValue) nicht möglich."
                dropPreview()
                return
            }
            shape = combined
        }
        var preview = bodies
        preview[target] = preview[target].with(shape)
        for tool in used {
            preview[tool].isHidden = true
        }
        message = nil
        showPreview(preview, name: kind.rawValue, plain: true)
    }

    /// Hüllquader eines Körpers aus der Geometrie (min, max); nil ohne Kernel.
    func exactBounds(ofBody index: Int) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard bodies.indices.contains(index),
              let values = bodies[index].shape.boundingBox?.map(\.doubleValue), values.count == 6 else { return nil }
        let low = SIMD3<Double>(values[0], values[1], values[2])
        let high = SIMD3<Double>(values[3], values[4], values[5])
        return (low, high)
    }

    /// Negativform (Vorschau): Block mit Rand um den Körper, Körper mit Spiel herausgeschnitten, wahlweise an der
    /// Ebene durch die Körpermitte in zwei Hälften geteilt. Der Körper selbst bleibt unverändert erhalten; die Form
    /// kommt als neue Körper dazu (Übernahme mit commitPreview, im Verlauf ein fester Stand).
    func previewMold(body index: Int, spec: MoldSpec) {
        guard requireKernel(), bodies.indices.contains(index) else { return }
        let source = bodies[index]
        guard let bounds = exactBounds(ofBody: index) else {
            message = "Größe von „\(source.name)“ nicht bestimmbar."
            dropPreview()
            return
        }
        let margin: Double = max(spec.margin, 0.1)
        let border = SIMD3<Double>(repeating: 2 * margin)
        let size: SIMD3<Double> = bounds.max - bounds.min + border
        let center: SIMD3<Double> = (bounds.min + bounds.max) / 2
        let base = SIMD3<Double>(center.x, center.y, bounds.min.z - margin)
        guard let block = PCKShape.box(width: size.x, depth: size.y, height: size.z).translated(by: base) else {
            message = "Block für die Negativform nicht möglich."
            dropPreview()
            return
        }
        guard let tool = Self.booleanTool(source.shape, kind: .subtract, clearance: spec.clearance) else {
            message = Self.clearanceFailure(spec.clearance)
            dropPreview()
            return
        }
        guard let negative = block.cutting(tool) else {
            message = "Negativform nicht möglich: der Körper ließ sich nicht aus dem Block schneiden."
            dropPreview()
            return
        }
        var pieces: [(name: String, shape: PCKShape)] = [(name: "Negativform \(source.name)", shape: negative)]
        if spec.halves {
            guard let halves = negative.split(planeOrigin: center, normal: spec.parting.normal), halves.count >= 2 else {
                message = "Teilen an der Mitte nicht möglich – andere Trennebene versuchen."
                dropPreview()
                return
            }
            pieces = Self.namedHalves(halves, center: center, parting: spec.parting)
        }
        var preview = bodies
        for (offset, piece) in pieces.enumerated() {
            let color: SIMD3<Float> = Self.moldColors[offset % Self.moldColors.count]
            preview.append(SceneBody(shape: piece.shape, name: piece.name, color: color))
        }
        let unit = LengthUnit.current
        let sizeText = "\(unit.number(size.x)) × \(unit.number(size.y)) × \(unit.format(size.z))"
        message = spec.halves ? "Zweiteilige Form, Block \(sizeText) – „Fertig“ übernimmt."
            : "Form-Block \(sizeText) – „Fertig“ übernimmt."
        showPreview(preview, name: "Negativform")
    }

    /// Farben der Formteile (hell und gut vom Körper zu unterscheiden)
    private static let moldColors: [SIMD3<Float>] = [[0.55, 0.72, 0.88], [0.88, 0.70, 0.45], [0.62, 0.80, 0.62]]

    /// Hälften nach ihrer Lage zur Trennebene benennen (Schwerpunkt unter bzw. über der Mitte).
    private static func namedHalves(_ halves: [PCKShape], center: SIMD3<Double>,
                                    parting: MoldParting) -> [(name: String, shape: PCKShape)] {
        let names = parting.halfNames
        var result: [(name: String, shape: PCKShape)] = []
        for (offset, half) in halves.enumerated() {
            var name = "Formteil \(offset + 1)"
            if let values = half.centerOfMass?.map(\.doubleValue), values.count == 3 {
                let point = SIMD3<Double>(values[0], values[1], values[2])
                let side: Double = simd_dot(point - center, parting.normal)
                name = side < 0 ? names.low : names.high
            }
            result.append((name: name, shape: half))
        }
        return result
    }
}
