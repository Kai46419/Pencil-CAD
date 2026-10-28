import Combine
import Foundation
import simd

// Formgenerator (Kai, Punkt 7): fertige Formen aus einer Bibliothek – Dreiecke, Sterne, Polygone, Herz, Zahnrad,
// Wabe, Schraubenkopf, Kabelclip … – und eigene, gespeicherte Formen. Gezeichnet wird mit dem Ablauf des
// Polygons (Mitte antippen bzw. aufsetzen, dann Größe und Drehung ziehen). Ergebnis sind gewöhnliche
// Skizzenlinien, -bögen und -kreise, die sich wie jede Kontur extrudieren lassen.

/// Formen der Bibliothek. Alle sind um den Ursprung gebaut, „oben“ zeigt nach +y, Größe = Durchmesser des Umkreises.
enum ShapeKind: String, CaseIterable, Identifiable, Codable {
    case triangle = "Dreieck"
    case rightTriangle = "Rechtwinkliges Dreieck"
    case triforce = "Triforce"
    case triangleGrid = "Dreiecksgitter"
    case star = "Stern"
    case polygon = "Vieleck"
    case diamond = "Raute"
    case arrow = "Pfeil"
    case heart = "Herz"
    case plus = "Kreuz"
    case ring = "Ring"
    case slot = "Langloch"
    case gear = "Zahnrad"
    case honeycomb = "Wabe"
    case hexHead = "Sechskant mit Bohrung"
    case cableClip = "Kabelclip"
    case teardrop = "Tropfen"
    case keyhole = "Schlüsselloch"

    var id: Self { self }

    /// Bedeutung des Zahlenwerts (nil = Form hat keinen)
    var countTitle: String? {
        switch self {
        case .star: "Zacken"
        case .polygon: "Ecken"
        case .gear: "Zähne"
        case .triangleGrid: "Teilung"
        case .honeycomb: "Ringe"
        default: nil
        }
    }

    var countRange: ClosedRange<Int> {
        switch self {
        case .star: 3...24
        case .polygon: 3...12
        case .gear: 6...60
        case .triangleGrid: 2...8
        case .honeycomb: 1...5
        default: 1...1
        }
    }

    /// Bedeutung des Verhältnisses (Anteil am Außenradius; nil = Form hat keins)
    var innerTitle: String? {
        switch self {
        case .star: "Innenradius"
        case .ring, .cableClip: "Innenradius"
        case .gear: "Fußkreis"
        case .diamond: "Breite"
        case .arrow: "Schaftbreite"
        case .plus: "Balkenbreite"
        case .slot: "Breite"
        case .honeycomb: "Zellgröße"
        case .hexHead: "Bohrung"
        case .keyhole: "Schlitzbreite"
        default: nil
        }
    }

    /// Erlaubtes Verhältnis (in Prozent des Außenradius)
    var innerRange: ClosedRange<Double> {
        switch self {
        case .honeycomb: 0.3...0.98
        case .gear: 0.5...0.95
        case .hexHead: 0.1...0.8
        case .keyhole: 0.1...0.9
        default: 0.05...0.95
        }
    }
}

/// Kachel der Bibliothek: Form mit Voreinstellung (z. B. Stern 5, Stern 6, Oktogramm).
struct ShapePreset: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: ShapeKind
    var count: Int = 1
    var inner: Double = 0.5
    var rotation: Double = 0

    static let all: [ShapePreset] = [
        ShapePreset(id: "triangle", title: "Dreieck", kind: .triangle),
        ShapePreset(id: "rightTriangle", title: "Rechtwinklig", kind: .rightTriangle),
        ShapePreset(id: "triforce", title: "Triforce", kind: .triforce),
        ShapePreset(id: "triangleGrid", title: "Dreiecksgitter", kind: .triangleGrid, count: 3),
        ShapePreset(id: "star5", title: "Stern 5", kind: .star, count: 5, inner: 0.4),
        ShapePreset(id: "star6", title: "Stern 6", kind: .star, count: 6, inner: 0.58),
        ShapePreset(id: "octagram", title: "Oktogramm", kind: .star, count: 8, inner: 0.65),
        ShapePreset(id: "polygon", title: "Vieleck", kind: .polygon, count: 6),
        ShapePreset(id: "diamond", title: "Raute", kind: .diamond, inner: 0.6),
        ShapePreset(id: "arrow", title: "Pfeil", kind: .arrow, inner: 0.45),
        ShapePreset(id: "heart", title: "Herz", kind: .heart),
        ShapePreset(id: "plus", title: "Plus", kind: .plus, inner: 0.35),
        ShapePreset(id: "cross", title: "Kreuz (X)", kind: .plus, inner: 0.35, rotation: 45),
        ShapePreset(id: "ring", title: "Ring", kind: .ring, inner: 0.6),
        ShapePreset(id: "slot", title: "Langloch", kind: .slot, inner: 0.4),
        ShapePreset(id: "gear", title: "Zahnrad", kind: .gear, count: 12, inner: 0.8),
        ShapePreset(id: "honeycomb", title: "Wabe", kind: .honeycomb, count: 2, inner: 0.85),
        ShapePreset(id: "hexHead", title: "Sechskant", kind: .hexHead, inner: 0.5),
        ShapePreset(id: "cableClip", title: "Kabelclip", kind: .cableClip, inner: 0.7),
        ShapePreset(id: "teardrop", title: "Tropfen", kind: .teardrop),
        ShapePreset(id: "keyhole", title: "Schlüsselloch", kind: .keyhole, inner: 0.45),
    ]
}

/// Gewählte Form: aus der Bibliothek oder eine eigene (gespeicherte) Form.
enum ShapeChoice: Hashable {
    case builtIn(ShapeKind)
    case custom(UUID)
}

/// Werte der Form (rechts im Fenster einstellbar). Größe und Drehung kommen beim Aufziehen vom Stift.
struct ShapeParameters: Equatable {
    /// Durchmesser des Umkreises (mm)
    var size: Double = 20
    /// Zacken, Ecken, Zähne, Teilung bzw. Ringe
    var count: Int = 5
    /// Innenradius, Breite usw. als Anteil des Außenradius (0…1)
    var inner: Double = 0.5
    /// Drehung in Grad (gegen den Uhrzeigersinn, 0 = „oben“ zeigt nach oben)
    var rotation: Double = 0
}

/// Zuletzt gesetzte Form: Werteänderungen rechts zeichnen sie neu, solange danach nichts anderes geschah.
struct ShapePlacement {
    var center: Point2
    var range: Range<Int>
    var fingerprint: [Point2]
    var constraintCount: Int
    /// Stand des Rückgängig-Stapels nach dem Setzen (auch Änderungen ohne neue Punkte, z. B. Konstruktion, zählen)
    var undoRevision: Int
}

/// Zustand des Formgenerators im Skizzen-Controller (`SketchController.generatedShape`).
struct GeneratedShape {
    var choice: ShapeChoice
    /// Kachel, die zuletzt gewählt wurde (Markierung in der Bibliothek)
    var presetID: String?
    var params = ShapeParameters()
    var placement: ShapePlacement?

    static let standard = GeneratedShape(choice: .builtIn(.star), presetID: "star5",
                                         params: ShapeParameters(size: 20, count: 5, inner: 0.4, rotation: 0))

    var kind: ShapeKind? {
        if case .builtIn(let kind) = choice { return kind }
        return nil
    }

    var customID: UUID? {
        if case .custom(let id) = choice { return id }
        return nil
    }

    /// Name für Leiste und Fenster
    @MainActor var title: String {
        switch choice {
        case .builtIn(let kind):
            return ShapePreset.all.first { $0.id == presetID }?.title ?? kind.rawValue
        case .custom(let id):
            return ShapeLibrary.shared.custom.first { $0.id == id }?.name ?? "Eigene Form"
        }
    }
}

// MARK: Eigene Formen

/// Eigene Form: normierte Skizzenelemente (Mitte im Ursprung, Umkreisradius 1).
struct CustomShape: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var entities: [SketchEntity]
    var created = Date()

    static func == (a: CustomShape, b: CustomShape) -> Bool {
        a.id == b.id && a.name == b.name && a.entities.count == b.entities.count
    }
}

/// Bibliothek der eigenen Formen, dauerhaft als JSON in Application Support (`PencilCAD/eigene-formen.json`).
@MainActor
final class ShapeLibrary: ObservableObject {
    static let shared = ShapeLibrary()

    @Published private(set) var custom: [CustomShape] = []
    /// Zuletzt benutzte Form (die Kachel „Formen“ nimmt sie wieder auf; nur für diese Sitzung)
    var lastShape: GeneratedShape?

    private init() {
        load()
    }

    private static var fileURL: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let folder = base.appendingPathComponent("PencilCAD", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("eigene-formen.json")
    }

    private func load() {
        guard let url = Self.fileURL, let data = try? Data(contentsOf: url),
              let shapes = try? JSONDecoder().decode([CustomShape].self, from: data) else { return }
        custom = shapes
    }

    private func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(custom) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Elemente als eigene Form speichern (Text wird ausgelassen). nil, wenn nichts Zeichenbares übrig bleibt.
    @discardableResult
    func add(name: String, entities: [SketchEntity]) -> CustomShape? {
        guard let normalized = ShapeGeometry.normalized(entities) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = CustomShape(name: trimmed.isEmpty ? "Form \(custom.count + 1)" : trimmed, entities: normalized)
        custom.append(shape)
        save()
        return shape
    }

    func remove(_ id: UUID) {
        custom.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[index].name = trimmed
        save()
    }

    func shape(_ id: UUID) -> CustomShape? {
        custom.first { $0.id == id }
    }
}

// MARK: Geometrie

enum ShapeGeometry {
    /// Elemente der Form mit Umkreisradius radius um den Ursprung, „oben“ = +y (noch nicht gedreht/verschoben).
    static func entities(_ kind: ShapeKind, radius r: Double, count: Int, inner: Double) -> [SketchEntity] {
        guard r > 1e-9 else { return [] }
        let k = min(max(count, kind.countRange.lowerBound), kind.countRange.upperBound)
        let q = min(max(inner, kind.innerRange.lowerBound), kind.innerRange.upperBound)
        switch kind {
        case .triangle:
            return closed(regular(3, radius: r, start: .pi / 2))
        case .rightTriangle:
            let a = r / sqrt(2)
            return closed([Point2(-a, -a), Point2(a, -a), Point2(-a, a)])
        case .triforce:
            return triforce(r)
        case .triangleGrid:
            return triangleGrid(r, divisions: k)
        case .star:
            var points: [Point2] = []
            for i in 0..<(2 * k) {
                let angle = .pi / 2 + Double(i) * .pi / Double(k)
                let radius = i % 2 == 0 ? r : r * q
                points.append(radius * Point2(cos(angle), sin(angle)))
            }
            return closed(points)
        case .polygon:
            // Gerade Eckenzahl: Kante unten waagerecht, ungerade: Spitze oben
            let start: Double = k % 2 == 0 ? .pi / 2 + .pi / Double(k) : .pi / 2
            return closed(regular(k, radius: r, start: start))
        case .diamond:
            return closed([Point2(0, r), Point2(-r * q, 0), Point2(0, -r), Point2(r * q, 0)])
        case .arrow:
            return arrow(r, shaft: q)
        case .heart:
            return heart(r)
        case .plus:
            let w = r * q / 2
            let points: [Point2] = [
                Point2(w, w), Point2(w, r), Point2(-w, r), Point2(-w, w), Point2(-r, w), Point2(-r, -w),
                Point2(-w, -w), Point2(-w, -r), Point2(w, -r), Point2(w, -w), Point2(r, -w), Point2(r, w),
            ]
            return closed(points)
        case .ring:
            return [.circle(center: .zero, radius: r), .circle(center: .zero, radius: r * q)]
        case .slot:
            // Länge = Größe, Breite = Anteil davon; senkrecht („oben“ = Längsrichtung)
            let half = r * q / 2
            let c = max(r - half, 1e-6)
            return SketchShapes.slot(Point2(0, -c), Point2(0, c), half: half) ?? []
        case .gear:
            return gear(r, teeth: k, root: q)
        case .honeycomb:
            return honeycomb(r, rings: k, cell: q)
        case .hexHead:
            let hexagon = closed(regular(6, radius: r, start: 0))
            return hexagon + [.circle(center: .zero, radius: r * cos(.pi / 6) * q)]
        case .cableClip:
            return cableClip(r, inner: q)
        case .teardrop:
            return teardrop(r)
        case .keyhole:
            return keyhole(r, slot: q)
        }
    }

    /// Fertige Elemente der gewählten Form an center, gedreht und skaliert (nil = Form nicht verfügbar).
    @MainActor
    static func placed(_ shape: GeneratedShape, center: Point2) -> [SketchEntity] {
        let radius = max(shape.params.size, 1e-6) / 2
        let rotation = shape.params.rotation * .pi / 180
        switch shape.choice {
        case .builtIn(let kind):
            let local = entities(kind, radius: radius, count: shape.params.count, inner: shape.params.inner)
            return local.compactMap { transformed($0, scale: 1, rotation: rotation, offset: center) }
        case .custom(let id):
            guard let custom = ShapeLibrary.shared.shape(id) else { return [] }
            return custom.entities.compactMap { transformed($0, scale: radius, rotation: rotation, offset: center) }
        }
    }

    /// Vorschau für die Kacheln: Polylinien mit Umkreisradius 1 (Drehung der Voreinstellung eingerechnet).
    static func previewLines(_ preset: ShapePreset) -> [[Point2]] {
        let local = entities(preset.kind, radius: 1, count: preset.count, inner: preset.inner)
        let rotation = preset.rotation * .pi / 180
        return local.compactMap { transformed($0, scale: 1, rotation: rotation, offset: .zero) }.flatMap(\.drawing)
    }

    static func previewLines(_ custom: CustomShape) -> [[Point2]] {
        custom.entities.flatMap(\.drawing)
    }

    // MARK: Einzelne Formen

    private static func regular(_ n: Int, radius r: Double, start: Double) -> [Point2] {
        (0..<max(n, 3)).map { i -> Point2 in
            let angle = start + Double(i) * 2 * .pi / Double(max(n, 3))
            return r * Point2(cos(angle), sin(angle))
        }
    }

    /// Geschlossener Linienzug als einzelne Linien (Enden fallen exakt zusammen).
    private static func closed(_ points: [Point2]) -> [SketchEntity] {
        guard points.count >= 3 else { return [] }
        return points.indices.map { i in .line(points[i], points[(i + 1) % points.count]) }
    }

    /// Drei Dreiecke im großen Dreieck: Außenkanten in Hälften, dazu das umgedrehte Mitteldreieck.
    private static func triforce(_ r: Double) -> [SketchEntity] {
        let c = regular(3, radius: r, start: .pi / 2)
        let m = [(c[0] + c[1]) / 2, (c[1] + c[2]) / 2, (c[2] + c[0]) / 2]
        return [
            .line(c[0], m[0]), .line(m[0], c[1]), .line(c[1], m[1]), .line(m[1], c[2]), .line(c[2], m[2]),
            .line(m[2], c[0]), .line(m[0], m[1]), .line(m[1], m[2]), .line(m[2], m[0]),
        ]
    }

    /// Gleichseitiges Dreieck in n × n kleine Dreiecke geteilt; jede Gitterkante genau einmal.
    private static func triangleGrid(_ r: Double, divisions n: Int) -> [SketchEntity] {
        let c = regular(3, radius: r, start: .pi / 2)
        // Knoten (i, j) mit i + j ≤ n: c[1] + i/n·(c[2] − c[1]) + j/n·(c[0] − c[1])
        func node(_ i: Int, _ j: Int) -> Point2 {
            c[1] + Double(i) / Double(n) * (c[2] - c[1]) + Double(j) / Double(n) * (c[0] - c[1])
        }
        var result: [SketchEntity] = []
        for i in 0...n {
            for j in 0...(n - i) {
                if i + j + 1 <= n {
                    result.append(.line(node(i, j), node(i + 1, j)))
                    result.append(.line(node(i, j), node(i, j + 1)))
                    result.append(.line(node(i + 1, j), node(i, j + 1)))
                }
            }
        }
        return result
    }

    /// Pfeil nach oben: Spitze bei +r, Schaft bis −r; shaft = Schaftbreite im Verhältnis zur Kopfbreite.
    private static func arrow(_ r: Double, shaft: Double) -> [SketchEntity] {
        let head = r * 0.7
        let neck = r - head * 1.1
        let w = head * shaft
        return closed([
            Point2(0, r), Point2(-head, neck), Point2(-w, neck), Point2(-w, -r),
            Point2(w, -r), Point2(w, neck), Point2(head, neck),
        ])
    }

    /// Herz aus einem auf die Spitze gestellten Quadrat und zwei Halbkreisen auf den oberen Kanten.
    private static func heart(_ r: Double) -> [SketchEntity] {
        let k = (1 + sqrt(2)) / 2      // halbe Breite bzw. Oberkante je d
        // Weitester Punkt der Bögen liegt ≈ 1,345·d von der Mitte
        let d = r / 1.35
        let shift = Point2(0, -(k - 1) * d / 2)
        let bottom = Point2(0, -d) + shift
        let right = Point2(d, 0) + shift, top = Point2(0, d) + shift, left = Point2(-d, 0) + shift
        return [
            .line(bottom, right),
            .arc(start: right, mid: Point2(d, d) + shift, end: top),
            .arc(start: top, mid: Point2(-d, d) + shift, end: left),
            .line(left, bottom),
        ]
    }

    /// Zahnrad mit trapezförmigen Zähnen (Kopfkreis r, Fußkreis root·r).
    private static func gear(_ r: Double, teeth n: Int, root: Double) -> [SketchEntity] {
        let pitch = 2 * .pi / Double(n)
        let rootR = r * root
        var points: [Point2] = []
        for i in 0..<n {
            let a = .pi / 2 + Double(i) * pitch
            // Fußlücke 50 %, Flanken je 12,5 %, Kopf 25 % der Teilung
            let angles = [a - pitch * 0.25, a - pitch * 0.125, a + pitch * 0.125, a + pitch * 0.25]
            let radii = [rootR, r, r, rootR]
            for (angle, radius) in zip(angles, radii) {
                points.append(radius * Point2(cos(angle), sin(angle)))
            }
        }
        return closed(points)
    }

    /// Sechseckwaben: getrennte Sechsecke (Taschen) in rings Ringen um die Mitte.
    private static func honeycomb(_ r: Double, rings: Int, cell: Double) -> [SketchEntity] {
        let m = Double(rings - 1)
        let s = r / (sqrt(3) * m + 1)
        var result: [SketchEntity] = []
        let n = rings - 1
        for q in -n...n {
            for rr in max(-n, -q - n)...min(n, -q + n) {
                let center = Point2(s * sqrt(3) * (Double(q) + Double(rr) / 2), s * 1.5 * Double(rr))
                let corners = regular(6, radius: s * cell, start: .pi / 2).map { $0 + center }
                result += closed(corners)
            }
        }
        return result
    }

    /// Kabelclip: C-Profil, oben offen (Öffnung etwas schmaler als der Innendurchmesser zum Einrasten).
    private static func cableClip(_ r: Double, inner: Double) -> [SketchEntity] {
        let ri = r * inner
        let open = 0.7 * .pi / 2   // halber Öffnungswinkel 63° (Öffnung ≈ 0,89 × Innendurchmesser)
        func point(_ radius: Double, _ angle: Double) -> Point2 { radius * Point2(cos(angle), sin(angle)) }
        let a0 = .pi / 2 + open, a1 = .pi / 2 - open + 2 * .pi
        let mid = (a0 + a1) / 2
        return [
            .arc(start: point(r, a0), mid: point(r, mid), end: point(r, a1)),
            .line(point(r, a1), point(ri, a1)),
            .arc(start: point(ri, a1), mid: point(ri, mid), end: point(ri, a0)),
            .line(point(ri, a0), point(r, a0)),
        ]
    }

    /// Tropfen (3D-Druck: waagerechte Bohrung ohne Stützen), Spitze oben mit 45°-Flanken.
    private static func teardrop(_ r: Double) -> [SketchEntity] {
        // Kreis ρ, Spitze bei ρ·√2; Höhe ρ(1 + √2) → mittig verschieben
        let rho = r / ((1 + sqrt(2)) / 2 + 0.05)
        let shift = Point2(0, -(sqrt(2) - 1) * rho / 2)
        let tip = Point2(0, rho * sqrt(2)) + shift
        let a = rho / sqrt(2)
        let right = Point2(a, a) + shift, left = Point2(-a, a) + shift
        return [
            .line(tip, left),
            .arc(start: left, mid: Point2(0, -rho) + shift, end: right),
            .line(right, tip),
        ]
    }

    /// Schlüsselloch zum Aufhängen: großer Kreis oben, schmaler Schlitz mit runder Unterkante.
    private static func keyhole(_ r: Double, slot: Double) -> [SketchEntity] {
        let a = 0.42 * r
        let cy = r - a
        let w = a * slot
        let y0 = cy - sqrt(max(a * a - w * w, 0))
        let bottomCenter = -r + w
        return [
            .arc(start: Point2(w, y0), mid: Point2(0, cy + a), end: Point2(-w, y0)),
            .line(Point2(-w, y0), Point2(-w, bottomCenter)),
            .arc(start: Point2(-w, bottomCenter), mid: Point2(0, -r), end: Point2(w, bottomCenter)),
            .line(Point2(w, bottomCenter), Point2(w, y0)),
        ]
    }

    // MARK: Abbildung

    /// Element skaliert (um den Ursprung), gedreht und verschoben. nil = nicht übertragbar (Text).
    static func transformed(_ entity: SketchEntity, scale s: Double, rotation: Double, offset: Point2) -> SketchEntity? {
        let c = cos(rotation), sn = sin(rotation)
        func f(_ p: Point2) -> Point2 {
            let v = p * s
            return offset + Point2(c * v.x - sn * v.y, sn * v.x + c * v.y)
        }
        let unrotated = abs(remainder(rotation, 2 * .pi)) < 1e-9
        switch entity {
        case .line(let a, let b):
            return .line(f(a), f(b))
        case .arc(let a, let m, let b):
            return .arc(start: f(a), mid: f(m), end: f(b))
        case .circle(let center, let radius):
            return .circle(center: f(center), radius: radius * s)
        case .point(let p):
            return .point(f(p))
        case .polyline(let points, let isClosed):
            return .polyline(points.map(f), closed: isClosed)
        case .spline(let points, let kind, let isClosed, let tangents):
            return .spline(points: points.map(f), kind: kind, closed: isClosed,
                           tangents: SketchEntity.mappedTangents(tangents, points: points, f))
        case .regularPolygon(let center, let radius, let sides, let angle):
            return .regularPolygon(center: f(center), radius: radius * s, sides: sides, angle: angle + rotation)
        case .rectangle(let corner, let size):
            if unrotated { return .rectangle(corner: f(corner), size: size * s) }
            let corners = [corner, corner + Point2(size.x, 0), corner + size, corner + Point2(0, size.y)]
            return .polyline(corners.map(f), closed: true)
        case .ellipse(let center, let radii):
            if unrotated { return .ellipse(center: f(center), radii: radii * s) }
            let samples = (0..<36).map { k -> Point2 in
                let t = Double(k) / 36 * 2 * .pi
                return f(center + Point2(radii.x * cos(t), radii.y * sin(t)))
            }
            return .spline(points: samples, kind: .fit, closed: true)
        case .text:
            return nil
        }
    }

    /// Elemente für die Bibliothek normieren: Mitte des Umgrenzungsrechtecks in den Ursprung, größter Abstand 1.
    static func normalized(_ entities: [SketchEntity]) -> [SketchEntity]? {
        let usable = entities.filter { if case .text = $0 { return false } else { return true } }
        let points = usable.flatMap(\.drawing).flatMap { $0 }
        guard let first = points.first else { return nil }
        var lo = first, hi = first
        for p in points {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        let center = (lo + hi) / 2
        let reach = points.map { simd_distance($0, center) }.max() ?? 0
        guard reach > 1e-9 else { return nil }
        let moved = usable.compactMap { transformed($0, scale: 1, rotation: 0, offset: -center) }
        let result = moved.compactMap { transformed($0, scale: 1 / reach, rotation: 0, offset: .zero) }
        return result.isEmpty ? nil : result
    }
}
