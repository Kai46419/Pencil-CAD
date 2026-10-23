import Foundation
import simd

// Messen in der Skizze (wie Fusion 360 „Messen“): ein Element zeigt Länge, Radius bzw. Lage,
// zwei Elemente ihren Abstand und Winkel – zwei Linien sagen, ob sie wirklich parallel sind.

struct SketchMeasurement {
    /// Was angetippt wurde
    enum Item {
        case point(Point2)
        case line(Point2, Point2)
        case circle(center: Point2, radius: Double, polyline: [Point2], isArc: Bool)
        case curve([Point2])

        /// Punkte zum Abstandmessen
        var polyline: [Point2] {
            switch self {
            case .point(let p): [p]
            case .line(let a, let b): [a, b]
            case .circle(_, _, let polyline, _), .curve(let polyline): polyline
            }
        }
    }

    /// Ergebniszeilen für die Karte
    private(set) var lines: [String] = []
    /// Kürzeste Verbindung der beiden Elemente (lokal), gestrichelt angezeigt
    private(set) var span: [Point2] = []

    /// Unterhalb dieser Abweichung gelten Winkel als exakt (parallel, rechtwinklig)
    private static let exactDegrees = 0.0005

    init(_ items: [Item]) {
        switch items.count {
        case 1: describe(items[0])
        case 2: compare(items[0], items[1])
        default: break
        }
    }

    // MARK: Ein Element

    private mutating func describe(_ item: Item) {
        switch item {
        case .point(let p):
            lines.append("Punkt  X \(Self.mm(p.x))  Y \(Self.mm(p.y))")
        case .line(let a, let b):
            let d = b - a
            lines.append("Länge: \(Self.mm(simd_length(d)))")
            lines.append("Winkel zur Waagerechten: \(Self.degrees(Self.direction(d)))")
            lines.append("ΔX \(Self.mm(abs(d.x)))  ΔY \(Self.mm(abs(d.y)))")
        case .circle(let center, let radius, let polyline, let isArc):
            if isArc {
                let length = Self.length(polyline)
                lines.append("Radius: \(Self.mm(radius))")
                lines.append("Bogenlänge: \(Self.mm(length))  Öffnung: \(Self.degrees(length / radius * 180 / .pi))")
            } else {
                lines.append("Durchmesser: \(Self.mm(2 * radius))  Radius: \(Self.mm(radius))")
                lines.append("Umfang: \(Self.mm(2 * .pi * radius))")
            }
            lines.append("Mitte  X \(Self.mm(center.x))  Y \(Self.mm(center.y))")
        case .curve(let polyline):
            lines.append("Länge: \(Self.mm(Self.length(polyline)))")
        }
    }

    // MARK: Zwei Elemente

    private mutating func compare(_ first: Item, _ second: Item) {
        switch (first, second) {
        case (.point(let p), .point(let q)):
            let d = q - p
            lines.append("Abstand: \(Self.mm(simd_length(d)))")
            lines.append("ΔX \(Self.mm(abs(d.x)))  ΔY \(Self.mm(abs(d.y)))")
            span = [p, q]
        case (.point(let p), .line(let a, let b)), (.line(let a, let b), .point(let p)):
            let foot = Self.foot(of: p, onLineThrough: a, b)
            lines.append("Abstand senkrecht: \(Self.mm(simd_distance(p, foot)))")
            span = [p, foot]
            let segment = polylineDistance(from: p, to: [a, b], closed: false)
            if abs(segment.distance - simd_distance(p, foot)) > 1e-6 {
                lines.append("Kürzester Abstand zur Strecke: \(Self.mm(segment.distance))")
            }
        case (.point(let p), .circle(let center, let radius, _, _)), (.circle(let center, let radius, _, _), .point(let p)):
            let toCenter = simd_distance(p, center)
            lines.append("Abstand zur Mitte: \(Self.mm(toCenter))")
            lines.append("Abstand zum Kreis: \(Self.mm(abs(toCenter - radius)))")
            span = [p, center]
        case (.line(let a, let b), .line(let c, let d)):
            compareLines(a, b, c, d)
        case (.line(let a, let b), .circle(let center, let radius, _, _)),
             (.circle(let center, let radius, _, _), .line(let a, let b)):
            let foot = Self.foot(of: center, onLineThrough: a, b)
            let distance = simd_distance(center, foot)
            lines.append("Abstand Mitte – Linie: \(Self.mm(distance))")
            lines.append(abs(distance - radius) < 1e-4 ? "Tangential ✓"
                         : "Abstand Kreis – Linie: \(Self.mm(max(distance - radius, 0)))")
            span = [center, foot]
        case (.circle(let c1, let r1, _, _), .circle(let c2, let r2, _, _)):
            let distance = simd_distance(c1, c2)
            if distance < 1e-6 {
                lines.append("Konzentrisch ✓")
            } else {
                lines.append("Mittenabstand: \(Self.mm(distance))")
                let gap = distance - r1 - r2
                lines.append(abs(gap) < 1e-4 ? "Berühren sich ✓" : gap > 0 ? "Abstand der Kreise: \(Self.mm(gap))"
                             : "Überlappen sich")
                span = [c1, c2]
            }
            if abs(r1 - r2) < 1e-6 { lines.append("Gleicher Radius ✓ (\(Self.mm(r1)))") }
        default:
            let nearest = Self.closest(first.polyline, second.polyline)
            lines.append("Kürzester Abstand: \(Self.mm(nearest.distance))")
            span = [nearest.a, nearest.b]
        }
    }

    /// Zwei Linien: Winkel, und bei (fast) parallelen Linien Abstand und Abweichung.
    private mutating func compareLines(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) {
        let u = b - a, v = d - c
        guard simd_length(u) > 1e-9, simd_length(v) > 1e-9 else { return }
        // Spitzer Winkel zwischen den Richtungen (0° = parallel)
        var angle = abs(Self.direction(u) - Self.direction(v)).truncatingRemainder(dividingBy: 180)
        if angle > 90 { angle = 180 - angle }
        let startDistance = simd_distance(c, Self.foot(of: c, onLineThrough: a, b))
        let endDistance = simd_distance(d, Self.foot(of: d, onLineThrough: a, b))
        if angle < Self.exactDegrees {
            lines.append("Parallel ✓")
            lines.append("Abstand: \(Self.mm(startDistance))")
            let mid = (c + d) / 2
            span = [mid, Self.foot(of: mid, onLineThrough: a, b)]
        } else if angle < 10 {
            lines.append("Nicht parallel – Abweichung \(Self.degrees(angle))")
            lines.append("Abstand am Anfang \(Self.mm(startDistance)), am Ende \(Self.mm(endDistance))")
            let near = startDistance < endDistance ? c : d
            span = [near, Self.foot(of: near, onLineThrough: a, b)]
        } else if abs(angle - 90) < Self.exactDegrees {
            lines.append("Rechtwinklig ✓")
        } else {
            lines.append("Winkel: \(Self.degrees(angle))  (bzw. \(Self.degrees(180 - angle)))")
        }
        if angle >= 10 {
            let nearest = Self.closest([a, b], [c, d])
            if nearest.distance > 1e-6 {
                lines.append("Kürzester Abstand: \(Self.mm(nearest.distance))")
                span = [nearest.a, nearest.b]
            }
        }
    }

    // MARK: Hilfen

    private static func mm(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...3)))) mm"
    }

    private static func degrees(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...3))))°"
    }

    /// Richtung in Grad (0…360)
    private static func direction(_ d: Point2) -> Double {
        let degrees = atan2(d.y, d.x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    private static func foot(of p: Point2, onLineThrough a: Point2, _ b: Point2) -> Point2 {
        let d = b - a
        let lengthSquared = simd_length_squared(d)
        guard lengthSquared > 1e-18 else { return a }
        return a + d * (simd_dot(p - a, d) / lengthSquared)
    }

    private static func length(_ polyline: [Point2]) -> Double {
        zip(polyline, polyline.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    /// Kürzeste Verbindung zweier Linienzüge (Ecken des einen gegen die Strecken des anderen).
    private static func closest(_ first: [Point2], _ second: [Point2]) -> (distance: Double, a: Point2, b: Point2) {
        var best = (distance: Double.infinity, a: Point2.zero, b: Point2.zero)
        guard let only = second.first else { return best }
        for p in first {
            var hit = (distance: simd_distance(p, only), point: only)
            if second.count > 1 {
                let found = polylineDistance(from: p, to: second, closed: false)
                hit = (found.distance, found.point)
            }
            if hit.distance < best.distance { best = (hit.distance, p, hit.point) }
        }
        for q in second where first.count > 1 {
            let hit = polylineDistance(from: q, to: first, closed: false)
            if hit.distance < best.distance { best = (hit.distance, hit.point, q) }
        }
        return best
    }
}
