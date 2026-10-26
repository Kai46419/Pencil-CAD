import Foundation
import simd

// Austausch von Skizzen mit anderen Programmen: DXF (ASCII) und SVG lesen und schreiben.
// Alle Koordinaten in mm im lokalen System der Skizze, y nach oben.

/// Ergebnis eines Imports: Skizzenelemente, gefundene Ebenen und Zahl der nicht übernommenen Objekte.
struct VectorImport {
    var entities: [SketchEntity]
    var layers: [String]
    var skipped: Int
}

/// Fehler beim Lesen einer Vektordatei.
struct VectorFileError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum VectorFiles {
    /// DXF (ASCII, R12 bis 2018): LINE, ARC, CIRCLE, ELLIPSE, LWPOLYLINE (inkl. Bulge = Bogen), POLYLINE/VERTEX, SPLINE, POINT. layers nil = alle Ebenen.
    static func importDXF(_ data: Data, layers filter: Set<String>? = nil) throws -> VectorImport {
        guard !data.isEmpty else { throw VectorFileError("Die DXF-Datei ist leer.") }
        if data.starts(with: Array("AutoCAD Binary DXF".utf8)) {
            throw VectorFileError("Binäre DXF-Dateien werden nicht unterstützt. Bitte als ASCII-DXF speichern.")
        }
        let records = try dxfRecords(data)
        // Ohne Abschnitte (Minimaldatei) gilt alles als Objekt
        var section = records.contains(where: { $0.type == "SECTION" }) ? "" : "ENTITIES"
        var unit = 1.0
        var entities: [SketchEntity] = []
        var layerNames: [String] = []
        var knownLayers: Set<String> = []
        var skipped = 0
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            if record.type == "SECTION" {
                section = (record.string(2) ?? "").uppercased()
                if section == "HEADER" { unit = dxfUnitScale(record) }
                continue
            }
            if record.type == "ENDSEC" {
                section = ""
                continue
            }
            // Blöcke (BLOCKS) und Tabellen werden nicht gelesen
            guard section == "ENTITIES" else { continue }
            // Eckpunkte gehören zur vorangehenden POLYLINE
            var vertices: [DXFRecord] = []
            if record.type == "POLYLINE" {
                while index < records.count, records[index].type == "VERTEX" {
                    vertices.append(records[index])
                    index += 1
                }
                if index < records.count, records[index].type == "SEQEND" { index += 1 }
            }
            if ["VERTEX", "SEQEND", "ATTRIB", "VIEWPORT", "EOF"].contains(record.type) { continue }
            // Papierbereich überspringen
            if record.int(67) == 1 { continue }
            let layer = record.string(8) ?? "0"
            if knownLayers.insert(layer).inserted { layerNames.append(layer) }
            if let filter, !filter.contains(layer) { continue }
            if let converted = dxfEntities(record, vertices: vertices, unit: unit) {
                entities += converted
            } else {
                skipped += 1
            }
        }
        let sortedLayers = layerNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return VectorImport(entities: entities, layers: sortedLayers, skipped: skipped)
    }

    /// SVG: path (M m L l H h V v C c S s Q q T t A a Z z), rect (auch mit rx/ry), circle, ellipse, line, polyline, polygon; transform= translate/scale/rotate/matrix auf g und Elementen (verschachtelt). Einheit: viewBox + width/height in mm/cm/in/pt/px; ohne Angabe 96 dpi (1 px = 25.4/96 mm). y wird gespiegelt (SVG y nach unten).
    static func importSVG(_ data: Data) throws -> VectorImport {
        guard !data.isEmpty else { throw VectorFileError("Die SVG-Datei ist leer.") }
        let reader = SVGReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        let reason = parser.parserError?.localizedDescription ?? "ungültiges XML"
        guard reader.foundRoot else {
            throw VectorFileError(ok ? "Die Datei enthält keine SVG-Grafik." : "Die SVG-Datei ist nicht lesbar (\(reason)).")
        }
        // Fehler nach bereits gelesener Geometrie: das Gelesene behalten
        if !ok, reader.entities.isEmpty {
            throw VectorFileError("Die SVG-Datei ist nicht lesbar (\(reason)).")
        }
        return VectorImport(entities: reader.entities, layers: reader.layers, skipped: reader.skipped)
    }

    /// Export der Skizzenelemente (lokale mm-Koordinaten) als DXF R12 (ENTITIES-Abschnitt reicht, mit gültigem HEADER $INSUNITS=4) bzw. SVG (viewBox um die Geometrie, width/height in mm, y gespiegelt). construction = Indizes, die als Konstruktion gelten (DXF Ebene „KONSTRUKTION“, SVG gestrichelt).
    static func exportDXF(_ entities: [SketchEntity], construction: Set<Int> = []) -> Data {
        var out = DXFWriter()
        out.pair(0, "SECTION")
        out.pair(2, "HEADER")
        out.pair(9, "$ACADVER")
        out.pair(1, "AC1009")
        out.pair(9, "$INSUNITS")
        out.pair(70, "4")
        out.pair(9, "$MEASUREMENT")
        out.pair(70, "1")
        if let box = bounds(entities) {
            out.pair(9, "$EXTMIN")
            out.point(10, box.min)
            out.pair(9, "$EXTMAX")
            out.point(10, box.max)
        }
        out.pair(0, "ENDSEC")

        // Linientypen und Ebenen
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
        out.pair(40, "0.0")
        out.pair(0, "LTYPE")
        out.pair(2, "DASHED")
        out.pair(70, "0")
        out.pair(3, "__ __ __ __")
        out.pair(72, "65")
        out.pair(73, "2")
        out.pair(40, "3.0")
        out.pair(49, "2.0")
        out.pair(49, "-1.0")
        out.pair(0, "ENDTAB")
        out.pair(0, "TABLE")
        out.pair(2, "LAYER")
        out.pair(70, "2")
        out.pair(0, "LAYER")
        out.pair(2, "0")
        out.pair(70, "0")
        out.pair(62, "7")
        out.pair(6, "CONTINUOUS")
        out.pair(0, "LAYER")
        out.pair(2, constructionLayer)
        out.pair(70, "0")
        out.pair(62, "8")
        out.pair(6, "DASHED")
        out.pair(0, "ENDTAB")
        out.pair(0, "ENDSEC")

        out.pair(0, "SECTION")
        out.pair(2, "ENTITIES")
        for (index, entity) in entities.enumerated() {
            writeDXF(entity, layer: construction.contains(index) ? constructionLayer : "0", to: &out)
        }
        out.pair(0, "ENDSEC")
        out.pair(0, "EOF")
        return out.data
    }

    /// SVG-Export: ein path je Element, Bögen als A, Splines als exakte Bézierkurven.
    static func exportSVG(_ entities: [SketchEntity], construction: Set<Int> = []) -> Data {
        var low = Point2(0, 0), high = Point2(10, 10)
        if let box = bounds(entities) {
            low = box.min
            high = box.max
        }
        let margin = 1.0
        low -= Point2(margin, margin)
        high += Point2(margin, margin)
        let size = high - low
        let width = decimal(size.x), height = decimal(size.y)
        let viewBox = "\(decimal(low.x)) \(decimal(-high.y)) \(width) \(height)"
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>",
            "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(width)mm\" height=\"\(height)mm\" viewBox=\"\(viewBox)\">",
            "<g fill=\"none\" stroke=\"#000000\" stroke-width=\"0.25\" stroke-linecap=\"round\" stroke-linejoin=\"round\">",
        ]
        for (index, entity) in entities.enumerated() {
            let dash = construction.contains(index) ? " stroke-dasharray=\"2 1\"" : ""
            if case .point(let p) = entity {
                // Punkt als Fleck (Linie der Länge 0 mit runden Enden)
                guard p.x.isFinite, p.y.isFinite else { continue }
                lines.append("<path d=\"M \(decimal(p.x)) \(decimal(-p.y)) h 0\" stroke-width=\"0.8\"/>")
                continue
            }
            var path = SVGPathWriter()
            for loop in entity.loops { path.add(loop) }
            for segment in entity.openSegments { path.add(segment) }
            guard !path.d.isEmpty else { continue }
            lines.append("<path d=\"\(path.d)\"\(dash)/>")
        }
        lines.append("</g>")
        lines.append("</svg>")
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

// MARK: Gemeinsame Geometrie

extension VectorFiles {
    fileprivate static let tolerance = 1e-7
    fileprivate static let constructionLayer = "KONSTRUKTION"

    /// Affine Abbildung x' = a·x + c·y + e, y' = b·x + d·y + f (wie SVG matrix()).
    fileprivate struct Affine {
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

        static let identity = Affine()

        func apply(_ p: Point2) -> Point2 { Point2(a * p.x + c * p.y + e, b * p.x + d * p.y + f) }

        /// Nur der lineare Anteil (für Richtungen).
        func linear(_ p: Point2) -> Point2 { Point2(a * p.x + c * p.y, b * p.x + d * p.y) }

        /// Erst other, dann self.
        func concatenating(_ o: Affine) -> Affine {
            Affine(a: a * o.a + c * o.b, b: b * o.a + d * o.b,
                   c: a * o.c + c * o.d, d: b * o.c + d * o.d,
                   e: a * o.e + c * o.f + e, f: b * o.e + d * o.f + f)
        }

        static func translation(_ x: Double, _ y: Double) -> Affine { Affine(e: x, f: y) }
        static func scale(_ x: Double, _ y: Double) -> Affine { Affine(a: x, d: y) }
        static func rotation(_ angle: Double) -> Affine {
            Affine(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle))
        }

        var isFinite: Bool { [a, b, c, d, e, f].allSatisfy { $0.isFinite } }

        /// Achsparallele Rechtecke bleiben achsparallel (keine Drehung außer um Vielfache von 90°, keine Scherung).
        var keepsAxes: Bool {
            let size = abs(a) + abs(b) + abs(c) + abs(d)
            guard size > 0 else { return false }
            let small = 1e-12 * size
            return (abs(b) <= small && abs(c) <= small) || (abs(a) <= small && abs(d) <= small)
        }
    }

    fileprivate static func same(_ p: Point2, _ q: Point2) -> Bool { simd_distance(p, q) < tolerance }

    fileprivate static func isFinite(_ p: Point2) -> Bool { p.x.isFinite && p.y.isFinite }

    /// Punkte ohne unendliche Werte und ohne direkt aufeinanderfolgende Doppelte.
    fileprivate static func dedupe(_ input: [Point2]) -> [Point2] {
        var points: [Point2] = []
        for p in input where isFinite(p) {
            if let last = points.last, same(last, p) { continue }
            points.append(p)
        }
        return points
    }

    /// Linienzug als Element: zwei Punkte werden eine Linie, weniger nichts.
    fileprivate static func polylineEntity(_ input: [Point2], closed: Bool) -> SketchEntity? {
        var points = dedupe(input)
        if closed, points.count > 2, let first = points.first, let last = points.last, same(first, last) {
            points.removeLast()
        }
        guard points.count >= 2 else { return nil }
        if points.count == 2 { return .line(points[0], points[1]) }
        return .polyline(points, closed: closed)
    }

    /// Abgetastete Kurve als Fit-Spline; geschlossen, wenn Anfang und Ende zusammenfallen.
    fileprivate static func sampledCurve(_ input: [Point2]) -> SketchEntity? {
        var points = dedupe(input)
        guard points.count >= 2 else { return nil }
        if points.count == 2 { return .line(points[0], points[1]) }
        if points.count > 3, let first = points.first, let last = points.last, same(first, last) {
            points.removeLast()
            return .spline(points: points, kind: .fit, closed: true)
        }
        return .spline(points: points, kind: .fit, closed: false)
    }

    /// Liegt p auf der Strecke a–b?
    fileprivate static func onSegment(_ p: Point2, _ a: Point2, _ b: Point2) -> Bool {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 0 else { return same(p, a) }
        let t = simd_dot(p - a, ab) / lengthSquared
        guard t >= -1e-9, t <= 1 + 1e-9 else { return false }
        return simd_distance(p, a + t * ab) < 1e-6
    }

    /// Kreis, Ellipse oder Bogen center + u·cos t + v·sin t für t von start um sweep, abgebildet mit m.
    /// full: ganze Kurve. from/to ersetzen Anfangs- und Endpunkt (exakter Anschluss in Pfaden).
    /// Kreisbögen werden 3-Punkt-Bögen (ab 359° geteilt), gedrehte oder offene Ellipsen Fit-Splines.
    fileprivate static func conic(center: Point2, u: Point2, v: Point2, start: Double, sweep: Double, full: Bool,
                                  transform m: Affine, from: Point2? = nil, to: Point2? = nil) -> [SketchEntity] {
        let c = m.apply(center), mu = m.linear(u), mv = m.linear(v)
        guard isFinite(c), isFinite(mu), isFinite(mv), start.isFinite, sweep.isFinite,
              full || abs(sweep) > 1e-9 else { return [] }
        // Hauptachsen: Parameter, bei dem |u·cos t + v·sin t| extremal wird
        let t0 = 0.5 * atan2(2 * simd_dot(mu, mv), simd_length_squared(mu) - simd_length_squared(mv))
        let major = mu * cos(t0) + mv * sin(t0)
        let minor = mv * cos(t0) - mu * sin(t0)
        let r1 = simd_length(major), r2 = simd_length(minor)
        guard r1 > tolerance, r2 > tolerance else { return [] }
        let isCircle = abs(r1 - r2) <= 1e-7 * max(r1, r2)
        func point(_ t: Double) -> Point2 { c + mu * cos(t) + mv * sin(t) }

        if full {
            if isCircle { return [.circle(center: c, radius: (r1 + r2) / 2)] }
            if abs(major.y) <= 1e-9 * r1 { return [.ellipse(center: c, radii: Point2(r1, r2))] }
            if abs(major.x) <= 1e-9 * r1 { return [.ellipse(center: c, radii: Point2(r2, r1))] }
            let count = 48
            let points = (0..<count).map { point(2 * .pi * Double($0) / Double(count)) }
            return [.spline(points: points, kind: .fit, closed: true)]
        }

        let first = from ?? point(start), last = to ?? point(start + sweep)
        if isCircle {
            if abs(sweep) >= 359 * .pi / 180 {
                let half = sweep / 2
                let middle = point(start + half)
                return [.arc(start: first, mid: point(start + half / 2), end: middle),
                        .arc(start: middle, mid: point(start + 1.5 * half), end: last)]
            }
            guard !same(first, last) else { return [] }
            return [.arc(start: first, mid: point(start + sweep / 2), end: last)]
        }
        let count = Int(min(256, max(8, (abs(sweep) / (2 * .pi) * 32).rounded(.up))))
        var points = (0...count).map { point(start + sweep * Double($0) / Double(count)) }
        points[0] = first
        points[count] = last
        guard let curve = sampledCurve(points) else { return [] }
        return [curve]
    }

    /// Mittelpunkt, Radius, Startwinkel und Öffnungswinkel (positiv = gegen den Uhrzeigersinn) eines 3-Punkt-Bogens.
    fileprivate static func arcGeometry(_ a: Point2, _ m: Point2, _ b: Point2)
        -> (center: Point2, radius: Double, start: Double, sweep: Double)? {
        guard let circle = circleThrough(a, m, b), circle.radius.isFinite, circle.radius > 0 else { return nil }
        let c = circle.center
        let a0 = atan2(a.y - c.y, a.x - c.x)
        var am = (atan2(m.y - c.y, m.x - c.x) - a0).truncatingRemainder(dividingBy: 2 * .pi)
        var ab = (atan2(b.y - c.y, b.x - c.x) - a0).truncatingRemainder(dividingBy: 2 * .pi)
        if am < 0 { am += 2 * .pi }
        if ab < 0 { ab += 2 * .pi }
        // Wie SketchSegment.samples: liegt m zwischen a und b, läuft der Bogen gegen den Uhrzeigersinn
        let sweep = am <= ab ? ab : ab - 2 * .pi
        return (c, circle.radius, a0, sweep)
    }

    /// Umgebendes Rechteck aller Elemente (Darstellungspunkte).
    fileprivate static func bounds(_ entities: [SketchEntity]) -> (min: Point2, max: Point2)? {
        var low = Point2(repeating: .infinity), high = Point2(repeating: -.infinity)
        for entity in entities {
            for line in entity.drawing {
                for p in line where isFinite(p) {
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
        }
        guard low.x <= high.x, low.y <= high.y else { return nil }
        return (low, high)
    }

    /// Zahl ohne überflüssige Nullen, immer mit Punkt.
    fileprivate static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.6f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        if text == "-0" { text = "0" }
        return text
    }

    /// Bézierpole des geklemmten Kontrollpunkt-Splines der App (Knoteneinfügung nach Boehm): Grad und Pole.
    fileprivate static func bezierPoles(clamped poles: [Point2]) -> (degree: Int, poles: [Point2]) {
        let n = poles.count
        guard n >= 3 else { return (1, poles) }
        let p = min(3, n - 1)
        let spans = n - p
        var knots = [Double](repeating: 0, count: p + 1)
        if spans > 1 { knots += (1..<spans).map(Double.init) }
        knots += [Double](repeating: Double(spans), count: p + 1)
        var result = poles
        if spans > 1 {
            for knot in 1..<spans {
                let u = Double(knot)
                for _ in 0..<(p - 1) {
                    guard let k = knots.lastIndex(where: { $0 <= u }), k >= p, k < result.count else { continue }
                    var next: [Point2] = []
                    next.reserveCapacity(result.count + 1)
                    for i in 0...result.count {
                        if i <= k - p {
                            next.append(result[i])
                        } else if i <= k {
                            let denominator = knots[i + p] - knots[i]
                            let alpha = denominator == 0 ? 0 : (u - knots[i]) / denominator
                            next.append((1 - alpha) * result[i - 1] + alpha * result[i])
                        } else {
                            next.append(result[i - 1])
                        }
                    }
                    knots.insert(u, at: k + 1)
                    result = next
                }
            }
        }
        return (p, result)
    }

    /// Bézierpole des geschlossenen gleichmäßigen Kontrollpunkt-Splines der App: Grad und Pole (Anfang = Ende).
    fileprivate static func bezierPoles(periodic poles: [Point2]) -> (degree: Int, poles: [Point2])? {
        let n = poles.count
        guard n >= 3 else { return nil }
        if n == 3 {
            var result = [(poles[0] + poles[1]) / 2]
            for j in 0..<n {
                let p1 = poles[(j + 1) % n], p2 = poles[(j + 2) % n]
                result += [p1, (p1 + p2) / 2]
            }
            return (2, result)
        }
        var result = [(poles[0] + 4 * poles[1] + poles[2]) / 6]
        for j in 0..<n {
            let p1 = poles[(j + 1) % n], p2 = poles[(j + 2) % n], p3 = poles[(j + 3) % n]
            result += [(2 * p1 + p2) / 3, (p1 + 2 * p2) / 3, (p1 + 4 * p2 + p3) / 6]
        }
        return (3, result)
    }
}

// MARK: DXF lesen

extension VectorFiles {
    /// Ein DXF-Objekt: Typ (Gruppe 0) und die folgenden Gruppen.
    fileprivate struct DXFRecord {
        var type: String
        var groups: [(code: Int, value: String)]

        func string(_ code: Int) -> String? { groups.first(where: { $0.code == code })?.value }

        func double(_ code: Int) -> Double? {
            guard let text = string(code), let value = Double(text), value.isFinite else { return nil }
            return value
        }

        func int(_ code: Int) -> Int? {
            guard let text = string(code) else { return nil }
            if let value = Int(text) { return value }
            guard let value = Double(text), value.isFinite, abs(value) < 1e9 else { return nil }
            return Int(value)
        }

        /// Alle Werte einer wiederholten Gruppe.
        func doubles(_ code: Int) -> [Double] {
            groups.compactMap { group -> Double? in
                guard group.code == code, let value = Double(group.value), value.isFinite else { return nil }
                return value
            }
        }

        /// Punkt aus x (code) und y (code + 10); fehlende Werte 0.
        func point(_ code: Int) -> Point2 { Point2(double(code) ?? 0, double(code + 10) ?? 0) }

        /// Wiederholte Punkte: jede Gruppe code beginnt einen neuen Punkt, code + 10 setzt dessen y.
        func points(_ code: Int) -> [Point2] {
            var result: [Point2] = []
            for group in groups {
                if group.code == code {
                    result.append(Point2(Double(group.value) ?? 0, 0))
                } else if group.code == code + 10, !result.isEmpty {
                    result[result.count - 1].y = Double(group.value) ?? 0
                }
            }
            return result.filter { VectorFiles.isFinite($0) }
        }
    }

    /// Gruppenpaare der Datei, zu Objekten zusammengefasst (Zeilenenden CRLF, CR oder LF).
    fileprivate static func dxfRecords(_ data: Data) throws -> [DXFRecord] {
        guard var text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw VectorFileError("Die DXF-Datei ist nicht lesbar.")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var records: [DXFRecord] = []
        var index = 0
        while index + 1 < lines.count {
            let codeText = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if codeText.isEmpty,
               lines[index...].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                break
            }
            guard let code = Int(codeText) else {
                throw VectorFileError("Die Datei ist keine lesbare DXF-Datei (Zeile \(index + 1)).")
            }
            let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 2
            if code == 0 {
                let type = value.uppercased()
                records.append(DXFRecord(type: type, groups: []))
                if type == "EOF" { break }
            } else if !records.isEmpty {
                records[records.count - 1].groups.append((code: code, value: value))
            }
        }
        guard !records.isEmpty else { throw VectorFileError("Die Datei enthält keine DXF-Daten.") }
        return records
    }

    /// Faktor nach mm aus $INSUNITS im HEADER (0 oder fehlend = mm).
    fileprivate static func dxfUnitScale(_ header: DXFRecord) -> Double {
        guard let index = header.groups.firstIndex(where: { $0.code == 9 && $0.value.uppercased() == "$INSUNITS" })
        else { return 1 }
        let rest = header.groups[(index + 1)...]
        guard let group = rest.first(where: { $0.code == 70 || $0.code == 9 }), group.code == 70,
              let code = Int(group.value) else { return 1 }
        switch code {
        case 1: return 25.4
        case 2: return 304.8
        case 3: return 1_609_344
        case 5: return 10
        case 6: return 1000
        case 7: return 1_000_000
        case 8: return 25.4e-6
        case 9: return 0.0254
        case 10: return 914.4
        case 11: return 1e-7
        case 12: return 1e-6
        case 13: return 1e-3
        case 14: return 100
        case 15: return 10_000
        case 16: return 100_000
        default: return 1
        }
    }

    /// Richtung der Objektnormale: +1 oder −1 für ±z, nil bei schräger Lage (3D).
    fileprivate static func dxfNormalZ(_ record: DXFRecord) -> Double? {
        let normal = SIMD3<Double>(record.double(210) ?? 0, record.double(220) ?? 0, record.double(230) ?? 1)
        let length = simd_length(normal)
        guard length > 0 else { return 1 }
        let unit = normal / length
        guard abs(unit.x) < 1e-6, abs(unit.y) < 1e-6 else { return nil }
        return unit.z > 0 ? 1 : -1
    }

    /// Objektkoordinatensystem (OCS) nach Weltkoordinaten: bei Normale −z ist x gespiegelt.
    fileprivate static func dxfOCS(_ record: DXFRecord) -> Affine? {
        guard let z = dxfNormalZ(record) else { return nil }
        return z > 0 ? Affine.identity : Affine(a: -1)
    }

    /// Skizzenelemente eines DXF-Objekts; [] bei entarteter Geometrie, nil wenn nicht unterstützt.
    fileprivate static func dxfEntities(_ record: DXFRecord, vertices: [DXFRecord], unit: Double) -> [SketchEntity]? {
        let scale = Affine.scale(unit, unit)
        switch record.type {
        case "LINE":
            let a = scale.apply(record.point(10)), b = scale.apply(record.point(11))
            return same(a, b) ? [] : [.line(a, b)]

        case "POINT":
            let p = scale.apply(record.point(10))
            return isFinite(p) ? [.point(p)] : []

        case "CIRCLE", "ARC":
            guard let ocs = dxfOCS(record) else { return nil }
            let m = scale.concatenating(ocs)
            let r = record.double(40) ?? 0
            guard r > 0 else { return [] }
            let center = record.point(10)
            let u = Point2(r, 0), v = Point2(0, r)
            if record.type == "CIRCLE" {
                return conic(center: center, u: u, v: v, start: 0, sweep: 2 * .pi, full: true, transform: m)
            }
            let start = (record.double(50) ?? 0) * .pi / 180
            let end = (record.double(51) ?? 360) * .pi / 180
            var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
            if sweep <= 1e-12 { sweep += 2 * .pi }
            return conic(center: center, u: u, v: v, start: start, sweep: sweep, full: false, transform: m)

        case "ELLIPSE":
            guard let normal = dxfNormalZ(record) else { return nil }
            let center = record.point(10), major = record.point(11)
            let ratio = record.double(40) ?? 1
            guard simd_length(major) > 0, ratio > 0 else { return [] }
            // Nebenachse = Normale × Hauptachse
            let minor = ratio * (normal > 0 ? Point2(-major.y, major.x) : Point2(major.y, -major.x))
            let start = record.double(41) ?? 0
            let end = record.double(42) ?? 2 * .pi
            var sweep = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
            if sweep <= 1e-12 { sweep += 2 * .pi }
            let full = abs(sweep - 2 * .pi) < 1e-9
            return conic(center: center, u: major, v: minor, start: start, sweep: sweep, full: full, transform: scale)

        case "LWPOLYLINE":
            guard let ocs = dxfOCS(record) else { return nil }
            var points: [(point: Point2, bulge: Double)] = []
            for group in record.groups {
                switch group.code {
                case 10:
                    points.append((point: Point2(Double(group.value) ?? 0, 0), bulge: 0))
                case 20:
                    if !points.isEmpty { points[points.count - 1].point.y = Double(group.value) ?? 0 }
                case 42:
                    if !points.isEmpty { points[points.count - 1].bulge = Double(group.value) ?? 0 }
                default:
                    break
                }
            }
            let closed = (record.int(70) ?? 0) & 1 != 0
            return bulgePolyline(points, closed: closed, transform: scale.concatenating(ocs))

        case "POLYLINE":
            let flags = record.int(70) ?? 0
            // Netze (Polygon- und Flächennetz) sind keine Skizzenkurven
            guard flags & (16 | 64) == 0 else { return nil }
            let is3D = flags & 8 != 0
            let m: Affine
            if is3D {
                m = scale
            } else {
                guard let ocs = dxfOCS(record) else { return nil }
                m = scale.concatenating(ocs)
            }
            // Rahmenpunkte eines Spline-Linienzugs (Flag 16) gehören nicht zur Kurve
            let points: [(point: Point2, bulge: Double)] = vertices
                .filter { (($0.int(70) ?? 0) & 16) == 0 }
                .map { (point: $0.point(10), bulge: is3D ? 0 : ($0.double(42) ?? 0)) }
            return bulgePolyline(points, closed: flags & 1 != 0, transform: m)

        case "SPLINE":
            let flags = record.int(70) ?? 0
            let closed = flags & 1 != 0
            let degree = record.int(71) ?? 3
            let controls = record.points(10).map { scale.apply($0) }
            let fits = record.points(11).map { scale.apply($0) }
            if controls.count >= 2, degree >= 1, degree < controls.count {
                if degree == 1 {
                    guard let entity = polylineEntity(controls, closed: closed) else { return [] }
                    return [entity]
                }
                let knots = record.doubles(40), weights = record.doubles(41)
                if isAppControlSpline(count: controls.count, degree: degree, knots: knots, weights: weights) {
                    guard dedupe(controls).count >= 2 else { return [] }
                    return [.spline(points: controls, kind: .control, closed: false)]
                }
                if let samples = nurbsSamples(controls, weights: weights, knots: knots, degree: degree) {
                    guard let curve = sampledCurve(samples) else { return [] }
                    return [curve]
                }
            }
            if fits.count >= 2 {
                var points = dedupe(fits)
                var isClosed = closed
                if points.count > 3, let first = points.first, let last = points.last, same(first, last) {
                    points.removeLast()
                    isClosed = true
                }
                guard points.count >= 2 else { return [] }
                if points.count == 2 { return [.line(points[0], points[1])] }
                return [.spline(points: points, kind: .fit, closed: isClosed)]
            }
            return nil

        default:
            // INSERT (Blockreferenz), Text, Bemaßung, Schraffur usw.
            return nil
        }
    }

    /// Linienzug mit Bögen (bulge = tan(Winkel/4), positiv gegen den Uhrzeigersinn) als Linienzüge und Bögen.
    fileprivate static func bulgePolyline(_ input: [(point: Point2, bulge: Double)], closed: Bool,
                                          transform m: Affine) -> [SketchEntity] {
        var vertices: [(point: Point2, bulge: Double)] = []
        for vertex in input where isFinite(vertex.point) {
            let bulge = vertex.bulge.isFinite ? vertex.bulge : 0
            if let last = vertices.last, same(m.apply(last.point), m.apply(vertex.point)) {
                // Strecke der Länge 0: die Wölbung gilt für die nächste Strecke
                vertices[vertices.count - 1].bulge = bulge
            } else {
                vertices.append((point: vertex.point, bulge: bulge))
            }
        }
        if closed, vertices.count > 1, let first = vertices.first, let last = vertices.last,
           same(m.apply(first.point), m.apply(last.point)) {
            vertices.removeLast()
        }
        guard vertices.count >= 2 else { return [] }
        if vertices.allSatisfy({ abs($0.bulge) < 1e-12 }) {
            guard let entity = polylineEntity(vertices.map { m.apply($0.point) }, closed: closed) else { return [] }
            return [entity]
        }
        var result: [SketchEntity] = []
        var run: [Point2] = []
        func flush() {
            if let entity = polylineEntity(run, closed: false) { result.append(entity) }
            run = []
        }
        let segmentCount = closed ? vertices.count : vertices.count - 1
        for i in 0..<segmentCount {
            let a = vertices[i].point, b = vertices[(i + 1) % vertices.count].point
            let bulge = vertices[i].bulge
            if abs(bulge) < 1e-12 {
                if run.isEmpty { run.append(m.apply(a)) }
                run.append(m.apply(b))
                continue
            }
            flush()
            result += bulgeArc(from: a, to: b, bulge: bulge, transform: m)
        }
        flush()
        return result
    }

    /// Bogen einer Polylinienstrecke mit Wölbung.
    fileprivate static func bulgeArc(from a: Point2, to b: Point2, bulge: Double, transform m: Affine) -> [SketchEntity] {
        let chord = b - a
        let length = simd_length(chord)
        guard length > 0 else { return [] }
        let sweep = 4 * atan(bulge)
        // Bogenmitte liegt rechts der Sehne, wenn der Bogen gegen den Uhrzeigersinn läuft
        let mid = (a + b) / 2 + bulge * length / 2 * rightNormal(chord)
        guard let circle = circleThrough(a, mid, b) else {
            let p = m.apply(a), q = m.apply(b)
            return same(p, q) ? [] : [.line(p, q)]
        }
        let start = atan2(a.y - circle.center.y, a.x - circle.center.x)
        let r = circle.radius
        return conic(center: circle.center, u: Point2(r, 0), v: Point2(0, r), start: start, sweep: sweep, full: false,
                     transform: m, from: m.apply(a), to: m.apply(b))
    }

    /// Entspricht der DXF-Spline genau dem Kontrollpunkt-Spline der App
    /// (geklemmt, gleichmäßige innere Knoten, Grad min(3, n − 1), nicht rational)?
    fileprivate static func isAppControlSpline(count n: Int, degree p: Int, knots: [Double], weights: [Double]) -> Bool {
        guard n >= 2, p == min(3, n - 1), knots.count == n + p + 1,
              let first = knots.first, let last = knots.last, last > first else { return false }
        let spans = n - p
        var expected = [Double](repeating: 0, count: p + 1)
        if spans > 1 { expected += (1..<spans).map(Double.init) }
        expected += [Double](repeating: Double(spans), count: p + 1)
        let range = last - first
        for (knot, target) in zip(knots, expected) {
            if abs((knot - first) / range * Double(spans) - target) > 1e-6 * Double(spans) { return false }
        }
        if weights.count == n, let w = weights.first,
           weights.contains(where: { abs($0 - w) > 1e-9 * max(abs(w), 1e-12) }) {
            return false
        }
        return true
    }

    /// Punkte eines (rationalen) B-Splines nach de Boor; ungültige Knoten werden durch geklemmte gleichmäßige ersetzt.
    fileprivate static func nurbsSamples(_ poles: [Point2], weights: [Double], knots input: [Double],
                                         degree p: Int) -> [Point2]? {
        let n = poles.count
        guard p >= 1, n > p else { return nil }
        var knots = input
        let ascending = zip(knots, knots.dropFirst()).allSatisfy { $0.0 <= $0.1 }
        if !(knots.count == n + p + 1 && ascending && knots[n] - knots[p] > 0) {
            let spans = n - p
            knots = [Double](repeating: 0, count: p + 1)
            if spans > 1 { knots += (1..<spans).map(Double.init) }
            knots += [Double](repeating: Double(spans), count: p + 1)
        }
        let useWeights = weights.count == n && weights.allSatisfy { $0 > 0 && $0.isFinite }
        let homogeneous = (0..<n).map { i -> SIMD3<Double> in
            let w = useWeights ? weights[i] : 1
            return SIMD3<Double>(poles[i].x * w, poles[i].y * w, w)
        }
        let t0 = knots[p], t1 = knots[n]
        let count = min(400, max(16, (n - p) * 12))
        var result: [Point2] = []
        for s in 0...count {
            let t = t0 + (t1 - t0) * Double(s) / Double(count)
            var k = p
            while k < n - 1, t >= knots[k + 1] { k += 1 }
            var d = (0...p).map { homogeneous[$0 + k - p] }
            for r in 1...p {
                for j in stride(from: p, through: r, by: -1) {
                    let i = j + k - p
                    let denominator = knots[i + 1 + p - r] - knots[i]
                    let alpha = denominator == 0 ? 0 : (t - knots[i]) / denominator
                    d[j] = (1 - alpha) * d[j - 1] + alpha * d[j]
                }
            }
            let h = d[p]
            guard h.z != 0 else { continue }
            let point = Point2(h.x / h.z, h.y / h.z)
            if isFinite(point) { result.append(point) }
        }
        return result.count >= 2 ? result : nil
    }
}

// MARK: DXF schreiben

extension VectorFiles {
    /// Gruppenpaare einer DXF-Datei.
    fileprivate struct DXFWriter {
        var lines: [String] = []

        mutating func pair(_ code: Int, _ value: String) {
            let text = String(code)
            lines.append(String(repeating: " ", count: max(0, 3 - text.count)) + text)
            lines.append(value)
        }

        mutating func number(_ code: Int, _ value: Double) { pair(code, VectorFiles.decimal(value)) }

        mutating func point(_ code: Int, _ p: Point2) {
            number(code, p.x)
            number(code + 10, p.y)
            number(code + 20, 0)
        }

        var data: Data { Data((lines.joined(separator: "\r\n") + "\r\n").utf8) }
    }

    fileprivate static func writeDXF(_ entity: SketchEntity, layer: String, to out: inout DXFWriter) {
        switch entity {
        case .line(let a, let b):
            writeLine(a, b, layer: layer, to: &out)
        case .arc(let a, let m, let b):
            guard let arc = arcGeometry(a, m, b) else {
                writeLine(a, b, layer: layer, to: &out)
                return
            }
            // DXF-Bögen laufen gegen den Uhrzeigersinn von 50 nach 51
            var from = arc.start, to = arc.start + arc.sweep
            if arc.sweep < 0 { swap(&from, &to) }
            out.pair(0, "ARC")
            out.pair(8, layer)
            out.point(10, arc.center)
            out.number(40, arc.radius)
            out.number(50, degrees(from))
            out.number(51, degrees(to))
        case .circle(let center, let radius):
            guard radius > 0, radius.isFinite, isFinite(center) else { return }
            out.pair(0, "CIRCLE")
            out.pair(8, layer)
            out.point(10, center)
            out.number(40, radius)
        case .point(let p):
            guard isFinite(p) else { return }
            out.pair(0, "POINT")
            out.pair(8, layer)
            out.point(10, p)
        case .rectangle(let c, let s):
            writePolyline([c, c + Point2(s.x, 0), c + s, c + Point2(0, s.y)], closed: true, layer: layer, to: &out)
        case .regularPolygon(let center, let radius, let sides, let angle):
            writePolyline(SketchEntity.polygonCorners(center: center, radius: radius, sides: sides, angle: angle),
                          closed: true, layer: layer, to: &out)
        case .polyline(let points, let closed):
            writePolyline(points, closed: closed, layer: layer, to: &out)
        case .ellipse, .spline, .text:
            // R12 kennt weder Ellipsen noch Splines: als Linienzug aus Abtastpunkten
            for loop in entity.loops {
                writePolyline(loop.polygon, closed: true, layer: layer, to: &out)
            }
            for segment in entity.openSegments {
                writePolyline(segment.samples, closed: false, layer: layer, to: &out)
            }
        }
    }

    fileprivate static func writeLine(_ a: Point2, _ b: Point2, layer: String, to out: inout DXFWriter) {
        guard isFinite(a), isFinite(b), !same(a, b) else { return }
        out.pair(0, "LINE")
        out.pair(8, layer)
        out.point(10, a)
        out.point(11, b)
    }

    fileprivate static func writePolyline(_ input: [Point2], closed: Bool, layer: String, to out: inout DXFWriter) {
        var points = dedupe(input)
        if closed, points.count > 2, let first = points.first, let last = points.last, same(first, last) {
            points.removeLast()
        }
        guard points.count >= 2 else { return }
        out.pair(0, "POLYLINE")
        out.pair(8, layer)
        out.pair(66, "1")
        out.point(10, .zero)
        out.pair(70, closed ? "1" : "0")
        for p in points {
            out.pair(0, "VERTEX")
            out.pair(8, layer)
            out.point(10, p)
        }
        out.pair(0, "SEQEND")
        out.pair(8, layer)
    }

    /// Winkel in Grad in [0, 360).
    fileprivate static func degrees(_ radians: Double) -> Double {
        var value = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }
}

// MARK: SVG lesen

extension VectorFiles {
    /// Zahlen und Flags in SVG-Attributen und Pfaddaten.
    fileprivate struct NumberScanner {
        let bytes: [UInt8]
        var index = 0

        init(_ text: String) { bytes = Array(text.utf8) }

        var atEnd: Bool { index >= bytes.count }

        /// Rest ab der aktuellen Stelle (z. B. Einheit hinter einer Zahl).
        var rest: String { String(decoding: bytes[min(index, bytes.count)...], as: UTF8.self) }

        /// Aktuelles Zeichen, falls es ein Buchstabe ist (Pfadbefehl).
        var letter: UInt8? {
            guard index < bytes.count else { return nil }
            let c = bytes[index]
            return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ? c : nil
        }

        mutating func skipSeparators() {
            while index < bytes.count {
                let c = bytes[index]
                guard c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 44 else { return }
                index += 1
            }
        }

        private func isDigit(_ i: Int) -> Bool { i < bytes.count && bytes[i] >= 48 && bytes[i] <= 57 }

        /// Nächste Zahl („-1.5e3“, „.5“); nil ohne Zahl oder bei unendlichem Wert.
        mutating func number() -> Double? {
            skipSeparators()
            let start = index
            var i = index
            if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
            var digits = 0
            while isDigit(i) {
                i += 1
                digits += 1
            }
            if i < bytes.count, bytes[i] == 46 {
                i += 1
                while isDigit(i) {
                    i += 1
                    digits += 1
                }
            }
            guard digits > 0 else { return nil }
            if i < bytes.count, bytes[i] == 101 || bytes[i] == 69 {
                var j = i + 1
                if j < bytes.count, bytes[j] == 43 || bytes[j] == 45 { j += 1 }
                var exponentDigits = 0
                while isDigit(j) {
                    j += 1
                    exponentDigits += 1
                }
                if exponentDigits > 0 { i = j }
            }
            index = i
            guard let value = Double(String(decoding: bytes[start..<i], as: UTF8.self)), value.isFinite else {
                return nil
            }
            return value
        }

        /// Bogen-Flag „0“ oder „1“ (darf ohne Trennzeichen folgen).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == 48 || bytes[index] == 49 else { return nil }
            let value = bytes[index] == 49
            index += 1
            return value
        }
    }

    fileprivate static func numbers(_ text: String) -> [Double] {
        var scanner = NumberScanner(text)
        var result: [Double] = []
        while let value = scanner.number() { result.append(value) }
        return result
    }

    /// Länge in SVG-Benutzereinheiten (px); Einheiten px, mm, cm, in, pt, pc, q. Prozent und Unlesbares: nil.
    fileprivate static func svgLength(_ text: String?) -> Double? {
        guard let text else { return nil }
        var scanner = NumberScanner(text)
        guard let value = scanner.number() else { return nil }
        let mmPerUnit: Double
        switch scanner.rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "px": return value
        case "mm": mmPerUnit = 1
        case "cm": mmPerUnit = 10
        case "in": mmPerUnit = 25.4
        case "pt": mmPerUnit = 25.4 / 72
        case "pc": mmPerUnit = 25.4 / 6
        case "q": mmPerUnit = 0.25
        default: return nil
        }
        return value * mmPerUnit * 96 / 25.4
    }

    /// Benutzereinheiten des Wurzelelements nach mm mit gespiegelter y-Achse (viewBox, width, height).
    fileprivate static func svgViewport(_ attributes: [String: String]) -> Affine {
        let pxToMM = 25.4 / 96
        var sx = pxToMM, sy = pxToMM
        let box = numbers(attributes["viewBox"] ?? "")
        if box.count == 4, box[2] > 0, box[3] > 0 {
            let width = svgLength(attributes["width"]).map { $0 * pxToMM }.flatMap { $0 > 0 ? $0 : nil }
            let height = svgLength(attributes["height"]).map { $0 * pxToMM }.flatMap { $0 > 0 ? $0 : nil }
            let fx = width.map { $0 / box[2] }, fy = height.map { $0 / box[3] }
            switch (fx, fy) {
            case let (x?, y?):
                let aspect = (attributes["preserveAspectRatio"] ?? "").trimmingCharacters(in: .whitespaces)
                if aspect.hasPrefix("none") {
                    sx = x
                    sy = y
                } else {
                    sx = min(x, y)
                    sy = sx
                }
            case let (x?, nil):
                sx = x
                sy = x
            case let (nil, y?):
                sx = y
                sy = y
            default:
                break
            }
        }
        return Affine(a: sx, d: -sy)
    }

    /// transform-Attribut: translate, scale, rotate, skewX, skewY, matrix (in Lesereihenfolge verkettet).
    fileprivate static func svgTransform(_ text: String?) -> Affine {
        guard let text, !text.isEmpty else { return .identity }
        var result = Affine.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,")).lowercased()
            let values = numbers(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
            guard let first = values.first else { continue }
            var step = Affine.identity
            switch name {
            case "matrix":
                if values.count >= 6 {
                    step = Affine(a: values[0], b: values[1], c: values[2], d: values[3], e: values[4], f: values[5])
                }
            case "translate":
                step = .translation(first, values.count >= 2 ? values[1] : 0)
            case "scale":
                step = .scale(first, values.count >= 2 ? values[1] : first)
            case "rotate":
                let rotation = Affine.rotation(first * .pi / 180)
                if values.count >= 3 {
                    step = Affine.translation(values[1], values[2])
                        .concatenating(rotation)
                        .concatenating(.translation(-values[1], -values[2]))
                } else {
                    step = rotation
                }
            case "skewx":
                step = Affine(c: tan(first * .pi / 180))
            case "skewy":
                step = Affine(b: tan(first * .pi / 180))
            default:
                break
            }
            result = result.concatenating(step)
        }
        return result.isFinite ? result : .identity
    }

    /// Ausgeblendet (display="none" bzw. style="display:none")?
    fileprivate static func svgHidden(_ attributes: [String: String]) -> Bool {
        if attributes["display"]?.trimmingCharacters(in: .whitespaces) == "none" { return true }
        let style = (attributes["style"] ?? "").replacingOccurrences(of: " ", with: "").lowercased()
        return style.contains("display:none")
    }

    /// Elementname ohne Namensraum-Präfix („svg:path“ → „path“).
    fileprivate static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// Skizzenelemente einer SVG-Grundform; m bildet Benutzereinheiten auf mm ab.
    fileprivate static func svgShape(_ name: String, _ attributes: [String: String], transform m: Affine) -> [SketchEntity] {
        func length(_ key: String) -> Double { svgLength(attributes[key]) ?? 0 }
        switch name {
        case "path":
            var path = SVGPath(transform: m)
            path.parse(attributes["d"] ?? "")
            return path.entities

        case "line":
            let a = m.apply(Point2(length("x1"), length("y1"))), b = m.apply(Point2(length("x2"), length("y2")))
            return isFinite(a) && isFinite(b) && !same(a, b) ? [.line(a, b)] : []

        case "polyline", "polygon":
            let values = numbers(attributes["points"] ?? "")
            let points = stride(from: 0, to: values.count - 1, by: 2).map { m.apply(Point2(values[$0], values[$0 + 1])) }
            guard let entity = polylineEntity(points, closed: name == "polygon") else { return [] }
            return [entity]

        case "rect":
            let x = length("x"), y = length("y"), w = length("width"), h = length("height")
            guard w > 0, h > 0 else { return [] }
            let rx = svgLength(attributes["rx"]), ry = svgLength(attributes["ry"])
            let cornerX = min(max(rx ?? ry ?? 0, 0), w / 2), cornerY = min(max(ry ?? rx ?? 0, 0), h / 2)
            if cornerX > 0, cornerY > 0 {
                // Abgerundete Ecken als Pfad
                var path = SVGPath(transform: m)
                path.moveTo(Point2(x + cornerX, y))
                path.lineTo(Point2(x + w - cornerX, y))
                path.arcTo(rx: cornerX, ry: cornerY, angle: 0, large: false, sweep: true, to: Point2(x + w, y + cornerY))
                path.lineTo(Point2(x + w, y + h - cornerY))
                path.arcTo(rx: cornerX, ry: cornerY, angle: 0, large: false, sweep: true, to: Point2(x + w - cornerX, y + h))
                path.lineTo(Point2(x + cornerX, y + h))
                path.arcTo(rx: cornerX, ry: cornerY, angle: 0, large: false, sweep: true, to: Point2(x, y + h - cornerY))
                path.lineTo(Point2(x, y + cornerY))
                path.arcTo(rx: cornerX, ry: cornerY, angle: 0, large: false, sweep: true, to: Point2(x + cornerX, y))
                path.close()
                path.finish()
                return path.entities
            }
            let corners = [Point2(x, y), Point2(x + w, y), Point2(x + w, y + h), Point2(x, y + h)].map { m.apply($0) }
            guard corners.allSatisfy({ isFinite($0) }) else { return [] }
            if m.keepsAxes {
                let low = corners.dropFirst().reduce(corners[0]) { simd_min($0, $1) }
                let high = corners.dropFirst().reduce(corners[0]) { simd_max($0, $1) }
                let size = high - low
                guard size.x > tolerance, size.y > tolerance else { return [] }
                return [.rectangle(corner: low, size: size)]
            }
            guard let entity = polylineEntity(corners, closed: true) else { return [] }
            return [entity]

        case "circle":
            let r = length("r")
            guard r > 0 else { return [] }
            return conic(center: Point2(length("cx"), length("cy")), u: Point2(r, 0), v: Point2(0, r),
                         start: 0, sweep: 2 * .pi, full: true, transform: m)

        case "ellipse":
            let rx = svgLength(attributes["rx"]), ry = svgLength(attributes["ry"])
            let a = rx ?? ry ?? 0, b = ry ?? rx ?? 0
            guard a > 0, b > 0 else { return [] }
            return conic(center: Point2(length("cx"), length("cy")), u: Point2(a, 0), v: Point2(0, b),
                         start: 0, sweep: 2 * .pi, full: true, transform: m)

        default:
            return []
        }
    }

    /// Liest SVG-Pfaddaten in Benutzereinheiten und bildet sie mit transform ab.
    /// Gerade Stücke werden zu Linienzügen, Béziers zu Kontrollpunkt-Splines (4 Pole = exakt kubisch).
    fileprivate struct SVGPath {
        let transform: Affine
        var entities: [SketchEntity] = []
        private var current = Point2.zero
        private var start = Point2.zero
        /// Fertige Stücke des aktuellen Teilpfads
        private var pieces: [SketchEntity] = []
        /// Abgebildete Punkte der laufenden Folge gerader Stücke
        private var run: [Point2] = []

        init(transform: Affine) { self.transform = transform }

        mutating func parse(_ text: String) {
            var scanner = NumberScanner(text)
            var command: UInt8 = 0
            var lastCubic: Point2?
            var lastQuad: Point2?
            parsing: while true {
                scanner.skipSeparators()
                if scanner.atEnd { break }
                if let letter = scanner.letter {
                    scanner.index += 1
                    command = letter
                    if (letter | 32) == UInt8(ascii: "z") {
                        close()
                        lastCubic = nil
                        lastQuad = nil
                        continue
                    }
                } else if command == 0 || (command | 32) == UInt8(ascii: "z") {
                    break
                }
                let relative = command >= 97
                let origin = relative ? current : Point2.zero
                var cubicControl: Point2?
                var quadControl: Point2?
                switch command | 32 {
                case UInt8(ascii: "m"):
                    guard let x = scanner.number(), let y = scanner.number() else { break parsing }
                    moveTo(origin + Point2(x, y))
                    // Weitere Koordinatenpaare sind Linien
                    command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                case UInt8(ascii: "l"):
                    guard let x = scanner.number(), let y = scanner.number() else { break parsing }
                    lineTo(origin + Point2(x, y))
                case UInt8(ascii: "h"):
                    guard let x = scanner.number() else { break parsing }
                    lineTo(Point2(relative ? current.x + x : x, current.y))
                case UInt8(ascii: "v"):
                    guard let y = scanner.number() else { break parsing }
                    lineTo(Point2(current.x, relative ? current.y + y : y))
                case UInt8(ascii: "c"):
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break parsing }
                    let c2 = origin + Point2(x2, y2)
                    cubicTo(origin + Point2(x1, y1), c2, origin + Point2(x, y))
                    cubicControl = c2
                case UInt8(ascii: "s"):
                    guard let x2 = scanner.number(), let y2 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break parsing }
                    var c1 = current
                    if let last = lastCubic { c1 = 2 * current - last }
                    let c2 = origin + Point2(x2, y2)
                    cubicTo(c1, c2, origin + Point2(x, y))
                    cubicControl = c2
                case UInt8(ascii: "q"):
                    guard let x1 = scanner.number(), let y1 = scanner.number(),
                          let x = scanner.number(), let y = scanner.number() else { break parsing }
                    let q = origin + Point2(x1, y1)
                    quadTo(q, origin + Point2(x, y))
                    quadControl = q
                case UInt8(ascii: "t"):
                    guard let x = scanner.number(), let y = scanner.number() else { break parsing }
                    var q = current
                    if let last = lastQuad { q = 2 * current - last }
                    quadTo(q, origin + Point2(x, y))
                    quadControl = q
                case UInt8(ascii: "a"):
                    guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                          let large = scanner.flag(), let sweep = scanner.flag(),
                          let x = scanner.number(), let y = scanner.number() else { break parsing }
                    arcTo(rx: rx, ry: ry, angle: angle, large: large, sweep: sweep, to: origin + Point2(x, y))
                default:
                    break parsing
                }
                lastCubic = cubicControl
                lastQuad = quadControl
            }
            finish()
        }

        mutating func moveTo(_ p: Point2) {
            finish()
            current = p
            start = p
        }

        mutating func lineTo(_ p: Point2) {
            let a = transform.apply(current), b = transform.apply(p)
            current = p
            addLine(a, b)
        }

        mutating func cubicTo(_ c1: Point2, _ c2: Point2, _ p: Point2) {
            let poles = [current, c1, c2, p].map { transform.apply($0) }
            current = p
            guard poles.allSatisfy({ VectorFiles.isFinite($0) }),
                  poles.contains(where: { !VectorFiles.same($0, poles[0]) }) else { return }
            // Gerade Kurven (Kontrollpunkte auf der Sehne) als Linie
            if VectorFiles.onSegment(poles[1], poles[0], poles[3]), VectorFiles.onSegment(poles[2], poles[0], poles[3]) {
                addLine(poles[0], poles[3])
                return
            }
            flushRun()
            // Ein geklemmter Kontrollpunkt-Spline mit 4 Polen ist genau diese kubische Bézierkurve
            pieces.append(.spline(points: poles, kind: .control, closed: false))
        }

        mutating func quadTo(_ q: Point2, _ p: Point2) {
            let p0 = current
            cubicTo(p0 + (2.0 / 3.0) * (q - p0), p + (2.0 / 3.0) * (q - p), p)
        }

        /// Elliptischer Bogen nach SVG (Endpunkt-Parameter, Umrechnung auf Mittelpunkt wie in SVG 1.1 F.6.5).
        mutating func arcTo(rx inputRX: Double, ry inputRY: Double, angle: Double, large: Bool, sweep: Bool, to p: Point2) {
            let p0 = current
            guard p0 != p else { return }
            var rx = abs(inputRX), ry = abs(inputRY)
            guard rx > 0, ry > 0, angle.isFinite else {
                lineTo(p)
                return
            }
            let phi = angle * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (p0.x - p.x) / 2, dy = (p0.y - p.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                rx *= lambda.squareRoot()
                ry *= lambda.squareRoot()
            }
            let rx2 = rx * rx, ry2 = ry * ry
            let numerator = rx2 * ry2 - rx2 * y1 * y1 - ry2 * x1 * x1
            let denominator = rx2 * y1 * y1 + ry2 * x1 * x1
            guard denominator > 0 else {
                lineTo(p)
                return
            }
            var factor = max(0, numerator / denominator).squareRoot()
            if large == sweep { factor = -factor }
            let cx1 = factor * rx * y1 / ry, cy1 = -factor * ry * x1 / rx
            let center = Point2(cosPhi * cx1 - sinPhi * cy1 + (p0.x + p.x) / 2,
                                sinPhi * cx1 + cosPhi * cy1 + (p0.y + p.y) / 2)
            let a = Point2((x1 - cx1) / rx, (y1 - cy1) / ry)
            let b = Point2((-x1 - cx1) / rx, (-y1 - cy1) / ry)
            let theta = atan2(a.y, a.x)
            var delta = atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
            if !sweep, delta > 0 { delta -= 2 * .pi }
            if sweep, delta < 0 { delta += 2 * .pi }
            let u = rx * Point2(cosPhi, sinPhi), v = ry * Point2(-sinPhi, cosPhi)
            let result = VectorFiles.conic(center: center, u: u, v: v, start: theta, sweep: delta, full: false,
                                           transform: transform, from: transform.apply(p0), to: transform.apply(p))
            current = p
            guard !result.isEmpty else { return }
            flushRun()
            pieces += result
        }

        /// Teilpfad schließen (Z): nur aus Linien = geschlossener Linienzug.
        mutating func close() {
            lineTo(start)
            let startPoint = transform.apply(start)
            if pieces.isEmpty, run.count >= 3, let first = run.first, let last = run.last,
               VectorFiles.same(first, startPoint), VectorFiles.same(last, startPoint) {
                if let entity = VectorFiles.polylineEntity(run, closed: true) { entities.append(entity) }
                run = []
            } else {
                flushRun()
            }
            entities += pieces
            pieces = []
            current = start
        }

        /// Offenen Teilpfad abschließen.
        mutating func finish() {
            flushRun()
            entities += pieces
            pieces = []
        }

        private mutating func addLine(_ a: Point2, _ b: Point2) {
            guard VectorFiles.isFinite(a), VectorFiles.isFinite(b), !VectorFiles.same(a, b) else { return }
            if let last = run.last, VectorFiles.same(last, a) {
                run.append(b)
            } else {
                flushRun()
                run = [a, b]
            }
        }

        private mutating func flushRun() {
            if let entity = VectorFiles.polylineEntity(run, closed: false) { pieces.append(entity) }
            run = []
        }
    }

    /// SAX-Leser: verfolgt die Transformationen der Gruppen und sammelt die Grundformen.
    fileprivate final class SVGReader: NSObject, XMLParserDelegate {
        var entities: [SketchEntity] = []
        var layers: [String] = []
        var skipped = 0
        var foundRoot = false
        /// Gesamttransformation je offenem Element
        private var stack: [VectorFiles.Affine] = []
        /// Tiefe innerhalb eines ignorierten Teilbaums (defs, Text, ausgeblendet …)
        private var hidden = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if hidden > 0 {
                hidden += 1
                return
            }
            let name = VectorFiles.localName(elementName)
            if !foundRoot {
                guard name == "svg" else {
                    hidden = 1
                    return
                }
                foundRoot = true
                stack.append(VectorFiles.svgViewport(attributeDict)
                    .concatenating(VectorFiles.svgTransform(attributeDict["transform"])))
                return
            }
            if VectorFiles.svgHidden(attributeDict) {
                hidden = 1
                return
            }
            let parent = stack.last ?? VectorFiles.Affine.identity
            let ctm = parent.concatenating(VectorFiles.svgTransform(attributeDict["transform"]))
            switch name {
            case "g", "a", "switch":
                if attributeDict["inkscape:groupmode"] == "layer",
                   let label = attributeDict["inkscape:label"] ?? attributeDict["id"], !layers.contains(label) {
                    layers.append(label)
                }
                stack.append(ctm)
            case "svg":
                let x = VectorFiles.svgLength(attributeDict["x"]) ?? 0, y = VectorFiles.svgLength(attributeDict["y"]) ?? 0
                stack.append(ctm.concatenating(.translation(x, y)))
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                entities += VectorFiles.svgShape(name, attributeDict, transform: ctm)
                stack.append(ctm)
            case "text", "image", "use", "flowRoot", "foreignObject":
                skipped += 1
                hidden = 1
            default:
                // defs, symbol, clipPath, mask, marker, pattern, style, title, Metadaten …
                hidden = 1
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            if hidden > 0 {
                hidden -= 1
                return
            }
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}

// MARK: SVG schreiben

extension VectorFiles {
    /// Pfaddaten in mm mit gespiegelter y-Achse; Bögen als A, Splines als exakte Bézierkurven.
    fileprivate struct SVGPathWriter {
        var d = ""
        private var current: Point2?

        private func xy(_ p: Point2) -> String { "\(VectorFiles.decimal(p.x)) \(VectorFiles.decimal(-p.y))" }

        private mutating func append(_ text: String) {
            if !d.isEmpty { d += " " }
            d += text
        }

        private mutating func move(_ p: Point2) {
            if let last = current, VectorFiles.same(last, p) { return }
            append("M " + xy(p))
            current = p
        }

        private mutating func line(_ p: Point2) {
            append("L " + xy(p))
            current = p
        }

        /// counterClockwise bezieht sich auf die Skizze (y nach oben); in SVG kehrt sich der Drehsinn um.
        private mutating func arcTo(rx: Double, ry: Double, large: Bool, counterClockwise: Bool, to p: Point2) {
            let flags = "0 \(large ? 1 : 0) \(counterClockwise ? 0 : 1)"
            append("A \(VectorFiles.decimal(rx)) \(VectorFiles.decimal(ry)) " + flags + " " + xy(p))
            current = p
        }

        private mutating func cubic(_ c1: Point2, _ c2: Point2, _ p: Point2) {
            append("C " + xy(c1) + " " + xy(c2) + " " + xy(p))
            current = p
        }

        private mutating func quad(_ q: Point2, _ p: Point2) {
            append("Q " + xy(q) + " " + xy(p))
            current = p
        }

        private mutating func close() {
            append("Z")
            current = nil
        }

        /// Bézierkette vom Grad 1 bis 3 ab dem aktuellen Punkt.
        private mutating func bezier(degree: Int, poles: [Point2]) {
            switch degree {
            case 3 where poles.count >= 4:
                for k in stride(from: 0, to: poles.count - 3, by: 3) { cubic(poles[k + 1], poles[k + 2], poles[k + 3]) }
            case 2 where poles.count >= 3:
                for k in stride(from: 0, to: poles.count - 2, by: 2) { quad(poles[k + 1], poles[k + 2]) }
            default:
                for p in poles.dropFirst() { line(p) }
            }
        }

        mutating func add(_ segment: SketchSegment) {
            move(segment.start)
            switch segment {
            case .line(_, let b):
                line(b)
            case .arc(let a, let m, let b):
                guard let arc = VectorFiles.arcGeometry(a, m, b) else {
                    line(b)
                    return
                }
                let ccw = arc.sweep > 0
                if abs(arc.sweep) > .pi {
                    // Über 180° in zwei Hälften, damit das Flag für den großen Bogen eindeutig bleibt
                    let angle = arc.start + arc.sweep / 2
                    let half = arc.center + arc.radius * Point2(cos(angle), sin(angle))
                    arcTo(rx: arc.radius, ry: arc.radius, large: false, counterClockwise: ccw, to: half)
                }
                arcTo(rx: arc.radius, ry: arc.radius, large: false, counterClockwise: ccw, to: b)
            case .bezier(let poles):
                bezier(degree: 3, poles: poles)
            case .bspline(let poles):
                let converted = VectorFiles.bezierPoles(clamped: poles)
                bezier(degree: converted.degree, poles: converted.poles)
            }
        }

        mutating func add(_ loop: SketchLoop) {
            current = nil
            switch loop {
            case .chain(let segments):
                guard let first = segments.first else { return }
                move(first.start)
                for segment in segments { add(segment) }
                close()
            case .circle(let c, let r):
                guard r > 0 else { return }
                move(c + Point2(r, 0))
                arcTo(rx: r, ry: r, large: false, counterClockwise: true, to: c - Point2(r, 0))
                arcTo(rx: r, ry: r, large: false, counterClockwise: true, to: c + Point2(r, 0))
                close()
            case .ellipse(let c, let radii):
                let rx = abs(radii.x), ry = abs(radii.y)
                guard rx > 0, ry > 0 else { return }
                move(c + Point2(rx, 0))
                arcTo(rx: rx, ry: ry, large: false, counterClockwise: true, to: c - Point2(rx, 0))
                arcTo(rx: rx, ry: ry, large: false, counterClockwise: true, to: c + Point2(rx, 0))
                close()
            case .periodic(let poles):
                if let converted = VectorFiles.bezierPoles(periodic: poles), let first = converted.poles.first {
                    move(first)
                    bezier(degree: converted.degree, poles: converted.poles)
                } else {
                    let polygon = loop.polygon
                    guard let first = polygon.first else { return }
                    move(first)
                    for p in polygon.dropFirst() { line(p) }
                }
                close()
            }
        }
    }
}
