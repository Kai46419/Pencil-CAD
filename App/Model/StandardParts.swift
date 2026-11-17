import Foundation
import simd

// MARK: - Normteile und parametrische Vorlagen

/// Normteile (Einfügen › Normteile). Maße aus den Normtabellen unten; Gewinde vereinfacht.
enum StandardPartKind: String, CaseIterable, Identifiable, Codable {
    case socketScrew = "Zylinderschraube ISO 4762"
    case hexScrew = "Sechskantschraube ISO 4017"
    // Build 83 (Kai): weitere Kopfformen und Montagehülse
    case lowHeadScrew = "Flachkopfschraube DIN 7984"
    case countersunkScrew = "Senkkopfschraube ISO 10642"
    case buttonScrew = "Linsenkopfschraube ISO 7380-1"
    case flangeButtonScrew = "Linsenkopf mit Scheibe ISO 7380-2"
    case nut = "Sechskantmutter ISO 4032"
    case washer = "Scheibe ISO 7089"
    case sleeve = "Montagehülse"
    case bearing = "Kugellager 6xx"

    var id: Self { self }

    var isScrew: Bool {
        switch self {
        case .socketScrew, .hexScrew, .lowHeadScrew, .countersunkScrew, .buttonScrew, .flangeButtonScrew: true
        default: false
        }
    }

    /// Steckt mit der Achse in einer Bohrung (Schrauben, Hülse): „In Loch zentrieren“
    var fitsInHole: Bool { isScrew || self == .sleeve }

    /// Sitzt auf einer Schraube (Mutter, Scheibe): „Auf Schraube setzen“
    var mountsOnScrew: Bool { self == .nut || self == .washer }

    var systemImage: String {
        switch self {
        case .socketScrew, .hexScrew, .lowHeadScrew, .countersunkScrew, .buttonScrew, .flangeButtonScrew: "sc.fastener"
        case .nut: "hexagon"
        case .washer: "circle.circle"
        case .sleeve: "cylinder"
        case .bearing: "circle.dotted.circle"
        }
    }
}

/// Parametrische Vorlagen (Einfügen › Vorlagen).
enum TemplateKind: String, CaseIterable, Identifiable {
    case enclosure = "Gehäuse"
    case gear = "Stirnrad"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .enclosure: "shippingbox"
        case .gear: "gearshape"
        }
    }
}

/// Maße einer metrischen Größe (Regelgewinde) nach ISO 4762, ISO 4017, ISO 4032 und ISO 7089, in mm.
struct MetricSize {
    let name: String
    /// Nenndurchmesser und Steigung
    let d: Double
    let pitch: Double
    /// ISO 4762: Kopfdurchmesser dk, Kopfhöhe k, Schlüsselweite Innensechskant s, Tiefe t
    let headDiameter: Double
    let headHeight: Double
    let socket: Double
    let socketDepth: Double
    /// ISO 4017 / ISO 4032: Schlüsselweite s, Kopfhöhe k, Mutterhöhe m
    let hexWidth: Double
    let hexHeadHeight: Double
    let nutHeight: Double
    /// ISO 7089: Innen-Ø d1, Außen-Ø d2, Dicke h
    let washerInner: Double
    let washerOuter: Double
    let washerThickness: Double

    /// Index in all (M2, M2,5, M3, M4, M5, M6, M8, M10)
    private var index: Int { Self.all.firstIndex { $0.name == name } ?? 2 }

    // Build 83: Kopfmaße weiterer Normen (Tabellenwerte; M2/M2,5 dort, wo die Norm sie nicht führt, angenähert)
    /// DIN 7984 (niedriger Zylinderkopf): Kopfhöhe, Schlüsselweite
    var lowHeadHeight: Double { [1.5, 1.8, 2, 2.8, 3.5, 4, 5, 6][index] }
    var lowHeadSocket: Double { [1.3, 1.5, 2, 2.5, 3, 4, 5, 7][index] }
    /// ISO 10642 (Senkkopf, 90°): Kopf-Ø, Kopfhöhe, Schlüsselweite
    var countersunkDiameter: Double { [4.4, 5.5, 6.72, 8.96, 11.2, 13.44, 17.92, 22.4][index] }
    var countersunkHeight: Double { [1.2, 1.5, 1.86, 2.48, 3.1, 3.72, 4.96, 6.2][index] }
    var countersunkSocket: Double { [1.3, 1.5, 2, 2.5, 3, 4, 5, 6][index] }
    /// ISO 7380-1 (Linsenkopf): Kopf-Ø, Kopfhöhe, Schlüsselweite
    var buttonDiameter: Double { [3.8, 4.7, 5.7, 7.6, 9.5, 10.5, 14, 17.5][index] }
    var buttonHeight: Double { [1.1, 1.4, 1.65, 2.2, 2.75, 3.3, 4.4, 5.5][index] }
    var buttonSocket: Double { [1.3, 1.5, 2, 2.5, 3, 4, 5, 6][index] }
    /// ISO 7380-2 (Linsenkopf mit Bund): Bund-Ø und Bundhöhe (angenähert)
    var flangeDiameter: Double { [4.4, 5.4, 6.5, 8.6, 10.6, 12.5, 16.6, 20.8][index] }
    var flangeHeight: Double { [0.35, 0.4, 0.5, 0.6, 0.7, 0.8, 1, 1.2][index] }

    /// Build 88: Feingewinde nach ISO 261 (gängigste Feinsteigung je Größe)
    var finePitch: Double { [0.25, 0.35, 0.35, 0.5, 0.5, 0.75, 1, 1.25][index] }

    static let all: [MetricSize] = [
        MetricSize(name: "M2", d: 2, pitch: 0.4, headDiameter: 3.8, headHeight: 2, socket: 1.5, socketDepth: 1,
                   hexWidth: 4, hexHeadHeight: 1.4, nutHeight: 1.6, washerInner: 2.2, washerOuter: 5, washerThickness: 0.3),
        MetricSize(name: "M2,5", d: 2.5, pitch: 0.45, headDiameter: 4.5, headHeight: 2.5, socket: 2, socketDepth: 1.1,
                   hexWidth: 5, hexHeadHeight: 1.7, nutHeight: 2, washerInner: 2.7, washerOuter: 6, washerThickness: 0.5),
        MetricSize(name: "M3", d: 3, pitch: 0.5, headDiameter: 5.5, headHeight: 3, socket: 2.5, socketDepth: 1.3,
                   hexWidth: 5.5, hexHeadHeight: 2, nutHeight: 2.4, washerInner: 3.2, washerOuter: 7, washerThickness: 0.5),
        MetricSize(name: "M4", d: 4, pitch: 0.7, headDiameter: 7, headHeight: 4, socket: 3, socketDepth: 2,
                   hexWidth: 7, hexHeadHeight: 2.8, nutHeight: 3.2, washerInner: 4.3, washerOuter: 9, washerThickness: 0.8),
        MetricSize(name: "M5", d: 5, pitch: 0.8, headDiameter: 8.5, headHeight: 5, socket: 4, socketDepth: 2.5,
                   hexWidth: 8, hexHeadHeight: 3.5, nutHeight: 4.7, washerInner: 5.3, washerOuter: 10, washerThickness: 1),
        MetricSize(name: "M6", d: 6, pitch: 1, headDiameter: 10, headHeight: 6, socket: 5, socketDepth: 3,
                   hexWidth: 10, hexHeadHeight: 4, nutHeight: 5.2, washerInner: 6.4, washerOuter: 12, washerThickness: 1.6),
        MetricSize(name: "M8", d: 8, pitch: 1.25, headDiameter: 13, headHeight: 8, socket: 6, socketDepth: 4,
                   hexWidth: 13, hexHeadHeight: 5.3, nutHeight: 6.8, washerInner: 8.4, washerOuter: 16, washerThickness: 1.6),
        MetricSize(name: "M10", d: 10, pitch: 1.5, headDiameter: 16, headHeight: 10, socket: 8, socketDepth: 5,
                   hexWidth: 16, hexHeadHeight: 6.4, nutHeight: 8.4, washerInner: 10.5, washerOuter: 20, washerThickness: 2),
    ]

    /// Gängige Schraubenlängen (ISO 4762/4017), je Größe ab etwa 1,5 × d.
    static let lengths: [Double] = [3, 4, 5, 6, 8, 10, 12, 16, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 80, 90, 100]

    var standardLengths: [Double] { Self.lengths.filter { $0 >= 1.5 * d && $0 <= 20 * d } }
}

/// Rillenkugellager der Reihen 60, 62 und 6xx (Miniatur): Bohrung d, Außen-Ø D, Breite B in mm.
struct BearingSize {
    let name: String
    let d: Double
    let outer: Double
    let width: Double

    static let all: [BearingSize] = [
        BearingSize(name: "623", d: 3, outer: 10, width: 4),
        BearingSize(name: "624", d: 4, outer: 13, width: 5),
        BearingSize(name: "625", d: 5, outer: 16, width: 5),
        BearingSize(name: "626", d: 6, outer: 19, width: 6),
        BearingSize(name: "608", d: 8, outer: 22, width: 7),
        BearingSize(name: "6000", d: 10, outer: 26, width: 8),
        BearingSize(name: "6001", d: 12, outer: 28, width: 8),
        BearingSize(name: "6200", d: 10, outer: 30, width: 9),
        BearingSize(name: "6201", d: 12, outer: 32, width: 10),
        BearingSize(name: "6202", d: 15, outer: 35, width: 11),
        BearingSize(name: "6203", d: 17, outer: 40, width: 12),
        BearingSize(name: "6204", d: 20, outer: 47, width: 14),
    ]
}

/// Einstellungen für Normteile.
struct StandardPartSpec: Codable, Hashable {
    var kind: StandardPartKind = .socketScrew
    /// Index in MetricSize.all
    var size = 2
    var length: Double = 12
    /// Gewinde als echte Schraubenlinie (langsam); sonst glatter Schaft mit Nenn-Ø
    var realThread = false
    /// Bei aus dem Namen übernommenen Altteilen ist die tatsächliche Gewindegeometrie unbekannt.
    var threadGeometryKnown = true
    /// Festigkeitsklasse ist eine Angabe des Bauteils, nicht aus seiner Geometrie ableitbar.
    var propertyClass = "Nicht festgelegt"
    /// Index in BearingSize.all
    var bearing = 4
    /// Kugeln zwischen den Ringen (mit Laufrillen)
    var balls = true
    /// Build 83: Montagehülse Innen- und Außen-Ø (0 = aus der Größe: d + 0,3 bzw. 1,8 × d)
    var sleeveInner: Double = 0
    var sleeveOuter: Double = 0
    /// Build 88: Feingewinde (ISO 261) statt Regelgewinde
    var finePitch = false

    /// Steigung des gewählten Gewindes (Regel- oder Feingewinde)
    var pitch: Double { finePitch ? metric.finePitch : metric.pitch }

    /// Gewindebezeichnung, z. B. „M3“ bzw. „M8×1“ (Feingewinde)
    var threadDesignation: String {
        finePitch ? "\(metric.name)×\(pitch.formatted())" : metric.name
    }

    /// Gewindetiefe außen (ISO 68-1: h3 ≈ 0,6134 · P) und Kerndurchmesser d3 ≈ d − 1,2269 · P
    var threadDepth: Double { 0.6134 * pitch }
    var minorDiameter: Double { metric.d - 1.2269 * pitch }

    var sleeveInnerDiameter: Double { sleeveInner > 0 ? sleeveInner : metric.d + 0.3 }
    var sleeveOuterDiameter: Double { max(sleeveOuter > 0 ? sleeveOuter : 1.8 * metric.d, sleeveInnerDiameter + 0.4) }

    /// Höhe des Kopfes über der Auflage (Senkkopf: liegt unter der Auflage, oben bündig = 0)
    var headHeight: Double {
        let m = metric
        switch kind {
        case .socketScrew: return m.headHeight
        case .hexScrew: return m.hexHeadHeight
        case .lowHeadScrew: return m.lowHeadHeight
        case .countersunkScrew: return 0
        case .buttonScrew: return m.buttonHeight
        case .flangeButtonScrew: return m.buttonHeight + m.flangeHeight
        default: return 0
        }
    }

    init() {}

    // Ältere Projekte kennen die neuen Felder nicht: alles optional lesen (Build 83)
    private enum CodingKeys: String, CodingKey {
        case kind, size, length, realThread, threadGeometryKnown, propertyClass, bearing, balls, sleeveInner, sleeveOuter
        case finePitch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(StandardPartKind.self, forKey: .kind) ?? .socketScrew
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 2
        length = try c.decodeIfPresent(Double.self, forKey: .length) ?? 12
        realThread = try c.decodeIfPresent(Bool.self, forKey: .realThread) ?? false
        threadGeometryKnown = try c.decodeIfPresent(Bool.self, forKey: .threadGeometryKnown) ?? true
        propertyClass = try c.decodeIfPresent(String.self, forKey: .propertyClass) ?? "Nicht festgelegt"
        bearing = try c.decodeIfPresent(Int.self, forKey: .bearing) ?? 4
        balls = try c.decodeIfPresent(Bool.self, forKey: .balls) ?? true
        sleeveInner = try c.decodeIfPresent(Double.self, forKey: .sleeveInner) ?? 0
        sleeveOuter = try c.decodeIfPresent(Double.self, forKey: .sleeveOuter) ?? 0
        finePitch = try c.decodeIfPresent(Bool.self, forKey: .finePitch) ?? false
    }

    var metric: MetricSize { MetricSize.all[max(0, min(MetricSize.all.count - 1, size))] }
    var bearingSize: BearingSize { BearingSize.all[max(0, min(BearingSize.all.count - 1, bearing))] }

    var modeledThreadLength: Double { min(length, 2 * metric.d + 6) }

    /// Ältere Projekte haben nur den vom Normteil-Werkzeug vergebenen Namen gespeichert.
    /// Daraus sind Gewindegeometrie und Festigkeitsklasse ausdrücklich nicht ablesbar.
    static func recognizedLegacyName(_ name: String) -> StandardPartSpec? {
        for kind in StandardPartKind.allCases where kind != .bearing {
            let prefix: String
            switch kind {
            case .socketScrew: prefix = "ISO 4762 "
            case .hexScrew: prefix = "ISO 4017 "
            case .nut: prefix = "ISO 4032 "
            case .washer: prefix = "ISO 7089 "
            default: continue
            }
            guard name.hasPrefix(prefix) else { continue }
            let rest = String(name.dropFirst(prefix.count))
            for index in MetricSize.all.indices {
                let size = MetricSize.all[index]
                guard rest == size.name || rest.hasPrefix(size.name + "×") || rest.hasPrefix(size.name + " (") else { continue }
                var spec = StandardPartSpec()
                spec.kind = kind
                spec.size = index
                spec.threadGeometryKnown = false
                if kind.isScrew {
                    guard let value = rest.split(separator: "×").dropFirst().first?.split(separator: " ").first,
                          let length = Double(value.replacingOccurrences(of: ",", with: ".")), length > 0 else { return nil }
                    spec.length = length
                }
                return spec
            }
        }
        return nil
    }

    /// Name des neuen Körpers, z. B. „ISO 4762 M3×12“.
    var bodyName: String {
        let m = metric
        switch kind {
        case .socketScrew: return "ISO 4762 \(threadDesignation)×\(length.formatted())"
        case .hexScrew: return "ISO 4017 \(threadDesignation)×\(length.formatted())"
        case .nut: return "ISO 4032 \(threadDesignation)"
        case .washer: return "ISO 7089 \(m.name)"
        case .bearing: return "Kugellager \(bearingSize.name)"
        case .lowHeadScrew: return "DIN 7984 \(threadDesignation)×\(length.formatted())"
        case .countersunkScrew: return "ISO 10642 \(threadDesignation)×\(length.formatted())"
        case .buttonScrew: return "ISO 7380-1 \(threadDesignation)×\(length.formatted())"
        case .flangeButtonScrew: return "ISO 7380-2 \(threadDesignation)×\(length.formatted())"
        case .sleeve:
            return "Hülse \(sleeveInnerDiameter.formatted())×\(sleeveOuterDiameter.formatted())×\(length.formatted())"
        }
    }
}

enum ScrewFaceAnchor: String, CaseIterable, Identifiable {
    case headSeat = "Kopfauflage bündig"
    case headTop = "Kopfoberseite bündig"
    case tip = "Schraubenspitze bündig"

    var id: Self { self }

    func localZ(for spec: StandardPartSpec) -> Double {
        switch self {
        case .headSeat: 0
        case .headTop: spec.headHeight
        case .tip: -spec.length
        }
    }
}

extension ModelStore {
    /// Platzierung einer Schraube auf einer ebenen Zielfläche; ein einzelner rückgängig machbarer Schritt.
    /// Der vorhandene Körper wird starr gedreht/verschoben, ohne mit dem Zielkörper zu verschmelzen.
    func placeScrew(_ index: Int, on target: FaceRef, at hitPoint: SIMD3<Double>,
                    anchor: ScrewFaceAnchor, offset: Double) -> Bool {
        guard bodies.indices.contains(index), target.body != index,
              let spec = bodies[index].effectiveStandardPart, spec.kind.isScrew,
              let plane = plane(of: target), offset.isFinite,
              hitPoint.x.isFinite, hitPoint.y.isFinite, hitPoint.z.isFinite else {
            message = "Schraube und ebene Zielfläche wählen."
            return false
        }
        dropPreview()
        let normal = simd_normalize(plane.normal)
        let old = bodies[index]
        let origin = SIMD3(old.placement.columns.3.x, old.placement.columns.3.y, old.placement.columns.3.z)
        let oldAxis = simd_normalize(SIMD3(old.placement.columns.2.x, old.placement.columns.2.y,
                                          old.placement.columns.2.z))
        guard simd_length(normal) > 0.9, simd_length(oldAxis) > 0.9 else { return false }
        let dot = max(-1.0, min(1.0, simd_dot(oldAxis, normal)))
        let angle = acos(dot)
        var axis = simd_cross(oldAxis, normal)
        if simd_length(axis) < 1e-9 {
            let reference = abs(oldAxis.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            axis = simd_cross(oldAxis, reference)
        }
        axis = simd_normalize(axis)
        let rotated: PCKShape
        if angle > 1e-9 {
            guard let shape = old.shape.rotated(origin: origin, axis: axis, angle: angle) else {
                message = "Schraube lässt sich nicht ausrichten."
                return false
            }
            rotated = shape
        } else {
            rotated = old.shape
        }
        let desiredOrigin = hitPoint + normal * (offset - anchor.localZ(for: spec))
        let delta = desiredOrigin - origin
        guard let moved = rotated.translated(by: delta) else {
            message = "Schraube lässt sich nicht platzieren."
            return false
        }
        let rotation = simd_double4x4.rotation(origin: origin, axis: axis, angle: angle)
        let motion = simd_double4x4.translation(delta) * rotation
        var result = bodies
        result[index] = old.with(moved, moving: motion)
        commit(result, name: "Schraube platzieren")
        selectBodies([index])
        message = "\(spec.bodyName) an Fläche platziert."
        return true
    }

    func setStandardPartClass(_ value: String, body index: Int) {
        guard bodies.indices.contains(index), var spec = bodies[index].effectiveStandardPart,
              spec.kind.isScrew, spec.propertyClass != value else { return }
        spec.propertyClass = value
        var result = bodies
        result[index].standardPart = spec
        commit(result, name: "Schraubenklasse ändern")
        selectBodies([index])
    }

    /// Build 88 (Kai): Größe, Länge, Gewindeart oder Gewindegeometrie eines eingefügten Normteils ändern.
    /// Das Teil wird neu erzeugt und an seiner bisherigen Lage (placement) wieder eingesetzt.
    func updateStandardPart(_ index: Int, step: String, change: (inout StandardPartSpec) -> Void) {
        guard bodies.indices.contains(index), let old = bodies[index].effectiveStandardPart else { return }
        var spec = old
        change(&spec)
        spec.threadGeometryKnown = true
        if spec.kind.isScrew {
            spec.length = max(spec.length, 1)
        }
        guard spec != old else { return }
        guard let shape = PartBuilder.build(spec)?.first?.shape,
              let placed = Self.placedStandardShape(shape, by: bodies[index].placement) else {
            message = "Normteil lässt sich so nicht erzeugen."
            return
        }
        var result = bodies
        let oldName = result[index].name
        result[index] = result[index].with(placed)
        result[index].standardPart = spec
        if oldName == old.bodyName || StandardPartSpec.recognizedLegacyName(oldName) != nil {
            result[index].name = spec.bodyName
        }
        commit(result, name: step)
        selectBodies([index])
    }

    /// Form aus dem Normteil-Ursprung an die Lage des Körpers bringen (Drehung um den Ursprung, dann Verschiebung).
    private static func placedStandardShape(_ shape: PCKShape, by m: simd_double4x4) -> PCKShape? {
        let r = simd_double3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                               SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                               SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var result: PCKShape? = shape
        let q = simd_quatd(r)
        if abs(q.angle) > 1e-12, q.angle.isFinite, simd_length(q.axis) > 0.5 {
            result = result?.rotated(origin: [0, 0, 0], axis: simd_normalize(q.axis), angle: q.angle)
        }
        if simd_length(t) > 1e-12 {
            result = result?.translated(by: t)
        }
        return result
    }

    /// Nach ausdrücklichem Wechsel darf das Normteil wie ein freier Volumenkörper bearbeitet werden.
    func convertStandardPartToBody(_ index: Int) {
        guard bodies.indices.contains(index), bodies[index].effectiveStandardPart != nil else { return }
        var result = bodies
        result[index].standardPart = nil
        result[index].name = "Körper aus \(result[index].name)"
        commit(result, name: "Normteil zu Körper")
        selectBodies([index])
    }
}

/// Einstellungen der Vorlagen Gehäuse und Stirnrad.
struct TemplateSpec: Equatable {
    var kind: TemplateKind = .enclosure
    // Gehäuse
    var boxLength: Double = 80
    var boxWidth: Double = 50
    var boxHeight: Double = 30
    var wall: Double = 2
    var cornerRadius: Double = 4
    var lid = true
    // Stirnrad
    var module: Double = 1
    var teeth = 20
    var gearWidth: Double = 8
    var bore: Double = 5
}

/// Baut Normteile und Vorlagen aus Kernel-Grundkörpern. Alle Teile stehen am Ursprung: Schrauben mit der
/// Kopfauflage auf Z = 0 (Schaft nach unten), alles andere mit der Unterseite auf Z = 0.
enum PartBuilder {
    private static let up = SIMD3<Double>(0, 0, 1)

    /// Sechskantprisma (Schlüsselweite s) ab z0 mit Höhe h.
    static func hexPrism(width s: Double, z0: Double, height h: Double) -> PCKShape? {
        let r = s / sqrt(3)
        let points = (0..<6).flatMap { k -> [NSNumber] in
            let a = Double(k) * .pi / 3 + .pi / 6
            return [NSNumber(value: r * cos(a)), NSNumber(value: r * sin(a)), NSNumber(value: z0)]
        }
        return PCKShape.prism(pointsXYZ: points, direction: [0, 0, h])
    }

    /// Rohr (Ring) ab z0: Außenradius outer, Innenradius inner, Höhe h.
    static func ring(outer: Double, inner: Double, z0: Double, height h: Double) -> PCKShape? {
        guard outer > inner, inner > 0,
              let full = PCKShape.cylinder(base: [0, 0, z0], axis: up, radius: outer, height: h),
              let hole = PCKShape.cylinder(base: [0, 0, z0 - 1], axis: up, radius: inner, height: h + 2) else { return nil }
        return full.cutting(hole)
    }

    /// Schraubennut (Gewinde, 60°-Flanken) als Werkzeug zum Abziehen: außen (Bolzen) schneidet sie nach innen,
    /// innen (Bohrung) nach außen. Die Nut läuft von base über length entlang axis.
    static func threadGroove(base: SIMD3<Double>, axis: SIMD3<Double>, radius: Double, pitch: Double, length: Double,
                             external: Bool) -> PCKShape? {
        let w = 0.7 * pitch
        let depth = w / 2 * sqrt(3)
        let eps = min(0.05, 0.1 * pitch)
        let profile: [Double] = external
            ? [radius + eps, -w / 2, radius - depth, 0, radius + eps, w / 2]
            : [radius - eps, -w / 2, radius + depth, 0, radius - eps, w / 2]
        return PCKShape.helixSweep(base: base, axis: axis, radius: radius, pitch: pitch, height: length, leftHanded: false,
                                   profileRZ: profile.map { NSNumber(value: $0) })
    }

    // MARK: Normteile

    /// Neue Körper (Form und Name) eines Normteils; nil bei ungültigen Maßen oder Kernelfehler.
    static func build(_ spec: StandardPartSpec) -> [(shape: PCKShape, name: String)]? {
        let m = spec.metric
        switch spec.kind {
        case .lowHeadScrew, .countersunkScrew, .buttonScrew, .flangeButtonScrew:
            return headScrew(spec)
        case .sleeve:
            // Rohr von der Auflage (Z = 0) nach unten in die Bohrung
            guard spec.length > 0,
                  let tube = ring(outer: spec.sleeveOuterDiameter / 2, inner: spec.sleeveInnerDiameter / 2,
                                  z0: -spec.length, height: spec.length) else { return nil }
            return [(tube, spec.bodyName)]
        case .socketScrew, .hexScrew:
            let length = spec.length
            guard length > 0 else { return nil }
            let head: PCKShape?
            if spec.kind == .socketScrew {
                // Zylinderkopf mit Innensechskant
                guard let cylinder = PCKShape.cylinder(base: .zero, axis: up, radius: m.headDiameter / 2, height: m.headHeight),
                      let socket = hexPrism(width: m.socket, z0: m.headHeight - m.socketDepth, height: m.socketDepth + 1)
                else { return nil }
                head = cylinder.cutting(socket)
            } else {
                head = hexPrism(width: m.hexWidth, z0: 0, height: m.hexHeadHeight)
            }
            // Schaft mit kleiner Fase an der Spitze, reicht etwas in den Kopf (sicheres Vereinigen)
            let chamfer = min(0.1 * m.d, length / 4)
            let into = (spec.kind == .socketScrew ? m.headHeight - m.socketDepth : m.hexHeadHeight) * 0.5
            guard let head,
                  let shank = PCKShape.cylinder(base: [0, 0, -length + chamfer], axis: up, radius: m.d / 2,
                                                height: length - chamfer + into),
                  let tip = PCKShape.cone(base: [0, 0, -length], axis: up, bottomRadius: m.d / 2 - chamfer,
                                          topRadius: m.d / 2, height: chamfer),
                  let rod = shank.fusing(tip),
                  var screw = head.fusing(rod) else { return nil }
            if spec.realThread {
                // Gewindelänge nach ISO (b = 2d + 6), bei kurzen Schrauben bis zum Kopf
                let threadLength = spec.modeledThreadLength
                guard let groove = threadGroove(base: [0, 0, -length - spec.pitch], axis: up, radius: m.d / 2,
                                                pitch: spec.pitch, length: threadLength + spec.pitch, external: true),
                      let threaded = screw.cutting(groove) else { return nil }
                screw = threaded
            }
            return [(screw, spec.bodyName)]
        case .nut:
            guard let body = hexPrism(width: m.hexWidth, z0: 0, height: m.nutHeight),
                  let hole = PCKShape.cylinder(base: [0, 0, -1], axis: up, radius: m.d / 2, height: m.nutHeight + 2),
                  var nut = body.cutting(hole) else { return nil }
            if spec.realThread {
                guard let groove = threadGroove(base: [0, 0, -spec.pitch], axis: up, radius: m.d / 2, pitch: spec.pitch,
                                                length: m.nutHeight + 2 * spec.pitch, external: false),
                      let threaded = nut.cutting(groove) else { return nil }
                nut = threaded
            }
            return [(nut, spec.bodyName)]
        case .washer:
            guard let washer = ring(outer: m.washerOuter / 2, inner: m.washerInner / 2, z0: 0, height: m.washerThickness)
            else { return nil }
            return [(washer, spec.bodyName)]
        case .bearing:
            return bearing(spec.bearingSize, balls: spec.balls, name: spec.bodyName)
        }
    }

    /// Build 83: Schrauben mit Innensechskant und flachem, Senk- oder Linsenkopf. Kopfauflage auf Z = 0, Schaft nach
    /// unten; beim Senkkopf liegt der Kopf unter Z = 0 (Oberseite bündig).
    private static func headScrew(_ spec: StandardPartSpec) -> [(shape: PCKShape, name: String)]? {
        let m = spec.metric
        let length = spec.length
        guard length > 0 else { return nil }
        let head: PCKShape?
        let socket: Double
        let top: Double
        switch spec.kind {
        case .lowHeadScrew:
            socket = m.lowHeadSocket
            top = m.lowHeadHeight
            head = PCKShape.cylinder(base: .zero, axis: up, radius: m.headDiameter / 2, height: top)
        case .countersunkScrew:
            socket = m.countersunkSocket
            top = 0
            head = PCKShape.cone(base: [0, 0, -m.countersunkHeight], axis: up, bottomRadius: m.d / 2,
                                 topRadius: m.countersunkDiameter / 2, height: m.countersunkHeight)
        case .flangeButtonScrew:
            socket = m.buttonSocket
            top = m.flangeHeight + m.buttonHeight
            guard let flange = PCKShape.cylinder(base: .zero, axis: up, radius: m.flangeDiameter / 2, height: m.flangeHeight),
                  let dome = buttonDome(m, z0: m.flangeHeight) else { return nil }
            head = flange.fusing(dome)
        default:
            socket = m.buttonSocket
            top = m.buttonHeight
            head = buttonDome(m, z0: 0)
        }
        let depth = max(0.6 * (top > 0 ? top : m.countersunkHeight), 0.5)
        let shankTop = spec.kind == .countersunkScrew ? -m.countersunkHeight + 0.1 * m.d : 0.3 * max(top, 0.5)
        let chamfer = min(0.1 * m.d, length / 4)
        guard let head,
              let hex = hexPrism(width: socket, z0: top - depth, height: depth + 1),
              let cut = head.cutting(hex),
              let shank = PCKShape.cylinder(base: [0, 0, -length + chamfer], axis: up, radius: m.d / 2,
                                            height: length - chamfer + shankTop),
              let tip = PCKShape.cone(base: [0, 0, -length], axis: up, bottomRadius: m.d / 2 - chamfer,
                                      topRadius: m.d / 2, height: chamfer),
              let rod = shank.fusing(tip),
              var screw = cut.fusing(rod) else { return nil }
        if spec.realThread {
            let threadLength = spec.modeledThreadLength
            guard let groove = threadGroove(base: [0, 0, -length - spec.pitch], axis: up, radius: m.d / 2,
                                            pitch: spec.pitch, length: threadLength + spec.pitch, external: true),
                  let threaded = screw.cutting(groove) else { return nil }
            screw = threaded
        }
        return [(screw, spec.bodyName)]
    }

    /// Linsenkopf: flacher Kugelabschnitt (Kegelstumpf mit großem Radius unten, rund genug für die Darstellung).
    private static func buttonDome(_ m: MetricSize, z0: Double) -> PCKShape? {
        let r = m.buttonDiameter / 2, k = m.buttonHeight
        // Kugel durch Rand (r, z0) und Scheitel (0, z0 + k): Radius R = (r² + k²) / 2k
        let big = (r * r + k * k) / (2 * k)
        guard let sphere = PCKShape.sphere(center: [0, 0, z0 + k - big], radius: big),
              let slab = PCKShape.cylinder(base: [0, 0, z0], axis: up, radius: r + 0.01, height: k + 0.01) else { return nil }
        return sphere.intersecting(slab)
    }

    /// Kugellager vereinfacht: Innen- und Außenring als Ringkörper, optional Kugeln in Laufrillen.
    private static func bearing(_ b: BearingSize, balls: Bool, name: String) -> [(shape: PCKShape, name: String)]? {
        let wall = (b.outer - b.d) / 2
        let innerOuter = b.d / 2 + 0.35 * wall
        let outerInner = b.outer / 2 - 0.35 * wall
        guard var inner = ring(outer: innerOuter, inner: b.d / 2, z0: 0, height: b.width),
              var outer = ring(outer: b.outer / 2, inner: outerInner, z0: 0, height: b.width) else { return nil }
        var parts: [(shape: PCKShape, name: String)] = []
        if balls {
            let pitchRadius = (innerOuter + outerInner) / 2
            let ball = min(0.5 * wall, 0.8 * b.width)
            // Laufrillen etwas größer als die Kugeln, damit sich nichts überschneidet
            guard let groove = PCKShape.torus(center: [0, 0, b.width / 2], axis: up, majorRadius: pitchRadius,
                                              minorRadius: ball / 2 + 0.02),
                  let grooved = inner.cutting(groove), let groovedOuter = outer.cutting(groove) else { return nil }
            inner = grooved
            outer = groovedOuter
            let count = max(3, Int(floor(2 * .pi * pitchRadius / (ball * 1.35))))
            var spheres: [PCKShape] = []
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi
                guard let sphere = PCKShape.sphere(center: [pitchRadius * cos(a), pitchRadius * sin(a), b.width / 2],
                                                   radius: ball / 2) else { return nil }
                spheres.append(sphere)
            }
            // Käfig verbindet die Kugeln zu einem Körper (getrennte Teile würden beim Laden einzelne Körper)
            let band = 0.3 * ball
            guard let all = PCKShape.compound(spheres),
                  let cage = ring(outer: pitchRadius + band / 2, inner: pitchRadius - band / 2,
                                  z0: b.width / 2 - band / 2, height: band),
                  let caged = cage.fusing(all) else { return nil }
            parts.append((caged, "\(name) Kugeln"))
        }
        var result: [(shape: PCKShape, name: String)] = [(outer, "\(name) Außenring"), (inner, "\(name) Innenring")]
        result += parts
        return result
    }

    // MARK: Vorlagen

    static func build(_ spec: TemplateSpec) -> [(shape: PCKShape, name: String)]? {
        switch spec.kind {
        case .enclosure: return enclosure(spec)
        case .gear: return gear(spec)
        }
    }

    /// Rechteck mit gerundeten Ecken um den Ursprung in der Höhe z (Kernel-Kodierung, Linien und Bögen).
    static func roundedRect(length: Double, width: Double, radius: Double, z: Double) -> [NSNumber] {
        let hx = length / 2, hy = width / 2
        let r = max(0, min(radius, min(hx, hy) - 0.01))
        func p(_ x: Double, _ y: Double) -> [NSNumber] { [NSNumber(value: x), NSNumber(value: y), NSNumber(value: z)] }
        func line(_ a: [NSNumber], _ b: [NSNumber]) -> [NSNumber] { [NSNumber(value: 0)] + a + b }
        // Schrittweise zusammensetzen: eine lange „+“-Kette überfordert den Swift-Typprüfer
        var result: [NSNumber] = []
        guard r > 0.01 else {
            result += line(p(-hx, -hy), p(hx, -hy))
            result += line(p(hx, -hy), p(hx, hy))
            result += line(p(hx, hy), p(-hx, hy))
            result += line(p(-hx, hy), p(-hx, -hy))
            return result
        }
        let s: Double = r * (1 - 1 / sqrt(2))
        func arc(_ a: [NSNumber], _ m: [NSNumber], _ b: [NSNumber]) -> [NSNumber] { [NSNumber(value: 1)] + a + m + b }
        let xl: Double = -hx, xr: Double = hx, yb: Double = -hy, yt: Double = hy
        result += line(p(xl + r, yb), p(xr - r, yb))
        result += arc(p(xr - r, yb), p(xr - s, yb + s), p(xr, yb + r))
        result += line(p(xr, yb + r), p(xr, yt - r))
        result += arc(p(xr, yt - r), p(xr - s, yt - s), p(xr - r, yt))
        result += line(p(xr - r, yt), p(xl + r, yt))
        result += arc(p(xl + r, yt), p(xl + s, yt - s), p(xl, yt - r))
        result += line(p(xl, yt - r), p(xl, yb + r))
        result += arc(p(xl, yb + r), p(xl + s, yb + s), p(xl + r, yb))
        return result
    }

    private static func roundedPrism(length: Double, width: Double, radius: Double, z0: Double, height: Double) -> PCKShape? {
        PCKShape.prism(profileWires: [roundedRect(length: length, width: width, radius: radius, z: z0)],
                       direction: [0, 0, height])
    }

    /// Gehäuse oben offen (Wandstärke rundum und am Boden) und optional ein Deckel mit Rand, der innen
    /// hineinpasst (0,2 mm Spiel). Der Deckel schwebt 10 mm über dem Gehäuse.
    private static func enclosure(_ s: TemplateSpec) -> [(shape: PCKShape, name: String)]? {
        let w = s.wall
        guard w > 0, s.boxLength > 2 * w + 1, s.boxWidth > 2 * w + 1, s.boxHeight > w + 0.5 else { return nil }
        let r = max(0, s.cornerRadius)
        guard let outer = roundedPrism(length: s.boxLength, width: s.boxWidth, radius: r, z0: 0, height: s.boxHeight),
              let inner = roundedPrism(length: s.boxLength - 2 * w, width: s.boxWidth - 2 * w, radius: max(0, r - w),
                                       z0: w, height: s.boxHeight),
              let box = outer.cutting(inner) else { return nil }
        var parts: [(shape: PCKShape, name: String)] = [(box, "Gehäuse \(s.boxLength.formatted())×\(s.boxWidth.formatted())×\(s.boxHeight.formatted())")]
        if s.lid {
            let clearance = 0.2
            let lipLength = s.boxLength - 2 * w - 2 * clearance
            let lipWidth = s.boxWidth - 2 * w - 2 * clearance
            let lipHeight = max(2, 2 * w)
            let z = s.boxHeight + 10
            guard let plate = roundedPrism(length: s.boxLength, width: s.boxWidth, radius: r, z0: z, height: w)
            else { return nil }
            var lid = plate
            if lipLength > 2 * w + 1, lipWidth > 2 * w + 1 {
                let lipRadius = max(0, r - w - clearance)
                guard let lipOuter = roundedPrism(length: lipLength, width: lipWidth, radius: lipRadius,
                                                  z0: z - lipHeight, height: lipHeight + w / 2),
                      let lipInner = roundedPrism(length: lipLength - 2 * w, width: lipWidth - 2 * w,
                                                  radius: max(0, lipRadius - w), z0: z - lipHeight - 1, height: lipHeight + 1),
                      let lip = lipOuter.cutting(lipInner),
                      let joined = plate.fusing(lip) else { return nil }
                lid = joined
            }
            parts.append((lid, "Deckel"))
        }
        return parts
    }

    /// Stirnrad mit Evolventenverzahnung (Eingriffswinkel 20°). Die Flanken sind B-Splines durch Punkte der
    /// Evolvente (angenähert), Kopf und Fuß Kreisbögen; unterhalb des Grundkreises radial.
    private static func gear(_ s: TemplateSpec) -> [(shape: PCKShape, name: String)]? {
        let z = s.teeth, m = s.module
        guard z >= 6, z <= 300, m > 0, s.gearWidth > 0 else { return nil }
        let alpha = 20 * Double.pi / 180
        let rp = m * Double(z) / 2
        let rb = rp * cos(alpha)
        let ra = rp + m
        let rf = rp - 1.25 * m
        guard rf > 0.5 * m else { return nil }
        func inv(_ a: Double) -> Double { tan(a) - a }
        /// Halber Zahnwinkel bei Radius r (gemessen von der Zahnmitte)
        func half(_ r: Double) -> Double {
            let a = acos(min(1, rb / max(r, rb)))
            return .pi / (2 * Double(z)) + inv(alpha) - inv(a)
        }
        let start = max(rb, rf)
        let tipHalf = half(ra)
        let rootHalf = half(start)
        let toothPitch: Double = 2 * Double.pi / Double(z)
        guard tipHalf > 0.002, toothPitch - 2 * rootHalf > 0.002 else { return nil }
        func p(_ r: Double, _ phi: Double) -> [NSNumber] {
            [NSNumber(value: r * cos(phi)), NSNumber(value: r * sin(phi)), NSNumber(value: 0)]
        }
        let samples = 8
        var flankRadii: [Double] = rf < rb ? [rf] : []
        for k in 0...samples {
            let fraction: Double = Double(k) / Double(samples)
            flankRadii.append(start + (ra - start) * fraction)
        }
        func flankAngle(_ r: Double) -> Double { r < rb ? rootHalf : half(r) }
        var code: [NSNumber] = []
        for i in 0..<z {
            let c = 2 * .pi * Double(i) / Double(z)
            let next = 2 * .pi * Double(i + 1) / Double(z)
            // linke Flanke vom Fuß zum Kopf
            code += [NSNumber(value: 5), NSNumber(value: flankRadii.count)]
            code += flankRadii.flatMap { p($0, c - flankAngle($0)) }
            // Kopfkreis
            code += [NSNumber(value: 1)] + p(ra, c - tipHalf) + p(ra, c) + p(ra, c + tipHalf)
            // rechte Flanke vom Kopf zum Fuß
            code += [NSNumber(value: 5), NSNumber(value: flankRadii.count)]
            code += flankRadii.reversed().flatMap { p($0, c + flankAngle($0)) }
            // Fußkreis bis zur nächsten Zahnlücke
            let rootStart: Double = c + rootHalf, rootMid: Double = (c + next) / 2, rootEnd: Double = next - rootHalf
            code.append(NSNumber(value: 1))
            code += p(rf, rootStart)
            code += p(rf, rootMid)
            code += p(rf, rootEnd)
        }
        guard var gear = PCKShape.prism(profileWires: [code], direction: [0, 0, s.gearWidth]) else { return nil }
        if s.bore > 0 {
            guard s.bore < 2 * rf - 2 * m,
                  let hole = PCKShape.cylinder(base: [0, 0, -1], axis: up, radius: s.bore / 2, height: s.gearWidth + 2),
                  let bored = gear.cutting(hole) else { return nil }
            gear = bored
        }
        return [(gear, "Stirnrad m\(m.formatted()) z\(z)")]
    }
}
