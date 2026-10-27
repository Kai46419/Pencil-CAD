import CoreGraphics
import CoreText
import Foundation
import simd

// Geometrie der Skizze im lokalen 2D-System der Skizzenebene (mm).

typealias Point2 = SIMD2<Double>

private func samePoint(_ a: Point2, _ b: Point2) -> Bool {
    simd_distance(a, b) < 1e-6
}

/// Rechte Normale einer Richtung.
func rightNormal(_ t: Point2) -> Point2 {
    let n = Point2(t.y, -t.x)
    let length = simd_length(n)
    return length > 0 ? n / length : .zero
}

/// Kreis durch drei Punkte; nil, wenn sie auf einer Geraden liegen.
func circleThrough(_ a: Point2, _ b: Point2, _ c: Point2) -> (center: Point2, radius: Double)? {
    let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    guard abs(d) > 1e-9 else { return nil }
    let a2 = simd_length_squared(a), b2 = simd_length_squared(b), c2 = simd_length_squared(c)
    let center = Point2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                        (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
    return (center, simd_distance(center, a))
}

// Fit-Splines (fitBezierPoles, fitSplineTangent): siehe SketchSplineInterpolation.swift.

/// Punkt auf einer kubischen Bézierkurve.
private func bezierPoint(_ p0: Point2, _ p1: Point2, _ p2: Point2, _ p3: Point2, _ t: Double) -> Point2 {
    let u = 1 - t
    let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
    return b0 * p0 + b1 * p1 + b2 * p2 + b3 * p3
}

/// Geklemmter B-Spline (Grad min(3, n−1), gleichmäßige innere Knoten), wie im Kernel.
private func clampedBSplineSamples(_ poles: [Point2], perSpan: Int) -> [Point2] {
    let n = poles.count
    guard n >= 2 else { return poles }
    let degree = min(3, n - 1)
    let spans = n - degree
    var knots: [Double] = Array(repeating: 0, count: degree + 1)
    if spans > 1 { knots += (1..<spans).map(Double.init) }
    knots += Array(repeating: Double(spans), count: degree + 1)
    func evaluate(_ t: Double) -> Point2 {
        var k = degree
        while k < n - 1, t >= knots[k + 1] { k += 1 }
        var d = (0...degree).map { poles[$0 + k - degree] }
        if degree > 0 {
            for r in 1...degree {
                for j in stride(from: degree, through: r, by: -1) {
                    let i = j + k - degree
                    let denominator = knots[i + 1 + degree - r] - knots[i]
                    let alpha = denominator == 0 ? 0 : (t - knots[i]) / denominator
                    d[j] = (1 - alpha) * d[j - 1] + alpha * d[j]
                }
            }
        }
        return d[degree]
    }
    let steps = spans * perSpan
    return (0...steps).map { evaluate(Double(spans) * Double($0) / Double(steps)) }
}

/// Geschlossener gleichmäßiger B-Spline (Grad min(3, n−1)), wie der periodische Kernel-Spline.
private func periodicBSplineSamples(_ poles: [Point2], perSpan: Int) -> [Point2] {
    let n = poles.count
    guard n >= 3 else { return poles }
    let degree = min(3, n - 1)
    var result: [Point2] = []
    for j in 0..<n {
        let p = (0...degree).map { poles[(j + $0) % n] }
        for s in 0..<perSpan {
            let t = Double(s) / Double(perSpan)
            let u = 1 - t
            let t2 = t * t, t3 = t2 * t
            if degree == 3 {
                let b0 = u * u * u / 6
                let b1 = (3 * t3 - 6 * t2 + 4) / 6
                let b2 = (-3 * t3 + 3 * t2 + 3 * t + 1) / 6
                let b3 = t3 / 6
                result.append(b0 * p[0] + b1 * p[1] + b2 * p[2] + b3 * p[3])
            } else {
                let b0 = u * u / 2
                let b1 = (-2 * t2 + 2 * t + 1) / 2
                let b2 = t2 / 2
                result.append(b0 * p[0] + b1 * p[1] + b2 * p[2])
            }
        }
    }
    return result
}

// MARK: Segmente und Konturen

/// Gerichtetes Kurvenstück einer Kontur.
enum SketchSegment {
    case line(Point2, Point2)
    /// Start, Punkt auf dem Bogen, Ende
    case arc(Point2, Point2, Point2)
    /// Kette kubischer Bézierkurven, 3k + 1 Pole
    case bezier([Point2])
    /// Offener B-Spline durch Kontrollpunkte (Enden auf dem ersten und letzten Pol)
    case bspline([Point2])

    var start: Point2 {
        switch self {
        case .line(let a, _), .arc(let a, _, _): a
        case .bezier(let poles), .bspline(let poles): poles.first ?? .zero
        }
    }

    var end: Point2 {
        switch self {
        case .line(_, let b), .arc(_, _, let b): b
        case .bezier(let poles), .bspline(let poles): poles.last ?? .zero
        }
    }

    var reversed: SketchSegment {
        switch self {
        case .line(let a, let b): .line(b, a)
        case .arc(let a, let m, let b): .arc(b, m, a)
        case .bezier(let poles): .bezier(poles.reversed())
        case .bspline(let poles): .bspline(poles.reversed())
        }
    }

    /// Punkte entlang der Kurve, inklusive Start und Ende.
    var samples: [Point2] {
        switch self {
        case .line(let a, let b):
            return [a, b]
        case .arc(let a, let m, let b):
            guard let circle = circleThrough(a, m, b) else { return [a, b] }
            let c = circle.center
            let a0 = atan2(a.y - c.y, a.x - c.x)
            var am = atan2(m.y - c.y, m.x - c.x) - a0
            var ab = atan2(b.y - c.y, b.x - c.x) - a0
            am = am.truncatingRemainder(dividingBy: 2 * .pi)
            ab = ab.truncatingRemainder(dividingBy: 2 * .pi)
            if am < 0 { am += 2 * .pi }
            if ab < 0 { ab += 2 * .pi }
            // Läuft der Bogen gegen den Uhrzeigersinn, liegt m zwischen a und b
            let sweep = am <= ab ? ab : ab - 2 * .pi
            let steps = max(8, Int(abs(sweep) / (2 * .pi) * 72))
            return (0...steps).map { i in
                let angle = a0 + sweep * Double(i) / Double(steps)
                return c + circle.radius * Point2(cos(angle), sin(angle))
            }
        case .bezier(let poles):
            guard poles.count >= 4 else { return poles }
            var result = [poles[0]]
            for k in stride(from: 0, to: poles.count - 3, by: 3) {
                for s in 1...16 {
                    result.append(bezierPoint(poles[k], poles[k + 1], poles[k + 2], poles[k + 3], Double(s) / 16))
                }
            }
            return result
        case .bspline(let poles):
            return clampedBSplineSamples(poles, perSpan: 16)
        }
    }

    /// Kodierung für PCKShape.prism(profileWires:), base wird zu jedem Punkt addiert.
    func code(_ world: (Point2) -> [NSNumber]) -> [NSNumber] {
        switch self {
        case .line(let a, let b):
            return [NSNumber(value: 0)] + world(a) + world(b)
        case .arc(let a, let m, let b):
            if circleThrough(a, m, b) == nil { return [NSNumber(value: 0)] + world(a) + world(b) }
            return [NSNumber(value: 1)] + world(a) + world(m) + world(b)
        case .bezier(let poles):
            return [NSNumber(value: 2), NSNumber(value: poles.count)] + poles.flatMap(world)
        case .bspline(let poles):
            return [NSNumber(value: 5), NSNumber(value: poles.count)] + poles.flatMap(world)
        }
    }
}

/// Geschlossene Kontur.
enum SketchLoop {
    case chain([SketchSegment])
    case circle(center: Point2, radius: Double)
    case ellipse(center: Point2, radii: Point2)
    /// Geschlossener Kontrollpunkt-Spline
    case periodic([Point2])

    /// Umriss als Polygon (ohne doppelten Endpunkt).
    var polygon: [Point2] {
        switch self {
        case .chain(let segments):
            var points: [Point2] = []
            for segment in segments {
                points += segment.samples.dropLast()
            }
            return points
        case .circle(let center, let radius):
            return (0..<72).map { i -> Point2 in
                let a = Double(i) / 72 * 2 * .pi
                return center + radius * Point2(cos(a), sin(a))
            }
        case .ellipse(let center, let radii):
            return (0..<72).map {
                let a = Double($0) / 72 * 2 * .pi
                return center + Point2(radii.x * cos(a), radii.y * sin(a))
            }
        case .periodic(let poles):
            return periodicBSplineSamples(poles, perSpan: 12)
        }
    }

    func code(normal: SIMD3<Double>, xAxis: SIMD3<Double>, world: (Point2) -> [NSNumber]) -> [NSNumber] {
        let vector = { (v: SIMD3<Double>) -> [NSNumber] in [NSNumber(value: v.x), NSNumber(value: v.y), NSNumber(value: v.z)] }
        switch self {
        case .chain(let segments):
            return segments.flatMap { $0.code(world) }
        case .circle(let center, let radius):
            return [NSNumber(value: 3)] + world(center) + vector(normal) + [NSNumber(value: radius)]
        case .ellipse(let center, let radii):
            return [NSNumber(value: 4)] + world(center) + vector(normal) + vector(xAxis) + [NSNumber(value: radii.x), NSNumber(value: radii.y)]
        case .periodic(let poles):
            return [NSNumber(value: 6), NSNumber(value: poles.count)] + poles.flatMap(world)
        }
    }
}

/// Polygonfläche mit Vorzeichen (positiv = gegen den Uhrzeigersinn).
func signedArea(_ polygon: [Point2]) -> Double {
    guard polygon.count >= 3 else { return 0 }
    var sum = 0.0
    for i in polygon.indices {
        let a = polygon[i], b = polygon[(i + 1) % polygon.count]
        sum += a.x * b.y - b.x * a.y
    }
    return sum / 2
}

func polygonContains(_ polygon: [Point2], _ p: Point2) -> Bool {
    var inside = false
    var j = polygon.count - 1
    for i in polygon.indices {
        let a = polygon[i], b = polygon[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
            inside.toggle()
        }
        j = i
    }
    return inside
}

/// Abstand eines Punkts zu einem Linienzug.
func polylineDistance(from p: Point2, to points: [Point2], closed: Bool) -> (distance: Double, point: Point2, tangent: Point2) {
    var best = (distance: Double.infinity, point: p, tangent: Point2(1, 0))
    let count = closed ? points.count : points.count - 1
    guard count > 0 else {
        if let first = points.first { return (simd_distance(p, first), first, Point2(1, 0)) }
        return best
    }
    for i in 0..<count {
        let a = points[i], b = points[(i + 1) % points.count]
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        let t = lengthSquared > 0 ? min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1) : 0
        let q = a + t * ab
        let d = simd_distance(p, q)
        if d < best.distance, lengthSquared > 0 {
            best = (d, q, simd_normalize(ab))
        }
    }
    return best
}

/// Bereich zum Extrudieren: Außenkontur mit Löchern.
struct SketchRegion {
    var outer: SketchLoop
    var holes: [SketchLoop]
    var polygon: [Point2]
    var area: Double
}

// MARK: Elemente

enum SplineKind: String, CaseIterable, Identifiable, Codable {
    case fit = "Fit-Punkte"
    case control = "Kontrollpunkte"

    var id: Self { self }
}

enum OffsetKind: String, CaseIterable, Identifiable {
    case loop = "Schleife"
    case single = "Einzeln"

    var id: Self { self }
}

enum TextAlignmentOption: String, CaseIterable, Identifiable, Codable {
    case left = "Links"
    case center = "Mitte"
    case right = "Rechts"

    var id: Self { self }
}

/// Text als Skizzenprofil: Umrisse der Buchstaben aus der Schrift.
struct SketchText: Codable {
    var string: String
    var anchor: Point2
    var height: Double
    var fontName: String
    var alignment: TextAlignmentOption
    /// Drehung um den Ankerpunkt (Bogenmaß, gegen den Uhrzeigersinn); fehlt in älteren Projekten (= 0)
    var rotation: Double
    var loops: [SketchLoop]

    struct Font: Identifiable {
        let name: String
        let title: String
        var id: String { name }
    }

    static let fonts: [Font] = [
        Font(name: "Helvetica-Bold", title: "Helvetica Fett"), Font(name: "Helvetica", title: "Helvetica"),
        Font(name: "AvenirNext-Bold", title: "Avenir Next Fett"), Font(name: "AvenirNext-Regular", title: "Avenir Next"),
        Font(name: "Futura-Bold", title: "Futura Fett"), Font(name: "Georgia-Bold", title: "Georgia Fett"),
        Font(name: "Courier-Bold", title: "Courier Fett"), Font(name: "Menlo-Bold", title: "Menlo Fett"),
    ]

    private enum CodingKeys: String, CodingKey {
        case string, anchor, height, fontName, alignment, rotation
    }

    /// Die Umrisse werden nicht gespeichert, sondern beim Laden aus der Schrift neu erzeugt.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(string: try container.decode(String.self, forKey: .string),
                  anchor: try container.decode(Point2.self, forKey: .anchor),
                  height: try container.decode(Double.self, forKey: .height),
                  fontName: try container.decode(String.self, forKey: .fontName),
                  alignment: try container.decode(TextAlignmentOption.self, forKey: .alignment),
                  rotation: (try? container.decodeIfPresent(Double.self, forKey: .rotation)) ?? 0)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(string, forKey: .string)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(height, forKey: .height)
        try container.encode(fontName, forKey: .fontName)
        try container.encode(alignment, forKey: .alignment)
        // Nur gedrehten Text mit Winkel speichern (sonst bleibt die Datei wie bisher)
        if rotation != 0 { try container.encode(rotation, forKey: .rotation) }
    }

    init(string: String, anchor: Point2, height: Double, fontName: String, alignment: TextAlignmentOption,
         rotation: Double = 0) {
        self.string = string
        self.anchor = anchor
        self.height = height
        self.fontName = fontName
        self.alignment = alignment
        self.rotation = rotation
        loops = Self.outlines(string: string, anchor: anchor, height: height, fontName: fontName, alignment: alignment,
                              rotation: rotation)
    }

    /// Buchstabenumrisse als geschlossene Ketten aus Linien und Bézierkurven.
    /// height = Höhe der Großbuchstaben; anchor liegt auf der Grundlinie, rotation dreht um anchor.
    private static func outlines(string: String, anchor: Point2, height: Double, fontName: String,
                                 alignment: TextAlignmentOption, rotation: Double) -> [SketchLoop] {
        let text = string.replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty, height > 0 else { return [] }
        let font = CTFontCreateWithName(fontName as CFString, 100, nil)
        let capHeight = max(Double(CTFontGetCapHeight(font)), 1)
        let scale = height / capHeight
        let attributed = NSAttributedString(string: text,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        let shift: Double = switch alignment {
        case .left: 0
        case .center: -width / 2
        case .right: -width
        }

        let cosR: Double = cos(rotation), sinR: Double = sin(rotation)
        var loops: [SketchLoop] = []
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? font
            for index in 0..<count {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                let origin = positions[index]
                let map = { (p: CGPoint) -> Point2 in
                    let x: Double = scale * (Double(p.x + origin.x) + shift)
                    let y: Double = scale * Double(p.y + origin.y)
                    return anchor + Point2(cosR * x - sinR * y, sinR * x + cosR * y)
                }
                loops += Self.loops(of: path, map: map)
            }
        }
        return loops
    }

    private static func loops(of path: CGPath, map: @escaping (CGPoint) -> Point2) -> [SketchLoop] {
        var loops: [SketchLoop] = []
        var segments: [SketchSegment] = []
        var start = Point2.zero
        var current = Point2.zero
        func close() {
            if !samePoint(current, start) {
                segments.append(.line(current, start))
            }
            if segments.count >= 2 {
                loops.append(.chain(segments))
            }
            segments = []
            current = start
        }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                if !segments.isEmpty { close() }
                start = map(points[0])
                current = start
            case .addLineToPoint:
                let p = map(points[0])
                if !samePoint(p, current) { segments.append(.line(current, p)) }
                current = p
            case .addQuadCurveToPoint:
                let q = map(points[0]), p = map(points[1])
                segments.append(.bezier([current, current + 2 / 3 * (q - current), p + 2 / 3 * (q - p), p]))
                current = p
            case .addCurveToPoint:
                let c1 = map(points[0]), c2 = map(points[1]), p = map(points[2])
                segments.append(.bezier([current, c1, c2, p]))
                current = p
            case .closeSubpath:
                close()
            @unknown default:
                break
            }
        }
        if !segments.isEmpty { close() }
        return loops
    }
}

/// Ein Element der Skizze.
enum SketchEntity: Codable {
    case line(Point2, Point2)
    case rectangle(corner: Point2, size: Point2)
    case circle(center: Point2, radius: Double)
    case ellipse(center: Point2, radii: Point2)
    case regularPolygon(center: Point2, radius: Double, sides: Int, angle: Double)
    case arc(start: Point2, mid: Point2, end: Point2)
    /// tangents: nur Fit-Splines, je Fit-Punkt optional eine eigene Tangente (Richtung und Stärke, Tangentengriffe)
    case spline(points: [Point2], kind: SplineKind, closed: Bool, tangents: [Point2?]? = nil)
    case polyline([Point2], closed: Bool)
    case point(Point2)
    case text(SketchText)

    static func polygonCorners(center: Point2, radius: Double, sides: Int, angle: Double) -> [Point2] {
        let n = max(sides, 3)
        return (0..<n).map { i in
            let a = angle + Double(i) / Double(n) * 2 * .pi
            return center + radius * Point2(cos(a), sin(a))
        }
    }

    private static func lines(_ points: [Point2], closed: Bool) -> [SketchSegment] {
        guard points.count >= 2 else { return [] }
        var result = zip(points, points.dropFirst()).map { SketchSegment.line($0, $1) }
        if closed, let first = points.first, let last = points.last, !samePoint(first, last) {
            result.append(.line(last, first))
        }
        return result
    }

    /// Geschlossene Konturen, die das Element allein bildet.
    var loops: [SketchLoop] {
        switch self {
        case .rectangle(let c, let s):
            return [.chain(Self.lines([c, c + Point2(s.x, 0), c + s, c + Point2(0, s.y)], closed: true))]
        case .circle(let center, let radius):
            return [.circle(center: center, radius: radius)]
        case .ellipse(let center, let radii):
            return [.ellipse(center: center, radii: radii)]
        case .regularPolygon(let center, let radius, let sides, let angle):
            return [.chain(Self.lines(Self.polygonCorners(center: center, radius: radius, sides: sides, angle: angle),
                                      closed: true))]
        case .spline(let points, let kind, true, let tangents):
            switch kind {
            case .fit: return [.chain([.bezier(fitBezierPoles(points, closed: true, tangents: tangents))])]
            case .control: return [.periodic(points)]
            }
        case .polyline(let points, true):
            return [.chain(Self.lines(points, closed: true))]
        case .text(let text):
            return text.loops
        default:
            return []
        }
    }

    /// Offene Kurvenstücke, die mit anderen zu Konturen verkettet werden können.
    var openSegments: [SketchSegment] {
        switch self {
        case .line(let a, let b):
            return samePoint(a, b) ? [] : [.line(a, b)]
        case .arc(let a, let m, let b):
            return [.arc(a, m, b)]
        case .spline(let points, let kind, false, let tangents):
            guard points.count >= 2 else { return [] }
            return [kind == .fit ? .bezier(fitBezierPoles(points, closed: false, tangents: tangents)) : .bspline(points)]
        case .polyline(let points, false):
            return Self.lines(points, closed: false)
        default:
            return []
        }
    }

    /// Fangpunkte: Enden, Ecken, Mittelpunkte, Punkte.
    var snapPoints: [Point2] {
        switch self {
        case .line(let a, let b): return [a, b]
        case .rectangle(let c, let s): return [c, c + Point2(s.x, 0), c + s, c + Point2(0, s.y), c + s / 2]
        case .circle(let center, _), .ellipse(let center, _): return [center]
        case .regularPolygon(let center, let radius, let sides, let angle):
            return [center] + Self.polygonCorners(center: center, radius: radius, sides: sides, angle: angle)
        case .arc(let a, _, let b): return [a, b]
        case .spline(let points, _, _, _), .polyline(let points, _): return points
        case .point(let p): return [p]
        case .text: return []
        }
    }

    /// Linienzüge für die Darstellung.
    var drawing: [[Point2]] {
        if case .point(let p) = self {
            let s = 0.6
            return [[p - Point2(s, s), p + Point2(s, s)], [p - Point2(s, -s), p + Point2(s, -s)]]
        }
        return loops.map { $0.polygon + [$0.polygon.first ?? .zero] } + openSegments.map(\.samples)
    }
}

// MARK: Speichern

/// Gleiches JSON wie die früher automatisch erzeugte Codable-Umsetzung (Fallname → Werte, unbenannte Werte als
/// „_0“, „_1“), damit vorhandene Projekte lesbar bleiben. Neue Felder (Spline-Tangenten) sind optional.
extension SketchEntity {
    private enum CaseKey: String, CodingKey {
        case line, rectangle, circle, ellipse, regularPolygon, arc, spline, polyline, point, text
    }

    private enum ValueKey: String, CodingKey {
        case _0, _1, corner, size, center, radius, radii, sides, angle, start, mid, end, points, kind, closed, tangents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CaseKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            let context = DecodingError.Context(codingPath: decoder.codingPath,
                                                debugDescription: "Skizzenelement ohne eindeutige Art")
            throw DecodingError.dataCorrupted(context)
        }
        let v = try container.nestedContainer(keyedBy: ValueKey.self, forKey: key)
        switch key {
        case .line:
            let a = try v.decode(Point2.self, forKey: ._0)
            let b = try v.decode(Point2.self, forKey: ._1)
            self = .line(a, b)
        case .rectangle:
            let corner = try v.decode(Point2.self, forKey: .corner)
            let size = try v.decode(Point2.self, forKey: .size)
            self = .rectangle(corner: corner, size: size)
        case .circle:
            let center = try v.decode(Point2.self, forKey: .center)
            let radius = try v.decode(Double.self, forKey: .radius)
            self = .circle(center: center, radius: radius)
        case .ellipse:
            let center = try v.decode(Point2.self, forKey: .center)
            let radii = try v.decode(Point2.self, forKey: .radii)
            self = .ellipse(center: center, radii: radii)
        case .regularPolygon:
            let center = try v.decode(Point2.self, forKey: .center)
            let radius = try v.decode(Double.self, forKey: .radius)
            let sides = try v.decode(Int.self, forKey: .sides)
            let angle = try v.decode(Double.self, forKey: .angle)
            self = .regularPolygon(center: center, radius: radius, sides: sides, angle: angle)
        case .arc:
            let start = try v.decode(Point2.self, forKey: .start)
            let mid = try v.decode(Point2.self, forKey: .mid)
            let end = try v.decode(Point2.self, forKey: .end)
            self = .arc(start: start, mid: mid, end: end)
        case .spline:
            let points = try v.decode([Point2].self, forKey: .points)
            let kind = try v.decode(SplineKind.self, forKey: .kind)
            let closed = try v.decode(Bool.self, forKey: .closed)
            // Fehlt in älteren Projekten
            let tangents: [Point2?]? = try? v.decodeIfPresent([Point2?].self, forKey: .tangents)
            self = .spline(points: points, kind: kind, closed: closed, tangents: tangents)
        case .polyline:
            let points = try v.decode([Point2].self, forKey: ._0)
            let closed = try v.decode(Bool.self, forKey: .closed)
            self = .polyline(points, closed: closed)
        case .point:
            self = .point(try v.decode(Point2.self, forKey: ._0))
        case .text:
            self = .text(try v.decode(SketchText.self, forKey: ._0))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .line(let a, let b):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .line)
            try v.encode(a, forKey: ._0)
            try v.encode(b, forKey: ._1)
        case .rectangle(let corner, let size):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .rectangle)
            try v.encode(corner, forKey: .corner)
            try v.encode(size, forKey: .size)
        case .circle(let center, let radius):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .circle)
            try v.encode(center, forKey: .center)
            try v.encode(radius, forKey: .radius)
        case .ellipse(let center, let radii):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .ellipse)
            try v.encode(center, forKey: .center)
            try v.encode(radii, forKey: .radii)
        case .regularPolygon(let center, let radius, let sides, let angle):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .regularPolygon)
            try v.encode(center, forKey: .center)
            try v.encode(radius, forKey: .radius)
            try v.encode(sides, forKey: .sides)
            try v.encode(angle, forKey: .angle)
        case .arc(let start, let mid, let end):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .arc)
            try v.encode(start, forKey: .start)
            try v.encode(mid, forKey: .mid)
            try v.encode(end, forKey: .end)
        case .spline(let points, let kind, let closed, let tangents):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .spline)
            try v.encode(points, forKey: .points)
            try v.encode(kind, forKey: .kind)
            try v.encode(closed, forKey: .closed)
            // Nur mit eigenen Tangenten speichern (sonst bleibt die Datei wie bisher)
            if let tangents, tangents.contains(where: { $0 != nil }) {
                try v.encode(tangents, forKey: .tangents)
            }
        case .polyline(let points, let closed):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .polyline)
            try v.encode(points, forKey: ._0)
            try v.encode(closed, forKey: .closed)
        case .point(let p):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .point)
            try v.encode(p, forKey: ._0)
        case .text(let text):
            var v = container.nestedContainer(keyedBy: ValueKey.self, forKey: .text)
            try v.encode(text, forKey: ._0)
        }
    }
}

// MARK: Bereiche finden

/// Bereiche der Skizze (Teilflächen aller Kurven) und die geschlossenen Konturen.
func findRegions(in entities: [SketchEntity]) -> (regions: [SketchRegion], loops: [SketchLoop]) {
    var loops = entities.flatMap(\.loops)
    var unused = entities.flatMap(\.openSegments)
    while let first = unused.popLast() {
        var chain = [first]
        while !samePoint(chain[chain.count - 1].end, chain[0].start) {
            let end = chain[chain.count - 1].end
            if let i = unused.firstIndex(where: { samePoint($0.start, end) }) {
                chain.append(unused.remove(at: i))
            } else if let i = unused.firstIndex(where: { samePoint($0.end, end) }) {
                chain.append(unused.remove(at: i).reversed)
            } else {
                break
            }
        }
        // Eine einzelne Linie kann keine Kontur bilden, ein geschlossener Spline schon
        var startsWithLine = false
        if case .line = chain[0] { startsWithLine = true }
        if samePoint(chain[chain.count - 1].end, chain[0].start), chain.count >= 2 || !startsWithLine {
            loops.append(.chain(chain))
        }
    }

    // Teilflächen wie bei Shapr3D (Überschneidungen teilen Bereiche); verschachtelte Konturen nur als Rückfall
    if let arranged = SketchArrangement.regions(entities), !arranged.isEmpty || loops.isEmpty {
        return (arranged, loops)
    }

    let polygons = loops.map(\.polygon)
    let areas = polygons.map { abs(signedArea($0)) }
    // Elternkontur = kleinste Kontur, die einen Punkt der Kontur enthält
    let parents: [Int?] = loops.indices.map { i in
        guard let probe = polygons[i].first else { return nil }
        return loops.indices
            .filter { $0 != i && areas[$0] > areas[i] && polygonContains(polygons[$0], probe) }
            .min { areas[$0] < areas[$1] }
    }
    func depth(_ i: Int) -> Int {
        var d = 0
        var current = parents[i]
        while let parent = current, d < loops.count {
            d += 1
            current = parents[parent]
        }
        return d
    }
    var regions: [SketchRegion] = []
    for i in loops.indices where depth(i) % 2 == 0 && areas[i] > 1e-6 {
        let holes = loops.indices.filter { parents[$0] == i }.map { loops[$0] }
        regions.append(SketchRegion(outer: loops[i], holes: holes, polygon: polygons[i], area: areas[i]))
    }
    return (regions.sorted { $0.area > $1.area }, loops)
}

// MARK: Versatz

/// Versetzt Konturen und Kurvenstücke in der Skizzenebene.
enum SketchOffset {
    /// Ein Kurvenstück um distance zur Seite sign·rechts versetzen.
    static func segment(_ segment: SketchSegment, distance d: Double, sign: Double) -> SketchSegment? {
        switch segment {
        case .line(let a, let b):
            let n = rightNormal(b - a) * sign
            return .line(a + n * d, b + n * d)
        case .arc(let a, let m, let b):
            guard let circle = circleThrough(a, m, b) else { return self.segment(.line(a, b), distance: d, sign: sign) }
            let samples = segment.samples
            let n = rightNormal(samples[1] - samples[0]) * sign
            let outward = simd_dot(simd_normalize(a - circle.center), n) > 0 ? 1.0 : -1.0
            let radius = circle.radius + outward * d
            guard radius > 1e-6 else { return nil }
            let move = { (p: Point2) in circle.center + simd_normalize(p - circle.center) * radius }
            return .arc(move(a), move(m), move(b))
        case .bezier, .bspline:
            let points = offsetPolyline(segment.samples, distance: d, sign: sign, closed: false)
            let step = max(1, points.count / 12)
            var fit = stride(from: 0, to: points.count, by: step).map { points[$0] }
            if let last = points.last, !samePoint(fit[fit.count - 1], last) { fit.append(last) }
            return .bezier(fitBezierPoles(fit, closed: false))
        }
    }

    /// Kontur nach außen (distance > 0) bzw. innen versetzen. Liefert neue Skizzenelemente.
    static func loop(_ loop: SketchLoop, distance d: Double) -> [SketchEntity] {
        let polygon = loop.polygon
        let ccw = signedArea(polygon) > 0
        // rechts der Laufrichtung liegt bei Umlauf gegen den Uhrzeigersinn außen
        let sign: Double = ccw ? 1 : -1
        switch loop {
        case .circle(let center, let radius):
            return radius + d > 1e-6 ? [.circle(center: center, radius: radius + d)] : []
        case .ellipse, .periodic:
            let points = offsetPolyline(polygon, distance: d, sign: sign, closed: true)
            let step = max(1, points.count / 36)
            return [.spline(points: stride(from: 0, to: points.count, by: step).map { points[$0] }, kind: .fit, closed: true)]
        case .chain(let segments):
            if segments.allSatisfy({ if case .line = $0 { return true } else { return false } }) {
                let corners = segments.map(\.start)
                return [.polyline(offsetPolyline(corners, distance: d, sign: sign, closed: true), closed: true)]
            }
            var pieces = segments.compactMap { Self.segment($0, distance: d, sign: sign) }
            guard pieces.count == segments.count else { return [] }
            var result: [SketchEntity] = []
            for i in pieces.indices {
                let next = pieces[(i + 1) % pieces.count]
                if case .line(let a, let b) = pieces[i], case .line(let c, let e) = next,
                   let x = intersect(a, b, c, e) {
                    pieces[i] = .line(a, x)
                    pieces[(i + 1) % pieces.count] = .line(x, e)
                }
            }
            for i in pieces.indices {
                result.append(entity(pieces[i]))
                let next = pieces[(i + 1) % pieces.count]
                if !samePoint(pieces[i].end, next.start) {
                    result.append(.line(pieces[i].end, next.start))
                }
            }
            return result
        }
    }

    static func entity(_ segment: SketchSegment) -> SketchEntity {
        switch segment {
        case .line(let a, let b): .line(a, b)
        case .arc(let a, let m, let b): .arc(start: a, mid: m, end: b)
        case .bezier(let poles):
            // Bézierkette als Fit-Spline durch ihre Knotenpunkte
            .spline(points: stride(from: 0, to: poles.count, by: 3).map { poles[$0] }, kind: .fit, closed: false)
        case .bspline(let poles): .spline(points: poles, kind: .control, closed: false)
        }
    }

    /// Schnittpunkt der Geraden a–b und c–e.
    private static func intersect(_ a: Point2, _ b: Point2, _ c: Point2, _ e: Point2) -> Point2? {
        let r = b - a, s = e - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-9 else { return nil }
        let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
        return a + t * r
    }

    /// Linienzug mit Gehrung versetzen.
    static func offsetPolyline(_ points: [Point2], distance d: Double, sign: Double, closed: Bool) -> [Point2] {
        let n = points.count
        guard n >= 2 else { return points }
        return points.indices.map { i in
            let prev = closed ? points[(i - 1 + n) % n] : points[max(i - 1, 0)]
            let next = closed ? points[(i + 1) % n] : points[min(i + 1, n - 1)]
            let p = points[i]
            let n1 = rightNormal(p - prev) * sign
            let n2 = rightNormal(next - p) * sign
            if i == 0, !closed { return p + n2 * d }
            if i == n - 1, !closed { return p + n1 * d }
            let bisector = n1 + n2
            let length = simd_length(bisector)
            guard length > 1e-9 else { return p + n1 * d }
            let miter = bisector / length
            let scale = 1 / max(simd_dot(miter, n1), 0.2)
            return p + miter * d * scale
        }
    }
}

// MARK: Profile für den Kernel

/// Außenkontur und Löcher eines Bereichs als Kernel-Kodierung, um offset entlang der Normale verschoben.
func profileWires(_ region: SketchRegion, plane: SketchPlane, offset: Double = 0) -> [[NSNumber]] {
    let base = plane.normal * offset
    let world = { (p: Point2) -> [NSNumber] in
        let w = plane.world(p) + base
        return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
    }
    return ([region.outer] + region.holes).map { $0.code(normal: plane.normal, xAxis: plane.u, world: world) }
}

/// Richtung einer Extrusion wie in Fusion 360.
enum ExtrudeDirection: String, CaseIterable, Identifiable {
    case oneSide = "Eine Seite"
    /// Gleich weit nach beiden Seiten (Abstand je Seite)
    case symmetric = "Symmetrisch"
    /// Zweite Seite mit eigenem Abstand
    case twoSides = "Zwei Seiten"

    var id: Self { self }
}

/// Körper aus Bereichen einer Skizze. Beim Abziehen beginnt das Werkzeug minimal außerhalb,
/// damit keine hauchdünnen Restflächen bleiben. taper: Verjüngungswinkel in Grad (Seitenflächen geneigt).
func extrudeRegions(_ chosen: [SketchRegion], plane: SketchPlane, distance: Double, mode: ExtrudeMode,
                    direction: ExtrudeDirection = .oneSide, secondDistance: Double = 0, taper: Double = 0) -> PCKShape? {
    guard !chosen.isEmpty, distance != 0, distance.isFinite else { return nil }
    // Neuer Körper: jeder Bereich einzeln (eigener Körper). Sonst bzw. bei sehr vielen Bereichen angrenzende
    // (z. B. Zähne einer Gewindestange) als ein Profil: keine Vereinigung vieler Prismen
    let regions = SketchRegionMerge.forExtrusion(chosen, mode: mode)
    let sign = plane.extrusionSign(mode: mode)
    let main = sign * distance
    let from: Double
    let length: Double
    switch direction {
    case .oneSide:
        from = mode == .cut ? -sign * 0.01 : 0
        length = main - from
    case .symmetric:
        from = -main
        length = 2 * main
    case .twoSides:
        let second = abs(secondDistance) * (main >= 0 ? -1 : 1)
        from = second
        length = main - second
    }
    guard length != 0 else { return nil }
    let vector = plane.normal * length
    var shapes: [PCKShape] = []
    for region in regions {
        let shape: PCKShape?
        if PCKShape.kernelAvailable {
            if abs(taper) > 1e-9 {
                shape = PCKShape.draftPrism(profileWires: profileWires(region, plane: plane, offset: from),
                                            direction: vector, angle: taper)
            } else {
                shape = holedPrism(region, plane: plane, from: from, length: length)
                    ?? PCKShape.prism(profileWires: profileWires(region, plane: plane, offset: from), direction: vector)
            }
        } else {
            let xyz = region.polygon.flatMap { p -> [NSNumber] in
                let w = plane.world(p) + plane.normal * from
                return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
            }
            shape = PCKShape.prism(pointsXYZ: xyz, direction: vector)
        }
        guard let shape else { return nil }
        shapes.append(shape)
    }
    return PCKShape.compound(shapes)
}

/// Ringe und Bereiche mit Löchern: Außenkontur voll extrudieren und die Löcher als etwas längere
/// Prismen abziehen. Robuster als eine Fläche mit Lochdrähten, deren Umlaufrichtung (Ellipsen,
/// Splines) der Kernel sonst selbst erraten muss. nil ohne Löcher oder wenn der Kernel scheitert.
private func holedPrism(_ region: SketchRegion, plane: SketchPlane, from: Double, length: Double) -> PCKShape? {
    guard !region.holes.isEmpty, length != 0 else { return nil }
    let outer = SketchRegion(outer: region.outer, holes: [], polygon: region.polygon, area: region.area)
    guard var body = PCKShape.prism(profileWires: profileWires(outer, plane: plane, offset: from),
                                    direction: plane.normal * length) else { return nil }
    let overshoot = 0.5 * (length > 0 ? 1.0 : -1.0)
    for hole in region.holes {
        let tool = SketchRegion(outer: hole, holes: [], polygon: hole.polygon, area: abs(signedArea(hole.polygon)))
        guard let prism = PCKShape.prism(profileWires: profileWires(tool, plane: plane, offset: from - overshoot),
                                         direction: plane.normal * (length + 2 * overshoot)),
              let cut = body.cutting(prism) else { return nil }
        body = cut
    }
    return body
}

/// Dreiecke (Weltpunkte, je drei) zum Einfärben eines Bereichs.
func regionTriangles(_ region: SketchRegion, plane: SketchPlane) -> [SIMD3<Float>] {
    if region.holes.isEmpty, PCKShape.kernelAvailable, let face = PCKShape.face(profileWires: profileWires(region, plane: plane)) {
        let mesh = Mesh(face.triangulate(deflection: 0.05), body: -1)
        return mesh.indices.map { mesh.vertices[Int($0)].position }
    }
    // Mit Löchern (Ringe) oder ohne Kernel: Polygon mit Löchern in Ohren zerlegen
    let triangles = triangulate(outer: region.polygon, holes: region.holes.map(\.polygon))
    return triangles.map { SIMD3<Float>(plane.world($0)) }
}

// MARK: Triangulierung

/// Zerlegt ein Polygon mit Löchern in Dreiecke (Ohrenschneiden, Löcher über Brücken eingebunden).
/// Liefert die Eckpunkte, je drei pro Dreieck.
func triangulate(outer: [Point2], holes: [[Point2]]) -> [Point2] {
    var polygon = signedArea(outer) >= 0 ? outer : outer.reversed()
    guard polygon.count >= 3 else { return [] }
    // Löcher im Uhrzeigersinn, von rechts nach links einbinden
    let prepared = holes
        .filter { $0.count >= 3 }
        .map { signedArea($0) <= 0 ? $0 : Array($0.reversed()) }
        .sorted { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
    for hole in prepared {
        polygon = bridge(hole, into: polygon)
    }
    return earClip(polygon)
}

/// Verbindet ein Loch über eine Brücke vom rechtesten Lochpunkt zu einem sichtbaren Randpunkt.
private func bridge(_ hole: [Point2], into polygon: [Point2]) -> [Point2] {
    guard let m = hole.indices.max(by: { hole[$0].x < hole[$1].x }) else { return polygon }
    let p = hole[m]
    // Strahl nach rechts: nächster Schnitt mit dem Rand
    var best: (x: Double, index: Int)?
    for i in polygon.indices {
        let a = polygon[i], b = polygon[(i + 1) % polygon.count]
        guard (a.y > p.y) != (b.y > p.y) || a.y == p.y || b.y == p.y else { continue }
        let x: Double
        if a.y == b.y {
            x = max(a.x, b.x)
        } else {
            let t = (p.y - a.y) / (b.y - a.y)
            guard t >= 0, t <= 1 else { continue }
            x = a.x + t * (b.x - a.x)
        }
        guard x >= p.x, x < (best?.x ?? .infinity) else { continue }
        // Endpunkt mit größerem x ist Kandidat
        best = (x, a.x > b.x ? i : (i + 1) % polygon.count)
    }
    var target: Int
    if let best {
        target = best.index
        // Liegt ein anderer Randpunkt im Dreieck (p, Schnitt, Kandidat), den mit kleinstem Winkel nehmen
        let hit = Point2(best.x, p.y)
        let candidate = polygon[target]
        var bestAngle = Double.infinity
        for (i, q) in polygon.enumerated() where i != target {
            guard q.x >= p.x, pointInTriangle(q, p, hit, candidate) else { continue }
            let angle = abs(atan2(q.y - p.y, q.x - p.x))
            if angle < bestAngle {
                bestAngle = angle
                target = i
            }
        }
    } else {
        target = polygon.indices.min { simd_distance(polygon[$0], p) < simd_distance(polygon[$1], p) } ?? 0
    }
    var result = Array(polygon[...target])
    result += Array(hole[m...]) + Array(hole[..<m])
    result.append(p)
    result.append(polygon[target])
    if target + 1 < polygon.count { result += polygon[(target + 1)...] }
    return result
}

private func pointInTriangle(_ p: Point2, _ a: Point2, _ b: Point2, _ c: Point2) -> Bool {
    let d1 = cross2(b - a, p - a), d2 = cross2(c - b, p - b), d3 = cross2(a - c, p - c)
    let negative = d1 < 0 || d2 < 0 || d3 < 0
    let positive = d1 > 0 || d2 > 0 || d3 > 0
    return !(negative && positive)
}

private func cross2(_ a: Point2, _ b: Point2) -> Double { a.x * b.y - a.y * b.x }

/// Ohrenschneiden für ein einfaches Polygon gegen den Uhrzeigersinn (Brückenkanten erlaubt).
private func earClip(_ input: [Point2]) -> [Point2] {
    var indices = Array(input.indices)
    var result: [Point2] = []
    var guardCount = 0
    while indices.count > 3, guardCount < input.count * input.count {
        guardCount += 1
        var clipped = false
        for k in indices.indices {
            let i0 = indices[(k + indices.count - 1) % indices.count]
            let i1 = indices[k]
            let i2 = indices[(k + 1) % indices.count]
            let a = input[i0], b = input[i1], c = input[i2]
            let turn = cross2(b - a, c - b)
            if abs(turn) < 1e-14, simd_distance(a, c) > 0 {
                // Gerader Punkt: ohne Dreieck entfernen
                indices.remove(at: k)
                clipped = true
                break
            }
            guard turn > 0 else { continue }
            let blocked = indices.contains { j in
                guard j != i0, j != i1, j != i2 else { return false }
                let q = input[j]
                // Doppelte Brückenpunkte zählen nicht als innen
                if q == a || q == b || q == c { return false }
                return pointInTriangle(q, a, b, c)
            }
            guard !blocked else { continue }
            result += [a, b, c]
            indices.remove(at: k)
            clipped = true
            break
        }
        // Kein Ohr gefunden (numerisch entartet): Rest als Fächer
        if !clipped { break }
    }
    if indices.count >= 3 {
        let first = input[indices[0]]
        for k in 1..<(indices.count - 1) {
            result += [first, input[indices[k]], input[indices[k + 1]]]
        }
    }
    return result
}
