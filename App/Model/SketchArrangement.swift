import Foundation
import simd

// Bereiche wie bei Shapr3D: Alle Kurven der Skizze teilen die Ebene in Teilflächen.
// Überschneiden sich zwei Kreise, sind beide Sicheln und die Schnittlinse je ein eigener Bereich;
// eine Linie quer durch ein Rechteck teilt es in zwei Bereiche.
//
// Ablauf: Kurven an allen Schnittpunkten (und an Enden, die auf anderen Kurven liegen) teilen,
// daraus einen ebenen Graphen bauen, dessen Flächen umlaufen (Fläche links der Laufrichtung) und
// Brücken bzw. Sackgassen abtrennen. Positive Umläufe sind Bereiche, negative Umläufe sind Ränder
// von Zusammenhangskomponenten und werden als Löcher dem kleinsten umgebenden Bereich zugeordnet.

enum SketchArrangement {
    /// Punkte gelten als gleich, wenn sie näher als tolerance beieinander liegen (mm).
    private static let tolerance = 1e-5

    // MARK: Kurven

    private enum Shape {
        case line(Point2, Point2)
        case arc(ArcGeometry)
        case circle(center: Point2, radius: Double)
        /// Linienzug durch Abtastpunkte (Bézier, B-Spline, Ellipse, periodischer Spline)
        case sampled([Point2], closed: Bool)
    }

    private struct Curve {
        var shape: Shape
        /// Unverändert übernommenes Kurvenstück (offene Kurven)
        var segment: SketchSegment?
        /// Unverändert übernommene Kontur (geschlossene Kurven)
        var loop: SketchLoop?
        var lower: Point2
        var upper: Point2
        var cuts: [Double] = []

        init(shape: Shape, segment: SketchSegment? = nil, loop: SketchLoop? = nil) {
            self.shape = shape
            self.segment = segment
            self.loop = loop
            let points: [Point2]
            switch shape {
            case .line(let a, let b): points = [a, b]
            case .arc(let arc): points = (0...16).map { arc.point(Double($0) / 16) }
            case .circle(let c, let r): points = [c - Point2(r, r), c + Point2(r, r)]
            case .sampled(let samples, _): points = samples
            }
            lower = points.reduce(Point2(.infinity, .infinity)) { simd_min($0, $1) }
            upper = points.reduce(Point2(-.infinity, -.infinity)) { simd_max($0, $1) }
        }

        var isClosed: Bool {
            switch shape {
            case .circle: true
            case .sampled(_, let closed): closed
            default: false
            }
        }

        func overlaps(_ other: Curve) -> Bool {
            let t = SketchArrangement.tolerance
            return lower.x <= other.upper.x + t && other.lower.x <= upper.x + t
                && lower.y <= other.upper.y + t && other.lower.y <= upper.y + t
        }

        /// Grundformen zum Schneiden; Index k gehört zu Parameter k…k+1 bei Linienzügen.
        var primitives: [TrimPrimitive] {
            switch shape {
            case .line(let a, let b): return [.segment(a, b)]
            case .arc(let arc): return [.arc(arc)]
            case .circle(let c, let r): return [.circle(center: c, radius: r)]
            case .sampled(let points, let closed):
                let count = closed ? points.count : points.count - 1
                guard count > 0 else { return [] }
                return (0..<count).map { .segment(points[$0], points[($0 + 1) % points.count]) }
            }
        }

        /// Parameter eines Punkts auf Grundform k.
        func parameter(of p: Point2, primitive k: Int) -> Double {
            switch shape {
            case .line(let a, let b):
                let d = b - a
                return min(max(simd_dot(p - a, d) / max(simd_length_squared(d), 1e-18), 0), 1)
            case .arc(let arc):
                if let s = arc.parameter(p) { return s }
                return simd_distance(p, arc.point(0)) < simd_distance(p, arc.point(1)) ? 0 : 1
            case .circle(let c, _):
                return positiveAngle(atan2(p.y - c.y, p.x - c.x))
            case .sampled(let points, _):
                let a = points[k], b = points[(k + 1) % points.count]
                let d = b - a
                let t = min(max(simd_dot(p - a, d) / max(simd_length_squared(d), 1e-18), 0), 1)
                return Double(k) + t
            }
        }

        /// Punkt zum Parameter.
        func point(_ s: Double) -> Point2 {
            switch shape {
            case .line(let a, let b): return a + (b - a) * s
            case .arc(let arc): return arc.point(s)
            case .circle(let c, let r): return c + r * Point2(cos(s), sin(s))
            case .sampled(let points, let closed):
                let n = points.count
                let s = closed ? SketchArrangement.positiveAngleMod(s, Double(n)) : s
                let k = min(Int(s.rounded(.down)), n - 1)
                let t = s - Double(k)
                guard t > 0 else { return points[(k + n) % n] }
                return points[k % n] + (points[(k + 1) % n] - points[k % n]) * t
            }
        }

        /// Nächster Punkt der Kurve: Parameter und Abstand.
        func closest(to p: Point2) -> (parameter: Double, distance: Double) {
            switch shape {
            case .circle(let c, let r):
                return (positiveAngle(atan2(p.y - c.y, p.x - c.x)), abs(simd_distance(p, c) - r))
            case .arc(let arc):
                if let s = arc.parameter(p) { return (s, abs(simd_distance(p, arc.center) - arc.radius)) }
                let d0 = simd_distance(p, arc.point(0)), d1 = simd_distance(p, arc.point(1))
                return d0 < d1 ? (0, d0) : (1, d1)
            default:
                var best = (parameter: 0.0, distance: Double.infinity)
                for (k, primitive) in primitives.enumerated() {
                    guard case .segment(let a, let b) = primitive else { continue }
                    let s = parameter(of: p, primitive: k)
                    let t = s - Double(k)
                    let d = simd_distance(p, a + (b - a) * t)
                    if d < best.distance { best = (s, d) }
                }
                return best
            }
        }

        /// Endpunkte offener Kurven (für T-Stöße auf anderen Kurven).
        var ends: [Point2] {
            switch shape {
            case .line(let a, let b): return [a, b]
            case .arc(let arc): return [arc.point(0), arc.point(1)]
            case .sampled(let points, false): return [points[0], points[points.count - 1]]
            default: return []
            }
        }

        /// Periodenlänge geschlossener Kurven.
        var period: Double {
            switch shape {
            case .circle: 2 * .pi
            case .sampled(let points, true): Double(points.count)
            default: 1
            }
        }
    }

    /// Kurven der Skizze: Ketten werden in ihre Stücke zerlegt, geschlossene Einzelkurven bleiben ganz.
    private static func curves(_ entities: [SketchEntity]) -> [Curve] {
        var segments: [SketchSegment] = []
        var result: [Curve] = []
        for entity in entities {
            for loop in entity.loops {
                switch loop {
                case .circle(let c, let r):
                    guard r > tolerance else { continue }
                    result.append(Curve(shape: .circle(center: c, radius: r), loop: loop))
                case .ellipse, .periodic:
                    let polygon = loop.polygon
                    guard polygon.count >= 3 else { continue }
                    result.append(Curve(shape: .sampled(polygon, closed: true), loop: loop))
                case .chain(let pieces):
                    if pieces.count == 1 {
                        let polygon = loop.polygon
                        guard polygon.count >= 3 else { continue }
                        result.append(Curve(shape: .sampled(polygon, closed: true), loop: loop))
                    } else {
                        segments += pieces
                    }
                }
            }
            segments += entity.openSegments
        }
        for segment in segments {
            guard simd_distance(segment.start, segment.end) > tolerance || segment.samples.count > 2 else { continue }
            switch segment {
            case .line(let a, let b):
                result.append(Curve(shape: .line(a, b), segment: segment))
            case .arc(let a, let m, let b):
                if let arc = ArcGeometry(a, m, b) {
                    result.append(Curve(shape: .arc(arc), segment: segment))
                } else if simd_distance(a, b) > tolerance {
                    result.append(Curve(shape: .line(a, b), segment: .line(a, b)))
                }
            case .bezier, .bspline:
                let samples = segment.samples
                if simd_distance(segment.start, segment.end) <= tolerance {
                    // Geschlossene Kurve aus einem Stück
                    let polygon = Array(samples.dropLast())
                    guard polygon.count >= 3 else { continue }
                    result.append(Curve(shape: .sampled(polygon, closed: true), loop: .chain([segment])))
                } else {
                    result.append(Curve(shape: .sampled(samples, closed: false), segment: segment))
                }
            }
        }
        return result
    }

    // MARK: Schnittpunkte

    private static func addCuts(_ curves: inout [Curve]) {
        for i in curves.indices {
            for j in curves.indices where j > i && curves[i].overlaps(curves[j]) {
                let pi = curves[i].primitives, pj = curves[j].primitives
                for (k, p) in pi.enumerated() {
                    for (l, q) in pj.enumerated() {
                        for x in SketchTrim.intersections(p, q) {
                            curves[i].cuts.append(curves[i].parameter(of: x, primitive: k))
                            curves[j].cuts.append(curves[j].parameter(of: x, primitive: l))
                        }
                    }
                }
            }
        }
        // Enden, die auf einer anderen Kurve liegen (T-Stoß, überlappende Kanten)
        for i in curves.indices {
            for end in curves[i].ends {
                for j in curves.indices where j != i {
                    guard end.x >= curves[j].lower.x - tolerance, end.x <= curves[j].upper.x + tolerance,
                          end.y >= curves[j].lower.y - tolerance, end.y <= curves[j].upper.y + tolerance else { continue }
                    let hit = curves[j].closest(to: end)
                    if hit.distance < tolerance * 10 { curves[j].cuts.append(hit.parameter) }
                }
            }
        }
    }

    // MARK: Graph

    private struct Edge {
        var from: Int
        var to: Int
        var segment: SketchSegment
    }

    private final class Graph {
        var vertices: [Point2] = []
        var edges: [Edge] = []
        /// Ungeteilte geschlossene Kurven
        var isolated: [SketchLoop] = []

        func vertex(_ p: Point2) -> Int {
            if let index = vertices.firstIndex(where: { simd_distance($0, p) < SketchArrangement.tolerance * 10 }) {
                return index
            }
            vertices.append(p)
            return vertices.count - 1
        }

        func add(_ segment: SketchSegment) {
            let from = vertex(segment.start), to = vertex(segment.end)
            guard from != to else { return }
            let fixed = Self.snap(segment, start: vertices[from], end: vertices[to])
            let mean = Self.mean(fixed)
            // Doppelte Kanten (überlappende Linien) nur einmal
            let duplicate = edges.contains { edge in
                ((edge.from == from && edge.to == to) || (edge.from == to && edge.to == from))
                    && simd_distance(Self.mean(edge.segment), mean) < SketchArrangement.tolerance * 100
            }
            if !duplicate { edges.append(Edge(from: from, to: to, segment: fixed)) }
        }

        private static func mean(_ segment: SketchSegment) -> Point2 {
            let samples = segment.samples
            return samples.reduce(Point2.zero, +) / Double(max(samples.count, 1))
        }

        /// Enden exakt auf die gemeinsamen Knoten legen, damit die Konturen im Kernel geschlossen sind.
        private static func snap(_ segment: SketchSegment, start: Point2, end: Point2) -> SketchSegment {
            switch segment {
            case .line: return .line(start, end)
            case .arc(_, let m, _): return .arc(start, m, end)
            case .bezier(var poles):
                poles[0] = start
                poles[poles.count - 1] = end
                return .bezier(poles)
            case .bspline(var poles):
                poles[0] = start
                poles[poles.count - 1] = end
                return .bspline(poles)
            }
        }
    }

    /// Teilt die Kurven an ihren Schnittpunkten in Kanten.
    private static func split(_ curve: Curve, into graph: Graph) {
        let period = curve.period
        var cuts: [Double] = []
        for s in curve.cuts.map({ curve.isClosed ? positiveAngleMod($0, period) : $0 }).sorted() {
            let p = curve.point(s)
            if let last = cuts.last, simd_distance(curve.point(last), p) < tolerance * 10 { continue }
            cuts.append(s)
        }

        if curve.isClosed {
            if let first = cuts.first, cuts.count > 1,
               simd_distance(curve.point(first), curve.point(cuts[cuts.count - 1])) < tolerance * 10 {
                cuts.removeLast()
            }
            guard let first = cuts.first else {
                if let loop = curve.loop { graph.isolated.append(loop) }
                return
            }
            // Ein einzelner Berührpunkt teilt nicht; Gegenpunkt ergänzen, damit keine Schleifenkante entsteht
            if cuts.count == 1 { cuts.append(first + period / 2) }
            for (index, s0) in cuts.enumerated() {
                var s1 = index + 1 < cuts.count ? cuts[index + 1] : cuts[0] + period
                if s1 <= s0 { s1 += period }
                graph.add(piece(curve, from: s0, to: s1))
            }
            return
        }

        let start = curve.point(0)
        let endParameter: Double
        switch curve.shape {
        case .sampled(let points, _): endParameter = Double(points.count - 1)
        default: endParameter = 1
        }
        let end = curve.point(endParameter)
        let inner = cuts.filter {
            let p = curve.point($0)
            return simd_distance(p, start) >= tolerance * 10 && simd_distance(p, end) >= tolerance * 10
        }
        if inner.isEmpty, let segment = curve.segment {
            graph.add(segment)
            return
        }
        let bounds = [0] + inner + [endParameter]
        for k in 0..<(bounds.count - 1) {
            graph.add(piece(curve, from: bounds[k], to: bounds[k + 1]))
        }
    }

    private static func positiveAngleMod(_ value: Double, _ period: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: period)
        return r < 0 ? r + period : r
    }

    /// Kurvenstück zwischen zwei Parametern (bei geschlossenen Kurven darf s1 über die Periode hinausgehen).
    private static func piece(_ curve: Curve, from s0: Double, to s1: Double) -> SketchSegment {
        switch curve.shape {
        case .line:
            return .line(curve.point(s0), curve.point(s1))
        case .arc, .circle:
            return .arc(curve.point(s0), curve.point((s0 + s1) / 2), curve.point(s1))
        case .sampled(let points, let closed):
            let n = points.count
            var sub = [curve.point(closed ? positiveAngleMod(s0, Double(n)) : s0)]
            var k = Int(s0.rounded(.down)) + 1
            while Double(k) < s1 - 1e-9 {
                sub.append(points[closed ? k % n : min(k, n - 1)])
                k += 1
            }
            sub.append(curve.point(closed ? positiveAngleMod(s1, Double(n)) : s1))
            if sub.count == 2 { return .line(sub[0], sub[1]) }
            // Lange Linienzüge ausdünnen, damit der Kernel nicht unnötig viele Bézierstücke bekommt
            let step = max(1, (sub.count - 1) / 24)
            var fit = stride(from: 0, to: sub.count - 1, by: step).map { sub[$0] }
            fit.append(sub[sub.count - 1])
            return .bezier(fitBezierPoles(fit, closed: false))
        }
    }

    // MARK: Flächen

    /// Teilflächen der Skizze als Bereiche; nil, wenn die Skizze keine Kurven hat.
    static func regions(_ entities: [SketchEntity]) -> [SketchRegion]? {
        var all = curves(entities)
        guard !all.isEmpty else { return nil }
        addCuts(&all)
        let graph = Graph()
        for curve in all { split(curve, into: graph) }

        // Halbkanten: 2e läuft von from nach to, 2e+1 zurück
        let edges = graph.edges
        func segment(_ h: Int) -> SketchSegment {
            h % 2 == 0 ? edges[h / 2].segment : edges[h / 2].segment.reversed
        }
        func origin(_ h: Int) -> Int { h % 2 == 0 ? edges[h / 2].from : edges[h / 2].to }
        func angle(_ h: Int) -> Double {
            let samples = segment(h).samples
            let start = samples[0]
            let probe = samples.dropFirst().first { simd_distance($0, start) > 1e-9 } ?? samples[samples.count - 1]
            return atan2(probe.y - start.y, probe.x - start.x)
        }
        var outgoing = [[Int]](repeating: [], count: graph.vertices.count)
        for h in 0..<(edges.count * 2) { outgoing[origin(h)].append(h) }
        let angles = (0..<(edges.count * 2)).map(angle)
        for v in outgoing.indices { outgoing[v].sort { angles[$0] < angles[$1] } }
        var position = [Int](repeating: 0, count: edges.count * 2)
        for list in outgoing { for (i, h) in list.enumerated() { position[h] = i } }

        // Nächste Halbkante: an der Zielecke die im Uhrzeigersinn nächste nach der Gegenkante
        func next(_ h: Int) -> Int {
            let twin = h ^ 1
            let list = outgoing[origin(twin)]
            return list[(position[twin] - 1 + list.count) % list.count]
        }

        var visited = [Bool](repeating: false, count: edges.count * 2)
        var cycles: [[Int]] = []
        for h in 0..<(edges.count * 2) where !visited[h] {
            var cycle: [Int] = []
            var current = h
            repeat {
                visited[current] = true
                cycle.append(current)
                current = next(current)
            } while current != h && cycle.count <= edges.count * 2
            cycles += splitBridges(cycle)
        }

        // Positive Umläufe = Bereiche, negative = Ränder (Löcher), dazu ungeteilte geschlossene Kurven
        struct Face { var loop: SketchLoop; var polygon: [Point2]; var area: Double; var holes: [SketchLoop] = [] }
        var faces: [Face] = []
        var boundaries: [(loop: SketchLoop, probe: Point2)] = []
        for cycle in cycles {
            let loop = SketchLoop.chain(cycle.map(segment))
            let polygon = loop.polygon
            let area = signedArea(polygon)
            if area > 1e-6 {
                faces.append(Face(loop: loop, polygon: polygon, area: area))
            } else if area < -1e-6, let probe = outsideProbe(polygon, counterClockwise: false) {
                boundaries.append((loop, probe))
            }
        }
        for loop in graph.isolated {
            let polygon = loop.polygon
            let area = signedArea(polygon)
            guard abs(area) > 1e-6 else { continue }
            faces.append(Face(loop: loop, polygon: polygon, area: abs(area)))
            if let probe = outsideProbe(polygon, counterClockwise: area > 0) { boundaries.append((loop, probe)) }
        }
        for boundary in boundaries {
            let container = faces.indices
                .filter { polygonContains(faces[$0].polygon, boundary.probe) }
                .min { faces[$0].area < faces[$1].area }
            if let container { faces[container].holes.append(boundary.loop) }
        }
        return faces
            .map { SketchRegion(outer: $0.loop, holes: $0.holes, polygon: $0.polygon, area: $0.area) }
            .sorted { $0.area > $1.area }
    }

    /// Trennt Brücken und Sackgassen ab: Kommt eine Kante in beiden Richtungen vor,
    /// zerfällt der Umlauf in den Teil dazwischen und den Rest.
    private static func splitBridges(_ cycle: [Int]) -> [[Int]] {
        var seen: [Int: Int] = [:]
        for (i, h) in cycle.enumerated() {
            if let j = seen[h ^ 1] {
                let inner = Array(cycle[(j + 1)..<i])
                let outer = Array(cycle[..<j]) + Array(cycle[(i + 1)...])
                return splitBridges(inner) + splitBridges(outer)
            }
            seen[h] = i
        }
        return cycle.isEmpty ? [] : [cycle]
    }

    /// Punkt knapp außerhalb einer Kontur, an der Mitte ihrer längsten Sehne.
    private static func outsideProbe(_ polygon: [Point2], counterClockwise: Bool) -> Point2? {
        guard polygon.count >= 2 else { return nil }
        var best = (index: 0, length: 0.0)
        for i in polygon.indices {
            let length = simd_distance(polygon[i], polygon[(i + 1) % polygon.count])
            if length > best.length { best = (i, length) }
        }
        guard best.length > 1e-9 else { return nil }
        let a = polygon[best.index], b = polygon[(best.index + 1) % polygon.count]
        let direction = (b - a) / best.length
        // Links der Laufrichtung liegt bei Umlauf gegen den Uhrzeigersinn innen
        let left = Point2(-direction.y, direction.x)
        let side = counterClockwise ? -left : left
        return (a + b) / 2 + side * min(best.length * 1e-3, 1e-2)
    }
}
