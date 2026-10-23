import Foundation
import simd

// Weitere Skizzenwerkzeuge nach dem Vorbild von Fusion 360 (Erstellen- und Ändern-Menü):
// Kreis aus 2 bzw. 3 Punkten, Bogen um einen Mittelpunkt, Polygon innen/außen, Langloch,
// Spiegeln, Rechteck- und Kreismuster, Verlängern und Unterbrechen.

/// Varianten des Kreis-Werkzeugs (Fusion 360: Mittelpunkt/Durchmesser, 2 Punkte, 3 Punkte).
enum CircleMode: String, CaseIterable, Identifiable {
    case center = "Mittelpunkt"
    case twoPoint = "2 Punkte"
    case threePoint = "3 Punkte"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .center: "circle.circle"
        case .twoPoint: "circle.and.line.horizontal"
        case .threePoint: "circle.dotted"
        }
    }
}

/// Varianten des Bogen-Werkzeugs (3 Punkte wie bisher, oder Mittelpunkt, Start, Ende).
enum ArcMode: String, CaseIterable, Identifiable {
    case threePoint = "3 Punkte"
    case center = "Mittelpunkt"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .threePoint: "point.topleft.down.curvedto.point.bottomright.up"
        case .center: "circle.bottomhalf.filled"
        }
    }
}

/// Polygon: Ecke auf dem gezogenen Kreis (innen, „Inscribed“) oder Kantenmitte (außen, „Circumscribed“).
enum PolygonMode: String, CaseIterable, Identifiable {
    case inscribed = "Ecke"
    case circumscribed = "Kante"

    var id: Self { self }
}

/// Varianten des Langlochs (Fusion 360: Mitte zu Mitte, Gesamtlänge, Mittelpunkt).
enum SlotMode: String, CaseIterable, Identifiable {
    case centerToCenter = "Mitte zu Mitte"
    case overall = "Gesamt"
    case centerPoint = "Mittelpunkt"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .centerToCenter: "capsule"
        case .overall: "capsule.portrait"
        case .centerPoint: "capsule.inset.filled"
        }
    }
}

enum SketchShapes {
    /// Kreis durch zwei Punkte als Durchmesser.
    static func circle(diameterFrom a: Point2, to b: Point2) -> SketchEntity? {
        let d = simd_distance(a, b)
        return d > 1e-6 ? .circle(center: (a + b) / 2, radius: d / 2) : nil
    }

    /// Kreis durch drei Punkte.
    static func circle(through a: Point2, _ b: Point2, _ c: Point2) -> SketchEntity? {
        circleThrough(a, b, c).map { .circle(center: $0.center, radius: $0.radius) }
    }

    /// Bogen um center, beginnend bei start, mit vorzeichenbehaftetem Öffnungswinkel sweep.
    static func arc(center: Point2, start: Point2, sweep: Double) -> SketchEntity? {
        let radius = simd_distance(center, start)
        guard radius > 1e-6, abs(sweep) > 1e-4 else { return nil }
        let a0 = atan2(start.y - center.y, start.x - center.x)
        let limited = max(min(sweep, 2 * .pi - 1e-3), -(2 * .pi - 1e-3))
        func point(_ angle: Double) -> Point2 { center + radius * Point2(cos(angle), sin(angle)) }
        return .arc(start: start, mid: point(a0 + limited / 2), end: point(a0 + limited))
    }

    /// Polygon um center durch through: als Ecke (innen) oder Kantenmitte (außen).
    static func polygon(center: Point2, through p: Point2, sides: Int, mode: PolygonMode) -> SketchEntity? {
        let r = simd_distance(center, p)
        guard r > 1e-6 else { return nil }
        let angle = atan2(p.y - center.y, p.x - center.x)
        switch mode {
        case .inscribed:
            return .regularPolygon(center: center, radius: r, sides: sides, angle: angle)
        case .circumscribed:
            let n = Double(max(sides, 3))
            return .regularPolygon(center: center, radius: r / cos(.pi / n), sides: sides, angle: angle + .pi / n)
        }
    }

    /// Mitten der beiden Halbkreise eines Langlochs aus dem ersten Zug (a–b) und der Halbbreite.
    static func slotCenters(_ a: Point2, _ b: Point2, half: Double, mode: SlotMode) -> (Point2, Point2)? {
        guard simd_distance(a, b) > 1e-6 else { return nil }
        let u = simd_normalize(b - a)
        switch mode {
        case .centerToCenter:
            return (a, b)
        case .overall:
            guard simd_distance(a, b) > 2 * half + 1e-6 else { return nil }
            return (a + u * half, b - u * half)
        case .centerPoint:
            // a = Mitte des Langlochs, b = Mitte eines Halbkreises
            return (a * 2 - b, b)
        }
    }

    /// Halbbreite aus dem zweiten Zug: Abstand von p zur Mittellinie a–b.
    static func slotHalfWidth(_ a: Point2, _ b: Point2, through p: Point2) -> Double {
        guard simd_distance(a, b) > 1e-9 else { return 0 }
        let n = rightNormal(b - a)
        return abs(simd_dot(p - a, n))
    }

    /// Langloch aus zwei Linien und zwei Halbkreisen (geschlossene Kontur, Enden fallen exakt zusammen).
    static func slot(_ c1: Point2, _ c2: Point2, half h: Double) -> [SketchEntity]? {
        guard h > 1e-6, simd_distance(c1, c2) > 1e-6 else { return nil }
        let u = simd_normalize(c2 - c1)
        let n = Point2(-u.y, u.x)
        let p1 = c1 + n * h, p2 = c2 + n * h, p3 = c2 - n * h, p4 = c1 - n * h
        return [
            .line(p1, p2),
            .arc(start: p2, mid: c2 + u * h, end: p3),
            .line(p3, p4),
            .arc(start: p4, mid: c1 - u * h, end: p1),
        ]
    }
}

// MARK: Spiegeln, Drehen, Verschieben

extension SketchEntity {
    /// Element unter einer Kongruenzabbildung (Drehung um rotation bzw. Spiegelung an einer Geraden mit
    /// Winkel mirrorAngle). Achsparallele Formen, die danach nicht mehr achsparallel sind (Rechteck,
    /// gedrehte Ellipse), werden zu Linienzug bzw. Spline. nil = nicht übertragbar (Text).
    func mapped(_ f: (Point2) -> Point2, rotation: Double = 0, mirrorAngle: Double? = nil) -> SketchEntity? {
        // Vielfache von 90° (bzw. Spiegelachse waagrecht/senkrecht) halten achsparallele Formen achsparallel
        let axisAngle = mirrorAngle ?? rotation
        let quarter = (axisAngle / (.pi / 2)).rounded()
        let keepsAxes = abs(axisAngle - quarter * .pi / 2) < 1e-9
        let swapsAxes = keepsAxes && Int(quarter) % 2 != 0 && mirrorAngle == nil
        switch self {
        case .line(let a, let b):
            return .line(f(a), f(b))
        case .arc(let a, let m, let b):
            return .arc(start: f(a), mid: f(m), end: f(b))
        case .circle(let c, let r):
            return .circle(center: f(c), radius: r)
        case .point(let p):
            return .point(f(p))
        case .spline(let points, let kind, let closed):
            return .spline(points: points.map(f), kind: kind, closed: closed)
        case .polyline(let points, let closed):
            return .polyline(points.map(f), closed: closed)
        case .rectangle(let corner, let size):
            let corners = [corner, corner + Point2(size.x, 0), corner + size, corner + Point2(0, size.y)].map(f)
            if keepsAxes {
                let lo = corners.reduce(corners[0]) { simd_min($0, $1) }, hi = corners.reduce(corners[0]) { simd_max($0, $1) }
                return .rectangle(corner: lo, size: hi - lo)
            }
            return .polyline(corners, closed: true)
        case .ellipse(let c, let radii):
            if keepsAxes {
                return .ellipse(center: f(c), radii: swapsAxes ? Point2(radii.y, radii.x) : radii)
            }
            let samples = (0..<36).map { k -> Point2 in
                let t = Double(k) / 36 * 2 * .pi
                return f(c + Point2(radii.x * cos(t), radii.y * sin(t)))
            }
            return .spline(points: samples, kind: .fit, closed: true)
        case .regularPolygon(let c, let r, let n, let angle):
            if let mirrorAngle {
                return .regularPolygon(center: f(c), radius: r, sides: n, angle: 2 * mirrorAngle - angle)
            }
            return .regularPolygon(center: f(c), radius: r, sides: n, angle: angle + rotation)
        case .text:
            return nil
        }
    }

    /// Gespiegelt an der Geraden durch p mit Richtung d.
    func mirrored(through p: Point2, direction d: Point2) -> SketchEntity? {
        guard simd_length(d) > 1e-12 else { return nil }
        let u = simd_normalize(d)
        return mapped({ q in
            let v = q - p
            return p + 2 * simd_dot(v, u) * u - v
        }, mirrorAngle: atan2(u.y, u.x))
    }

    /// Um center gedreht (Bogenmaß, gegen den Uhrzeigersinn).
    func rotated(about center: Point2, by angle: Double) -> SketchEntity? {
        let c = cos(angle), s = sin(angle)
        return mapped({ q in
            let v = q - center
            return center + Point2(c * v.x - s * v.y, s * v.x + c * v.y)
        }, rotation: angle)
    }
}

// MARK: Unterbrechen und Verlängern

extension SketchTrim {
    /// Unterbrechen wie in Fusion 360 („Break“): das Element wird an den Schnittpunkten links und rechts
    /// der angetippten Stelle geteilt, nichts wird gelöscht. Ohne Schnittpunkte wird an der Stelle selbst
    /// geteilt. nil, wenn sich das Element nicht teilen lässt.
    static func split(_ entity: SketchEntity, at p: Point2, cutters: [TrimPrimitive]) -> [SketchEntity]? {
        let hits = entity.trimPrimitives.flatMap { primitive in cutters.flatMap { intersections(primitive, $0) } }
        func cuts(_ values: [Double], around t: Double) -> [Double] {
            let inner = values.filter { $0 > 1e-6 && $0 < 1 - 1e-6 }
            let lower = inner.filter { $0 <= t }.max(), upper = inner.filter { $0 > t }.min()
            let chosen = [lower, upper].compactMap { $0 }
            return chosen.isEmpty ? [min(max(t, 0.01), 0.99)] : chosen
        }
        switch entity {
        case .line(let a, let b):
            let ab = b - a
            let length2 = simd_length_squared(ab)
            guard length2 > 1e-18 else { return nil }
            let tp = min(max(simd_dot(p - a, ab) / length2, 0), 1)
            let bounds = [0] + cuts(hits.map { simd_dot($0 - a, ab) / length2 }, around: tp) + [1]
            return zip(bounds, bounds.dropFirst()).map { SketchEntity.line(a + ab * $0, a + ab * $1) }
        case .arc(let a, let m, let b):
            guard let arc = ArcGeometry(a, m, b) else { return nil }
            let sp = arc.parameter(p) ?? (simd_distance(p, a) < simd_distance(p, b) ? 0 : 1)
            let bounds = [0] + cuts(hits.compactMap { arc.parameter($0) }, around: sp) + [1]
            return zip(bounds, bounds.dropFirst()).map { arc.entity(from: $0, to: $1) }
        case .circle(let c, let r):
            var angles = hits.map { positiveAngle(atan2($0.y - c.y, $0.x - c.x)) }
            angles.sort()
            var unique: [Double] = []
            for angle in angles where !unique.contains(where: { abs($0 - angle) < 1e-7 }) { unique.append(angle) }
            if unique.count < 2 {
                // Ohne zwei Schnittpunkte: gegenüber der angetippten Stelle und dort teilen
                let tap = positiveAngle(atan2(p.y - c.y, p.x - c.x))
                unique = [tap, positiveAngle(tap + .pi)].sorted()
            }
            func point(_ angle: Double) -> Point2 { c + r * Point2(cos(angle), sin(angle)) }
            return unique.indices.map { i -> SketchEntity in
                let from = unique[i]
                let span = positiveAngle(unique[(i + 1) % unique.count] - from)
                let sweep = span < 1e-9 ? 2 * .pi : span
                return SketchEntity.arc(start: point(from), mid: point(from + sweep / 2), end: point(from + sweep))
            }
        default:
            return nil
        }
    }

    /// Verlängern wie in Fusion 360 („Extend“): das angetippte Ende einer Linie bis zur nächsten Kurve.
    /// Liefert die neue Linie oder nil, wenn in dieser Richtung nichts getroffen wird.
    static func extend(_ entity: SketchEntity, at p: Point2, cutters: [TrimPrimitive]) -> SketchEntity? {
        guard case .line(let a, let b) = entity, simd_distance(a, b) > 1e-9 else { return nil }
        let fromEnd = simd_distance(p, b) <= simd_distance(p, a)
        let tip = fromEnd ? b : a
        let direction = simd_normalize(fromEnd ? b - a : a - b)
        let far = tip + direction * 1e5
        let hits = cutters.flatMap { intersections(.segment(tip, far), $0) }
            .filter { simd_distance($0, tip) > 1e-6 }
        guard let nearest = hits.min(by: { simd_distance($0, tip) < simd_distance($1, tip) }) else { return nil }
        return fromEnd ? .line(a, nearest) : .line(nearest, b)
    }
}
