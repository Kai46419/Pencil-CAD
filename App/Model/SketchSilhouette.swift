import Foundation
import simd

// Build 76 (Kai): Skizze aus einer STL erzeugen – neue Skizze z. B. auf „Oben“, dann Projizieren › „Umriss der
// Körper“: der Umriss aller sichtbaren Körper, senkrecht auf die Skizzenebene projiziert, wird zu Skizzenlinien
// (außen und innen, z. B. durchgehende Löcher). Gerechnet wird über ein feines Raster (Dreiecke des Anzeige-
// netzes einfärben, Rand nachfahren, Linien vereinfachen) – das klappt auch bei unsauberen STL-Netzen, an denen
// exakte Kanten scheitern. Runde Löcher werden echte Kreise, gerade Kanten gerade Linien.

enum SketchSilhouette {
    /// Zellen entlang der längeren Seite (Genauigkeit ≈ Größe / resolution)
    static let resolution = 1000

    /// Umrisslinien (geschlossen, erster Punkt = letzter) in Skizzenkoordinaten.
    static func loops(mesh: Mesh, plane: SketchPlane, bodies: Set<Int>? = nil) -> [[Point2]] {
        var triangles: [(Point2, Point2, Point2)] = []
        triangles.reserveCapacity(mesh.triangleCount)
        var low = Point2(Double.infinity, Double.infinity), high = Point2(-Double.infinity, -Double.infinity)
        for t in 0..<mesh.triangleCount {
            guard t < mesh.triangleFaces.count else { break }
            if let bodies, !bodies.contains(mesh.triangleFaces[t].body) { continue }
            var corners: [Point2] = []
            for k in 0..<3 {
                let index = Int(mesh.indices[t * 3 + k])
                guard index < mesh.vertices.count else { break }
                corners.append(plane.local(SIMD3<Double>(mesh.vertices[index].position)))
            }
            guard corners.count == 3 else { continue }
            for p in corners {
                low = simd_min(low, p)
                high = simd_max(high, p)
            }
            triangles.append((corners[0], corners[1], corners[2]))
        }
        guard !triangles.isEmpty, low.x.isFinite, high.x.isFinite else { return [] }
        let size: Point2 = high - low
        let longest: Double = max(size.x, size.y)
        guard longest > 1e-6 else { return [] }
        let h: Double = longest / Double(resolution)
        // Rand von 2 Zellen, damit jeder Umriss geschlossen ist
        let origin: Point2 = low - Point2(2 * h, 2 * h)
        let nx = Int((size.x / h).rounded(.up)) + 5, ny = Int((size.y / h).rounded(.up)) + 5
        var inside = [Bool](repeating: false, count: nx * ny)

        // Dreiecke einfärben (Mittelpunkte der Abtastpunkte im Dreieck)
        for (a, b, c) in triangles {
            let area: Double = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-14 else { continue }
            let sign: Double = area > 0 ? 1 : -1
            let i0 = max(0, Int(((min(a.x, b.x, c.x) - origin.x) / h).rounded(.down)))
            let i1 = min(nx - 1, Int(((max(a.x, b.x, c.x) - origin.x) / h).rounded(.up)))
            let j0 = max(0, Int(((min(a.y, b.y, c.y) - origin.y) / h).rounded(.down)))
            let j1 = min(ny - 1, Int(((max(a.y, b.y, c.y) - origin.y) / h).rounded(.up)))
            guard i0 <= i1, j0 <= j1 else { continue }
            for j in j0...j1 {
                let y: Double = origin.y + Double(j) * h
                for i in i0...i1 where !inside[j * nx + i] {
                    let x: Double = origin.x + Double(i) * h
                    let w0: Double = ((b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)) * sign
                    let w1: Double = ((c.x - b.x) * (y - b.y) - (c.y - b.y) * (x - b.x)) * sign
                    let w2: Double = ((a.x - c.x) * (y - c.y) - (a.y - c.y) * (x - c.x)) * sign
                    let eps: Double = -1e-9 * abs(area)
                    if w0 >= eps, w1 >= eps, w2 >= eps { inside[j * nx + i] = true }
                }
            }
        }

        // Marching Squares: Randstücke zwischen Kantenmitten, Kanten über Nummern verbunden
        func hEdge(_ i: Int, _ j: Int) -> Int { (j * nx + i) * 2 }
        func vEdge(_ i: Int, _ j: Int) -> Int { (j * nx + i) * 2 + 1 }
        func point(_ id: Int) -> Point2 {
            let cell = id / 2, i = cell % nx, j = cell / nx
            return id % 2 == 0 ? origin + Point2((Double(i) + 0.5) * h, Double(j) * h)
                : origin + Point2(Double(i) * h, (Double(j) + 0.5) * h)
        }
        var links: [Int: [Int]] = [:]
        func link(_ a: Int, _ b: Int) {
            links[a, default: []].append(b)
            links[b, default: []].append(a)
        }
        for j in 0..<(ny - 1) {
            for i in 0..<(nx - 1) {
                let b0 = inside[j * nx + i], b1 = inside[j * nx + i + 1]
                let b2 = inside[(j + 1) * nx + i + 1], b3 = inside[(j + 1) * nx + i]
                let code = (b0 ? 1 : 0) | (b1 ? 2 : 0) | (b2 ? 4 : 0) | (b3 ? 8 : 0)
                guard code != 0, code != 15 else { continue }
                let e0 = hEdge(i, j), e1 = vEdge(i + 1, j), e2 = hEdge(i, j + 1), e3 = vEdge(i, j)
                switch code {
                case 1, 14: link(e3, e0)
                case 2, 13: link(e0, e1)
                case 3, 12: link(e3, e1)
                case 4, 11: link(e1, e2)
                case 6, 9: link(e0, e2)
                case 7, 8: link(e2, e3)
                case 5:
                    link(e3, e0)
                    link(e1, e2)
                case 10:
                    link(e0, e1)
                    link(e2, e3)
                default: break
                }
            }
        }

        // Schleifen nachfahren
        var used = Set<Int>()
        var result: [[Point2]] = []
        for start in links.keys where !used.contains(start) {
            var loop: [Point2] = []
            var previous = -1, current = start
            while !used.contains(current) {
                used.insert(current)
                loop.append(point(current))
                guard let next = links[current]?.first(where: { $0 != previous && !used.contains($0) }) else { break }
                previous = current
                current = next
            }
            guard loop.count >= 8 else { continue }
            // Winzige Schleifen (Rauschen) weglassen
            guard abs(signedArea(loop)) > 6 * h * h else { continue }
            result.append(clean(loop, cell: h))
        }
        return result
    }

    /// Kreis, wenn alle Punkte darauf liegen (dann exakt, damit die Skizze einen echten Kreis daraus macht), sonst
    /// vereinfachter Linienzug. Immer geschlossen (erster Punkt am Ende wiederholt).
    private static func clean(_ loop: [Point2], cell h: Double) -> [Point2] {
        if loop.count >= 16, let circle = MeshFeatures.fitCircle(loop) {
            let worst: Double = loop.map { abs(simd_distance($0, circle.center) - circle.radius) }.max() ?? .infinity
            if worst <= max(0.9 * h, 0.01 * circle.radius), circle.radius > 2 * h {
                var points: [Point2] = (0..<72).map { k in
                    let a = Double(k) / 72 * 2 * .pi
                    return circle.center + Point2(cos(a), sin(a)) * circle.radius
                }
                points.append(points[0])
                return points
            }
        }
        var simplified = douglasPeucker(loop + [loop[0]], tolerance: 0.75 * h)
        if simplified.count < 4 { simplified = loop + [loop[0]] }
        return simplified
    }

    private static func signedArea(_ loop: [Point2]) -> Double {
        var sum: Double = 0
        for k in loop.indices {
            let a = loop[k], b = loop[(k + 1) % loop.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Linienzug vereinfachen (Douglas-Peucker, ohne Rekursion).
    static func douglasPeucker(_ points: [Point2], tolerance: Double) -> [Point2] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        // Geschlossene Schleife: Anfang = Ende, erst am weitesten entfernten Punkt teilen
        if simd_distance(points[0], points[points.count - 1]) < 1e-12 {
            var far = 1
            var best: Double = -1
            for k in 1..<(points.count - 1) {
                let d = simd_distance(points[k], points[0])
                if d > best {
                    best = d
                    far = k
                }
            }
            keep[far] = true
            stack = [(0, far), (far, points.count - 1)]
        }
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let ab: Point2 = b - a
            let length: Double = simd_length(ab)
            var worst: Double = -1
            var index = first
            for k in (first + 1)..<last {
                let p = points[k]
                let d: Double = length > 1e-12 ? abs(ab.x * (p.y - a.y) - ab.y * (p.x - a.x)) / length : simd_distance(p, a)
                if d > worst {
                    worst = d
                    index = k
                }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
