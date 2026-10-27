import Foundation
import simd

// Einschränkungen (Constraints) für Skizzen, nach dem Vorbild von Shapr3D:
// Parallel, Senkrecht, Tangential, Zusammenfallend, Mittelpunkt, Konzentrisch, Horizontal/Vertikal,
// Gleich, Symmetrisch, Sperren. Ein numerischer Löser (Gauß-Newton mit kleinster Änderung) hält sie ein,
// wenn Maße geändert oder neue Einschränkungen gesetzt werden.

/// Punkt eines Elements: Ende, Ecke, Mitte. index je Elementart, siehe SketchEntity.handlePoints.
struct SketchPointRef: Hashable, Codable {
    var entity: Int
    var index: Int
}

/// Kurve eines Elements: bei Rechteck, Polygon und Linienzug die einzelne Kante, sonst 0.
struct SketchCurveRef: Hashable, Codable {
    var entity: Int
    var index: Int
}

/// Auswahl im Skizzenmodus.
enum SketchRef: Hashable {
    case point(SketchPointRef)
    case curve(SketchCurveRef)

    var entity: Int {
        switch self {
        case .point(let p): p.entity
        case .curve(let c): c.entity
        }
    }
}

enum ConstraintKind: String, CaseIterable, Identifiable, Codable {
    case parallel = "Parallel"
    /// Linien auf einer gemeinsamen Geraden (Fusion 360 „Collinear“): parallel und auf der Geraden der ersten
    case collinear = "Kollinear"
    case perpendicular = "Senkrecht"
    case tangent = "Tangential"
    case coincident = "Zusammenfallend"
    case midpoint = "Mittelpunkt"
    case concentric = "Konzentrisch"
    case horizontalVertical = "Horizontal/Vertikal"
    case equal = "Gleich"
    /// Gleicher bzw. gespiegelter Winkel zweier Linien (70° und 110°: symmetrisch zur Senkrechten)
    case equalAngle = "Gleicher Winkel"
    case symmetric = "Symmetrien"
    /// Punkte bzw. Kurven an ihrer Stelle verankern (Fusion 360 „Fix“)
    case lock = "Verankern"
    /// Bemaßung (Abstand, Winkel) als treibendes Maß; erscheint nicht in der Liste der Einschränkungen
    case dimension = "Bemaßung"

    var id: Self { self }

    /// Kurzzeichen am Element
    var badge: String {
        switch self {
        case .parallel: "∥"
        case .collinear: "—"
        case .perpendicular: "⊥"
        case .tangent: "T"
        case .coincident: "•"
        case .midpoint: "M"
        case .concentric: "◎"
        case .horizontalVertical: "H/V"
        case .equal: "="
        case .equalAngle: "∠="
        case .symmetric: "⟷"
        case .lock: "🔒"
        case .dimension: ""
        }
    }

    /// Was für diese Einschränkung ausgewählt sein muss.
    var selectionHint: String {
        switch self {
        case .parallel: "Parallel: zwei oder mehr Linien antippen."
        case .collinear: "Kollinear: zwei oder mehr Linien antippen – sie kommen auf die Gerade der ersten."
        case .perpendicular: "Senkrecht: zwei Linien antippen."
        case .tangent: "Tangential: Linie und Kreis/Bogen oder zwei Kreise antippen."
        case .coincident: "Zusammenfallend: zwei Punkte oder einen Punkt und eine Kurve antippen."
        case .midpoint: "Mittelpunkt: einen Punkt und eine Linie antippen."
        case .concentric: "Konzentrisch: zwei oder mehr Kreise/Bögen antippen."
        case .horizontalVertical: "Horizontal/Vertikal: Linien oder zwei Punkte antippen."
        case .equal: "Gleich: zwei Linien oder zwei Kreise/Bögen antippen."
        case .equalAngle: "Gleicher Winkel: zwei oder mehr Linien antippen – gleich oder gespiegelt (z. B. 70° und 110°)."
        case .symmetric: "Symmetrie: zwei Punkte (oder zwei Kreise/Linien) und zuletzt die Achse antippen."
        case .lock: "Verankern: Punkte oder Kurven antippen – sie bleiben beim Ändern von Maßen stehen."
        case .dimension: "Bemaßen: ein Element, zwei Punkte, Punkt und Linie oder zwei Linien antippen."
        }
    }

    var systemImage: String {
        switch self {
        case .parallel: "line.diagonal"
        case .collinear: "line.3.horizontal"
        case .perpendicular: "angle"
        case .tangent: "circle.and.line.horizontal"
        case .coincident: "smallcircle.filled.circle"
        case .midpoint: "line.3.horizontal.decrease"
        case .concentric: "circle.circle"
        case .horizontalVertical: "arrow.up.and.down.and.arrow.left.and.right"
        case .equal: "equal"
        case .equalAngle: "chevron.up"
        case .symmetric: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .lock: "lock"
        case .dimension: "ruler"
        }
    }
}

/// Eine gespeicherte Einschränkung.
struct SketchConstraint: Codable, Hashable {
    enum Variant: Codable, Hashable {
        case parallel(SketchCurveRef, SketchCurveRef)
        case perpendicular(SketchCurveRef, SketchCurveRef)
        /// outside = Kreise berühren sich außen (sonst innen)
        case tangent(SketchCurveRef, SketchCurveRef, outside: Bool)
        case coincident(SketchPointRef, SketchPointRef)
        case pointOnCurve(SketchPointRef, SketchCurveRef)
        case midpoint(SketchPointRef, SketchCurveRef)
        case concentric(SketchCurveRef, SketchCurveRef)
        case horizontal(SketchCurveRef)
        case vertical(SketchCurveRef)
        case horizontalPoints(SketchPointRef, SketchPointRef)
        case verticalPoints(SketchPointRef, SketchPointRef)
        case equalLength(SketchCurveRef, SketchCurveRef)
        case equalRadius(SketchCurveRef, SketchCurveRef)
        /// Gleicher Winkel zur Waagerechten: mirrored = gespiegelt (α und 180° − α, symmetrisch zur Senkrechten;
        /// für ungerichtete Linien dasselbe wie −α, symmetrisch zur Waagerechten), sonst wie parallel
        case equalAngle(SketchCurveRef, SketchCurveRef, mirrored: Bool)
        case symmetric(SketchPointRef, SketchPointRef, axis: SketchCurveRef)
        case lock(SketchPointRef, at: Point2)
        /// Treibende Maße: Abstand zweier Punkte, Abstand Punkt–Linie, Winkel zweier Linien (Grad)
        case distance(SketchPointRef, SketchPointRef, value: Double)
        case pointLineDistance(SketchPointRef, SketchCurveRef, value: Double)
        case angle(SketchCurveRef, SketchCurveRef, degrees: Double)
        /// Radius eines Bogens bzw. Durchmesser eines Kreises (diameter), eingegebenes Maß am Element
        case radius(SketchCurveRef, value: Double, diameter: Bool)
    }

    var variant: Variant
    /// Treibendes Maß gelöst (rotes Schloss): bleibt sichtbar, wird aber nicht eingehalten
    var isSuspended = false
    /// Formel mit Projektvariablen (z. B. „breite / 2“); das Maß folgt, wenn sich die Variablen ändern
    var expression: String?

    var kind: ConstraintKind {
        switch variant {
        case .parallel: .parallel
        case .perpendicular: .perpendicular
        case .tangent: .tangent
        case .coincident, .pointOnCurve: .coincident
        case .midpoint: .midpoint
        case .concentric: .concentric
        case .horizontal, .vertical, .horizontalPoints, .verticalPoints: .horizontalVertical
        case .equalLength, .equalRadius: .equal
        case .equalAngle: .equalAngle
        case .symmetric: .symmetric
        case .lock: .lock
        case .distance, .pointLineDistance, .angle, .radius: .dimension
        }
    }

    /// Wert eines treibenden Maßes (mm bzw. Grad); nil bei anderen Einschränkungen.
    var dimensionValue: Double? {
        switch variant {
        case .distance(_, _, let value), .pointLineDistance(_, _, let value): value
        case .angle(_, _, let degrees): degrees
        case .radius(_, let value, _): value
        default: nil
        }
    }

    /// Dasselbe Maß mit neuem Wert (wieder fest, die Formel bleibt verknüpft).
    func withDimensionValue(_ newValue: Double) -> SketchConstraint {
        let changed: Variant
        switch variant {
        case .distance(let a, let b, _): changed = .distance(a, b, value: newValue)
        case .pointLineDistance(let p, let c, _): changed = .pointLineDistance(p, c, value: newValue)
        case .angle(let a, let b, _): changed = .angle(a, b, degrees: newValue)
        case .radius(let c, _, let diameter): changed = .radius(c, value: newValue, diameter: diameter)
        default: return self
        }
        var result = SketchConstraint(variant: changed)
        result.expression = expression
        return result
    }

    var entities: [Int] {
        switch variant {
        case .parallel(let a, let b), .perpendicular(let a, let b), .tangent(let a, let b, _), .concentric(let a, let b),
             .equalLength(let a, let b), .equalRadius(let a, let b), .equalAngle(let a, let b, _):
            [a.entity, b.entity]
        case .coincident(let a, let b), .horizontalPoints(let a, let b), .verticalPoints(let a, let b):
            [a.entity, b.entity]
        case .pointOnCurve(let p, let c), .midpoint(let p, let c):
            [p.entity, c.entity]
        case .horizontal(let c), .vertical(let c):
            [c.entity]
        case .symmetric(let a, let b, let axis):
            [a.entity, b.entity, axis.entity]
        case .lock(let p, _):
            [p.entity]
        case .distance(let a, let b, _):
            [a.entity, b.entity]
        case .pointLineDistance(let p, let c, _):
            [p.entity, c.entity]
        case .angle(let a, let b, _):
            [a.entity, b.entity]
        case .radius(let c, _, _):
            [c.entity]
        }
    }

    /// Verweise nach dem Entfernen von Elementen anpassen; nil, wenn ein beteiligtes Element entfernt wurde.
    func remapped(_ map: (Int) -> Int?) -> SketchConstraint? {
        func p(_ r: SketchPointRef) -> SketchPointRef? { map(r.entity).map { SketchPointRef(entity: $0, index: r.index) } }
        func c(_ r: SketchCurveRef) -> SketchCurveRef? { map(r.entity).map { SketchCurveRef(entity: $0, index: r.index) } }
        let v: Variant?
        switch variant {
        case .parallel(let a, let b): v = c(a).flatMap { a in c(b).map { .parallel(a, $0) } }
        case .perpendicular(let a, let b): v = c(a).flatMap { a in c(b).map { .perpendicular(a, $0) } }
        case .tangent(let a, let b, let o): v = c(a).flatMap { a in c(b).map { .tangent(a, $0, outside: o) } }
        case .coincident(let a, let b): v = p(a).flatMap { a in p(b).map { .coincident(a, $0) } }
        case .pointOnCurve(let a, let b): v = p(a).flatMap { a in c(b).map { .pointOnCurve(a, $0) } }
        case .midpoint(let a, let b): v = p(a).flatMap { a in c(b).map { .midpoint(a, $0) } }
        case .concentric(let a, let b): v = c(a).flatMap { a in c(b).map { .concentric(a, $0) } }
        case .horizontal(let a): v = c(a).map { .horizontal($0) }
        case .vertical(let a): v = c(a).map { .vertical($0) }
        case .horizontalPoints(let a, let b): v = p(a).flatMap { a in p(b).map { .horizontalPoints(a, $0) } }
        case .verticalPoints(let a, let b): v = p(a).flatMap { a in p(b).map { .verticalPoints(a, $0) } }
        case .equalLength(let a, let b): v = c(a).flatMap { a in c(b).map { .equalLength(a, $0) } }
        case .equalRadius(let a, let b): v = c(a).flatMap { a in c(b).map { .equalRadius(a, $0) } }
        case .equalAngle(let a, let b, let m): v = c(a).flatMap { a in c(b).map { .equalAngle(a, $0, mirrored: m) } }
        case .symmetric(let a, let b, let axis):
            v = p(a).flatMap { a in p(b).flatMap { b in c(axis).map { .symmetric(a, b, axis: $0) } } }
        case .lock(let a, let at): v = p(a).map { .lock($0, at: at) }
        case .distance(let a, let b, let value): v = p(a).flatMap { a in p(b).map { .distance(a, $0, value: value) } }
        case .pointLineDistance(let a, let b, let value):
            v = p(a).flatMap { a in c(b).map { .pointLineDistance(a, $0, value: value) } }
        case .angle(let a, let b, let degrees): v = c(a).flatMap { a in c(b).map { .angle(a, $0, degrees: degrees) } }
        case .radius(let a, let value, let diameter): v = c(a).map { .radius($0, value: value, diameter: diameter) }
        }
        let suspended = isSuspended, expression = expression
        return v.map { variant -> SketchConstraint in
            var constraint = SketchConstraint(variant: variant)
            constraint.isSuspended = suspended
            constraint.expression = expression
            return constraint
        }
    }
}

/// Geometrie einer Kurve für Einschränkungen.
enum ConstraintCurve {
    case line(Point2, Point2)
    case circle(center: Point2, radius: Double)
    case other
}

extension SketchConstraint {
    private enum CodingKeys: String, CodingKey {
        case variant, isSuspended, expression
    }

    /// Ältere Skizzen kennen isSuspended und expression noch nicht
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(variant: try container.decode(Variant.self, forKey: .variant))
        isSuspended = try container.decodeIfPresent(Bool.self, forKey: .isSuspended) ?? false
        expression = try container.decodeIfPresent(String.self, forKey: .expression)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(variant, forKey: .variant)
        if isSuspended { try container.encode(isSuspended, forKey: .isSuspended) }
        try container.encodeIfPresent(expression, forKey: .expression)
    }
}

// MARK: Parameter der Elemente

extension SketchEntity {
    /// Freie Parameter des Elements (für den Löser).
    var parameters: [Double] {
        switch self {
        case .line(let a, let b): [a.x, a.y, b.x, b.y]
        case .rectangle(let c, let s): [c.x, c.y, s.x, s.y]
        case .circle(let c, let r): [c.x, c.y, r]
        case .ellipse(let c, let r): [c.x, c.y, r.x, r.y]
        case .regularPolygon(let c, let r, _, let a): [c.x, c.y, r, a]
        case .arc(let a, let m, let b): [a.x, a.y, m.x, m.y, b.x, b.y]
        case .spline(let points, _, _, _), .polyline(let points, _): points.flatMap { [$0.x, $0.y] }
        case .point(let p): [p.x, p.y]
        case .text(let t): [t.anchor.x, t.anchor.y]
        }
    }

    /// Element mit neuen Parametern (gleiche Anzahl wie parameters).
    func with(parameters v: [Double]) -> SketchEntity {
        func pts(_ n: Int) -> [Point2] { (0..<n).map { Point2(v[2 * $0], v[2 * $0 + 1]) } }
        switch self {
        case .line: return .line(Point2(v[0], v[1]), Point2(v[2], v[3]))
        case .rectangle: return .rectangle(corner: Point2(v[0], v[1]), size: Point2(v[2], v[3]))
        case .circle: return .circle(center: Point2(v[0], v[1]), radius: abs(v[2]))
        case .ellipse: return .ellipse(center: Point2(v[0], v[1]), radii: Point2(abs(v[2]), abs(v[3])))
        case .regularPolygon(_, _, let sides, _):
            return .regularPolygon(center: Point2(v[0], v[1]), radius: abs(v[2]), sides: sides, angle: v[3])
        case .arc: return .arc(start: Point2(v[0], v[1]), mid: Point2(v[2], v[3]), end: Point2(v[4], v[5]))
        case .spline(let points, let kind, let closed, let tangents):
            return .spline(points: pts(points.count), kind: kind, closed: closed, tangents: tangents)
        case .polyline(let points, let closed): return .polyline(pts(points.count), closed: closed)
        case .point: return .point(Point2(v[0], v[1]))
        case .text(let t):
            let anchor = Point2(v[0], v[1])
            guard simd_distance(anchor, t.anchor) > 1e-9 else { return self }
            return .text(SketchText(string: t.string, anchor: anchor, height: t.height, fontName: t.fontName,
                                    alignment: t.alignment))
        }
    }

    /// Griffpunkte: Enden, Ecken, Mitten (Reihenfolge = SketchPointRef.index).
    var handlePoints: [Point2] {
        switch self {
        case .line(let a, let b): return [a, b]
        case .rectangle(let c, let s): return [c, c + Point2(s.x, 0), c + s, c + Point2(0, s.y), c + s / 2]
        case .circle(let c, _), .ellipse(let c, _): return [c]
        case .regularPolygon(let c, let r, let n, let a):
            return [c] + SketchEntity.polygonCorners(center: c, radius: r, sides: n, angle: a)
        case .arc(let a, let m, let b):
            return [a, b] + (circleThrough(a, m, b).map { [$0.center] } ?? [])
        case .spline(let points, _, _, _), .polyline(let points, _): return points
        case .point(let p): return [p]
        case .text(let t): return [t.anchor]
        }
    }

    /// Element, bei dem Griffpunkt k (siehe handlePoints) nach p gezogen wurde – wie im Pfeil-Werkzeug:
    /// Rechteckecke zieht gegenüber fest, Polygonecke ändert Radius und Drehung, Zentren verschieben.
    /// nil, wenn der Punkt das ganze Element verschiebt.
    func movingHandle(_ k: Int, to p: Point2) -> SketchEntity? {
        switch self {
        case .line(let a, let b):
            return k == 0 ? .line(p, b) : .line(a, p)
        case .rectangle(let corner, let size):
            guard k < 4 else { return nil }
            let corners = [corner, corner + Point2(size.x, 0), corner + size, corner + Point2(0, size.y)]
            let opposite = corners[(k + 2) % 4]
            let lo = simd_min(opposite, p), hi = simd_max(opposite, p)
            guard hi.x - lo.x > 1e-6, hi.y - lo.y > 1e-6 else { return self }
            return .rectangle(corner: lo, size: hi - lo)
        case .regularPolygon(let center, _, let sides, _):
            guard k >= 1 else { return nil }
            let radius = simd_distance(center, p)
            guard radius > 1e-6 else { return self }
            let angle = atan2(p.y - center.y, p.x - center.x) - Double(k - 1) / Double(max(sides, 3)) * 2 * .pi
            return .regularPolygon(center: center, radius: radius, sides: sides, angle: angle)
        case .arc(let a, let m, let b):
            switch k {
            case 0:
                let moved = SketchEntity.arc(start: p, mid: m + (p - a) / 2, end: b)
                return circleThrough(p, m + (p - a) / 2, b) == nil ? self : moved
            case 1:
                let moved = SketchEntity.arc(start: a, mid: m + (p - b) / 2, end: p)
                return circleThrough(a, m + (p - b) / 2, p) == nil ? self : moved
            default:
                return nil
            }
        case .spline(var points, let kind, let closed, let tangents):
            guard points.indices.contains(k) else { return nil }
            points[k] = p
            return .spline(points: points, kind: kind, closed: closed, tangents: tangents)
        case .polyline(var points, let closed):
            guard points.indices.contains(k) else { return nil }
            points[k] = p
            return .polyline(points, closed: closed)
        case .point:
            return .point(p)
        case .circle, .ellipse, .text:
            return nil
        }
    }

    /// Anzahl auswählbarer Kurven (Kanten).
    var curveCount: Int {
        switch self {
        case .rectangle: 4
        case .regularPolygon(_, _, let n, _): max(n, 3)
        case .polyline(let points, let closed): max(points.count - (closed ? 0 : 1), 0)
        case .point, .text: 0
        default: 1
        }
    }

    /// Kurve index als Linie oder Kreis.
    func constraintCurve(_ index: Int) -> ConstraintCurve {
        switch self {
        case .line(let a, let b): return .line(a, b)
        case .rectangle, .regularPolygon:
            let corners = Array(handlePoints.dropLast(self.isRectangle ? 1 : 0).dropFirst(self.isRectangle ? 0 : 1))
            guard !corners.isEmpty else { return .other }
            let i = index % corners.count
            return .line(corners[i], corners[(i + 1) % corners.count])
        case .polyline(let points, _):
            guard points.count >= 2 else { return .other }
            let i = index % points.count
            return .line(points[i], points[(i + 1) % points.count])
        case .circle(let c, let r): return .circle(center: c, radius: r)
        case .arc(let a, let m, let b):
            return circleThrough(a, m, b).map { .circle(center: $0.center, radius: $0.radius) } ?? .line(a, b)
        default: return .other
        }
    }

    private var isRectangle: Bool {
        if case .rectangle = self { return true }
        return false
    }
}

// MARK: Löser

enum ConstraintSolver {
    /// Passt die Elemente so an, dass alle Einschränkungen gelten. locked: Elemente, die sich nicht bewegen.
    /// weights: wie teuer es ist, ein Element zu bewegen (fehlend = 1); der Löser sucht die kleinste gewichtete
    /// Änderung, teure Elemente bleiben also möglichst stehen (Kai: nur die geänderte Form soll sich bewegen).
    /// Liefert nil, wenn sich die Einschränkungen nicht erfüllen lassen.
    static func solve(_ original: [SketchEntity], constraints all: [SketchConstraint], locked: Set<Int> = [],
                      weights: [Int: Double] = [:]) -> [SketchEntity]? {
        // Gelöste Maße (rotes Schloss) gelten nicht
        let constraints = all.filter { !$0.isSuspended }
        guard !constraints.isEmpty else { return original }
        let entities = original.map(balancedArc)
        // Nur Elemente, die in Einschränkungen vorkommen, sind Unbekannte
        let involved = Set(constraints.flatMap(\.entities)).filter { entities.indices.contains($0) }.sorted()
        var offsets: [Int: Int] = [:]
        var x: [Double] = []
        for index in involved {
            offsets[index] = x.count
            x += entities[index].parameters
        }
        var free: [Int] = []
        // Spaltenfaktor 1/√Gewicht: kleinste Änderung im gewichteten Sinn
        var scales: [Double] = []
        for index in involved where !locked.contains(index) {
            let start = offsets[index]!
            let count = entities[index].parameters.count
            free += Array(start..<(start + count))
            let weight: Double = max(weights[index] ?? 1, 1e-6)
            scales += [Double](repeating: 1 / weight.squareRoot(), count: count)
        }
        func build(_ x: [Double]) -> [SketchEntity] {
            var result = entities
            for index in involved {
                let start = offsets[index]!
                let count = entities[index].parameters.count
                result[index] = entities[index].with(parameters: Array(x[start..<(start + count)]))
            }
            return result
        }
        func residuals(_ x: [Double]) -> [Double] {
            let current = build(x)
            return constraints.flatMap { residual($0, current) } + arcGauge(current, involved)
        }

        var r = residuals(x)
        guard !free.isEmpty else { return norm(r) < 1e-6 ? entities : nil }
        for _ in 0..<40 {
            if norm(r) < 1e-9 { break }
            // Jacobi-Matrix numerisch (m × n)
            let m = r.count, n = free.count
            var jacobian = [Double](repeating: 0, count: m * n)
            for (column, variable) in free.enumerated() {
                let h = 1e-6 * max(1, abs(x[variable]))
                var shifted = x
                shifted[variable] += h
                let rs = residuals(shifted)
                let scale = scales[column]
                for row in 0..<m { jacobian[row * n + column] = scale * (rs[row] - r[row]) / h }
            }
            // Kleinste Änderung: dx = -S Jᵀ (J S² Jᵀ + μ I)⁻¹ r mit S = Spaltenfaktoren (Gewichte)
            var a = [Double](repeating: 0, count: m * m)
            for i in 0..<m {
                for j in i..<m {
                    var sum = 0.0
                    for k in 0..<n { sum += jacobian[i * n + k] * jacobian[j * n + k] }
                    a[i * m + j] = sum
                    a[j * m + i] = sum
                }
                a[i * m + i] += 1e-9
            }
            guard let y = solveLinear(a, r, size: m) else { return nil }
            var step = [Double](repeating: 0, count: n)
            for k in 0..<n {
                var sum = 0.0
                for i in 0..<m { sum += jacobian[i * n + k] * y[i] }
                step[k] = -sum * scales[k]
            }
            // Schrittweite halbieren, bis der Fehler sinkt
            var factor = 1.0
            var improved = false
            for _ in 0..<12 {
                var candidate = x
                for (k, variable) in free.enumerated() { candidate[variable] += factor * step[k] }
                let rc = residuals(candidate)
                if norm(rc) < norm(r) {
                    x = candidate
                    r = rc
                    improved = true
                    break
                }
                factor /= 2
            }
            if !improved { break }
        }
        return norm(r) < 1e-5 ? build(x) : nil
    }

    /// Shapr3D „Sketch states“: Elemente, deren Parameter alle durch Einschränkungen festgelegt sind
    /// (Freiheitsgrade 0). Ein Parameter ist fest, wenn er senkrecht zum Nullraum der Jacobi-Matrix liegt:
    /// Zeilenraum per Gram-Schmidt orthonormieren, dann Σ q[i]² ≈ 1.
    static func determined(_ original: [SketchEntity], constraints all: [SketchConstraint]) -> Set<Int> {
        let constraints = all.filter { !$0.isSuspended }
        guard !constraints.isEmpty else { return [] }
        let entities = original.map(balancedArc)
        let involved = Set(constraints.flatMap(\.entities)).filter { entities.indices.contains($0) }.sorted()
        var offsets: [Int: Int] = [:]
        var x: [Double] = []
        for index in involved {
            offsets[index] = x.count
            x += entities[index].parameters
        }
        let n = x.count
        // Große Skizzen: nicht bei jedem Strich hunderte Spalten numerisch ableiten
        guard n > 0, n <= 600 else { return [] }
        func build(_ x: [Double]) -> [SketchEntity] {
            var result = entities
            for index in involved {
                guard let start = offsets[index] else { continue }
                let count = entities[index].parameters.count
                result[index] = entities[index].with(parameters: Array(x[start..<(start + count)]))
            }
            return result
        }
        func residuals(_ x: [Double]) -> [Double] {
            let current = build(x)
            return constraints.flatMap { residual($0, current) } + arcGauge(current, involved)
        }
        let r = residuals(x)
        let m = r.count
        guard m > 0 else { return [] }
        // Jacobi-Matrix zeilenweise (m Zeilen der Länge n)
        var rows = [[Double]](repeating: [Double](repeating: 0, count: n), count: m)
        for column in 0..<n {
            let h = 1e-6 * max(1, abs(x[column]))
            var shifted = x
            shifted[column] += h
            let rs = residuals(shifted)
            guard rs.count == m else { return [] }
            for row in 0..<m { rows[row][column] = (rs[row] - r[row]) / h }
        }
        // Orthonormalbasis des Zeilenraums (abhängige Zeilen = überzählige Einschränkungen fallen weg)
        var basis: [[Double]] = []
        for var row in rows {
            for q in basis {
                var dot = 0.0
                for k in 0..<n { dot += row[k] * q[k] }
                for k in 0..<n { row[k] -= dot * q[k] }
            }
            let length = row.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard length > 1e-7 else { continue }
            basis.append(row.map { $0 / length })
        }
        var fixed = [Bool](repeating: false, count: n)
        for k in 0..<n {
            var sum = 0.0
            for q in basis { sum += q[k] * q[k] }
            fixed[k] = sum > 1 - 1e-5
        }
        var result = Set<Int>()
        for index in involved {
            guard let start = offsets[index] else { continue }
            let count = entities[index].parameters.count
            if count > 0, (start..<(start + count)).allSatisfy({ fixed[$0] }) { result.insert(index) }
        }
        return result
    }

    /// Bogen mit der Mitte genau zwischen Anfang und Ende (gleiche Form). Kai (Langloch): Der freie
    /// Mittelpunkt rutschte im Löser über ein Bogenende hinaus – der Bogen klappte zum großen Gegenbogen um.
    static func balancedArc(_ entity: SketchEntity) -> SketchEntity {
        guard case .arc(let a, let m, let b) = entity, let circle = circleThrough(a, m, b) else { return entity }
        let c = circle.center
        func ccw(_ from: Double, _ to: Double) -> Double {
            var d = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
            if d < 0 { d += 2 * .pi }
            return d
        }
        let a0 = atan2(a.y - c.y, a.x - c.x)
        let sweepCCW = ccw(a0, atan2(b.y - c.y, b.x - c.x))
        let midCCW = ccw(a0, atan2(m.y - c.y, m.x - c.x))
        // Drehsinn, in dem m zwischen a und b liegt
        let sweep = midCCW <= sweepCCW ? sweepCCW : sweepCCW - 2 * .pi
        let half = a0 + sweep / 2
        return .arc(start: a, mid: c + Point2(cos(half), sin(half)) * circle.radius, end: b)
    }

    /// Bögen: Mitte bleibt gleich weit von beiden Enden (sonst ein freier Parameter ohne Wirkung auf die Form).
    private static func arcGauge(_ entities: [SketchEntity], _ indices: [Int]) -> [Double] {
        indices.compactMap { index -> Double? in
            guard entities.indices.contains(index), case .arc(let a, let m, let b) = entities[index] else { return nil }
            return simd_distance(m, a) - simd_distance(m, b)
        }
    }

    /// Kai (Parallelogramm): Eine Lösung, bei der zwei verbundene Linien plötzlich auf einer Geraden liegen
    /// (Ecke klappt auf 0° bzw. 180°) oder eine Linie auf Länge 0 schrumpft, ist ein Zusammenklappen – die
    /// Einschränkungen lassen das Maß nur so zu. Dann lieber ablehnen.
    static func folds(from before: [SketchEntity], to after: [SketchEntity]) -> Bool {
        var segments: [(before: [Point2], after: [Point2], moved: Bool)] = []
        for index in before.indices where after.indices.contains(index) {
            guard case .line(let a, let b) = before[index], case .line(let c, let d) = after[index] else { continue }
            let moved = simd_distance(a, c) > 1e-9 || simd_distance(b, d) > 1e-9
            if moved, simd_distance(a, b) > 1e-4, simd_distance(c, d) < 1e-6 { return true }
            segments.append(([a, b], [c, d], moved))
        }
        guard segments.count <= 400 else { return false }
        func angle(_ v: Point2, _ w: Point2) -> Double {
            atan2(abs(v.x * w.y - v.y * w.x), simd_dot(v, w)) * 180 / .pi
        }
        for i in segments.indices {
            for j in segments.indices where j > i && (segments[i].moved || segments[j].moved) {
                let s = segments[i], t = segments[j]
                for k in 0..<2 {
                    for l in 0..<2 where simd_distance(s.before[k], t.before[l]) < 1e-6 {
                        let v0 = s.before[1 - k] - s.before[k], w0 = t.before[1 - l] - t.before[l]
                        let v1 = s.after[1 - k] - s.after[k], w1 = t.after[1 - l] - t.after[l]
                        guard simd_length(v0) > 1e-9, simd_length(w0) > 1e-9,
                              simd_length(v1) > 1e-9, simd_length(w1) > 1e-9 else { continue }
                        let old = angle(v0, w0), new = angle(v1, w1)
                        if old > 2, old < 178, new < 0.3 || new > 179.7 { return true }
                    }
                }
            }
        }
        return false
    }

    /// Kai (Langloch): Ist eine zusammenhängende Gruppe vollständig bemaßt, bleibt beim Ziehen nur Verschieben.
    /// Prüfung: einen Punkt festhalten und die Drehung sperren – sind dann alle Elemente bestimmt, ist die Form
    /// starr. Liefert die Gruppe (mindestens zwei Elemente, nichts verankert), sonst nil.
    static func rigidGroup(containing index: Int, _ entities: [SketchEntity],
                           constraints all: [SketchConstraint]) -> Set<Int>? {
        let constraints = all.filter { !$0.isSuspended }
        guard entities.indices.contains(index), !constraints.isEmpty else { return nil }
        var group: Set<Int> = [index]
        var grew = true
        while grew {
            grew = false
            for constraint in constraints {
                let linked = Set(constraint.entities)
                if !linked.isDisjoint(with: group), !linked.isSubset(of: group) {
                    group.formUnion(linked)
                    grew = true
                }
            }
        }
        group = group.filter { entities.indices.contains($0) }
        guard group.count >= 2, group.count <= 200 else { return nil }
        let local = constraints.filter { !Set($0.entities).isDisjoint(with: group) }
        let anchored = local.contains { constraint in
            if case .lock = constraint.variant { return true }
            return false
        }
        guard !anchored, let anchor = entities[index].handlePoints.first else { return nil }
        var extended = entities
        var extra = [SketchConstraint(variant: .lock(SketchPointRef(entity: index, index: 0), at: anchor))]
        // Weitester Griffpunkt der Gruppe sperrt die Drehung (liegt auf einer festen Hilfslinie)
        var far: (ref: SketchPointRef, point: Point2, distance: Double)?
        for member in group {
            for (k, point) in entities[member].handlePoints.enumerated() {
                let distance = simd_distance(point, anchor)
                if distance > (far?.distance ?? 1e-6) { far = (SketchPointRef(entity: member, index: k), point, distance) }
            }
        }
        if let far {
            let helper = extended.count
            extended.append(.line(anchor, far.point))
            extra += [SketchConstraint(variant: .lock(SketchPointRef(entity: helper, index: 0), at: anchor)),
                      SketchConstraint(variant: .lock(SketchPointRef(entity: helper, index: 1), at: far.point)),
                      SketchConstraint(variant: .pointOnCurve(far.ref, SketchCurveRef(entity: helper, index: 0)))]
        }
        let fixed = determined(extended, constraints: local + extra)
        return group.isSubset(of: fixed) ? group : nil
    }

    private static func norm(_ v: [Double]) -> Double {
        v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    /// Gauß-Elimination mit Pivotsuche.
    private static func solveLinear(_ matrix: [Double], _ rhs: [Double], size n: Int) -> [Double]? {
        var a = matrix, b = rhs
        for column in 0..<n {
            var pivot = column
            for row in column..<n where abs(a[row * n + column]) > abs(a[pivot * n + column]) { pivot = row }
            guard abs(a[pivot * n + column]) > 1e-14 else { continue }
            if pivot != column {
                for k in 0..<n { a.swapAt(column * n + k, pivot * n + k) }
                b.swapAt(column, pivot)
            }
            for row in (column + 1)..<n {
                let f = a[row * n + column] / a[column * n + column]
                guard f != 0 else { continue }
                for k in column..<n { a[row * n + k] -= f * a[column * n + k] }
                b[row] -= f * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let d = a[row * n + row]
            guard abs(d) > 1e-14 else { x[row] = 0; continue }
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row * n + k] * x[k] }
            x[row] = sum / d
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    // MARK: Fehlerfunktionen

    static func point(_ ref: SketchPointRef, _ entities: [SketchEntity]) -> Point2? {
        guard entities.indices.contains(ref.entity) else { return nil }
        let points = entities[ref.entity].handlePoints
        return points.indices.contains(ref.index) ? points[ref.index] : nil
    }

    static func curve(_ ref: SketchCurveRef, _ entities: [SketchEntity]) -> ConstraintCurve {
        guard entities.indices.contains(ref.entity) else { return .other }
        return entities[ref.entity].constraintCurve(ref.index)
    }

    private static func direction(_ a: Point2, _ b: Point2) -> Point2 {
        let d = b - a
        let length = simd_length(d)
        return length > 1e-12 ? d / length : Point2(1, 0)
    }

    private static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }

    static func residual(_ constraint: SketchConstraint, _ e: [SketchEntity]) -> [Double] {
        switch constraint.variant {
        case .parallel(let a, let b):
            guard case .line(let p1, let p2) = curve(a, e), case .line(let q1, let q2) = curve(b, e) else { return [] }
            return [cross(direction(p1, p2), direction(q1, q2))]
        case .perpendicular(let a, let b):
            guard case .line(let p1, let p2) = curve(a, e), case .line(let q1, let q2) = curve(b, e) else { return [] }
            return [simd_dot(direction(p1, p2), direction(q1, q2))]
        case .tangent(let a, let b, let outside):
            switch (curve(a, e), curve(b, e)) {
            case (.line(let p1, let p2), .circle(let c, let r)), (.circle(let c, let r), .line(let p1, let p2)):
                return [abs(cross(direction(p1, p2), c - p1)) - r]
            case (.circle(let c1, let r1), .circle(let c2, let r2)):
                return [simd_distance(c1, c2) - (outside ? r1 + r2 : abs(r1 - r2))]
            default:
                return []
            }
        case .coincident(let a, let b):
            guard let p = point(a, e), let q = point(b, e) else { return [] }
            return [p.x - q.x, p.y - q.y]
        case .pointOnCurve(let a, let c):
            guard let p = point(a, e) else { return [] }
            switch curve(c, e) {
            case .line(let q1, let q2): return [cross(direction(q1, q2), p - q1)]
            case .circle(let center, let r): return [simd_distance(p, center) - r]
            case .other: return []
            }
        case .midpoint(let a, let c):
            guard let p = point(a, e), case .line(let q1, let q2) = curve(c, e) else { return [] }
            let m = (q1 + q2) / 2
            return [p.x - m.x, p.y - m.y]
        case .concentric(let a, let b):
            guard case .circle(let c1, _) = curve(a, e), case .circle(let c2, _) = curve(b, e) else { return [] }
            return [c1.x - c2.x, c1.y - c2.y]
        case .horizontal(let c):
            guard case .line(let p1, let p2) = curve(c, e) else { return [] }
            return [p2.y - p1.y]
        case .vertical(let c):
            guard case .line(let p1, let p2) = curve(c, e) else { return [] }
            return [p2.x - p1.x]
        case .horizontalPoints(let a, let b):
            guard let p = point(a, e), let q = point(b, e) else { return [] }
            return [p.y - q.y]
        case .verticalPoints(let a, let b):
            guard let p = point(a, e), let q = point(b, e) else { return [] }
            return [p.x - q.x]
        case .equalLength(let a, let b):
            guard case .line(let p1, let p2) = curve(a, e), case .line(let q1, let q2) = curve(b, e) else { return [] }
            return [simd_distance(p1, p2) - simd_distance(q1, q2)]
        case .equalRadius(let a, let b):
            guard case .circle(_, let r1) = curve(a, e), case .circle(_, let r2) = curve(b, e) else { return [] }
            return [r1 - r2]
        case .equalAngle(let a, let b, let mirrored):
            guard case .line(let p1, let p2) = curve(a, e), case .line(let q1, let q2) = curve(b, e) else { return [] }
            let d1 = direction(p1, p2), d2 = direction(q1, q2)
            // Gespiegelt: Richtung an der Waagerechten spiegeln (x, y) → (x, −y); für Linien ohne Richtungssinn
            // ist das dieselbe Gerade wie gespiegelt an der Senkrechten (−x, y)
            let target: Point2 = mirrored ? Point2(d2.x, -d2.y) : d2
            return [cross(d1, target)]
        case .symmetric(let a, let b, let axis):
            guard let p = point(a, e), let q = point(b, e), case .line(let s1, let s2) = curve(axis, e) else { return [] }
            let d = direction(s1, s2)
            return [cross(d, (p + q) / 2 - s1), simd_dot(q - p, d)]
        case .lock(let a, let at):
            guard let p = point(a, e) else { return [] }
            return [p.x - at.x, p.y - at.y]
        case .distance(let a, let b, let value):
            guard let p = point(a, e), let q = point(b, e) else { return [] }
            return [simd_distance(p, q) - value]
        case .pointLineDistance(let a, let c, let value):
            guard let p = point(a, e) else { return [] }
            switch curve(c, e) {
            case .line(let q1, let q2): return [abs(cross(direction(q1, q2), p - q1)) - value]
            case .circle(let center, let r): return [abs(simd_distance(p, center) - r) - value]
            case .other: return []
            }
        case .angle(let a, let b, let degrees):
            guard case .line(let p1, let p2) = curve(a, e), case .line(let q1, let q2) = curve(b, e) else { return [] }
            let d1 = direction(p1, p2), d2 = direction(q1, q2)
            let angle = atan2(abs(cross(d1, d2)), simd_dot(d1, d2))
            return [angle - degrees * .pi / 180]
        case .radius(let c, let value, let diameter):
            guard case .circle(_, let r) = curve(c, e) else { return [] }
            return [(diameter ? 2 * r : r) - value]
        }
    }
}
