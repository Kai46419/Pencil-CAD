import Foundation
import simd
import UIKit

// Abwicklungszeichnung (Punkt 12, Kai): das Flachmuster eines Blechteils als fertigungstaugliche Zeichnung.
// - FlatDrawingPlan: Flachmuster (sheet.flat_pattern) ausgerichtet (Biegelinien achsparallel) und so verschoben,
//   dass die Bezugsecke links unten im Ursprung liegt; Biegelinien mit Lage ab Bezugskante, Bohrungen erkannt.
// - Bemaßung als einfache Linien, Pfeile und Texte (FlatMark): Kettenmaß der Biegelinien und Gesamtmaß oben bzw.
//   rechts, Bezugsmaße (Ordinaten ab 0/0) der Konturecken (Laschen, Freischnitte, Ausschnitte) unten bzw. links,
//   Bohrungen mit Ø, Biegelinien beschriftet, Biegetabelle (Nr., Richtung, Winkel, Innenradius, Lage, Länge, BA, v).
// - DXF R12 (AC1009, wie die übrigen DXF-Schreiber der App) im Maßstab 1:1: Layer KONTUR (exakte Kontur aus
//   sheet.export_dxf), BIEGUNG (Linientyp DASHED in der LTYPE-Tabelle), BEMASSUNG, BIEGETABELLE.
// - Blatt (PDF, A4/A3 quer): Abwicklung mit Bemaßung, Biegetabelle, Ansichten des gekanteten Teils (Vorder-,
//   Seiten-, Draufsicht nach Methode 1 und Isometrie) mit L × B × H, Schriftfeld mit Blechdicke, Material, Zuschnitt.
// Alle Längen in mm; Bemaßungsgrößen (Schrift, Abstände, Pfeile) in Blatt-mm × unit (Modell-mm je Blatt-mm).

/// Linienart eines Zeichnungselements der Abwicklung.
enum FlatMarkLayer {
    case contour, bendUp, bendDown, dimension, table

    var pen: DrawingPen {
        switch self {
        case .contour: .visible
        case .bendUp, .bendDown: .bend
        case .dimension: .dimension
        case .table: .thin
        }
    }

    var dxfLayer: String {
        switch self {
        case .contour: "KONTUR"
        case .bendUp, .bendDown: "BIEGUNG"
        case .dimension: "BEMASSUNG"
        case .table: "BIEGETABELLE"
        }
    }
}

/// Element der Abwicklungszeichnung (Abwicklungs- bzw. Blatt-mm).
enum FlatMark {
    case line([Point2], FlatMarkLayer)
    /// Maßpfeil: Spitze, Richtung, Länge (Breite = Länge / 3)
    case arrow(tip: Point2, direction: Point2, size: Double)
    /// Text, mittig auf center (waagrecht und senkrecht), Schrifthöhe, Drehung in Grad
    case text(String, center: Point2, height: Double, rotation: Double, layer: FlatMarkLayer)
}

/// Biegelinie der Abwicklungszeichnung (ausgerichtete Koordinaten).
struct FlatDrawingBend {
    enum Axis { case vertical, horizontal, oblique }

    /// Nummer (B1, B2 …); eine durch Ausschnitte geteilte Biegung hat mehrere Linien mit derselben Nummer
    var number: Int
    var up: Bool
    /// Biegewinkel (Abweichung von gestreckt, 90° = rechtwinklig)
    var angle: Double
    /// Innenradius
    var radius: Double
    /// Biegezugabe (Länge der neutralen Faser in der Biegezone)
    var allowance: Double
    var length: Double
    var start: Point2
    var end: Point2

    var axis: Axis {
        let d = end - start
        if abs(d.x) <= 1e-6 * max(abs(d.y), 1) { return .vertical }
        if abs(d.y) <= 1e-6 * max(abs(d.x), 1) { return .horizontal }
        return .oblique
    }

    var mid: Point2 { (start + end) / 2 }
}

/// Flachmuster für die Zeichnung: ausgerichtet, Bezugsecke (links unten) im Ursprung.
struct FlatDrawingPlan {
    var outline: [[Point2]] = []
    /// Ausschnitte, die keine Bohrungen sind
    var cutouts: [[Point2]] = []
    /// Kreisrunde Ausschnitte (Bohrungen)
    var holes: [(center: Point2, radius: Double)] = []
    /// Perforationslöcher (nicht einzeln bemaßt)
    var perforation: [(center: Point2, radius: Double)] = []
    var bends: [FlatDrawingBend] = []
    /// Zuschnitt L × B (Hüllrechteck der ausgerichteten Kontur)
    var size = Point2(0, 0)
    var thickness = 0.0
    var kFactor = 0.0
    var rule = ""
    /// Drehung (Bogenmaß) und Verschiebung von Flachmuster-Koordinaten in Zeichnungskoordinaten
    var rotation = 0.0
    var shift = Point2(0, 0)

    /// Zeichnungspunkt aus einem Punkt des Flachmusters
    func drawingPoint(_ p: Point2) -> Point2 {
        let c = cos(rotation), s = sin(rotation)
        return Point2(c * p.x - s * p.y, s * p.x + c * p.y) + shift
    }

    init(_ flat: FlatPattern) {
        thickness = flat.thickness
        kFactor = flat.kFactor
        rule = flat.rule
        // Ausrichtung: Biegelinien (gewichtet mit ihrer Länge) achsparallel; Winkel modulo 90° über 4·α gemittelt.
        // Ohne Biegungen die Kanten der Kontur.
        var sumCos = 0.0, sumSin = 0.0
        func add(_ a: Point2, _ b: Point2) {
            let d = b - a
            let length = simd_length(d)
            guard length > 1e-9 else { return }
            let angle = atan2(d.y, d.x)
            sumCos += length * cos(4 * angle)
            sumSin += length * sin(4 * angle)
        }
        if flat.bends.isEmpty {
            for loop in flat.outline {
                for (a, b) in zip(loop, loop.dropFirst()) { add(a, b) }
            }
        } else {
            for bend in flat.bends { add(bend.start, bend.end) }
        }
        let dominant = hypot(sumCos, sumSin) > 1e-9 ? atan2(sumSin, sumCos) / 4 : 0
        let turnAngle = abs(dominant) < 1e-4 ? 0 : -dominant
        rotation = turnAngle
        let cosA = cos(turnAngle), sinA = sin(turnAngle)
        func turn(_ p: Point2) -> Point2 { Point2(cosA * p.x - sinA * p.y, sinA * p.x + cosA * p.y) }
        // Verschiebung: Hüllrechteck der gedrehten Kontur beginnt bei 0/0
        var offset = Point2(0, 0)
        let turned = flat.outline.flatMap { $0 }.map(turn)
        if let first = turned.first {
            let lo = turned.reduce(first) { simd_min($0, $1) }
            let hi = turned.reduce(first) { simd_max($0, $1) }
            offset = -lo
            size = hi - lo
        } else {
            size = Point2(flat.size.x, flat.size.y)
        }
        shift = offset
        let snap = 1e-7
        func place(_ p: Point2) -> Point2 {
            // Rundungsrauschen der Drehung entfernen (Konturpunkte auf den Kanten des Zuschnitts)
            let q = turn(p) + offset
            return Point2(abs(q.x) < snap ? 0 : q.x, abs(q.y) < snap ? 0 : q.y)
        }
        outline = flat.outline.map { $0.map(place) }
        for loop in flat.cutouts {
            let points = loop.map(place)
            if let circle = Self.circle(points) {
                holes.append(circle)
            } else {
                cutouts.append(points)
            }
        }
        perforation = flat.perforationHoles.map { (center: place($0.center), radius: $0.radius) }
        bends = flat.bends.map { bend -> FlatDrawingBend in
            var start = place(bend.start), end = place(bend.end)
            // Achsparallele Linien exakt achsparallel (Drehung um Bruchteile eines Grads)
            let d = end - start
            if abs(d.x) < 1e-4, abs(d.y) > 1e-3 {
                let x = (start.x + end.x) / 2
                start.x = x
                end.x = x
            } else if abs(d.y) < 1e-4, abs(d.x) > 1e-3 {
                let y = (start.y + end.y) / 2
                start.y = y
                end.y = y
            }
            return FlatDrawingBend(number: bend.index, up: bend.up, angle: bend.angle, radius: bend.radius,
                                   allowance: bend.allowance, length: bend.length, start: start, end: end)
        }
    }

    /// Kreis aus einem fein abgetasteten Ausschnitt (alle Punkte gleich weit von ihrer Mitte); nil sonst.
    static func circle(_ input: [Point2]) -> (center: Point2, radius: Double)? {
        var points = input
        if points.count > 2, let first = points.first, let last = points.last, simd_distance(first, last) < 1e-9 {
            points.removeLast()
        }
        guard points.count >= 8 else { return nil }
        let center = points.reduce(Point2(0, 0), +) / Double(points.count)
        let distances = points.map { simd_distance($0, center) }
        let radius = distances.reduce(0, +) / Double(distances.count)
        guard radius > 1e-6, distances.allSatisfy({ abs($0 - radius) <= max(0.01 * radius, 0.002) }) else { return nil }
        return (center, radius)
    }

    /// Ecken eines Linienzugs (Richtungswechsel über 20°); Abtastpunkte von Bögen fallen weg.
    static func corners(_ input: [Point2]) -> [Point2] {
        var points = input
        if points.count > 2, let first = points.first, let last = points.last, simd_distance(first, last) < 1e-9 {
            points.removeLast()
        }
        let n = points.count
        guard n >= 3 else { return points }
        var result: [Point2] = []
        let limit = cos(20 * Double.pi / 180)
        for i in 0..<n {
            let a = points[i] - points[(i + n - 1) % n], b = points[(i + 1) % n] - points[i]
            let la = simd_length(a), lb = simd_length(b)
            guard la > 1e-9, lb > 1e-9 else { continue }
            if simd_dot(a / la, b / lb) < limit { result.append(points[i]) }
        }
        return result
    }

    // MARK: Biegetabelle

    /// Zeile der Biegetabelle je Biegungsnummer (geteilte Biegungen zusammengefasst)
    struct TableRow {
        var bend: FlatDrawingBend
        var totalLength: Double
    }

    var tableRows: [TableRow] {
        var rows: [TableRow] = []
        for bend in bends {
            if let index = rows.firstIndex(where: { $0.bend.number == bend.number }) {
                rows[index].totalLength += bend.length
            } else {
                rows.append(TableRow(bend: bend, totalLength: bend.length))
            }
        }
        return rows.sorted { $0.bend.number < $1.bend.number }
    }

    /// Lage der Biegelinie ab Bezugskante (linke bzw. untere Kante des Zuschnitts)
    func positionText(_ bend: FlatDrawingBend) -> String {
        let n = TechnicalDrawing.number
        switch bend.axis {
        case .vertical: return "X = \(n(bend.start.x))"
        case .horizontal: return "Y = \(n(bend.start.y))"
        case .oblique: return "schräg, X \(n(bend.start.x)) / Y \(n(bend.start.y))"
        }
    }

    /// Ausgleichswert v nach DIN 6935 aus der Biegezugabe: Zuschnitt = Summe der Außenmaße + Summe v.
    /// nil bei Umschlägen (≥ 179°).
    func compensation(_ bend: FlatDrawingBend) -> Double? {
        let angle = bend.angle
        guard angle > 0, angle < 179 else { return nil }
        let outer = bend.radius + thickness
        if angle <= 90 { return bend.allowance - 2 * outer * tan(angle * .pi / 360) }
        return bend.allowance - 2 * outer
    }
}

// MARK: - Bemaßung

enum FlatDrawing {
    /// Schrifthöhen in Blatt-mm
    static let dimensionText = 3.5
    static let ordinateText = 2.5
    static let labelText = 2.5
    static let tableText = 2.5

    static let mergeTolerance = 0.05

    /// Text links ausgerichtet (Grundlinie links bei at, waagrecht)
    static func leftText(_ string: String, at: Point2, height: Double, layer: FlatMarkLayer = .dimension) -> FlatMark {
        let width = TechnicalDrawing.textWidth(string, height: height)
        return .text(string, center: Point2(at.x + width / 2, at.y + height / 2), height: height, rotation: 0, layer: layer)
    }

    /// Maßlinie mit Pfeilen; bei kurzen Maßen (unter 8 Blatt-mm) stehen die Pfeile außen.
    static func dimensionLine(_ a: Point2, _ b: Point2, unit u: Double, into marks: inout [FlatMark]) {
        let length = simd_distance(a, b)
        guard length > 1e-9 else { return }
        let d = (b - a) / length
        if length >= 8 * u {
            marks.append(.line([a, b], .dimension))
            marks.append(.arrow(tip: a, direction: -d, size: 3 * u))
            marks.append(.arrow(tip: b, direction: d, size: 3 * u))
        } else {
            marks.append(.line([a - d * 6 * u, b + d * 6 * u], .dimension))
            marks.append(.arrow(tip: a, direction: d, size: 3 * u))
            marks.append(.arrow(tip: b, direction: -d, size: 3 * u))
        }
    }

    /// Waagrechte Maßkette über Positionen xs (aufsteigend) auf Höhe rowY; Hilfslinien ab anchor(x).
    /// Maßzahlen über der Maßlinie, zu enge abwechselnd höher; Maßzahl = Abstand / valueScale (Blattmaßstab).
    static func horizontalChain(_ xs: [Double], rowY: Double, anchor: (Double) -> Double, unit u: Double,
                                height: Double = FlatDrawing.dimensionText, valueScale: Double = 1,
                                into marks: inout [FlatMark]) {
        guard xs.count >= 2 else { return }
        let up: Double = 1
        for x in xs {
            let from = anchor(x)
            let sign: Double = rowY >= from ? 1 : -1
            marks.append(.line([Point2(x, from + sign * 1.5 * u), Point2(x, rowY + sign * 2 * u)], .dimension))
        }
        var raised = false
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            dimensionLine(Point2(x0, rowY), Point2(x1, rowY), unit: u, into: &marks)
            let text = TechnicalDrawing.number((x1 - x0) / valueScale)
            let width = TechnicalDrawing.textWidth(text, height: height * u)
            let fits = x1 - x0 >= width + 2 * u
            raised = fits ? false : !raised
            let lift = raised ? (height + 1.2) * u : 0
            marks.append(.text(text, center: Point2((x0 + x1) / 2, rowY + up * (1 * u + height * u / 2 + lift)),
                               height: height * u, rotation: 0, layer: .dimension))
        }
    }

    /// Senkrechte Maßkette über Positionen ys (aufsteigend) bei x = rowX; Maßzahlen um 90° gedreht links der Linie.
    static func verticalChain(_ ys: [Double], rowX: Double, anchor: (Double) -> Double, unit u: Double,
                              height: Double = FlatDrawing.dimensionText, valueScale: Double = 1,
                              into marks: inout [FlatMark]) {
        guard ys.count >= 2 else { return }
        for y in ys {
            let from = anchor(y)
            let sign: Double = rowX >= from ? 1 : -1
            marks.append(.line([Point2(from + sign * 1.5 * u, y), Point2(rowX + sign * 2 * u, y)], .dimension))
        }
        var raised = false
        for (y0, y1) in zip(ys, ys.dropFirst()) {
            dimensionLine(Point2(rowX, y0), Point2(rowX, y1), unit: u, into: &marks)
            let text = TechnicalDrawing.number((y1 - y0) / valueScale)
            let width = TechnicalDrawing.textWidth(text, height: height * u)
            let fits = y1 - y0 >= width + 2 * u
            raised = fits ? false : !raised
            let lift = raised ? (height + 1.2) * u : 0
            marks.append(.text(text, center: Point2(rowX - 1 * u - height * u / 2 - lift, (y0 + y1) / 2),
                               height: height * u, rotation: 90, layer: .dimension))
        }
    }

    /// Beschriftungen entlang einer Achse auseinanderziehen: Abstand mindestens gap, Mittel bleibt (Gruppen).
    static func spread(_ values: [Double], gap: Double) -> [Double] {
        var clusters: [(lo: Int, hi: Int, start: Double)] = []
        for (i, value) in values.enumerated() {
            clusters.append((i, i, value))
            while clusters.count >= 2 {
                let b = clusters[clusters.count - 1], a = clusters[clusters.count - 2]
                let aEnd = a.start + Double(a.hi - a.lo) * gap
                if aEnd + gap <= b.start + 1e-12 { break }
                let lo = a.lo, hi = b.hi
                let mean = values[lo...hi].reduce(0, +) / Double(hi - lo + 1)
                clusters.removeLast(2)
                clusters.append((lo, hi, mean - Double(hi - lo) * gap / 2))
            }
        }
        var result: [Double] = []
        for cluster in clusters {
            for k in 0...(cluster.hi - cluster.lo) { result.append(cluster.start + Double(k) * gap) }
        }
        return result
    }

    /// Gleiche Werte (innerhalb mergeTolerance) zusammenfassen; je Wert der Bezugspunkt mit kleinstem key.
    static func merged(_ items: [(value: Double, point: Point2)], key: (Point2) -> Double)
        -> [(value: Double, point: Point2)] {
        let sorted = items.sorted { $0.value < $1.value }
        var result: [(value: Double, point: Point2)] = []
        for item in sorted {
            if let last = result.last, item.value - last.value <= mergeTolerance {
                if key(item.point) < key(last.point) { result[result.count - 1].point = item.point }
                continue
            }
            result.append(item)
        }
        return result
    }

    /// Bemaßung, Beschriftung der Biegelinien und Bohrungen (ohne Kontur und Biegelinien), Abwicklungs-mm.
    static func annotations(_ plan: FlatDrawingPlan, unit u: Double) -> [FlatMark] {
        var marks: [FlatMark] = []
        let length = plan.size.x, width = plan.size.y
        guard length > 1e-6, width > 1e-6 else { return marks }
        let tol = mergeTolerance
        let outlinePoints = plan.outline.flatMap { $0 }

        // Biegelinien: senkrechte (Lage in x) und waagrechte (Lage in y)
        let vertical = plan.bends.filter { $0.axis == .vertical }
        let horizontal = plan.bends.filter { $0.axis == .horizontal }

        func chainValues(_ positions: [Double], total: Double) -> [Double] {
            var values: [Double] = [0]
            for p in positions.sorted() where p > tol && p < total - tol {
                if let last = values.last, p - last <= tol { continue }
                values.append(p)
            }
            values.append(total)
            return values
        }

        // Oben: Kettenmaß der senkrechten Biegelinien (Laschenmaße), darüber Gesamtlänge
        var topRow = width + 8 * u
        func topAnchor(_ x: Double) -> Double {
            let bendEnds = vertical.filter { abs($0.start.x - x) <= tol }.map { max($0.start.y, $0.end.y) }
            let edge = outlinePoints.filter { abs($0.x - x) <= tol }.map(\.y)
            return (bendEnds + edge).max() ?? width
        }
        if !vertical.isEmpty {
            horizontalChain(chainValues(vertical.map(\.start.x), total: length), rowY: topRow, anchor: topAnchor,
                            unit: u, into: &marks)
            topRow += 9 * u
        }
        horizontalChain([0, length], rowY: topRow, anchor: topAnchor, unit: u, into: &marks)

        // Rechts: Kettenmaß der waagrechten Biegelinien, daneben Gesamtbreite
        var rightRow = length + 8 * u
        func rightAnchor(_ y: Double) -> Double {
            let bendEnds = horizontal.filter { abs($0.start.y - y) <= tol }.map { max($0.start.x, $0.end.x) }
            let edge = outlinePoints.filter { abs($0.y - y) <= tol }.map(\.x)
            return (bendEnds + edge).max() ?? length
        }
        if !horizontal.isEmpty {
            verticalChain(chainValues(horizontal.map(\.start.y), total: width), rowX: rightRow, anchor: rightAnchor,
                          unit: u, into: &marks)
            rightRow += 9 * u
        }
        verticalChain([0, width], rowX: rightRow, anchor: rightAnchor, unit: u, into: &marks)

        // Bezugsmaße ab 0/0: Ecken der Kontur (Laschen, Freischnitte), Ecken der Ausschnitte, Bohrungsmitten
        var features: [Point2] = plan.outline.flatMap { FlatDrawingPlan.corners($0) }
        if plan.cutouts.count <= 12 {
            for cutout in plan.cutouts { features += FlatDrawingPlan.corners(cutout) }
        }
        if plan.holes.count <= 40 { features += plan.holes.map { $0.center } }
        let xs = merged(features.map { (value: $0.x, point: $0) }, key: { $0.y })
        let ys = merged(features.map { (value: $0.y, point: $0) }, key: { $0.x })
        let h = ordinateText * u
        // Nur wenn die Kontur mehr als das Rechteck des Zuschnitts hat
        if xs.count > 2 || !plan.holes.isEmpty || !plan.cutouts.isEmpty {
            let labels = spread(xs.map { $0.value }, gap: h * 1.5)
            for (item, q) in zip(xs, labels) {
                let text = TechnicalDrawing.number(item.value)
                let w = TechnicalDrawing.textWidth(text, height: h)
                marks.append(.line([Point2(item.value, item.point.y - 1.5 * u), Point2(item.value, -3 * u),
                                    Point2(q, -6 * u), Point2(q, -7 * u)], .dimension))
                marks.append(.text(text, center: Point2(q, -8 * u - w / 2), height: h, rotation: 90, layer: .dimension))
            }
        }
        if ys.count > 2 || !plan.holes.isEmpty || !plan.cutouts.isEmpty {
            let labels = spread(ys.map { $0.value }, gap: h * 1.5)
            for (item, q) in zip(ys, labels) {
                let text = TechnicalDrawing.number(item.value)
                let w = TechnicalDrawing.textWidth(text, height: h)
                marks.append(.line([Point2(item.point.x - 1.5 * u, item.value), Point2(-3 * u, item.value),
                                    Point2(-6 * u, q), Point2(-7 * u, q)], .dimension))
                marks.append(.text(text, center: Point2(-8 * u - w / 2, q), height: h, rotation: 0, layer: .dimension))
            }
        }

        // Bohrungen: Mittellinienkreuz, je Durchmesser ein Hinweis „n× Ø d“
        for hole in plan.holes {
            let r = hole.radius + 1.5 * u
            marks.append(.line([hole.center - Point2(r, 0), hole.center + Point2(r, 0)], .dimension))
            marks.append(.line([hole.center - Point2(0, r), hole.center + Point2(0, r)], .dimension))
        }
        var diameters: [(diameter: Double, hole: (center: Point2, radius: Double), count: Int)] = []
        for hole in plan.holes {
            let d = 2 * hole.radius
            if let index = diameters.firstIndex(where: { abs($0.diameter - d) < 0.01 }) {
                diameters[index].count += 1
            } else {
                diameters.append((d, hole, 1))
            }
        }
        for entry in diameters {
            let dir = simd_normalize(Point2(1, 1))
            let edge = entry.hole.center + dir * entry.hole.radius
            let knee = entry.hole.center + dir * (entry.hole.radius + 5 * u)
            let text = (entry.count > 1 ? "\(entry.count)× " : "") + "Ø" + TechnicalDrawing.number(entry.diameter)
            let tw = TechnicalDrawing.textWidth(text, height: labelText * u)
            marks.append(.line([edge, knee, knee + Point2(tw + 1 * u, 0)], .dimension))
            marks.append(.arrow(tip: edge, direction: -dir, size: 2.5 * u))
            marks.append(.text(text, center: knee + Point2(0.5 * u + tw / 2, 0.8 * u + labelText * u / 2),
                               height: labelText * u, rotation: 0, layer: .dimension))
        }

        // Biegelinien beschriften (je Nummer einmal, an der längsten Linie)
        var labelled: Set<Int> = []
        for bend in plan.bends.sorted(by: { $0.length > $1.length }) {
            guard labelled.insert(bend.number).inserted else { continue }
            let d = bend.end - bend.start
            let lineLength = simd_length(d)
            guard lineLength > 1e-9 else { continue }
            var dir = d / lineLength
            // lesbar: Text läuft nach rechts bzw. von unten nach oben
            if dir.x < -1e-9 || (abs(dir.x) <= 1e-9 && dir.y < 0) { dir = -dir }
            let normal = Point2(-dir.y, dir.x)
            let text = "B\(bend.number) \(bend.up ? "oben" : "unten") \(TechnicalDrawing.degreesText(bend.angle)) "
                + "Ri \(TechnicalDrawing.number(bend.radius))"
            let center = bend.mid + normal * (1.2 * u + labelText * u / 2)
            marks.append(.text(text, center: center, height: labelText * u, rotation: atan2(dir.y, dir.x) * 180 / .pi,
                               layer: bend.up ? .bendUp : .bendDown))
        }
        return marks
    }

    /// Kontur, Ausschnitte, Perforation und Biegelinien als Linienzüge (für das Blatt; das DXF nimmt die exakte Kontur).
    static func geometry(_ plan: FlatDrawingPlan) -> [FlatMark] {
        var marks: [FlatMark] = []
        func closed(_ loop: [Point2]) -> [Point2] {
            guard let first = loop.first, let last = loop.last, simd_distance(first, last) > 1e-9 else { return loop }
            return loop + [first]
        }
        for loop in plan.outline { marks.append(.line(closed(loop), .contour)) }
        for loop in plan.cutouts { marks.append(.line(closed(loop), .contour)) }
        for hole in plan.holes + plan.perforation { marks.append(.line(circlePoints(hole.center, hole.radius), .contour)) }
        for bend in plan.bends { marks.append(.line([bend.start, bend.end], bend.up ? .bendUp : .bendDown)) }
        return marks
    }

    static func circlePoints(_ center: Point2, _ radius: Double, segments: Int = 48) -> [Point2] {
        (0...segments).map { k in
            let t = Double(k) / Double(segments) * 2 * .pi
            return center + Point2(cos(t), sin(t)) * radius
        }
    }

    /// Biegetabelle ab top (linke obere Ecke), Größen in Blatt-mm × unit. maxRows begrenzt die Zeilen.
    static func bendTable(_ plan: FlatDrawingPlan, topLeft: Point2, unit u: Double, maxRows: Int = .max) -> [FlatMark] {
        var marks: [FlatMark] = []
        let rows = plan.tableRows
        let h = tableText * u
        let n = TechnicalDrawing.number
        let header = ["Nr.", "Richtung", "Winkel", "Innenradius", "Lage ab Kante", "Länge", "BA", "v"]
        let widths = [9.0, 15, 13, 20, 30, 15, 13, 13].map { $0 * u }
        let rowHeight = 5 * u
        let totalWidth = widths.reduce(0, +)
        let ruleText = plan.rule.isEmpty ? "" : "  ·  Regel „\(plan.rule)“"
        marks.append(leftText("Biegetabelle  ·  t = \(n(plan.thickness)) mm  ·  K-Faktor \(n(plan.kFactor))\(ruleText)",
                              at: Point2(topLeft.x, topLeft.y - 4 * u), height: 2.8 * u, layer: .table))
        var y = topLeft.y - 6 * u
        let shown = Array(rows.prefix(maxRows))
        let lines = [header] + shown.map { row -> [String] in
            let bend = row.bend
            return ["B\(bend.number)", bend.up ? "oben" : "unten", TechnicalDrawing.degreesText(bend.angle),
                    n(bend.radius), plan.positionText(bend), n(row.totalLength), n(bend.allowance),
                    plan.compensation(bend).map(n) ?? "–"]
        }
        // Rahmen und Spalten
        let tableTop = y
        for _ in lines {
            marks.append(.line([Point2(topLeft.x, y), Point2(topLeft.x + totalWidth, y)], .table))
            y -= rowHeight
        }
        marks.append(.line([Point2(topLeft.x, y), Point2(topLeft.x + totalWidth, y)], .table))
        var x = topLeft.x
        for w in widths {
            marks.append(.line([Point2(x, tableTop), Point2(x, y)], .table))
            x += w
        }
        marks.append(.line([Point2(x, tableTop), Point2(x, y)], .table))
        // Zellen
        var rowY = tableTop
        for line in lines {
            var cellX = topLeft.x
            for (text, w) in zip(line, widths) {
                marks.append(.text(text, center: Point2(cellX + w / 2, rowY - rowHeight / 2), height: h, rotation: 0,
                                   layer: .table))
                cellX += w
            }
            rowY -= rowHeight
        }
        if rows.count > shown.count {
            marks.append(leftText("… \(rows.count - shown.count) weitere Biegungen (siehe DXF bzw. Biegetabelle CSV)",
                                  at: Point2(topLeft.x, y - 4 * u), height: 2 * u, layer: .table))
            y -= 4 * u
        }
        let notes = [
            "oben = Biegung zum Betrachter (Abwicklung von oben gesehen)",
            "Lage = Biegelinie (Mitte der Biegezone) ab Bezugskante links (X) bzw. unten (Y)",
            "BA = Biegezugabe, v = Ausgleichswert DIN 6935 (Zuschnitt = Summe Außenmaße + Summe v)",
        ]
        for note in notes {
            y -= 3.5 * u
            marks.append(leftText(note, at: Point2(topLeft.x, y), height: 1.8 * u, layer: .table))
        }
        return marks
    }

    /// Höhe der Biegetabelle in Blatt-mm (unit 1).
    static func bendTableHeight(rows: Int, truncated: Bool) -> Double {
        6 + Double(rows + 1) * 5 + (truncated ? 4 : 0) + 3 * 3.5 + 1
    }

    /// Hüllrechteck von Elementen (Texte über ihre geschätzte Breite).
    static func bounds(_ marks: [FlatMark]) -> (min: Point2, max: Point2)? {
        var lo = Point2(Double.infinity, Double.infinity), hi = -lo
        func add(_ p: Point2) {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        for mark in marks {
            switch mark {
            case .line(let points, _):
                points.forEach(add)
            case .arrow(let tip, _, _):
                add(tip)
            case .text(let string, let center, let height, let rotation, _):
                let w = TechnicalDrawing.textWidth(string, height: height)
                let a = rotation * .pi / 180
                let ex = abs(cos(a)) * w / 2 + abs(sin(a)) * height / 2
                let ey = abs(sin(a)) * w / 2 + abs(cos(a)) * height / 2
                add(center - Point2(ex, ey))
                add(center + Point2(ex, ey))
            }
        }
        return lo.x.isFinite ? (lo, hi) : nil
    }

    // MARK: Blatt

    /// Blattelemente aus Abwicklungselementen: p ↦ origin + p · scale.
    static func elements(_ marks: [FlatMark], origin: Point2, scale s: Double) -> [DrawingElement] {
        marks.compactMap { mark -> DrawingElement? in
            switch mark {
            case .line(let points, let layer):
                guard points.count >= 2 else { return nil }
                return .polyline(points.map { origin + $0 * s }, layer.pen)
            case .arrow(let tip, let direction, _):
                return .arrow(tip: origin + tip * s, direction: direction)
            case .text(let string, let center, let height, let rotation, _):
                let h = height * s
                let a = rotation * .pi / 180
                let up = Point2(-sin(a), cos(a))
                return .text(string, at: origin + center * s - up * (h / 2), height: h, rotation: rotation, centered: true)
            }
        }
    }

    // MARK: DXF der Abwicklung

    /// Maßstab der Bemaßung im 1:1-DXF: Schrift und Abstände so groß wie auf einem Blatt im Normmaßstab 1:u.
    static func dxfUnit(_ plan: FlatDrawingPlan) -> Double {
        let size = max(plan.size.x, plan.size.y)
        return [1.0, 2, 5, 10, 20, 50, 100].first { size / $0 <= 250 } ?? 100
    }

    /// Ebene der SolidCraft-Kontur in der Abwicklungszeichnung (nil = weglassen).
    static func contourLayer(_ layer: String) -> String? {
        let name = layer.uppercased()
        if ["OUTLINE", "CUT", "TEXT", "PERFORATION", "0"].contains(name) { return "KONTUR" }
        if name.hasPrefix("BEND") { return nil }
        if name == "ETCH" { return "GRAVUR" }
        if name.hasPrefix("POCKET") { return "TASCHE" }
        return name
    }

    /// Fertigungs-DXF (R12, 1:1, mm). source = DXF von sheet.export_dxf (exakte Kontur, ohne Biegelinien);
    /// leer bzw. unlesbar → Kontur aus dem Flachmuster (Linienzüge).
    static func dxf(_ plan: FlatDrawingPlan, source: Data, title: String, material: String?,
                    bendLines: Bool = true) -> Data {
        let u = dxfUnit(plan)
        // Kontur: exakte Elemente je SolidCraft-Ebene, gedreht und verschoben wie der Plan
        var contour: [(layer: String, entity: SketchEntity)] = []
        if !source.isEmpty, let all = try? VectorFiles.importDXF(source) {
            for layer in all.layers {
                guard let target = contourLayer(layer),
                      let part = try? VectorFiles.importDXF(source, layers: [layer]) else { continue }
                for entity in part.entities {
                    if let moved = entity.mapped({ plan.drawingPoint($0) }, rotation: plan.rotation) {
                        contour.append((target, moved))
                    }
                }
            }
        }
        var marks: [FlatMark] = []
        if contour.isEmpty {
            marks += geometry(plan).filter { mark in
                if case .line(_, let layer) = mark { return layer == .contour }
                return false
            }
        }
        // Schalter „Biegelinien“ im Panel gilt auch hier (z. B. Laser, der sonst die Linien schneidet)
        if bendLines {
            for bend in plan.bends { marks.append(.line([bend.start, bend.end], bend.up ? .bendUp : .bendDown)) }
        }
        marks += annotations(plan, unit: u)
        // Kopfzeile über der Bemaßung, Biegetabelle darunter
        let box = bounds(marks) ?? (Point2(0, 0), plan.size)
        let n = TechnicalDrawing.number
        var head = "Abwicklung \(title)  ·  Zuschnitt \(n(plan.size.x)) × \(n(plan.size.y)) mm  ·  t = \(n(plan.thickness)) mm"
        if let material, !material.isEmpty { head += "  ·  \(material)" }
        marks.append(leftText(head, at: Point2(min(box.min.x, 0), max(box.max.y, plan.size.y) + 6 * u), height: 5 * u))
        if !plan.bends.isEmpty {
            marks += bendTable(plan, topLeft: Point2(min(box.min.x, 0), min(box.min.y, 0) - 8 * u), unit: u)
        }

        var out = VectorFiles.DXFWriter()
        let extent = bounds(marks) ?? (Point2(0, 0), plan.size)
        out.pair(0, "SECTION")
        out.pair(2, "HEADER")
        out.pair(9, "$ACADVER")
        out.pair(1, "AC1009")
        out.pair(9, "$INSUNITS")
        out.pair(70, "4")
        out.pair(9, "$MEASUREMENT")
        out.pair(70, "1")
        out.pair(9, "$EXTMIN")
        out.point(10, simd_min(extent.min, Point2(0, 0)))
        out.pair(9, "$EXTMAX")
        out.point(10, simd_max(extent.max, plan.size))
        // Strichlänge der Biegelinien wächst mit dem Maßstab der Bemaßung
        out.pair(9, "$LTSCALE")
        out.number(40, u)
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "TABLES")
        out.pair(0, "TABLE")
        out.pair(2, "LTYPE")
        out.pair(70, "2")
        out.pair(0, "LTYPE")
        out.pair(2, "CONTINUOUS")
        out.pair(70, "0")
        out.pair(3, "Solid line")
        out.pair(72, "65")
        out.pair(73, "0")
        out.number(40, 0)
        out.pair(0, "LTYPE")
        out.pair(2, "DASHED")
        out.pair(70, "0")
        out.pair(3, "__ __ __ __")
        out.pair(72, "65")
        out.pair(73, "2")
        out.number(40, 9)
        out.number(49, 6)
        out.number(49, -3)
        out.pair(0, "ENDTAB")
        var layers: [(name: String, color: String, type: String)] = [
            ("0", "7", "CONTINUOUS"), ("KONTUR", "7", "CONTINUOUS"), ("BIEGUNG", "1", "DASHED"),
            ("BEMASSUNG", "3", "CONTINUOUS"), ("BIEGETABELLE", "7", "CONTINUOUS"),
        ]
        for name in contour.map({ $0.layer }) where !layers.contains(where: { $0.name == name }) {
            layers.append((name, name == "GRAVUR" ? "6" : "4", "CONTINUOUS"))
        }
        out.pair(0, "TABLE")
        out.pair(2, "LAYER")
        out.pair(70, String(layers.count))
        for layer in layers {
            out.pair(0, "LAYER")
            out.pair(2, layer.name)
            out.pair(70, "0")
            out.pair(62, layer.color)
            out.pair(6, layer.type)
        }
        out.pair(0, "ENDTAB")
        out.pair(0, "TABLE")
        out.pair(2, "STYLE")
        out.pair(70, "1")
        out.pair(0, "STYLE")
        out.pair(2, "STANDARD")
        out.pair(70, "0")
        out.number(40, 0)
        out.number(41, 1)
        out.number(50, 0)
        out.pair(71, "0")
        out.number(42, 2.5)
        out.pair(3, "txt")
        out.pair(4, "")
        out.pair(0, "ENDTAB")
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "ENTITIES")
        for item in contour { VectorFiles.appendDXF(item.entity, layer: item.layer, to: &out) }
        for mark in marks {
            switch mark {
            case .line(let points, let layer):
                guard points.count >= 2 else { continue }
                // Biegung nach oben rot, nach unten blau (wie SolidCraft BEND_UP / BEND_DOWN)
                let color: String? = layer == .bendUp ? "1" : layer == .bendDown ? "5" : nil
                if points.count == 2 {
                    out.pair(0, "LINE")
                    out.pair(8, layer.dxfLayer)
                    if let color { out.pair(62, color) }
                    out.point(10, points[0])
                    out.point(11, points[1])
                } else {
                    let closed = points.count > 3 && simd_distance(points[0], points[points.count - 1]) < 1e-9
                    out.pair(0, "POLYLINE")
                    out.pair(8, layer.dxfLayer)
                    if let color { out.pair(62, color) }
                    out.pair(66, "1")
                    out.point(10, .zero)
                    out.pair(70, String((closed ? 1 : 0) + 128))
                    for p in closed ? Array(points.dropLast()) : points {
                        out.pair(0, "VERTEX")
                        out.pair(8, layer.dxfLayer)
                        out.point(10, p)
                    }
                    out.pair(0, "SEQEND")
                    out.pair(8, layer.dxfLayer)
                }
            case .arrow(let tip, let direction, let size):
                let length = simd_length(direction)
                guard length > 1e-12 else { continue }
                let d = direction / length, normal = Point2(-d.y, d.x)
                let base = tip - d * size
                out.pair(0, "SOLID")
                out.pair(8, FlatMarkLayer.dimension.dxfLayer)
                out.point(10, tip)
                out.point(11, base + normal * size / 6)
                out.point(12, base - normal * size / 6)
                out.point(13, base - normal * size / 6)
            case .text(let string, let center, let height, let rotation, let layer):
                out.pair(0, "TEXT")
                out.pair(8, layer == .bendUp || layer == .bendDown ? FlatMarkLayer.dimension.dxfLayer : layer.dxfLayer)
                out.point(10, center)
                out.number(40, height)
                out.pair(1, dxfText(string))
                if rotation != 0 { out.number(50, rotation) }
                // Mitte, mittig (72 = 1, 73 = 2) am Ausrichtungspunkt 11
                out.pair(72, "1")
                out.point(11, center)
                out.pair(73, "2")
            }
        }
        out.pair(0, "ENDSEC")
        out.pair(0, "EOF")
        return out.data
    }

    /// Text für R12: Grad, Durchmesser, Plusminus als AutoCAD-Steuerzeichen, × als x, sonst \U+XXXX.
    static func dxfText(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "°": result += "%%d"
            case "Ø", "⌀": result += "%%c"
            case "±": result += "%%p"
            case "×": result += "x"
            case "·": result += "-"
            default:
                if scalar.isASCII {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += String(format: "\\U+%04X", scalar.value)
                }
            }
        }
        return result
    }
}

// MARK: - Modell: Fertigungs-DXF

extension ModelStore {
    /// Abwicklung als Fertigungs-DXF (Kontur, gestrichelte Biegelinien, Bemaßung, Biegetabelle) in eine temporäre
    /// Datei. Die Kontur kommt exakt aus sheet.export_dxf (Optionen exactCurves und etchText gelten weiter).
    func exportFlatDrawingDXF(of body: Int, options: SheetDXFOptions = SheetDXFOptions()) throws -> URL {
        let flat = try flatPattern(of: body)
        var contourOptions = options
        contourOptions.bendLines = false
        contourOptions.bendNotes = false
        contourOptions.singleLayer = false
        let source = try exportFlatPatternDXF(of: body, options: contourOptions)
        let data = (try? Data(contentsOf: source)) ?? Data()
        try? FileManager.default.removeItem(at: source)
        let plan = FlatDrawingPlan(flat)
        let name = bodies[body].name
        let dxf = FlatDrawing.dxf(plan, source: data, title: name, material: bodies[body].bodyMaterial?.name,
                                   bendLines: options.bendLines)
        let url = SheetKernel.temporaryURL("dxf", name: Self.sheetFileName(name) + " Abwicklung")
        try? FileManager.default.removeItem(at: url)
        try dxf.write(to: url)
        return url
    }
}
