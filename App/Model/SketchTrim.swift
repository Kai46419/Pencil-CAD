import Foundation
import simd

// Beschneiden, Projizieren und Skalieren von Skizzenelementen.
// Beschneiden wie bei Fusion 360 („Trim“): Das angetippte Stück einer Kurve bis zu den nächsten
// Schnittpunkten wird entfernt; ohne Schnittpunkte wird die ganze Kurve gelöscht.

/// Winkel in [0, 2π).
func positiveAngle(_ angle: Double) -> Double {
    let r = angle.truncatingRemainder(dividingBy: 2 * .pi)
    return r < 0 ? r + 2 * .pi : r
}

/// Kreisbogen mit Startwinkel und vorzeichenbehaftetem Öffnungswinkel (positiv = gegen den Uhrzeigersinn).
struct ArcGeometry {
    var center: Point2
    var radius: Double
    var startAngle: Double
    var sweep: Double

    init?(_ a: Point2, _ m: Point2, _ b: Point2) {
        guard let circle = circleThrough(a, m, b) else { return nil }
        center = circle.center
        radius = circle.radius
        let ta = atan2(a.y - center.y, a.x - center.x)
        let tb = atan2(b.y - center.y, b.x - center.x)
        let tm = atan2(m.y - center.y, m.x - center.x)
        let toEnd = positiveAngle(tb - ta), toMid = positiveAngle(tm - ta)
        startAngle = ta
        sweep = toMid < toEnd ? toEnd : -(2 * .pi - toEnd)
    }

    func point(_ s: Double) -> Point2 {
        let angle = startAngle + sweep * s
        return center + radius * Point2(cos(angle), sin(angle))
    }

    /// Parameter 0…1 eines Punkts auf dem Kreis; nil, wenn er nicht auf dem Bogen liegt.
    func parameter(_ p: Point2) -> Double? {
        let t = atan2(p.y - center.y, p.x - center.x)
        let d = sweep >= 0 ? positiveAngle(t - startAngle) : positiveAngle(startAngle - t)
        let s = d / abs(sweep)
        if s <= 1 + 1e-9 { return min(s, 1) }
        // Knapp vor dem Start
        return 2 * .pi - d < 1e-9 ? 0 : nil
    }

    func entity(from s0: Double, to s1: Double) -> SketchEntity {
        .arc(start: point(s0), mid: point((s0 + s1) / 2), end: point(s1))
    }
}

/// Grundform zum Schneiden.
enum TrimPrimitive {
    case segment(Point2, Point2)
    case circle(center: Point2, radius: Double)
    case arc(ArcGeometry)
}

extension SketchEntity {
    /// Grundformen dieses Elements (Ellipsen und Splines als Linienzug angenähert).
    var trimPrimitives: [TrimPrimitive] {
        switch self {
        case .line(let a, let b):
            return [.segment(a, b)]
        case .circle(let c, let r):
            return [.circle(center: c, radius: r)]
        case .arc(let a, let m, let b):
            return ArcGeometry(a, m, b).map { [.arc($0)] } ?? [.segment(a, b)]
        case .point, .text:
            return []
        default:
            return drawing.flatMap { line in
                line.count < 2 ? [] : (0..<(line.count - 1)).map { TrimPrimitive.segment(line[$0], line[$0 + 1]) }
            }
        }
    }

    /// Rechteck, Polygon und Linienzug als einzelne Linien (zum Beschneiden einer Kante).
    var exploded: [SketchEntity]? {
        switch self {
        case .rectangle, .regularPolygon:
            let count = curveCount
            return (0..<count).compactMap { i in
                if case .line(let a, let b) = constraintCurve(i) { return .line(a, b) }
                return nil
            }
        case .polyline(let points, let closed):
            guard points.count >= 2 else { return nil }
            let count = closed ? points.count : points.count - 1
            return (0..<count).map { .line(points[$0], points[($0 + 1) % points.count]) }
        default:
            return nil
        }
    }

    /// Element um center mit factor skaliert.
    func scaled(about center: Point2, by factor: Double) -> SketchEntity {
        func s(_ p: Point2) -> Point2 { center + (p - center) * factor }
        switch self {
        case .line(let a, let b): return .line(s(a), s(b))
        case .rectangle(let c, let size): return .rectangle(corner: s(c), size: size * factor)
        case .circle(let c, let r): return .circle(center: s(c), radius: r * abs(factor))
        case .ellipse(let c, let r): return .ellipse(center: s(c), radii: r * abs(factor))
        case .regularPolygon(let c, let r, let n, let a):
            return .regularPolygon(center: s(c), radius: r * abs(factor), sides: n, angle: a)
        case .arc(let a, let m, let b): return .arc(start: s(a), mid: s(m), end: s(b))
        case .spline(let points, let kind, let closed, let tangents):
            return .spline(points: points.map(s), kind: kind, closed: closed,
                           tangents: SketchEntity.mappedTangents(tangents, points: points, s))
        case .polyline(let points, let closed): return .polyline(points.map(s), closed: closed)
        case .point(let p): return .point(s(p))
        case .text(let t):
            return .text(SketchText(string: t.string, anchor: s(t.anchor), height: t.height * abs(factor),
                                    fontName: t.fontName, alignment: t.alignment))
        }
    }

    /// Element verschoben.
    func translated(by d: Point2) -> SketchEntity {
        let v = parameters
        switch self {
        case .circle, .ellipse, .regularPolygon, .rectangle:
            var moved = v
            moved[0] += d.x
            moved[1] += d.y
            return with(parameters: moved)
        default:
            return with(parameters: v.enumerated().map { $0.element + ($0.offset % 2 == 0 ? d.x : d.y) })
        }
    }
}

enum SketchTrim {
    // MARK: Schnittpunkte

    static func intersections(_ p: TrimPrimitive, _ q: TrimPrimitive) -> [Point2] {
        switch (p, q) {
        case (.segment(let a, let b), .segment(let c, let d)):
            return segmentSegment(a, b, c, d).map { [$0] } ?? []
        case (.segment(let a, let b), .circle(let c, let r)), (.circle(let c, let r), .segment(let a, let b)):
            return segmentCircle(a, b, c, r)
        case (.segment(let a, let b), .arc(let arc)), (.arc(let arc), .segment(let a, let b)):
            return segmentCircle(a, b, arc.center, arc.radius).filter { arc.parameter($0) != nil }
        case (.circle(let c1, let r1), .circle(let c2, let r2)):
            return circleCircle(c1, r1, c2, r2)
        case (.circle(let c, let r), .arc(let arc)), (.arc(let arc), .circle(let c, let r)):
            return circleCircle(c, r, arc.center, arc.radius).filter { arc.parameter($0) != nil }
        case (.arc(let a1), .arc(let a2)):
            return circleCircle(a1.center, a1.radius, a2.center, a2.radius)
                .filter { a1.parameter($0) != nil && a2.parameter($0) != nil }
        }
    }

    static func segmentSegment(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> Point2? {
        let r = b - a, s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let w = c - a
        let t = (w.x * s.y - w.y * s.x) / denominator
        let u = (w.x * r.y - w.y * r.x) / denominator
        let eps = 1e-9
        guard t >= -eps, t <= 1 + eps, u >= -eps, u <= 1 + eps else { return nil }
        return a + r * t
    }

    static func segmentCircle(_ a: Point2, _ b: Point2, _ center: Point2, _ radius: Double) -> [Point2] {
        let d = b - a, f = a - center
        let qa = simd_dot(d, d), qb = 2 * simd_dot(f, d), qc = simd_dot(f, f) - radius * radius
        guard qa > 1e-18 else { return [] }
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant >= -1e-12 else { return [] }
        let root = max(discriminant, 0).squareRoot()
        let ts = root < 1e-12 ? [-qb / (2 * qa)] : [(-qb - root) / (2 * qa), (-qb + root) / (2 * qa)]
        return ts.filter { $0 >= -1e-9 && $0 <= 1 + 1e-9 }.map { a + d * $0 }
    }

    static func circleCircle(_ c1: Point2, _ r1: Double, _ c2: Point2, _ r2: Double) -> [Point2] {
        let d = simd_distance(c1, c2)
        guard d > 1e-12, d <= r1 + r2 + 1e-9, d >= abs(r1 - r2) - 1e-9 else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = max(r1 * r1 - a * a, 0).squareRoot()
        let mid = c1 + (c2 - c1) * (a / d)
        let perpendicular = Point2(-(c2.y - c1.y), c2.x - c1.x) / d
        return h < 1e-9 ? [mid] : [mid + perpendicular * h, mid - perpendicular * h]
    }

    // MARK: Beschneiden

    /// Ersatz für entity, nachdem das Stück um p entfernt wurde ([] = ganz löschen).
    /// nil, wenn sich das Element nicht beschneiden lässt (Ellipse, Spline mit Schnittpunkten, Text).
    static func trim(_ entity: SketchEntity, at p: Point2, cutters: [TrimPrimitive]) -> [SketchEntity]? {
        let own = entity.trimPrimitives
        let hits = own.flatMap { primitive in cutters.flatMap { intersections(primitive, $0) } }
        switch entity {
        case .line(let a, let b):
            let ab = b - a
            let length2 = simd_length_squared(ab)
            guard length2 > 1e-18 else { return [] }
            let ts = hits.map { simd_dot($0 - a, ab) / length2 }
            let tp = min(max(simd_dot(p - a, ab) / length2, 0), 1)
            let (t0, t1) = interval(around: tp, cuts: ts)
            var pieces: [SketchEntity] = []
            if t0 > 1e-6 { pieces.append(.line(a, a + ab * t0)) }
            if t1 < 1 - 1e-6 { pieces.append(.line(a + ab * t1, b)) }
            return pieces
        case .arc(let a, let m, let b):
            guard let arc = ArcGeometry(a, m, b) else { return [] }
            let ss = hits.compactMap { arc.parameter($0) }
            let sp = arc.parameter(p) ?? (simd_distance(p, a) < simd_distance(p, b) ? 0 : 1)
            let (s0, s1) = interval(around: sp, cuts: ss)
            var pieces: [SketchEntity] = []
            if s0 > 1e-6 { pieces.append(arc.entity(from: 0, to: s0)) }
            if s1 < 1 - 1e-6 { pieces.append(arc.entity(from: s1, to: 1)) }
            return pieces
        case .circle(let c, let r):
            var angles = unique(hits.map { positiveAngle(atan2($0.y - c.y, $0.x - c.x)) })
            guard angles.count >= 2 else { return [] }
            angles.sort()
            let tap = positiveAngle(atan2(p.y - c.y, p.x - c.x))
            let before = angles.last { $0 <= tap } ?? angles.last!
            let after = angles.first { $0 > tap } ?? angles.first!
            // Übrig bleibt der Bogen von after bis before (gegen den Uhrzeigersinn)
            let span = positiveAngle(before - after)
            guard span > 1e-6 else { return [] }
            func point(_ angle: Double) -> Point2 { c + r * Point2(cos(angle), sin(angle)) }
            return [.arc(start: point(after), mid: point(after + span / 2), end: point(before))]
        case .point:
            return []
        case .ellipse, .spline:
            return hits.isEmpty ? [] : nil
        default:
            return nil
        }
    }

    /// Nächste Schnitte links und rechts von t (ohne die Enden 0 und 1).
    private static func interval(around t: Double, cuts: [Double]) -> (Double, Double) {
        let inner = cuts.filter { $0 > 1e-6 && $0 < 1 - 1e-6 }
        let lower = inner.filter { $0 <= t }.max() ?? 0
        let upper = inner.filter { $0 > t }.min() ?? 1
        return (lower, upper)
    }

    private static func unique(_ values: [Double]) -> [Double] {
        var result: [Double] = []
        for v in values where !result.contains(where: { abs($0 - v) < 1e-7 || abs(abs($0 - v) - 2 * .pi) < 1e-7 }) {
            result.append(v)
        }
        return result
    }

    // MARK: Projizieren

    /// Punktpaare zu zusammenhängenden Linienzügen verketten.
    static func chain(_ segments: [(Point2, Point2)], tolerance: Double = 1e-5) -> [[Point2]] {
        var rest = segments.filter { simd_distance($0.0, $0.1) > tolerance }
        var result: [[Point2]] = []
        while let first = rest.popLast() {
            var line = [first.0, first.1]
            var extended = true
            while extended {
                extended = false
                for (i, s) in rest.enumerated() {
                    if simd_distance(s.0, line.last!) < tolerance {
                        line.append(s.1)
                    } else if simd_distance(s.1, line.last!) < tolerance {
                        line.append(s.0)
                    } else if simd_distance(s.1, line.first!) < tolerance {
                        line.insert(s.0, at: 0)
                    } else if simd_distance(s.0, line.first!) < tolerance {
                        line.insert(s.1, at: 0)
                    } else {
                        continue
                    }
                    rest.remove(at: i)
                    extended = true
                    break
                }
            }
            result.append(line)
        }
        return result
    }

    /// Projizierten Linienzug als passendes Element: Linie, Kreis, Bogen oder Linienzug.
    static func entity(fromProjected input: [Point2]) -> SketchEntity? {
        var points: [Point2] = []
        for p in input where points.last.map({ simd_distance($0, p) > 1e-6 }) ?? true {
            points.append(p)
        }
        guard points.count >= 2 else { return nil }
        let closed = points.count > 3 && simd_distance(points.first!, points.last!) < 1e-5
        if closed { points.removeLast() }
        let tolerance = 1e-3
        if !closed {
            let a = points.first!, b = points.last!
            let length = simd_distance(a, b)
            if length > 1e-9, points.allSatisfy({ abs(cross(simd_normalize(b - a), $0 - a)) < tolerance }) {
                return .line(a, b)
            }
            if points.count >= 3, let circle = circleThrough(a, points[points.count / 2], b),
               points.allSatisfy({ abs(simd_distance($0, circle.center) - circle.radius) < max(tolerance, circle.radius * 0.005) }) {
                return .arc(start: a, mid: points[points.count / 2], end: b)
            }
            return .polyline(points, closed: false)
        }
        if points.count >= 8 {
            let center = points.reduce(.zero, +) / Double(points.count)
            let radius = points.map { simd_distance($0, center) }.reduce(0, +) / Double(points.count)
            if radius > 1e-9, points.allSatisfy({ abs(simd_distance($0, center) - radius) < max(tolerance, radius * 0.005) }) {
                return .circle(center: center, radius: radius)
            }
        }
        return .polyline(points, closed: true)
    }

    private static func cross(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }
}
