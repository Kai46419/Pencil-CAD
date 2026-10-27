import Foundation
import simd
import UIKit

// Winkelmaße in der technischen Zeichnung (Kai, Punkt 15): automatisch für schräge Kanten und Fasen der
// Normansichten, dazu von Hand gesetzte Winkelmaße (zwei Kanten antippen). Darstellung nach DIN 406 / ISO 129:
// Maßbogen um den Scheitel, Pfeile an den Schenkeln, Maßzahl in Grad (ganze Grad oder eine Nachkommastelle),
// Hilfslinien bis 2 mm über den Bogen. Alles in Blatt-mm (y nach oben), die Elemente sind gewöhnliche
// Linienzüge, Pfeile und Texte – PDF, Vorschau und DXF enthalten sie damit ohne Sonderfall.

/// Winkelmaß auf dem Blatt: zwei Geraden (je durch eine Kante gegeben) und ein Griffpunkt. Der Griff legt fest,
/// welcher der vier Winkel zwischen den Geraden bemaßt wird (der Sektor, in dem er liegt) und den Bogenradius.
struct DrawingAngle: Equatable, Identifiable {
    var id = UUID()
    var a0: Point2
    var a1: Point2
    var b0: Point2
    var b1: Point2
    var handle: Point2
}

/// Fertig berechnetes Winkelmaß: Blattelemente plus Trefferflächen für Antippen und Verschieben.
struct DrawingAngleShape {
    var elements: [DrawingElement]
    var vertex: Point2
    var radius: Double
    /// Maßbogen als Punktfolge
    var arc: [Point2]
    /// Rechteck der Maßzahl
    var label: (min: Point2, max: Point2)
    var degrees: Double
}

extension TechnicalDrawing {
    /// Schrifthöhe der Winkel-Maßzahlen (wie Längenmaße)
    static let angleTextHeight = 3.5

    /// Maßzahl in Grad: ganze Grad oder eine Nachkommastelle, Komma als Dezimaltrenner.
    static func degreesText(_ value: Double) -> String {
        let tenth = (value * 10).rounded() / 10
        if abs(tenth - tenth.rounded()) < 1e-9 { return "\(Int(tenth.rounded()))°" }
        return String(format: "%.1f°", tenth).replacingOccurrences(of: ".", with: ",")
    }

    /// Ungefähre Breite eines Textes (Ziffern der Systemschrift ≈ 0,8 × Versalhöhe).
    static func textWidth(_ text: String, height: Double) -> Double {
        Double(text.count) * height * 0.8
    }

    private static func cross(_ u: Point2, _ v: Point2) -> Double { u.x * v.y - u.y * v.x }

    /// Winkelmaß berechnen; nil bei parallelen Geraden oder entarteten Kanten.
    static func angleShape(_ angle: DrawingAngle) -> DrawingAngleShape? {
        let la = simd_distance(angle.a0, angle.a1), lb = simd_distance(angle.b0, angle.b1)
        guard la > 1e-9, lb > 1e-9 else { return nil }
        let d1 = (angle.a1 - angle.a0) / la, d2 = (angle.b1 - angle.b0) / lb
        let c = cross(d1, d2)
        // Fast parallel (unter 0,5°): kein sinnvoller Scheitel
        guard abs(c) > sin(0.5 * .pi / 180) else { return nil }
        let vertex = angle.a0 + d1 * (cross(angle.b0 - angle.a0, d2) / c)
        // Griff in den Schenkelrichtungen zerlegen: Vorzeichen wählen den Sektor
        let p = angle.handle - vertex
        let u1 = cross(p, d2) / c >= 0 ? d1 : -d1
        let u2 = cross(d1, p) / c >= 0 ? d2 : -d2
        let r = max(simd_length(p), 4)
        let t1 = atan2(u1.y, u1.x)
        var sweep = atan2(u2.y, u2.x) - t1
        while sweep > .pi { sweep -= 2 * .pi }
        while sweep <= -.pi { sweep += 2 * .pi }
        guard abs(sweep) > 1e-6 else { return nil }
        let degrees = abs(sweep) * 180 / .pi
        var elements: [DrawingElement] = []

        func point(_ t: Double) -> Point2 { vertex + Point2(cos(t), sin(t)) * r }
        func arcPoints(from t: Double, sweep s: Double) -> [Point2] {
            let n = min(120, max(6, Int((abs(s) * r / 0.8).rounded(.up))))
            return (0...n).map { point(t + s * Double($0) / Double(n)) }
        }
        let arc = arcPoints(from: t1, sweep: sweep)
        let sign: Double = sweep > 0 ? 1 : -1
        let t2 = t1 + sweep
        // Tangenten in Laufrichtung des Bogens an Anfang und Ende
        let tangent1 = Point2(-sin(t1), cos(t1)) * sign
        let tangent2 = Point2(-sin(t2), cos(t2)) * sign
        if r * abs(sweep) >= 8 {
            elements.append(.polyline(arc, .dimension))
            elements.append(.arrow(tip: arc[0], direction: -tangent1))
            elements.append(.arrow(tip: arc[arc.count - 1], direction: tangent2))
        } else {
            // Kurzer Bogen: Pfeile von außen, Bogen je 6 mm verlängert
            let extra = 6 / r * sign
            elements.append(.polyline(arcPoints(from: t1 - extra, sweep: sweep + 2 * extra), .dimension))
            elements.append(.arrow(tip: arc[0], direction: tangent1))
            elements.append(.arrow(tip: arc[arc.count - 1], direction: -tangent2))
        }

        // Hilfslinien: Schenkel bis 2 mm über den Bogen verlängern, wo die Kante nicht hinreicht
        func extensionLine(_ s0: Point2, _ s1: Point2, along u: Point2) {
            let e0 = max(simd_dot(s0 - vertex, u), 0), e1 = max(simd_dot(s1 - vertex, u), 0)
            let near = min(e0, e1), far = max(e0, e1)
            if far < r + 1.5 {
                elements.append(.polyline([vertex + u * (far > 1e-9 ? far + 0.8 : 0), vertex + u * (r + 2)], .dimension))
            } else if near > r + 0.5 {
                elements.append(.polyline([vertex + u * (r - 2), vertex + u * (near - 0.8)], .dimension))
            }
        }
        extensionLine(angle.a0, angle.a1, along: u1)
        extensionLine(angle.b0, angle.b1, along: u2)

        // Maßzahl waagerecht außen an der Bogenmitte
        let text = degreesText(degrees)
        let h = angleTextHeight
        let w = textWidth(text, height: h)
        let mid = t1 + sweep / 2
        let ub = Point2(cos(mid), sin(mid))
        let reach = (w / 2) * abs(ub.x) + (h / 2 + 0.6) * abs(ub.y)
        let center = vertex + ub * (r + 1 + reach)
        elements.append(.text(text, at: Point2(center.x, center.y - h / 2), height: h, centered: true))
        let label = (min: Point2(center.x - w / 2, center.y - h / 2 - 0.3), max: Point2(center.x + w / 2, center.y + h / 2 + 0.3))
        return DrawingAngleShape(elements: elements, vertex: vertex, radius: r, arc: arc, label: label, degrees: degrees)
    }

    /// Blatt mit zusätzlichen (von Hand gesetzten) Winkelmaßen, z. B. für den Export.
    static func withAngles(_ layout: DrawingLayout, _ angles: [DrawingAngle]) -> DrawingLayout {
        var result = layout
        for angle in angles {
            if let shape = angleShape(angle) { result.elements += shape.elements }
        }
        return result
    }

    /// Durchsichtiges Bild nur mit den angegebenen Elementen (Ebene über der Vorschau), width in Punkten.
    static func overlayImage(_ elements: [DrawingElement], width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: width * sheetHeight / sheetWidth)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(DrawingLayout(elements: elements), in: context.cgContext, pointsPerMM: Double(width) / sheetWidth)
        }
    }

    /// Winkelmaß aus zwei angetippten Kanten: bemaßt wird der Winkel zwischen den angetippten Kantenstücken,
    /// Bogen etwas innerhalb der Tippstellen. nil bei (fast) parallelen Kanten.
    static func angle(edge first: (Point2, Point2), tap firstTap: Point2,
                      edge second: (Point2, Point2), tap secondTap: Point2) -> DrawingAngle? {
        let la = simd_distance(first.0, first.1), lb = simd_distance(second.0, second.1)
        guard la > 1e-9, lb > 1e-9 else { return nil }
        let d1 = (first.1 - first.0) / la, d2 = (second.1 - second.0) / lb
        let c = cross(d1, d2)
        guard abs(c) > sin(0.5 * .pi / 180) else { return nil }
        let vertex = first.0 + d1 * (cross(second.0 - first.0, d2) / c)
        func ray(_ a: Point2, _ b: Point2, _ d: Point2, _ tap: Point2) -> (direction: Point2, distance: Double) {
            let q = a + d * simd_dot(tap - a, d)
            var v = q - vertex
            if simd_length(v) < 1e-6 {
                // Tippstelle am Scheitel: zum entfernteren Kantenende
                v = (simd_distance(a, vertex) > simd_distance(b, vertex) ? a : b) - vertex
            }
            let length = simd_length(v)
            return (length > 1e-9 ? v / length : d, length)
        }
        let r1 = ray(first.0, first.1, d1, firstTap), r2 = ray(second.0, second.1, d2, secondTap)
        let bisector = r1.direction + r2.direction
        guard simd_length(bisector) > 1e-6 else { return nil }
        let radius = min(max(min(r1.distance, r2.distance) * 0.7, 8), 40)
        return DrawingAngle(a0: first.0, a1: first.1, b0: second.0, b1: second.1,
                            handle: vertex + simd_normalize(bisector) * radius)
    }

    /// Nächste sichtbare Kante (Linienstück) zum Punkt, für das Werkzeug „Winkelmaß“.
    static func nearestEdge(in layout: DrawingLayout, to p: Point2, maxDistance: Double) -> (Point2, Point2)? {
        var best: (Point2, Point2)?
        var bestDistance = maxDistance
        for case .polyline(let points, let pen) in layout.elements where pen == .visible && points.count >= 2 {
            for i in 0..<(points.count - 1) {
                let a = points[i], b = points[i + 1]
                guard simd_distance(a, b) > 0.2 else { continue }
                let d = distance(p, segment: a, b)
                if d < bestDistance {
                    bestDistance = d
                    best = (a, b)
                }
            }
        }
        return best
    }

    /// Prüft, ob die Kante (noch) als sichtbares Linienstück im Blatt vorkommt.
    static func containsEdge(_ layout: DrawingLayout, _ a: Point2, _ b: Point2) -> Bool {
        for case .polyline(let points, let pen) in layout.elements where pen == .visible && points.count >= 2 {
            for i in 0..<(points.count - 1) {
                let p = points[i], q = points[i + 1]
                if (simd_distance(p, a) < 0.01 && simd_distance(q, b) < 0.01)
                    || (simd_distance(p, b) < 0.01 && simd_distance(q, a) < 0.01) { return true }
            }
        }
        return false
    }

    static func distance(_ p: Point2, segment a: Point2, _ b: Point2) -> Double {
        let ab = b - a
        let length2 = simd_length_squared(ab)
        guard length2 > 1e-18 else { return simd_distance(p, a) }
        let t = min(max(simd_dot(p - a, ab) / length2, 0), 1)
        return simd_distance(p, a + ab * t)
    }

    /// Trifft der Punkt ein Winkelmaß (Maßzahl oder Bogen)?
    static func hits(_ shape: DrawingAngleShape, _ p: Point2, tolerance: Double) -> Bool {
        if p.x >= shape.label.min.x - tolerance, p.x <= shape.label.max.x + tolerance,
           p.y >= shape.label.min.y - tolerance, p.y <= shape.label.max.y + tolerance { return true }
        for i in 0..<max(shape.arc.count - 1, 0) where distance(p, segment: shape.arc[i], shape.arc[i + 1]) < tolerance {
            return true
        }
        return false
    }

    // MARK: Automatische Winkelmaße

    private struct Box {
        var min: Point2
        var max: Point2

        func intersects(_ other: Box) -> Bool {
            min.x < other.max.x && max.x > other.min.x && min.y < other.max.y && max.y > other.min.y
        }

        func contains(_ p: Point2) -> Bool { p.x >= min.x && p.x <= max.x && p.y >= min.y && p.y <= max.y }

        /// Grobtest: Hüllrechteck des Stücks überlappt das Rechteck
        func touches(_ a: Point2, _ b: Point2) -> Bool {
            Swift.min(a.x, b.x) <= max.x && Swift.max(a.x, b.x) >= min.x
                && Swift.min(a.y, b.y) <= max.y && Swift.max(a.y, b.y) >= min.y
        }

        func crosses(_ a: Point2, _ b: Point2) -> Bool {
            if contains(a) || contains(b) { return true }
            let corners = [min, Point2(max.x, min.y), max, Point2(min.x, max.y)]
            for i in 0..<4 where TechnicalDrawing.segmentsIntersect(a, b, corners[i], corners[(i + 1) % 4]) { return true }
            return false
        }
    }

    private static func segmentsIntersect(_ p1: Point2, _ p2: Point2, _ q1: Point2, _ q2: Point2) -> Bool {
        let d1 = cross(p2 - p1, q1 - p1), d2 = cross(p2 - p1, q2 - p1)
        let d3 = cross(q2 - q1, p1 - q1), d4 = cross(q2 - q1, p2 - q1)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }

    /// Rechteck eines Textelements (für die Überlappungsprüfung).
    private static func textBox(_ text: String, at: Point2, height: Double, rotation: Double, centered: Bool) -> Box {
        let w = textWidth(text, height: height)
        let x0 = centered ? -w / 2 : 0
        let local = [Point2(x0, -0.3), Point2(x0 + w, -0.3), Point2(x0 + w, height + 0.3), Point2(x0, height + 0.3)]
        let t = rotation * .pi / 180
        let points = local.map { at + Point2($0.x * cos(t) - $0.y * sin(t), $0.x * sin(t) + $0.y * cos(t)) }
        return Box(min: points.reduce(points[0]) { simd_min($0, $1) }, max: points.reduce(points[0]) { simd_max($0, $1) })
    }

    /// Gerades Stück einer Ansicht (zusammengefasste, fluchtende Linienstücke).
    private struct Run {
        var a: Point2
        var b: Point2
        var length: Double { simd_distance(a, b) }
    }

    /// Winkel zwischen zwei Richtungen in Grad (0…180).
    private static func degreesBetween(_ u: Point2, _ v: Point2) -> Double {
        let lu = simd_length(u), lv = simd_length(v)
        guard lu > 1e-12, lv > 1e-12 else { return 0 }
        return acos(min(max(simd_dot(u, v) / (lu * lv), -1), 1)) * 180 / .pi
    }

    /// Abweichung von waagerecht/senkrecht in Grad (0 = achsparallel, 45 = diagonal).
    private static func axisDeviation(_ d: Point2) -> Double {
        let a = atan2(abs(d.y), abs(d.x)) * 180 / .pi
        return min(a, 90 - a)
    }

    /// Winkelmaße für schräge Kanten der Normansichten (Linien in Blatt-mm, je Ansicht mit ihrem Maßstab).
    /// Fasen unter 45° bekommen das Kurzmaß „c × 45°“ (DIN 406-11), andere schräge Kanten ein Winkelmaß zur
    /// anschließenden waagerechten bzw. senkrechten Kante (sonst zur Ansichtsachse). Platzierung außerhalb der
    /// Kontur: Kandidaten werden geprüft, bis Bogen und Maßzahl keine Linie, kein Maß und keinen Text berühren.
    static func automaticAngles(views: [(lines: [[Point2]], scale: Double)], into elements: inout [DrawingElement]) {
        // Hindernisse: alle bisherigen Linien (außer verdeckten) und Texte, dazu das Schriftfeld
        var obstacles: [(Point2, Point2)] = []
        var occupied: [Box] = [Box(min: titleMin - Point2(1, 1), max: titleMax + Point2(1, 1))]
        for element in elements {
            switch element {
            case .polyline(let points, let pen):
                guard pen != .hidden, points.count >= 2 else { continue }
                for i in 0..<(points.count - 1) { obstacles.append((points[i], points[i + 1])) }
            case .text(let string, let at, let height, let rotation, let centered, _):
                occupied.append(textBox(string, at: at, height: height, rotation: rotation, centered: centered))
            case .arrow:
                continue
            }
        }
        let sheet = Box(min: frameMin + Point2(1.5, 1.5), max: frameMax - Point2(1.5, 1.5))

        func free(_ shape: DrawingAngleShape, strict: Bool) -> Bool {
            let label = Box(min: shape.label.min, max: shape.label.max)
            guard sheet.contains(label.min), sheet.contains(label.max) else { return false }
            if occupied.contains(where: { $0.intersects(label) }) { return false }
            let near = Box(min: shape.vertex - Point2(1, 1) * (shape.radius + 30),
                           max: shape.vertex + Point2(1, 1) * (shape.radius + 30))
            let arcStart = max(1, shape.arc.count / 16), arcEnd = shape.arc.count - 1 - arcStart
            for (a, b) in obstacles where near.touches(a, b) {
                if label.crosses(a, b) { return false }
                if strict, arcStart < arcEnd {
                    for i in arcStart..<arcEnd where segmentsIntersect(shape.arc[i], shape.arc[i + 1], a, b) { return false }
                }
            }
            return true
        }

        func accept(_ shape: DrawingAngleShape) {
            elements += shape.elements
            occupied.append(Box(min: shape.label.min, max: shape.label.max))
            for case .polyline(let points, _) in shape.elements where points.count >= 2 {
                for i in 0..<(points.count - 1) { obstacles.append((points[i], points[i + 1])) }
            }
        }

        /// Fasen-Kurzmaß mit Hinweislinie: Pfeil auf der Fase, schräg nach außen, kurze waagerechte Schulter.
        func placeChamfer(run: Run, outward: Point2, text: String) -> Bool {
            let mid = (run.a + run.b) / 2
            let n = simd_normalize(outward)
            let h = angleTextHeight
            let w = textWidth(text, height: h)
            for length in [8.0, 12, 16, 21] {
                let knee = mid + n * length
                let side: Double = n.x >= 0 ? 1 : -1
                let shoulder = knee + Point2(side * 2, 0)
                let at = side > 0 ? Point2(shoulder.x + 0.8, shoulder.y - h / 2)
                                  : Point2(shoulder.x - 0.8 - w, shoulder.y - h / 2)
                let label = Box(min: Point2(at.x, at.y - 0.3), max: Point2(at.x + w, at.y + h + 0.3))
                guard sheet.contains(label.min), sheet.contains(label.max),
                      !occupied.contains(where: { $0.intersects(label) }) else { continue }
                let start = mid + n * 0.8
                let near = Box(min: mid - Point2(1, 1) * (length + w + 10), max: mid + Point2(1, 1) * (length + w + 10))
                var blocked = false
                for (a, b) in obstacles where near.touches(a, b) {
                    if label.crosses(a, b) || segmentsIntersect(start, knee, a, b) || segmentsIntersect(knee, shoulder, a, b) {
                        blocked = true
                        break
                    }
                }
                if blocked { continue }
                let leader: [DrawingElement] = [
                    .polyline([mid, knee, shoulder], .dimension),
                    .arrow(tip: mid, direction: -n),
                    .text(text, at: at, height: h),
                ]
                elements += leader
                occupied.append(label)
                obstacles.append((mid, knee))
                obstacles.append((knee, shoulder))
                return true
            }
            return false
        }

        for view in views {
            // Linienstücke der Ansicht
            var segments: [(Point2, Point2)] = []
            for line in view.lines where line.count >= 2 {
                for i in 0..<(line.count - 1) where simd_distance(line[i], line[i + 1]) > 1e-6 {
                    segments.append((line[i], line[i + 1]))
                }
            }
            // Fluchtende Stücke zu geraden Läufen zusammenfassen; Läufe, die tangential in Nachbarstücke
            // übergehen (Bogen-Sehnen, Knick unter 14°), sind keine Kanten
            var runs: [Run] = []
            for line in view.lines where line.count >= 2 {
                var points: [Point2] = [line[0]]
                for p in line.dropFirst() where simd_distance(p, points[points.count - 1]) > 1e-6 { points.append(p) }
                guard points.count >= 2 else { continue }
                var start = 0
                while start < points.count - 1 {
                    var end = start + 1
                    let direction = points[end] - points[start]
                    while end + 1 < points.count, degreesBetween(direction, points[end + 1] - points[end]) < 0.5 { end += 1 }
                    let before = start > 0 ? degreesBetween(points[start] - points[start - 1], direction) : 180
                    let after = end + 1 < points.count ? degreesBetween(direction, points[end + 1] - points[end]) : 180
                    if before >= 14, after >= 14 { runs.append(Run(a: points[start], b: points[end])) }
                    start = end
                }
            }
            let tolerance = 0.05
            /// Stücke mit einem Endpunkt am Punkt, als Richtung vom Punkt weg
            func neighbours(_ p: Point2) -> [Point2] {
                segments.compactMap { s in
                    if simd_distance(s.0, p) < tolerance { return s.1 - s.0 }
                    if simd_distance(s.1, p) < tolerance { return s.0 - s.1 }
                    return nil
                }
            }

            var placed = 0
            var tried = 0
            var seen: [(direction: Double, degrees: Double)] = []
            for run in runs.sorted(by: { $0.length > $1.length }) {
                guard placed < 10 else { break }
                let direction = run.b - run.a
                guard axisDeviation(direction) > 0.5 else { continue }
                let ends = [(vertex: run.a, other: run.b), (vertex: run.b, other: run.a)]
                // Tangential anschließende Stücke (Bogen) → keine echte Kante
                var tangential = false
                var axisNeighbour: [Point2?] = [nil, nil]
                for (index, end) in ends.enumerated() {
                    let onward = end.vertex - end.other
                    var bestLength = 0.0
                    for v in neighbours(end.vertex) {
                        let turn = degreesBetween(onward, v)
                        let along = degreesBetween(-onward, v)
                        if along < 0.5 { continue }  // das Stück selbst
                        if turn > 0.5, turn < 14 { tangential = true }
                        let length = simd_length(v)
                        if axisDeviation(v) < 0.3, length > 0.3, length > bestLength {
                            bestLength = length
                            // Hilfslinie: Verlängerung der anschließenden Kante über den Scheitel hinaus
                            axisNeighbour[index] = -v / length
                        }
                    }
                }
                guard !tangential else { continue }

                // Fase: beide Enden an achsparallelen, zueinander senkrechten Kanten, 45°
                if let r0 = axisNeighbour[0], let r1 = axisNeighbour[1], abs(simd_dot(r0, r1)) < 1e-3,
                   abs(axisDeviation(direction) - 45) < 0.3 {
                    let leg = abs(direction.x) / view.scale
                    let text = "\(number(leg)) × 45°"
                    if placeChamfer(run: run, outward: r0 + r1, text: text) { placed += 1 }
                    continue
                }
                guard run.length >= 3 else { continue }
                // Aufwand begrenzen (viele schräge Stücke, z. B. Schrift): die längsten zuerst, höchstens 40
                tried += 1
                guard tried <= 40 else { break }

                // Gleicher Winkel an paralleler Kante schon bemaßt → nicht wiederholen
                let lineAngle = (atan2(direction.y, direction.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 180)

                // Kandidaten: an jedem Ende zur anschließenden achsparallelen Kante, sonst zur Ansichtsachse
                var candidates: [(vertex: Point2, reference: Point2, edge: (Point2, Point2)?)] = []
                for (index, end) in ends.enumerated() {
                    if let ref = axisNeighbour[index] {
                        candidates.append((end.vertex, ref, (end.vertex - ref * 1e-3, end.vertex)))
                    }
                }
                for end in ends {
                    let u = simd_normalize(end.other - end.vertex)
                    let horizontal = Point2(u.x >= 0 ? 1 : -1, 0), vertical = Point2(0, u.y >= 0 ? 1 : -1)
                    let first = atan2(abs(u.y), abs(u.x)) <= .pi / 4 ? horizontal : vertical
                    let second = first == horizontal ? vertical : horizontal
                    candidates.append((end.vertex, first, nil))
                    candidates.append((end.vertex, second, nil))
                }
                var chosen: DrawingAngleShape?
                var fallback: DrawingAngleShape?
                search: for candidate in candidates {
                    let u = simd_normalize((candidate.vertex == run.a ? run.b : run.a) - candidate.vertex)
                    let bisector = u + candidate.reference
                    guard simd_length(bisector) > 1e-6 else { continue }
                    let reference = candidate.edge ?? (candidate.vertex, candidate.vertex + candidate.reference * 1e-3)
                    for radius in [8.0, 11, 14, 18, 23] {
                        let angle = DrawingAngle(a0: run.a, a1: run.b, b0: reference.0, b1: reference.1,
                                                 handle: candidate.vertex + simd_normalize(bisector) * radius)
                        guard let shape = angleShape(angle) else { continue search }
                        if free(shape, strict: true) {
                            chosen = shape
                            break search
                        }
                        if fallback == nil, free(shape, strict: false) { fallback = shape }
                    }
                }
                guard let shape = chosen ?? fallback else { continue }
                if seen.contains(where: { abs($0.direction - lineAngle) < 0.2 && abs($0.degrees - shape.degrees) < 0.05 }) {
                    continue
                }
                seen.append((lineAngle, shape.degrees))
                accept(shape)
                placed += 1
            }
        }

    }
}
