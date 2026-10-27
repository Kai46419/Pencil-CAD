import Foundation
import simd

// Text verformen wie in Illustrator („Frei transformieren“, „Verkrümmen“, „Text auf Pfad“) bzw. CorelDRAW
// („Hülle“, „Text an Pfad anpassen“). Kai: „Ich möchte auch mal Schriften erstellen, die halbrund sind, am Bogen
// ausgerichtet, oder ich möchte sie perspektivisch hin- und herschieben können.“
//
// Die Verformung ist parametrisch am Text gespeichert (SketchText.deform) und wirkt im System des Texts (Grundlinie
// = x-Achse, mm), bevor der Text in die Skizze gelegt wird (SketchText.place). Reihenfolge je Punkt:
//   Breite/Höhe (stretch, shift) → Hülle (Vorlage) → Verzerren/Perspektive (Vierpunkt-Abbildung des Rahmens)
//   bzw. statt Hülle und Perspektive: am Pfad ausrichten.
// Das Ergebnis sind echte Umrisse (Linien und Bézierketten), die Extrudieren und Textkörper wie jede Kontur nutzen.
// Gekrümmte Abbildungen tasten jede Kurve fein ab (kurze kubische Stücke, deren Pole abgebildet werden), damit
// Biegungen glatt bleiben. Griffe und Ziehen: SketchTextDeformHandles.swift, Leiste: SketchTextDeformPanel.swift.

extension SketchText {
    /// System des Texts (Grundlinie = x-Achse, mm) → Skizze: Anker, Drehung und Lage aus den Griffen.
    func place(_ p: Point2) -> Point2 { placed(p) }

    /// Skizze → System des Texts (Umkehrung von place).
    func unplace(_ q: Point2) -> Point2 { local(q) }
}

/// Umrisse eines Zeichens im System des Texts.
struct SketchTextGlyph {
    var loops: [SketchLoop]
    /// Anfang auf der Grundlinie (mm)
    var x: Double
    /// Vorschub (Breite des Zeichens inkl. Abstand, mm)
    var advance: Double
}

/// Vorlagen für die Hülle (vgl. Illustrator „Verkrümmen“-Stile).
enum SketchTextWarpStyle: String, Codable, CaseIterable, Identifiable {
    case arc = "Bogen"
    case arcLower = "Bogen unten"
    case arcUpper = "Bogen oben"
    case bulge = "Wölben"
    case wave = "Welle"
    case flag = "Flagge"
    case rise = "Ansteigen"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .arc: "rainbow"
        case .arcLower: "arrow.down.right.and.arrow.up.left"
        case .arcUpper: "arrow.up.left.and.arrow.down.right"
        case .bulge: "circle.dashed"
        case .wave: "water.waves"
        case .flag: "flag"
        case .rise: "chart.line.uptrend.xyaxis"
        }
    }
}

/// Hülle aus einer Vorlage mit Stärke −1…1 (negativ = Gegenrichtung).
struct SketchTextWarp: Codable, Equatable {
    var style: SketchTextWarpStyle
    var bend: Double
}

/// Text am Pfad: Buchstaben folgen einer Kurve der Skizze bzw. einer projizierten Körperkante.
struct SketchTextPath: Codable, Equatable {
    /// Kurve als fein abgetasteter Linienzug in Skizzenkoordinaten (Stand der Quelle beim letzten Abgleich)
    var points: [Point2]
    var closed: Bool
    /// Skizzenelement, dem der Pfad folgt (nil = feste Kurve, z. B. Körperkante)
    var source: Int?
    /// Anzahl der Skizzenelemente beim letzten Abgleich: sind es weniger geworden, kann source auf ein anderes
    /// Element zeigen (dann folgt der Text nicht mehr)
    var sourceCount: Int?
    /// Startversatz entlang des Pfads (mm, Startgriff)
    var offset: Double = 0
    /// Text unterhalb des Pfads (sonst darauf)
    var below: Bool = false
    /// Abstand zum Pfad (mm)
    var distance: Double = 0
    var alignment: TextAlignmentOption = .left
    /// Laufrichtung umgekehrt (Text auf die andere Seite bzw. von rechts nach links)
    var reversed: Bool = false
    /// „Kontur folgen“: Buchstaben verbiegen sich mit der Kurve (sonst nur gedreht)
    var bends: Bool = false
}

/// Verformung eines Texts. Alle Maße in mm im System des Texts.
struct SketchTextDeform: Codable, Equatable {
    /// Breite/Höhe des Rahmens als Faktor der natürlichen Größe (Seitenmitten-Griffe)
    var stretch: Point2 = Point2(1, 1)
    /// Verschiebung der linken unteren Rahmenecke (Ziehen links bzw. unten hält die Gegenseite fest)
    var shift: Point2 = .zero
    /// Verzerren: x-Versatz je mm Höhe, y-Versatz je mm Breite
    var shear: Point2 = .zero
    /// Perspektive: Versatz der Rahmenecken links unten, rechts unten, rechts oben, links oben
    var corners: [Point2]?
    /// Hülle aus einer Vorlage
    var warp: SketchTextWarp?
    /// Am Pfad ausrichten (ersetzt Hülle und Perspektive)
    var path: SketchTextPath?

    init() {}

    /// Keine Wirkung: dann speichert der Text keine Verformung.
    var isIdentity: Bool {
        let neutralCorners = corners.map { $0.allSatisfy { simd_length($0) < 1e-9 } } ?? true
        let neutralWarp = warp.map { abs($0.bend) < 1e-9 } ?? true
        return simd_distance(stretch, Point2(1, 1)) < 1e-12 && simd_length(shift) < 1e-12
            && simd_length(shear) < 1e-12 && neutralCorners && neutralWarp && path == nil
    }

    /// Ecken der Perspektive immer als vier Werte.
    var cornerOffsets: [Point2] {
        guard let corners, corners.count == 4 else { return Array(repeating: .zero, count: 4) }
        return corners
    }

    /// Hat eine Perspektive (mindestens eine verschobene Ecke).
    var hasPerspective: Bool { cornerOffsets.contains { simd_length($0) > 1e-9 } }

    /// Maße mit factor skaliert (Text größer/kleiner). about: Mitte der Skalierung in Skizzenkoordinaten für den
    /// Pfad (nil = Pfad bleibt, nur die Höhe des Texts ändert sich).
    func scaled(by factor: Double, about center: Point2?) -> SketchTextDeform {
        var result = self
        result.shift = shift * factor
        result.corners = corners?.map { $0 * factor }
        if var path = result.path {
            path.distance *= factor
            if let center {
                path.points = path.points.map { center + ($0 - center) * factor }
                path.offset *= factor
            }
            result.path = path
        }
        return result
    }

    // MARK: Abbilden

    /// Umrisse der Zeichen verformt (im System des Texts). toLocal: Skizze → System des Texts (für den Pfad).
    func shaped(_ glyphs: [SketchTextGlyph], height: Double, toLocal: (Point2) -> Point2) -> [SketchLoop] {
        guard let frame = SketchTextBox(glyphs) else { return glyphs.flatMap(\.loops) }
        let deformer = SketchTextDeformMap(deform: self, frame: frame, capHeight: height)
        // Feinheit der Abtastung: ein Sechzehntel der Schrifthöhe, höchstens 0,5 mm
        let piece: Double = min(max(height / 16, 0.02), 0.5)
        if let path, let curve = SketchTextPathCurve(path, toLocal: toLocal, step: piece) {
            return deformer.alongPath(glyphs, curve: curve, options: path, piece: piece)
        }
        if deformer.isAffine {
            return glyphs.flatMap(\.loops).map { loop in loop.mapped { p in deformer.point(p) } }
        }
        // Perspektive allein bildet Geraden auf Geraden ab, nur Kurven werden fein unterteilt
        let keepsLines: Bool = warp == nil || abs(warp?.bend ?? 0) < 1e-9
        return glyphs.flatMap(\.loops).map { loop in
            loop.subdivided(piece: piece, keepsLines: keepsLines) { p in deformer.point(p) }
        }
    }
}

/// Natürlicher Rahmen der Buchstaben (umgebendes Rechteck im System des Texts).
struct SketchTextBox {
    var lo: Point2
    var hi: Point2

    init(lo: Point2, hi: Point2) {
        self.lo = lo
        self.hi = hi
    }

    init?(_ glyphs: [SketchTextGlyph]) {
        let points: [Point2] = glyphs.flatMap { $0.loops.flatMap(\.polygon) }
        guard let first = points.first else { return nil }
        lo = points.reduce(first) { simd_min($0, $1) }
        hi = points.reduce(first) { simd_max($0, $1) }
        // Nie ganz flach (z. B. nur „-“): Mindestmaß, damit Teilungen definiert sind
        if hi.x - lo.x < 1e-6 { hi.x = lo.x + 1e-6 }
        if hi.y - lo.y < 1e-6 { hi.y = lo.y + 1e-6 }
    }

    var size: Point2 { hi - lo }
}

/// Abbildung der Verformung für einen Text mit bekanntem Rahmen.
struct SketchTextDeformMap {
    let deform: SketchTextDeform
    /// Natürlicher Rahmen
    let frame: SketchTextBox
    /// Gestreckter Rahmen (Breite/Höhe angewandt)
    let stretched: SketchTextBox
    /// Grundlinie im gestreckten Rahmen
    let baseline: Double
    /// Rahmenecken nach Verzerren und Perspektive (links unten, rechts unten, rechts oben, links oben)
    let quad: [Point2]
    private let projective: SketchQuadMap

    init(deform: SketchTextDeform, frame: SketchTextBox, capHeight: Double) {
        self.deform = deform
        self.frame = frame
        let lo: Point2 = frame.lo + deform.shift
        let size: Point2 = frame.size * simd_max(deform.stretch, Point2(1e-3, 1e-3))
        stretched = SketchTextBox(lo: lo, hi: lo + size)
        baseline = frame.lo.y + (0 - frame.lo.y) * deform.stretch.y + deform.shift.y
        let shear = deform.shear
        let base: [Point2] = [
            lo,
            lo + Point2(size.x, shear.y * size.x),
            lo + Point2(size.x + shear.x * size.y, size.y + shear.y * size.x),
            lo + Point2(shear.x * size.y, size.y),
        ]
        let offsets = deform.cornerOffsets
        quad = (0..<4).map { base[$0] + offsets[$0] }
        projective = SketchQuadMap(quad)
    }

    /// Nur Breite/Höhe/Verzerren (Geraden bleiben Geraden, Kurven exakt).
    var isAffine: Bool {
        !deform.hasPerspective && (deform.warp.map { abs($0.bend) < 1e-9 } ?? true)
    }

    /// Breite/Höhe: natürlicher Punkt → gestreckter Rahmen.
    func stretchedPoint(_ p: Point2) -> Point2 {
        stretched.lo + (p - frame.lo) * simd_max(deform.stretch, Point2(1e-3, 1e-3))
    }

    /// Ganzer Weg ohne Pfad: natürlicher Punkt → verformter Punkt.
    func point(_ p: Point2) -> Point2 {
        let q = warped(stretchedPoint(p))
        let size = stretched.size
        let u: Double = (q.x - stretched.lo.x) / size.x
        let v: Double = (q.y - stretched.lo.y) / size.y
        return projective.point(u, v)
    }

    /// Breite/Höhe und Verzerren (für den Pfad, ohne Hülle und Perspektive).
    func shearedPoint(_ p: Point2) -> Point2 {
        let q = stretchedPoint(p)
        let d: Point2 = q - stretched.lo
        return Point2(q.x + deform.shear.x * d.y, q.y + deform.shear.y * d.x)
    }

    /// Hülle aus der Vorlage (im gestreckten Rahmen, mm).
    func warped(_ q: Point2) -> Point2 {
        guard let warp = deform.warp, abs(warp.bend) > 1e-9 else { return q }
        let lo = stretched.lo
        let size = stretched.size
        let w: Double = size.x, h: Double = size.y
        let u: Double = (q.x - lo.x) / w
        let v: Double = (q.y - lo.y) / h
        let b: Double = max(-1, min(1, warp.bend))
        // Buckel: 0 an den Enden, 1 in der Mitte
        let bump: Double = 1 - (2 * u - 1) * (2 * u - 1)
        switch warp.style {
        case .arc:
            // Wie Text auf einem Kreisbogen: Grundlinie wird zum Bogen mit dem Öffnungswinkel b · 180°;
            // nicht enger als 1,2 Rahmenhöhen (sonst kippen die Buchstaben nach innen)
            var sweep: Double = b * .pi
            let limit: Double = w / (1.2 * h)
            if abs(sweep) > limit { sweep = sweep < 0 ? -limit : limit }
            guard abs(sweep) > 1e-6 else { return q }
            let radius: Double = w / sweep
            let mid: Double = lo.x + w / 2
            let center = Point2(mid, lo.y - radius)
            let angle: Double = (q.x - mid) / radius
            let r: Double = radius + (q.y - lo.y)
            return center + Point2(r * sin(angle), r * cos(angle))
        case .arcLower:
            return Point2(q.x, q.y - b * h * 0.5 * bump * (1 - v))
        case .arcUpper:
            return Point2(q.x, q.y + b * h * 0.5 * bump * v)
        case .bulge:
            return Point2(q.x, q.y + b * h * 0.5 * bump * (2 * v - 1))
        case .wave:
            return Point2(q.x, q.y + b * h * 0.35 * sin(2 * .pi * u) * v)
        case .flag:
            return Point2(q.x, q.y + b * h * 0.3 * sin(2 * .pi * u))
        case .rise:
            let smooth: Double = u * u * (3 - 2 * u)
            return Point2(q.x, q.y + b * h * 0.6 * (smooth - 0.5))
        }
    }

    /// Text am Pfad: jedes Zeichen entlang der Bogenlänge, nach der Tangente gedreht bzw. („Kontur folgen“)
    /// jeder Punkt einzeln auf die Normale der Kurve gelegt.
    func alongPath(_ glyphs: [SketchTextGlyph], curve: SketchTextPathCurve, options: SketchTextPath,
                   piece: Double) -> [SketchLoop] {
        let start: Double = pathStart(curve: curve, options: options)
        let top: Double = stretched.hi.y
        let left: Double = stretched.lo.x
        // Abstand eines Punkts von der Kurve (links = oberhalb in Laufrichtung)
        let normalOffset = { (y: Double) -> Double in
            let above: Double = y - baseline
            if options.below { return above - (top - baseline) - options.distance }
            return above + options.distance
        }
        if options.bends {
            return glyphs.flatMap(\.loops).map { loop in
                loop.subdivided(piece: piece, keepsLines: false) { p in
                    let q = shearedPoint(p)
                    let at = curve.sample(start + (q.x - left))
                    return at.point + at.normal * normalOffset(q.y)
                }
            }
        }
        var result: [SketchLoop] = []
        for glyph in glyphs {
            // Mitte des Zeichens auf dem Pfad, das Zeichen steht starr auf der Tangente
            let middle = shearedPoint(Point2(glyph.x + glyph.advance / 2, 0)).x
            let at = curve.sample(start + (middle - left))
            for loop in glyph.loops {
                result.append(loop.mapped { p in
                    let q = shearedPoint(p)
                    return at.point + at.tangent * (q.x - middle) + at.normal * normalOffset(q.y)
                })
            }
        }
        return result
    }

    /// Bogenlänge, an der der Text beginnt (Ausrichtung und Startversatz).
    func pathStart(curve: SketchTextPathCurve, options: SketchTextPath) -> Double {
        let width: Double = stretched.size.x
        let length: Double = curve.length
        let aligned: Double
        if curve.closed {
            // Geschlossene Kurve: ausgerichtet am Startpunkt (Kreis: oben)
            aligned = switch options.alignment {
            case .left: 0
            case .center: -width / 2
            case .right: -width
            }
        } else {
            aligned = switch options.alignment {
            case .left: 0
            case .center: (length - width) / 2
            case .right: length - width
            }
        }
        return aligned + options.offset
    }
}

// MARK: Vierpunkt-Abbildung

/// Einheitsquadrat → Viereck: projektiv (Heckbert), bei nicht konvexen Vierecken bilinear.
struct SketchQuadMap {
    private let q: [Point2]
    private let a: Double, b: Double, c: Double, d: Double, e: Double, f: Double, g: Double, h: Double
    private let bilinear: Bool

    init(_ quad: [Point2]) {
        q = quad.count == 4 ? quad : [Point2(0, 0), Point2(1, 0), Point2(1, 1), Point2(0, 1)]
        let x0 = q[0].x, y0 = q[0].y, x1 = q[1].x, y1 = q[1].y
        let x2 = q[2].x, y2 = q[2].y, x3 = q[3].x, y3 = q[3].y
        let sx: Double = x0 - x1 + x2 - x3
        let sy: Double = y0 - y1 + y2 - y3
        var gg = 0.0, hh = 0.0
        var flat = false
        if abs(sx) > 1e-12 || abs(sy) > 1e-12 {
            let dx1: Double = x1 - x2, dx2: Double = x3 - x2
            let dy1: Double = y1 - y2, dy2: Double = y3 - y2
            let den: Double = dx1 * dy2 - dx2 * dy1
            if abs(den) < 1e-12 {
                flat = true
            } else {
                gg = (sx * dy2 - dx2 * sy) / den
                hh = (dx1 * sy - sx * dy1) / den
            }
        }
        g = gg
        h = hh
        a = x1 - x0 + gg * x1
        b = x3 - x0 + hh * x3
        c = x0
        d = y1 - y0 + gg * y1
        e = y3 - y0 + hh * y3
        f = y0
        // Nenner muss im ganzen Quadrat positiv bleiben, das Viereck konvex sein
        let weights: [Double] = [1, 1 + gg, 1 + hh, 1 + gg + hh]
        bilinear = flat || weights.contains { $0 < 0.05 } || !Self.isConvex(q)
    }

    private static func isConvex(_ q: [Point2]) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            let cross: Double = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-12 { continue }
            if sign == 0 { sign = cross } else if sign * cross < 0 { return false }
        }
        return true
    }

    func point(_ u: Double, _ v: Double) -> Point2 {
        if bilinear {
            let p0: Point2 = q[0] * ((1 - u) * (1 - v))
            let p1: Point2 = q[1] * (u * (1 - v))
            let p2: Point2 = q[2] * (u * v)
            let p3: Point2 = q[3] * ((1 - u) * v)
            return p0 + p1 + p2 + p3
        }
        let w: Double = g * u + h * v + 1
        return Point2((a * u + b * v + c) / w, (d * u + e * v + f) / w)
    }
}

// MARK: Pfad

/// Pfad im System des Texts: Linienzug mit Bogenlängen und geglätteten Tangenten.
struct SketchTextPathCurve {
    let points: [Point2]
    let closed: Bool
    /// Bogenlänge bis Punkt i
    let lengths: [Double]
    /// Tangente je Punkt (Mittel der angrenzenden Stücke)
    let tangents: [Point2]

    var length: Double { lengths.last ?? 0 }

    /// step: größte Stücklänge (feiner unterteilt für glatte Normalen).
    init?(_ path: SketchTextPath, toLocal: (Point2) -> Point2, step: Double) {
        var source: [Point2] = path.points.map(toLocal)
        if path.reversed { source.reverse() }
        if path.closed, let first = source.first { source.append(first) }
        guard source.count >= 2 else { return nil }
        var dense: [Point2] = [source[0]]
        for i in 1..<source.count {
            let a = source[i - 1], b = source[i]
            let distance: Double = simd_distance(a, b)
            guard distance > 1e-9 else { continue }
            let n = min(max(Int((distance / max(step, 1e-3)).rounded(.up)), 1), 400)
            for k in 1...n { dense.append(a + (b - a) * (Double(k) / Double(n))) }
        }
        guard dense.count >= 2 else { return nil }
        var lengths: [Double] = [0]
        for i in 1..<dense.count { lengths.append(lengths[i - 1] + simd_distance(dense[i - 1], dense[i])) }
        guard let total = lengths.last, total > 1e-9 else { return nil }
        let closed = path.closed
        var tangents: [Point2] = []
        let last = dense.count - 1
        for i in dense.indices {
            var before: Point2 = i > 0 ? dense[i] - dense[i - 1] : .zero
            var after: Point2 = i < last ? dense[i + 1] - dense[i] : .zero
            if closed, i == 0 { before = dense[last] - dense[last - 1] }
            if closed, i == last { after = dense[1] - dense[0] }
            var t: Point2 = .zero
            if simd_length(before) > 1e-12 { t += simd_normalize(before) }
            if simd_length(after) > 1e-12 { t += simd_normalize(after) }
            if simd_length(t) < 1e-12 { t = Point2(1, 0) }
            tangents.append(simd_normalize(t))
        }
        points = dense
        self.closed = closed
        self.lengths = lengths
        self.tangents = tangents
    }

    /// Punkt, Tangente und linke Normale bei Bogenlänge s. Offene Kurven laufen an den Enden gerade weiter,
    /// geschlossene wiederholen sich.
    func sample(_ s: Double) -> (point: Point2, tangent: Point2, normal: Point2) {
        let total = length
        var t: Double = s
        if closed {
            t = s.truncatingRemainder(dividingBy: total)
            if t < 0 { t += total }
        } else if s < 0 {
            let tangent = tangents[0]
            return (points[0] + tangent * s, tangent, Point2(-tangent.y, tangent.x))
        } else if s > total {
            let tangent = tangents[tangents.count - 1]
            return (points[points.count - 1] + tangent * (s - total), tangent, Point2(-tangent.y, tangent.x))
        }
        // Stück suchen (binär)
        var low = 0, high = lengths.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if lengths[mid] <= t { low = mid } else { high = mid }
        }
        let span: Double = lengths[high] - lengths[low]
        let k: Double = span > 1e-12 ? (t - lengths[low]) / span : 0
        let point: Point2 = points[low] + (points[high] - points[low]) * k
        var tangent: Point2 = tangents[low] * (1 - k) + tangents[high] * k
        if simd_length(tangent) < 1e-12 { tangent = tangents[low] }
        tangent = simd_normalize(tangent)
        return (point, tangent, Point2(-tangent.y, tangent.x))
    }

    /// Bogenlänge des Kurvenpunkts, der p am nächsten liegt.
    func arcLength(nearest p: Point2) -> Double {
        var best = (distance: Double.infinity, s: 0.0)
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let ab: Point2 = b - a
            let squared: Double = simd_length_squared(ab)
            let k: Double = squared > 0 ? min(max(simd_dot(p - a, ab) / squared, 0), 1) : 0
            let distance: Double = simd_distance(p, a + ab * k)
            if distance < best.distance { best = (distance, lengths[i - 1] + k * (lengths[i] - lengths[i - 1])) }
        }
        return best.s
    }
}

extension SketchTextPath {
    /// Kurve eines Skizzenelements als Pfad (Linienzug in Laufrichtung). Kreise und Ellipsen beginnen oben und
    /// laufen im Uhrzeigersinn, damit Text darauf außen und lesbar steht. nil für Punkte und Text.
    static func curve(of entity: SketchEntity) -> (points: [Point2], closed: Bool)? {
        switch entity {
        case .point, .text:
            return nil
        case .line(let a, let b):
            return simd_distance(a, b) > 1e-9 ? ([a, b], false) : nil
        case .arc(let a, let m, let b):
            return (SketchSegment.arc(a, m, b).samples, false)
        case .circle(let center, let radius):
            let points: [Point2] = (0..<144).map { k in
                let angle: Double = .pi / 2 - Double(k) / 144 * 2 * .pi
                return center + Point2(cos(angle), sin(angle)) * radius
            }
            return (points, true)
        case .ellipse(let center, let radii):
            let points: [Point2] = (0..<144).map { k in
                let angle: Double = .pi / 2 - Double(k) / 144 * 2 * .pi
                return center + Point2(radii.x * cos(angle), radii.y * sin(angle))
            }
            return (points, true)
        case .polyline(let points, let closed):
            return points.count >= 2 ? (points, closed) : nil
        default:
            if let segment = entity.openSegments.first {
                var points: [Point2] = []
                for piece in entity.openSegments { points += points.isEmpty ? piece.samples : Array(piece.samples.dropFirst()) }
                if points.count < 2 { points = segment.samples }
                return (points, false)
            }
            if let loop = entity.loops.first {
                var polygon = loop.polygon
                // Im Uhrzeigersinn wie Kreise (Text außen)
                if signedArea(polygon) > 0 { polygon.reverse() }
                return polygon.count >= 3 ? (polygon, true) : nil
            }
            return nil
        }
    }
}

// MARK: Konturen abbilden

extension SketchSegment {
    /// Stück unter einer Abbildung, die Geraden auf Geraden abbildet (Pole werden abgebildet).
    func mapped(_ f: (Point2) -> Point2) -> SketchSegment {
        switch self {
        case .line(let a, let b): .line(f(a), f(b))
        case .arc(let a, let m, let b): .arc(f(a), f(m), f(b))
        case .bezier(let poles): .bezier(poles.map(f))
        case .bspline(let poles): .bspline(poles.map(f))
        }
    }

    /// Kubische Teilstücke (je vier Pole) von höchstens etwa piece Länge.
    func cubicPieces(piece: Double) -> [[Point2]] {
        func lineCubics(_ a: Point2, _ b: Point2) -> [[Point2]] {
            let n = min(max(Int((simd_distance(a, b) / piece).rounded(.up)), 1), 256)
            return (0..<n).map { k in
                let p0: Point2 = a + (b - a) * (Double(k) / Double(n))
                let p3: Point2 = a + (b - a) * (Double(k + 1) / Double(n))
                return [p0, p0 + (p3 - p0) / 3, p0 + (p3 - p0) * (2.0 / 3.0), p3]
            }
        }
        switch self {
        case .line(let a, let b):
            return lineCubics(a, b)
        case .bezier(let poles) where poles.count >= 4:
            var result: [[Point2]] = []
            for k in stride(from: 0, to: poles.count - 3, by: 3) {
                let cubic: [Point2] = Array(poles[k...(k + 3)])
                // Länge abgeschätzt über das Kontrollpolygon
                var hull = 0.0
                for i in 1..<4 { hull += simd_distance(cubic[i - 1], cubic[i]) }
                let n = min(max(Int((hull / piece).rounded(.up)), 1), 256)
                for i in 0..<n {
                    result.append(Self.subCubic(cubic, from: Double(i) / Double(n), to: Double(i + 1) / Double(n)))
                }
            }
            return result
        default:
            // Bogen, B-Spline: über die Abtastpunkte
            let samples = self.samples
            guard samples.count >= 2 else { return [] }
            var result: [[Point2]] = []
            for i in 1..<samples.count where simd_distance(samples[i - 1], samples[i]) > 1e-12 {
                result += lineCubics(samples[i - 1], samples[i])
            }
            return result
        }
    }

    /// Teil t0…t1 einer kubischen Bézierkurve (de Casteljau).
    private static func subCubic(_ p: [Point2], from t0: Double, to t1: Double) -> [Point2] {
        func split(_ c: [Point2], _ t: Double) -> (left: [Point2], right: [Point2]) {
            let p01 = c[0] + (c[1] - c[0]) * t, p12 = c[1] + (c[2] - c[1]) * t, p23 = c[2] + (c[3] - c[2]) * t
            let p012 = p01 + (p12 - p01) * t, p123 = p12 + (p23 - p12) * t
            let mid = p012 + (p123 - p012) * t
            return ([c[0], p01, p012, mid], [mid, p123, p23, c[3]])
        }
        let head = t1 < 1 ? split(p, t1).left : p
        guard t0 > 0, t1 > 0 else { return head }
        return split(head, t0 / t1).right
    }
}

extension SketchLoop {
    /// Kontur unter einer Abbildung, die Geraden auf Geraden abbildet (Ähnlichkeit, affin; Kreise nur unter
    /// Ähnlichkeiten exakt).
    func mapped(_ f: (Point2) -> Point2) -> SketchLoop {
        switch self {
        case .chain(let segments):
            return .chain(segments.map { $0.mapped(f) })
        case .circle(let center, let radius):
            let c = f(center)
            return .circle(center: c, radius: simd_distance(f(center + Point2(radius, 0)), c))
        case .ellipse(let center, let radii):
            let c = f(center)
            return .ellipse(center: c, radii: Point2(simd_distance(f(center + Point2(radii.x, 0)), c),
                                                     simd_distance(f(center + Point2(0, radii.y)), c)))
        case .periodic(let poles):
            return .periodic(poles.map(f))
        }
    }

    /// Kontur unter einer gekrümmten Abbildung: jede Kurve in kurze kubische Stücke geteilt, deren Pole abgebildet
    /// werden (eine Bézierkette je Stück der Kontur, Ecken bleiben Ecken). keepsLines: Geraden bleiben Geraden
    /// (Perspektive).
    func subdivided(piece: Double, keepsLines: Bool, _ f: (Point2) -> Point2) -> SketchLoop {
        let segments: [SketchSegment]
        switch self {
        case .chain(let list):
            segments = list
        default:
            // Kreis, Ellipse, geschlossener Spline (kommen in Schriften nicht vor): als Linienzug
            let polygon = self.polygon
            guard polygon.count >= 3 else { return mapped(f) }
            segments = polygon.indices.map { .line(polygon[$0], polygon[($0 + 1) % polygon.count]) }
        }
        var result: [SketchSegment] = []
        for segment in segments {
            if keepsLines, case .line(let a, let b) = segment {
                result.append(.line(f(a), f(b)))
                continue
            }
            let pieces = segment.cubicPieces(piece: piece)
            guard let first = pieces.first else { continue }
            var poles: [Point2] = [f(first[0])]
            for cubic in pieces { poles += [f(cubic[1]), f(cubic[2]), f(cubic[3])] }
            result.append(.bezier(poles))
        }
        return .chain(result)
    }
}
