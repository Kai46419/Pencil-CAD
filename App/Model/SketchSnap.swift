import Foundation
import simd

// Fang beim Skizzieren, nach dem Vorbild von Shapr3D und Fusion 360:
// Punktfang (Endpunkte, Mittelpunkte, Zentren, Schnittpunkte), Fang auf Kurven,
// Ausrichtung waagerecht/senkrecht zu vorhandenen Punkten, Winkelschritte und Raster.

enum SnapKind: String, CaseIterable, Identifiable, Codable {
    case endpoint = "Endpunkte"
    case midpoint = "Mittelpunkte"
    case center = "Zentren"
    case intersection = "Schnittpunkte"
    case onCurve = "Auf Kurve"
    case alignment = "Waagerecht/Senkrecht"
    case angle = "Winkel 15°"
    case grid = "Raster"
    /// Ecken und Kantenmitten der Körper, auf die Skizzenebene projiziert (Shapr3D „3D-Leitpunkte“)
    case modelPoint = "3D-Leitpunkte"
    /// Körperkanten außerhalb der Skizzenebene, projiziert (Shapr3D „Entfernte Kanten“)
    case distantEdge = "Entfernte Kanten"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .endpoint: "square"
        case .midpoint: "triangle"
        case .center: "circle.circle"
        case .intersection: "xmark"
        case .onCurve: "point.topleft.down.curvedto.point.bottomright.up"
        case .alignment: "arrow.up.and.down.and.arrow.left.and.right"
        case .angle: "angle"
        case .grid: "grid"
        case .modelPoint: "cube"
        case .distantEdge: "cube.transparent"
        }
    }

    var detail: String {
        switch self {
        case .endpoint: "Enden, Ecken und Punkte"
        case .midpoint: "Mitte von Linien und Bögen"
        case .center: "Kreis-, Bogen- und Polygonmitten"
        case .intersection: "Wo sich Kurven kreuzen"
        case .onCurve: "Nächster Punkt auf einer Kurve"
        case .alignment: "Hilfslinien zu vorhandenen Punkten"
        case .angle: "Linien in 15°-Schritten"
        case .grid: "Rasterpunkte"
        case .modelPoint: "Ecken und Kantenmitten der Körper"
        case .distantEdge: "Projizierte Körperkanten"
        }
    }

    /// Einrasthinweis am Stift (Shapr3D „Einrasthinweise“)
    var hint: String {
        switch self {
        case .endpoint: "Endpunkt"
        case .midpoint: "Mittelpunkt"
        case .center: "Zentrum"
        case .intersection: "Schnittpunkt"
        case .onCurve: "Auf Kurve"
        case .alignment: "Ausgerichtet"
        case .angle: "Winkel"
        case .grid: "Raster"
        case .modelPoint: "3D-Punkt"
        case .distantEdge: "Körperkante"
        }
    }
}

/// Richtungssperre beim Zeichnen (SketchUp: Shift bzw. Pfeiltasten, auf dem iPad als Werkzeugmodus).
enum DirectionLock: String, CaseIterable, Identifiable {
    case horizontal = "Waagerecht"
    case vertical = "Senkrecht"
    case parallel = "Parallel"
    case perpendicular = "Rechtwinklig"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .horizontal: "arrow.left.and.right"
        case .vertical: "arrow.up.and.down"
        case .parallel: "equal"
        case .perpendicular: "angle"
        }
    }
}

/// Beim Zeichnen erkannte Beziehung der neuen Linie zu einer vorhandenen.
enum InferredRelation: Equatable {
    case parallel(SketchCurveRef)
    case perpendicular(SketchCurveRef)
    /// Gespiegelter Winkel (70° ↔ 110°): symmetrisch zur Senkrechten bzw. Waagerechten der Skizze –
    /// für ungerichtete Linien ist beides dieselbe Richtung (siehe SketchAngleSnap.swift)
    case mirrored(SketchCurveRef)

    var isPerpendicular: Bool {
        if case .perpendicular = self { return true }
        return false
    }
}

/// Ergebnis des Fangs: gefangener Punkt, Art und Hilfslinien (Punktpaare, lokal).
struct SnapResult {
    var point: Point2
    var kind: SnapKind?
    var guides: [(Point2, Point2)] = []
}

/// Fangpunkte und Kurven der Skizze, einmal je Änderung berechnet.
struct SnapIndex {
    private(set) var endpoints: [Point2] = []
    private(set) var midpoints: [Point2] = []
    private(set) var centers: [Point2] = []
    private(set) var intersections: [Point2] = []
    private(set) var curves: [[Point2]] = []
    /// Projizierte Körpergeometrie (3D-Leitpunkte, entfernte Kanten)
    private(set) var guides = SketchGuides()

    init() {}

    init(entities: [SketchEntity], guides: SketchGuides = SketchGuides()) {
        self.guides = guides
        var crossable: [[Point2]] = []
        for entity in entities {
            if case .point(let p) = entity {
                endpoints.append(p)
                continue
            }
            // Text nur als Kurve (zu viele Knoten für Punktfang und Schnitte)
            if case .text = entity {
                curves += entity.drawing
                continue
            }
            let chainSegments = entity.loops.flatMap { loop -> [SketchSegment] in
                if case .chain(let segments) = loop { return segments }
                return []
            }
            for segment in entity.openSegments + chainSegments {
                endpoints += [segment.start, segment.end]
                switch segment {
                case .line(let a, let b):
                    midpoints.append((a + b) / 2)
                case .arc(let a, let m, let b):
                    let samples = segment.samples
                    midpoints.append(samples[samples.count / 2])
                    if let circle = circleThrough(a, m, b) { centers.append(circle.center) }
                case .bezier, .bspline:
                    break
                }
            }
            switch entity {
            case .rectangle(let corner, let size):
                centers.append(corner + size / 2)
            case .circle(let center, _), .ellipse(let center, _):
                centers.append(center)
            case .regularPolygon(let center, _, _, _):
                centers.append(center)
            case .spline(let points, .fit, _, _):
                // Fit-Punkte liegen auf der Kurve
                endpoints += points
            default:
                break
            }
            curves += entity.drawing
            crossable += entity.drawing
        }
        endpoints = Self.unique(endpoints)
        midpoints = Self.unique(midpoints)
        centers = Self.unique(centers)
        intersections = Self.unique(Self.crossings(crossable))
    }

    /// Alle Knoten mit ihrer Art (für die Anzeige beim Schweben).
    var nodes: [(point: Point2, kind: SnapKind)] {
        endpoints.map { ($0, .endpoint) } + midpoints.map { ($0, .midpoint) }
            + centers.map { ($0, .center) } + intersections.map { ($0, .intersection) }
    }

    /// Fang an p. extra sind Punkte der laufenden Eingabe (zählen als Endpunkte),
    /// anchor ist der Startpunkt einer Linie für Winkelschritte.
    func snap(_ p: Point2, tolerance: Double, kinds: Set<SnapKind>, extra: [Point2] = [],
              anchor: Point2? = nil, gridStep: Double) -> SnapResult {
        // 1. Punktfang: nächster Kandidat, Mittelpunkte etwas nachrangig
        var best: (score: Double, point: Point2, kind: SnapKind)?
        let lists: [(SnapKind, [Point2], Double)] = [
            (.endpoint, endpoints + extra, 1), (.center, centers, 1),
            (.intersection, intersections, 1), (.midpoint, midpoints, 1.2), (.modelPoint, guides.points, 1.1),
        ]
        for (kind, points, weight) in lists where kinds.contains(kind) {
            for q in points {
                let score = simd_distance(p, q) * weight
                if score <= tolerance, score < (best?.score ?? .infinity) {
                    best = (score, q, kind)
                }
            }
        }
        if let best {
            return SnapResult(point: best.point, kind: best.kind)
        }

        // 1b. Auf Kurve – vor Ausrichtung und Winkel, sonst fanden Kreis und Linie viele Stellen einer Linie
        //     nicht. Mit Raster rastet der Punkt im Rastermaß entlang der Linie ein (ab ihrem Anfang).
        if kinds.contains(.onCurve),
           let point = onCurve(p, in: curves, tolerance: tolerance * 0.7, step: kinds.contains(.grid) ? gridStep : 0) {
            return SnapResult(point: point, kind: .onCurve)
        }
        if kinds.contains(.distantEdge),
           let point = onCurve(p, in: guides.curves, tolerance: tolerance * 0.6, step: 0) {
            return SnapResult(point: point, kind: .distantEdge)
        }

        // 2. Winkelschritte und Ausrichtung
        var result = SnapResult(point: p, kind: nil)
        let keyPoints = endpoints + centers + midpoints + extra + (kinds.contains(.modelPoint) ? guides.points : [])
        var direction: Point2?
        if kinds.contains(.angle), let anchor, simd_distance(p, anchor) > tolerance {
            let step = Double.pi / 12
            let angle = (atan2(p.y - anchor.y, p.x - anchor.x) / step).rounded() * step
            let d = Point2(cos(angle), sin(angle))
            // Länge entlang des Winkelstrahls im Rastermaß (Kai: Raster gilt auch für schräge Linien)
            let along = max(simd_dot(p - anchor, d), 0)
            let stepped = kinds.contains(.grid) && gridStep > 0 ? (along / gridStep).rounded() * gridStep : along
            let projected = anchor + d * stepped
            if simd_distance(anchor + d * along, p) <= tolerance {
                direction = d
                result.point = projected
                result.kind = .angle
            }
        }
        var fixedX = false, fixedY = false
        if kinds.contains(.alignment) {
            if let direction, let anchor {
                // Auf dem Winkelstrahl: Schnitt mit Senkrechten/Waagerechten durch Fangpunkte
                var nearest: (distance: Double, point: Point2, source: Point2)?
                for k in keyPoints where simd_distance(k, anchor) > 1e-9 {
                    var hits: [Point2] = []
                    if abs(direction.x) > 1e-6 { hits.append(anchor + direction * ((k.x - anchor.x) / direction.x)) }
                    if abs(direction.y) > 1e-6 { hits.append(anchor + direction * ((k.y - anchor.y) / direction.y)) }
                    for hit in hits where simd_dot(hit - anchor, direction) > 0 {
                        let distance = simd_distance(hit, result.point)
                        if distance <= tolerance, distance < (nearest?.distance ?? .infinity) {
                            nearest = (distance, hit, k)
                        }
                    }
                }
                if let nearest {
                    result.point = nearest.point
                    result.guides.append((nearest.source, nearest.point))
                }
            } else {
                let vertical = keyPoints.filter { abs($0.x - p.x) <= tolerance }
                    .min { abs($0.x - p.x) < abs($1.x - p.x) }
                let horizontal = keyPoints.filter { abs($0.y - p.y) <= tolerance }
                    .min { abs($0.y - p.y) < abs($1.y - p.y) }
                if let vertical {
                    result.point.x = vertical.x
                    fixedX = true
                }
                if let horizontal {
                    result.point.y = horizontal.y
                    fixedY = true
                }
                if let vertical { result.guides.append((vertical, result.point)) }
                if let horizontal { result.guides.append((horizontal, result.point)) }
                if fixedX || fixedY { result.kind = .alignment }
            }
        }
        if let anchor, direction != nil {
            result.guides.append((anchor, result.point))
        }

        // 4. Raster für die noch freien Richtungen
        if kinds.contains(.grid), direction == nil, gridStep > 0 {
            let rounded = (p / gridStep).rounded(.toNearestOrAwayFromZero) * gridStep
            if !fixedX { result.point.x = rounded.x }
            if !fixedY { result.point.y = rounded.y }
            if result.kind == nil { result.kind = .grid }
        }
        return result
    }

    // MARK: Intern

    /// Nächster Punkt auf einer Kurve innerhalb tolerance. step > 0: im Rastermaß entlang der Kurve – bei
    /// Linienzügen ab der Ecke der getroffenen Strecke, bei fein abgetasteten Bögen/Splines ab Kurvenanfang.
    private func onCurve(_ p: Point2, in curves: [[Point2]], tolerance: Double, step: Double) -> Point2? {
        var best: (distance: Double, curve: Int, segment: Int, point: Point2)?
        for (index, curve) in curves.enumerated() where curve.count >= 2 {
            for k in 0..<(curve.count - 1) {
                let a = curve[k], b = curve[k + 1]
                let ab = b - a
                let lengthSquared = simd_length_squared(ab)
                let t = lengthSquared > 1e-18 ? min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1) : 0
                let foot = a + ab * t
                let distance = simd_distance(p, foot)
                if distance <= tolerance, distance < (best?.distance ?? .infinity) {
                    best = (distance, index, k, foot)
                }
            }
        }
        guard let best else { return nil }
        guard step > 0 else { return best.point }
        let curve = curves[best.curve]
        if curve.count <= 8 {
            let a = curve[best.segment], b = curve[best.segment + 1]
            let length = simd_distance(a, b)
            guard length > 1e-9 else { return best.point }
            let along = min(max((simd_distance(a, best.point) / step).rounded() * step, 0), length)
            return a + (b - a) * (along / length)
        }
        var lengths = [0.0]
        for k in 1..<curve.count { lengths.append(lengths[k - 1] + simd_distance(curve[k - 1], curve[k])) }
        let total = lengths[lengths.count - 1]
        let travelled = lengths[best.segment] + simd_distance(curve[best.segment], best.point)
        let target = min(max((travelled / step).rounded() * step, 0), total)
        guard let k = lengths.firstIndex(where: { $0 >= target }), k > 0 else { return curve[0] }
        let piece = lengths[k] - lengths[k - 1]
        let f = piece > 1e-12 ? (target - lengths[k - 1]) / piece : 0
        return curve[k - 1] + (curve[k] - curve[k - 1]) * f
    }

    private static func unique(_ points: [Point2]) -> [Point2] {
        var result: [Point2] = []
        for p in points where !result.contains(where: { simd_distance($0, p) < 1e-6 }) {
            result.append(p)
        }
        return result
    }

    /// Schnittpunkte verschiedener Linienzüge (ohne gemeinsame Endpunkte).
    private static func crossings(_ polylines: [[Point2]]) -> [Point2] {
        let polylines = polylines.filter { $0.count >= 2 }
        let total = polylines.reduce(0) { $0 + $1.count }
        guard polylines.count >= 2, total <= 4000 else { return [] }
        let boxes = polylines.map { line -> (min: Point2, max: Point2) in
            line.reduce((line[0], line[0])) { (simd_min($0.0, $1), simd_max($0.1, $1)) }
        }
        var result: [Point2] = []
        for i in polylines.indices {
            for j in polylines.indices where j > i {
                let a = boxes[i], b = boxes[j]
                guard a.min.x <= b.max.x + 1e-9, b.min.x <= a.max.x + 1e-9,
                      a.min.y <= b.max.y + 1e-9, b.min.y <= a.max.y + 1e-9 else { continue }
                for (p1, p2) in zip(polylines[i], polylines[i].dropFirst()) {
                    for (q1, q2) in zip(polylines[j], polylines[j].dropFirst()) {
                        if let x = segmentIntersection(p1, p2, q1, q2) { result.append(x) }
                    }
                }
            }
        }
        return result
    }

    private static func segmentIntersection(_ a: Point2, _ b: Point2, _ c: Point2, _ d: Point2) -> Point2? {
        let r = b - a, s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        let u = ((c.x - a.x) * r.y - (c.y - a.y) * r.x) / denominator
        guard t >= -1e-9, t <= 1 + 1e-9, u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        return a + t * r
    }
}

/// Fangsymbol als Linienzüge (lokal), size = halbe Kantenlänge in mm.
func snapMarker(_ kind: SnapKind, at p: Point2, size s: Double) -> [[Point2]] {
    switch kind {
    case .endpoint:
        return [[p + Point2(-s, -s), p + Point2(s, -s), p + Point2(s, s), p + Point2(-s, s), p + Point2(-s, -s)]]
    case .midpoint:
        return [[p + Point2(-s, -s * 0.8), p + Point2(s, -s * 0.8), p + Point2(0, s * 1.1), p + Point2(-s, -s * 0.8)]]
    case .center:
        let circle = (0...24).map { i -> Point2 in
            let a = Double(i) / 24 * 2 * .pi
            return p + s * Point2(cos(a), sin(a))
        }
        return [circle, [p + Point2(-s * 0.4, 0), p + Point2(s * 0.4, 0)], [p + Point2(0, -s * 0.4), p + Point2(0, s * 0.4)]]
    case .intersection:
        return [[p + Point2(-s, -s), p + Point2(s, s)], [p + Point2(-s, s), p + Point2(s, -s)]]
    case .onCurve:
        return [[p + Point2(0, -s), p + Point2(s, 0), p + Point2(0, s), p + Point2(-s, 0), p + Point2(0, -s)]]
    case .modelPoint:
        return [[p + Point2(0, -s), p + Point2(s, 0), p + Point2(0, s), p + Point2(-s, 0), p + Point2(0, -s)],
                [p + Point2(-s * 0.3, 0), p + Point2(s * 0.3, 0)]]
    case .distantEdge:
        return [[p + Point2(-s, -s * 0.5), p + Point2(s, -s * 0.5)], [p + Point2(-s, s * 0.5), p + Point2(s, s * 0.5)]]
    case .alignment, .angle:
        let k = s * 0.6
        return [[p + Point2(-k, -k), p + Point2(k, k)], [p + Point2(-k, k), p + Point2(k, -k)]]
    case .grid:
        let k = s * 0.6
        return [[p + Point2(-k, 0), p + Point2(k, 0)], [p + Point2(0, -k), p + Point2(0, k)]]
    }
}
