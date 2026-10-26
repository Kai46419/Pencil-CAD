import Foundation
import simd

// Prüfen › Messen am 3D-Modell (Kai): Kante antippen = ganze Kantenlänge (bei Kreis und Bogen auch Radius und
// Durchmesser), Fläche antippen = Flächeninhalt in mm² samt Länge × Breite (eben) bzw. Durchmesser und Höhe
// (Zylinder). Punkt zu Punkt: der zweite Punkt rastet parallel zu X, Y, Z bzw. senkrecht zur Fläche des ersten
// Punkts ein, damit „unten ein Punkt, oben drüber ein Punkt“ genau senkrecht gemessen wird.

/// Was ein Antippen im Messwerkzeug misst.
enum MeasureMode: String, CaseIterable, Identifiable {
    /// Ganze Kante bzw. ganze Fläche (kein Punktsetzen)
    case element = "Kante/Fläche"
    /// Zwei Punkte, der zweite rastet achsparallel ein
    case points = "Punkt zu Punkt"

    var id: Self { self }
}

/// Leitlinie beim Punkt-zu-Punkt-Messen: Verbindung genau parallel zu einer Achse bzw. senkrecht zur Fläche.
struct MeasureGuide: Equatable {
    enum Axis: Equatable {
        case x, y, z, normal
    }

    var axis: Axis
    var from: SIMD3<Double>
    var to: SIMD3<Double>

    var title: String {
        switch axis {
        case .x: "parallel zu X"
        case .y: "parallel zu Y"
        case .z: "parallel zu Z"
        case .normal: "senkrecht zur Fläche"
        }
    }

    /// Achsfarbe wie die Ursprungsachsen (X rot, Y grün, Z blau), senkrecht zur Fläche orange.
    var color: SIMD3<Float> {
        switch axis {
        case .x: SIMD3<Float>(0.78, 0.16, 0.11)
        case .y: SIMD3<Float>(0.17, 0.52, 0.2)
        case .z: SIMD3<Float>(0.1, 0.36, 0.88)
        case .normal: SIMD3<Float>(0.98, 0.45, 0.05)
        }
    }
}

/// Geometrie einer Körperkante aus dem Kernel.
struct EdgeMeasurement {
    enum Kind {
        case line, circle, ellipse, curve
    }

    var kind: Kind
    var length: Double
    var start: SIMD3<Double>
    var end: SIMD3<Double>
    var center: SIMD3<Double>
    var radius: Double
    var radius2: Double
    /// Öffnungswinkel im Bogenmaß (Kreis, Bogen, Ellipse)
    var sweep: Double
    var isClosed: Bool
}

/// Art einer Körperfläche aus dem Kernel.
enum SurfaceMeasurement {
    case plane
    case cylinder(radius: Double)
    case cone(semiAngle: Double)
    case sphere(radius: Double)
    case torus(major: Double, minor: Double)
    case other
}

extension ModelStore {
    /// Kantengeometrie (Kernel); nil ohne Kernel bzw. bei ungültiger Kante.
    func edgeMeasurement(_ edge: EdgeRef) -> EdgeMeasurement? {
        guard bodies.indices.contains(edge.body),
              let values = bodies[edge.body].shape.geometry(ofEdge: edge.edge)?.map(\.doubleValue),
              values.count == 18, values.allSatisfy(\.isFinite) else { return nil }
        let kind: EdgeMeasurement.Kind
        switch Int(values[0]) {
        case 0: kind = .line
        case 1: kind = .circle
        case 2: kind = .ellipse
        default: kind = .curve
        }
        let start = SIMD3<Double>(values[2], values[3], values[4])
        let end = SIMD3<Double>(values[5], values[6], values[7])
        let center = SIMD3<Double>(values[8], values[9], values[10])
        return EdgeMeasurement(kind: kind, length: values[1], start: start, end: end, center: center,
                               radius: values[14], radius2: values[15], sweep: values[16], isClosed: values[17] > 0.5)
    }

    /// Flächenart (Kernel); nil ohne Kernel.
    func surfaceMeasurement(_ face: FaceRef) -> SurfaceMeasurement? {
        guard bodies.indices.contains(face.body),
              let values = bodies[face.body].shape.surface(ofFace: face.face)?.map(\.doubleValue),
              values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        switch Int(values[0]) {
        case 0: return .plane
        case 1: return .cylinder(radius: values[1])
        case 2: return .cone(semiAngle: values[1])
        case 3: return .sphere(radius: values[1])
        case 4: return .torus(major: values[1], minor: values[2])
        default: return .other
        }
    }

    /// Punkte entlang des Flächenrands: fein vom Kernel, sonst die Eckpunkte des Anzeigenetzes.
    func outlinePoints(of face: FaceRef) -> [SIMD3<Double>] {
        guard bodies.indices.contains(face.body) else { return [] }
        if let values = bodies[face.body].shape.outline(ofFace: face.face, deflection: 0.001)?.map(\.doubleValue),
           values.count >= 9 {
            var points: [SIMD3<Double>] = []
            points.reserveCapacity(values.count / 3)
            var i = 0
            while i + 2 < values.count {
                let p = SIMD3<Double>(values[i], values[i + 1], values[i + 2])
                if p.x.isFinite, p.y.isFinite, p.z.isFinite { points.append(p) }
                i += 3
            }
            if points.count >= 3 { return points }
        }
        return mesh.trianglePoints(of: face).map { SIMD3<Double>($0) }
    }
}

/// Messwerte als Textzeilen für das Mess-Panel.
@MainActor
enum ModelMeasure {
    // MARK: Formatieren

    static func length(_ millimeters: Double) -> String {
        LengthUnit.current.format(millimeters)
    }

    /// Fläche in der Projekteinheit; in mm ab 10.000 mm² zusätzlich in cm².
    static func area(_ squareMillimeters: Double) -> String {
        let unit = LengthUnit.current
        guard unit == .mm else { return unit.formatArea(squareMillimeters) }
        let plain = squareMillimeters.formatted(.number.precision(.fractionLength(0...2)))
        guard squareMillimeters >= 10_000 else { return "\(plain) mm²" }
        let squareCentimeters = squareMillimeters / 100
        let cm = squareCentimeters.formatted(.number.precision(.fractionLength(0...2)))
        return "\(plain) mm² (\(cm) cm²)"
    }

    static func degrees(_ radians: Double) -> String {
        let value = radians * 180 / .pi
        return "\(value.formatted(.number.precision(.fractionLength(0...2))))°"
    }

    // MARK: Kante

    /// Ganze Kante: Länge, bei Kreis bzw. Bogen Radius und Durchmesser, bei Strecken ΔX/ΔY/ΔZ.
    static func edgeLines(model: ModelStore, edge: EdgeRef) -> [String] {
        let total = model.length(of: edge)
        guard let info = model.edgeMeasurement(edge) else {
            return ["Kantenlänge: \(length(total))"]
        }
        let full = info.length > 0 ? info.length : total
        var lines: [String] = []
        switch info.kind {
        case .line:
            lines.append("Kante (gerade): Länge \(length(full))")
            let d = info.end - info.start
            lines.append("ΔX \(length(abs(d.x)))  ΔY \(length(abs(d.y)))  ΔZ \(length(abs(d.z)))")
        case .circle:
            if info.isClosed {
                lines.append("Kreis: Ø \(length(info.radius * 2)) · Radius \(length(info.radius))")
                lines.append("Umfang: \(length(full))")
            } else {
                lines.append("Bogen: Länge \(length(full))")
                lines.append("Radius \(length(info.radius)) · Ø \(length(info.radius * 2)) · Winkel \(degrees(info.sweep))")
                lines.append("Sehne (Abstand der Enden): \(length(simd_distance(info.start, info.end)))")
            }
            let c = info.center
            lines.append("Mittelpunkt: X \(length(c.x))  Y \(length(c.y))  Z \(length(c.z))")
        case .ellipse:
            lines.append("Ellipse: Länge \(length(full))")
            lines.append("Halbachsen \(length(info.radius)) × \(length(info.radius2))")
        case .curve:
            lines.append("Kurve: Länge \(length(full))")
            if !info.isClosed {
                lines.append("Abstand der Enden: \(length(simd_distance(info.start, info.end)))")
            }
        }
        return lines
    }

    // MARK: Fläche

    /// Ganze Fläche: Inhalt, bei ebenen Flächen Länge × Breite, bei Zylindern Durchmesser und Höhe.
    static func faceLines(model: ModelStore, face: FaceRef) -> [String] {
        var lines: [String] = ["Flächeninhalt: \(area(model.area(of: face)))"]
        let surface = model.surfaceMeasurement(face)
        if let plane = model.plane(of: face) {
            let points = model.outlinePoints(of: face)
            if let size = planarSize(points, normal: plane.normal) {
                lines.append("Länge × Breite: \(length(size.length)) × \(length(size.width))")
            }
        } else if let cylinder = model.cylinder(of: face) {
            let points = model.outlinePoints(of: face)
            let height = extent(points, along: cylinder.axis)
            let kind = cylinder.convex ? "Zylinder" : "Bohrung"
            lines.append("\(kind): Ø \(length(cylinder.radius * 2)) · Radius \(length(cylinder.radius))")
            if height > 1e-6 { lines.append("Höhe: \(length(height))") }
        } else if let surface {
            switch surface {
            case .sphere(let radius):
                lines.append("Kugelfläche: Ø \(length(radius * 2)) · Radius \(length(radius))")
            case .cone(let semiAngle):
                lines.append("Kegelfläche: Öffnungswinkel \(degrees(abs(semiAngle) * 2))")
            case .torus(let major, let minor):
                lines.append("Torus: Radien \(length(major)) und \(length(minor))")
            case .plane, .cylinder, .other:
                break
            }
        }
        return lines
    }

    /// Länge × Breite einer ebenen Fläche: kleinstes umschließendes Rechteck der Randpunkte in der Ebene
    /// (bei Rechtecken genau die Seitenlängen, auch wenn die Fläche schräg im Raum liegt).
    static func planarSize(_ points: [SIMD3<Double>], normal: SIMD3<Double>) -> (length: Double, width: Double)? {
        guard points.count >= 3, simd_length(normal) > 1e-12 else { return nil }
        let n = simd_normalize(normal)
        let reference: SIMD3<Double> = abs(n.z) < 0.9 ? SIMD3<Double>(0, 0, 1) : SIMD3<Double>(1, 0, 0)
        let u = simd_normalize(simd_cross(reference, n))
        let v = simd_cross(n, u)
        let flat: [Point2] = points.map { p in Point2(simd_dot(p, u), simd_dot(p, v)) }
        let hull = convexHull(flat)
        guard hull.count >= 2 else { return nil }
        var best: (area: Double, a: Double, b: Double)?
        for i in hull.indices {
            let edge: Point2 = hull[(i + 1) % hull.count] - hull[i]
            let edgeLength = simd_length(edge)
            guard edgeLength > 1e-12 else { continue }
            let along: Point2 = edge / edgeLength
            let across = Point2(-along.y, along.x)
            var lowA = Double.infinity, highA = -Double.infinity
            var lowB = Double.infinity, highB = -Double.infinity
            for p in hull {
                let a = simd_dot(p, along)
                let b = simd_dot(p, across)
                lowA = min(lowA, a)
                highA = max(highA, a)
                lowB = min(lowB, b)
                highB = max(highB, b)
            }
            let sideA = highA - lowA
            let sideB = highB - lowB
            let rectangle = sideA * sideB
            if rectangle < (best?.area ?? .infinity) - 1e-9 { best = (rectangle, sideA, sideB) }
        }
        guard let best else { return nil }
        return (max(best.a, best.b), min(best.a, best.b))
    }

    /// Konvexe Hülle (Monotone Chain), gegen den Uhrzeigersinn.
    static func convexHull(_ input: [Point2]) -> [Point2] {
        let points = input.filter { $0.x.isFinite && $0.y.isFinite }.sorted { a, b in
            a.x != b.x ? a.x < b.x : a.y < b.y
        }
        guard points.count >= 3 else { return points }
        func cross(_ o: Point2, _ a: Point2, _ b: Point2) -> Double {
            let first: Double = (a.x - o.x) * (b.y - o.y)
            let second: Double = (a.y - o.y) * (b.x - o.x)
            return first - second
        }
        var lower: [Point2] = []
        for p in points {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Point2] = []
        for p in points.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Ausdehnung der Punkte entlang einer Richtung (z. B. Höhe eines Zylinders entlang seiner Achse).
    static func extent(_ points: [SIMD3<Double>], along axis: SIMD3<Double>) -> Double {
        guard !points.isEmpty, simd_length(axis) > 1e-12 else { return 0 }
        let direction = simd_normalize(axis)
        var low = Double.infinity, high = -Double.infinity
        for p in points {
            let t = simd_dot(p, direction)
            low = min(low, t)
            high = max(high, t)
        }
        return high > low ? high - low : 0
    }

    // MARK: Punkt zu Punkt

    /// Zweiter Punkt: liegt er nahe einer Linie durch den ersten Punkt parallel zu X, Y, Z bzw. entlang der
    /// Flächennormale des ersten Punkts, rastet er genau auf dieser Linie ein. surface = ebene Fläche unter dem
    /// zweiten Punkt: dann liegt der eingerastete Punkt genau dort, wo die Leitlinie diese Fläche trifft.
    static func locked(_ candidate: SIMD3<Double>, from first: SIMD3<Double>, normal: SIMD3<Double>?,
                       tolerance: Double, surface: SketchPlane?) -> (point: SIMD3<Double>, guide: MeasureGuide?) {
        var directions: [(axis: MeasureGuide.Axis, direction: SIMD3<Double>)] = [
            (.x, SIMD3<Double>(1, 0, 0)), (.y, SIMD3<Double>(0, 1, 0)), (.z, SIMD3<Double>(0, 0, 1)),
        ]
        if let normal, simd_length(normal) > 1e-9 {
            let n = simd_normalize(normal)
            // Zeigt die Normale ohnehin entlang einer Achse, genügt die Achse
            let isAxis = directions.contains { abs(simd_dot($0.direction, n)) > 0.9999 }
            if !isAxis { directions.append((.normal, n)) }
        }
        let offset = candidate - first
        var best: (axis: MeasureGuide.Axis, direction: SIMD3<Double>, along: Double, miss: Double, allowed: Double)?
        for entry in directions {
            let along = simd_dot(offset, entry.direction)
            guard abs(along) > 1e-6 else { continue }
            let miss = simd_length(offset - along * entry.direction)
            // Fangbereich: Fangtoleranz bzw. etwa 10° Abweichung von der Leitlinie
            let allowed = max(tolerance, abs(along) * 0.18)
            guard miss <= allowed, miss < (best?.miss ?? .infinity) else { continue }
            best = (entry.axis, entry.direction, along, miss, allowed)
        }
        guard let best else { return (candidate, nil) }
        var along = best.along
        if let surface {
            let n = simd_normalize(surface.normal)
            let denominator = simd_dot(best.direction, n)
            if abs(denominator) > 0.2 {
                let t = simd_dot(surface.anchor - first, n) / denominator
                if t.isFinite, abs(t - best.along) <= best.allowed * 2 + tolerance { along = t }
            }
        }
        let point = first + along * best.direction
        return (point, MeasureGuide(axis: best.axis, from: first, to: point))
    }

    /// Abstand zweier Punkte mit ΔX/ΔY/ΔZ, eingerastet mit Angabe der Richtung.
    static func distanceLines(_ a: SIMD3<Double>, _ b: SIMD3<Double>, guide: MeasureGuide?) -> [String] {
        let d = b - a
        var lines: [String] = []
        if let guide {
            lines.append("Abstand: \(length(simd_length(d))) (\(guide.title))")
        } else {
            lines.append("Abstand: \(length(simd_length(d)))")
        }
        lines.append("ΔX \(length(abs(d.x)))  ΔY \(length(abs(d.y)))  ΔZ \(length(abs(d.z)))")
        return lines
    }
}
