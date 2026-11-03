import Foundation
import simd

// Druckbarkeits-Check für einen Körper: Überhänge, dünne Wände, offene Kanten, Bettfläche, Bauhöhe
// und Volumen aus dem Dreiecksnetz (Weltkoordinaten, Einheit mm).

/// Ergebnis des Druckbarkeits-Checks (Einheit mm).
struct PrintReport {
    /// Dreiecke (je drei Weltpunkte) mit Überhang steiler als der Grenzwinkel (ohne Flächen, die auf dem Druckbett liegen)
    var overhang: [SIMD3<Float>]
    /// Überhangfläche in mm²
    var overhangArea: Float
    /// Dreiecke, an denen die Wand dünner als minWall ist
    var thin: [SIMD3<Float>]
    /// Kleinste gemessene Wandstärke in mm (nil = nicht messbar)
    var thinnestWall: Float?
    /// Offene Kanten nach Verschweißen gleicher Punkte (0 = dicht)
    var openEdges: Int
    /// Fläche in mm², die auf dem Bett aufliegt (Normale ≈ -up, auf minimaler Höhe)
    var bedContactArea: Float
    /// Bauhöhe entlang up
    var height: Float
    /// Volumen in mm³ aus dem Netz (Divergenzsatz)
    var volume: Float
}

enum PrintCheck {
    /// Punkte höchstens so weit über der minimalen Höhe liegen auf dem Bett (mm).
    private static let bedTolerance: Float = 0.05
    /// Normale gilt als „genau nach unten“, wenn cos des Winkels zu -up darüber liegt (≈ 5°).
    private static let bedNormalCos: Float = 0.996
    /// Höchstzahl der Strahlen für die Wandstärke.
    private static let maxRays = 20_000
    /// Treffer näher als das zählen nicht (mm).
    private static let minHit: Float = 1e-4
    /// Raster zum Verschweißen (mm).
    private static let weldStep: Double = 1e-3
    /// Höchstzahl Zellen je Achse im Beschleunigungsgitter.
    private static let maxCellsPerAxis = 128
    /// Höchstzahl Einträge im Gitter (sonst keine Wandstärke).
    private static let maxGridEntries = 8_000_000
    /// cos-Grenze, ab der alle Dreiecke einer Fläche als eben gelten (≈ 2,5°).
    private static let planarCos: Float = 0.999

    // MARK: - Öffentliche Schnittstelle

    static func analyze(mesh: Mesh, body: Int, up: SIMD3<Float> = [0, 0, 1], overhangAngle: Float = 45,
                        minWall: Float = 0.8) -> PrintReport {
        let tris = triangles(of: mesh, body: body)
        return report(tris, vertexCount: mesh.vertices.count, up: normalized(up),
                      overhangCos: overhangCos(overhangAngle), minWall: minWall)
    }

    /// Beste Ausrichtung: prüft die 6 Achsrichtungen und die Normalen der 8 größten ebenen Flächen (Flächennummern aus triangleFaces) als „unten“; Bewertung = Überhangfläche − 2 × Bettfläche + 0,1 × Höhe² (kleiner ist besser). Liefert die up-Richtung (normiert) und den Bericht.
    static func bestOrientation(mesh: Mesh, body: Int, overhangAngle: Float = 45) -> (up: SIMD3<Float>, report: PrintReport) {
        let tris = triangles(of: mesh, body: body)
        let limit = overhangCos(overhangAngle)
        var candidates: [SIMD3<Float>] = [[0, 0, 1], [0, 0, -1], [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0]]
        // Fläche nach unten heißt: up zeigt entgegen ihrer Außennormale
        for normal in largestPlanarFaceNormals(tris, limit: 8) {
            let up = -normal
            if !candidates.contains(where: { simd_dot($0, up) > 0.9999 }) { candidates.append(up) }
        }
        var best = (up: candidates[0], score: Float.infinity)
        for up in candidates {
            let score = orientation(tris, up: up, overhangCos: limit, collect: false).score
            if score < best.score { best = (up, score) }
        }
        // Wandstärke, Kanten und Volumen hängen nicht von der Ausrichtung ab: nur einmal rechnen
        let result = report(tris, vertexCount: mesh.vertices.count, up: best.up, overhangCos: limit, minWall: 0.8)
        return (best.up, result)
    }

    // MARK: - Dreiecke

    /// Ein Dreieck des Körpers mit nach außen ausgerichteter Normale.
    private struct Triangle {
        var i0: Int, i1: Int, i2: Int
        var a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>
        /// Normierte Außennormale (null bei entarteten Dreiecken)
        var normal: SIMD3<Float>
        /// Fläche in mm² (0 = entartet)
        var area: Float
        var face: Int
        var degenerate: Bool { area <= 0 }
    }

    /// Gültige Dreiecke des Körpers (Indizes geprüft, Punkte endlich).
    private static func triangles(of mesh: Mesh, body: Int) -> [Triangle] {
        let count = min(mesh.indices.count / 3, mesh.triangleFaces.count)
        let vertexCount = mesh.vertices.count
        var result: [Triangle] = []
        guard count > 0 else { return result }
        for t in 0..<count where mesh.triangleFaces[t].body == body {
            let i0 = Int(mesh.indices[t * 3]), i1 = Int(mesh.indices[t * 3 + 1]), i2 = Int(mesh.indices[t * 3 + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
            let a = mesh.vertices[i0].position, b = mesh.vertices[i1].position, c = mesh.vertices[i2].position
            guard isFinite(a), isFinite(b), isFinite(c) else { continue }
            // Umlaufsinn gegen die gespeicherten Punktnormalen prüfen (Außenseite)
            var cross = simd_cross(b - a, c - a)
            let reference = mesh.vertices[i0].normal + mesh.vertices[i1].normal + mesh.vertices[i2].normal
            if isFinite(reference), simd_dot(cross, reference) < 0 { cross = -cross }
            let length = simd_length(cross)
            let valid = length.isFinite && length > 1e-12
            result.append(Triangle(i0: i0, i1: i1, i2: i2, a: a, b: b, c: c,
                                   normal: valid ? cross / length : SIMD3<Float>(repeating: 0),
                                   area: valid ? length / 2 : 0, face: mesh.triangleFaces[t].face))
        }
        return result
    }

    private static func isFinite(_ p: SIMD3<Float>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite
    }

    private static func normalized(_ up: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(up)
        guard length.isFinite, length > 1e-9 else { return [0, 0, 1] }
        return up / length
    }

    /// cos des Grenzwinkels (Winkel in Grad zwischen Normale und -up).
    private static func overhangCos(_ angle: Float) -> Float {
        let degrees = angle.isFinite ? min(max(angle, 0), 180) : 45
        return cos(degrees * .pi / 180)
    }

    // MARK: - Bericht

    private static func report(_ tris: [Triangle], vertexCount: Int, up: SIMD3<Float>, overhangCos: Float,
                               minWall: Float) -> PrintReport {
        let placed = orientation(tris, up: up, overhangCos: overhangCos, collect: true)
        let walls = wallThickness(tris)
        var thinnest: Float?
        var thin: [SIMD3<Float>] = []
        for (t, distance) in walls.enumerated() where distance.isFinite {
            thinnest = min(thinnest ?? distance, distance)
            if distance < minWall { thin += [tris[t].a, tris[t].b, tris[t].c] }
        }
        return PrintReport(overhang: placed.overhang, overhangArea: placed.overhangArea, thin: thin,
                           thinnestWall: thinnest, openEdges: openEdgeCount(tris, vertexCount: vertexCount),
                           bedContactArea: placed.bedContactArea, height: placed.height, volume: volume(tris))
    }

    // MARK: - Ausrichtung (Überhang, Bett, Höhe)

    /// Teil des Berichts, der von der Ausrichtung abhängt.
    private struct Placement {
        var overhang: [SIMD3<Float>] = []
        var overhangArea: Float = 0
        var bedContactArea: Float = 0
        var height: Float = 0
        /// Bewertung für die beste Ausrichtung (kleiner ist besser)
        var score: Float { overhangArea - 2 * bedContactArea + 0.1 * height * height }
    }

    private static func orientation(_ tris: [Triangle], up: SIMD3<Float>, overhangCos: Float,
                                    collect: Bool) -> Placement {
        var result = Placement()
        guard !tris.isEmpty else { return result }
        var low = Float.infinity, high = -Float.infinity
        for tri in tris {
            let ha = simd_dot(tri.a, up), hb = simd_dot(tri.b, up), hc = simd_dot(tri.c, up)
            low = min(low, ha, hb, hc)
            high = max(high, ha, hb, hc)
        }
        result.height = high - low
        let down = -up
        for tri in tris where !tri.degenerate {
            let top = max(simd_dot(tri.a, up), simd_dot(tri.b, up), simd_dot(tri.c, up))
            let facing = simd_dot(tri.normal, down)
            if top - low <= bedTolerance {
                // Liegt auf dem Bett: kein Überhang, zählt als Auflage, wenn die Normale nach unten zeigt
                if facing > bedNormalCos { result.bedContactArea += tri.area }
            } else if facing > overhangCos {
                result.overhangArea += tri.area
                if collect { result.overhang += [tri.a, tri.b, tri.c] }
            }
        }
        return result
    }

    /// Normalen der größten ebenen Flächen (nach Fläche absteigend).
    private static func largestPlanarFaceNormals(_ tris: [Triangle], limit: Int) -> [SIMD3<Float>] {
        var normalSum: [Int: SIMD3<Float>] = [:]
        var areaSum: [Int: Float] = [:]
        for tri in tris where !tri.degenerate {
            normalSum[tri.face, default: SIMD3<Float>(repeating: 0)] += tri.normal * tri.area
            areaSum[tri.face, default: 0] += tri.area
        }
        var axis: [Int: SIMD3<Float>] = [:]
        for (face, sum) in normalSum {
            let length = simd_length(sum)
            if length.isFinite, length > 1e-9 { axis[face] = sum / length }
        }
        // Eben, wenn alle Dreiecksnormalen mit der mittleren Normale übereinstimmen
        var planar = Set(axis.keys)
        for tri in tris where !tri.degenerate {
            guard let n = axis[tri.face] else { continue }
            if simd_dot(tri.normal, n) < planarCos { planar.remove(tri.face) }
        }
        let sorted = planar.sorted { lhs, rhs in
            let l = areaSum[lhs] ?? 0, r = areaSum[rhs] ?? 0
            return l != r ? l > r : lhs < rhs
        }
        return sorted.prefix(max(0, limit)).compactMap { axis[$0] }
    }

    // MARK: - Wandstärke

    /// Gleichmäßiges 3D-Gitter über den Dreiecken (Zellinhalte als zusammenhängende Liste).
    private struct Grid {
        var lo: SIMD3<Float>
        var cell: SIMD3<Float>
        var dims: SIMD3<Int>
        /// Beginn der Einträge je Zelle (Länge Zellenzahl + 1)
        var starts: [Int]
        /// Dreiecksnummern
        var items: [Int32]

        static func build(_ tris: [Triangle]) -> Grid? {
            var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
            var used = 0
            for tri in tris where !tri.degenerate {
                lo = simd_min(lo, simd_min(tri.a, simd_min(tri.b, tri.c)))
                hi = simd_max(hi, simd_max(tri.a, simd_max(tri.b, tri.c)))
                used += 1
            }
            guard used > 0 else { return nil }
            let pad = max(1e-3, (hi - lo).max() * 1e-4)
            lo -= SIMD3<Float>(repeating: pad)
            hi += SIMD3<Float>(repeating: pad)
            let extent = hi - lo
            // Zellgröße: größte Ausdehnung / Kubikwurzel der Dreieckszahl, je Achse höchstens maxCellsPerAxis Zellen
            let target = extent.max() / max(1, Float(cbrt(Double(used))))
            guard target.isFinite, target > 0 else { return nil }
            var dims = SIMD3<Int>(repeating: 1)
            for k in 0..<3 {
                let wanted = (extent[k] / target).rounded(.up)
                dims[k] = wanted.isFinite ? max(1, min(PrintCheck.maxCellsPerAxis, Int(min(wanted, 1e6)))) : 1
            }
            let cell = extent / SIMD3<Float>(Float(dims.x), Float(dims.y), Float(dims.z))
            let cellCount = dims.x * dims.y * dims.z

            /// Zellbereich des Hüllquaders eines Dreiecks
            func range(_ tri: Triangle) -> (from: SIMD3<Int>, to: SIMD3<Int>) {
                let a = simd_min(tri.a, simd_min(tri.b, tri.c)), b = simd_max(tri.a, simd_max(tri.b, tri.c))
                var from = SIMD3<Int>(), to = SIMD3<Int>()
                for k in 0..<3 {
                    from[k] = clampedCell((a[k] - lo[k]) / cell[k], dims[k])
                    to[k] = clampedCell((b[k] - lo[k]) / cell[k], dims[k])
                }
                return (from, to)
            }

            var total = 0
            for tri in tris where !tri.degenerate {
                let (from, to) = range(tri)
                total += (to.x - from.x + 1) * (to.y - from.y + 1) * (to.z - from.z + 1)
            }
            guard total <= PrintCheck.maxGridEntries else { return nil }

            var starts = [Int](repeating: 0, count: cellCount + 1)
            for tri in tris where !tri.degenerate {
                let (from, to) = range(tri)
                for z in from.z...to.z {
                    for y in from.y...to.y {
                        for x in from.x...to.x { starts[(z * dims.y + y) * dims.x + x + 1] += 1 }
                    }
                }
            }
            for i in 0..<cellCount { starts[i + 1] += starts[i] }
            var fill = starts
            var items = [Int32](repeating: 0, count: total)
            for (t, tri) in tris.enumerated() where !tri.degenerate {
                let (from, to) = range(tri)
                for z in from.z...to.z {
                    for y in from.y...to.y {
                        for x in from.x...to.x {
                            let id = (z * dims.y + y) * dims.x + x
                            items[fill[id]] = Int32(truncatingIfNeeded: t)
                            fill[id] += 1
                        }
                    }
                }
            }
            return Grid(lo: lo, cell: cell, dims: dims, starts: starts, items: items)
        }

        /// Zellnummer auf einer Achse, auf das Gitter begrenzt.
        static func clampedCell(_ value: Float, _ count: Int) -> Int {
            guard value.isFinite else { return value > 0 ? count - 1 : 0 }
            let index = Int(min(max(value.rounded(.down), 0), Float(count - 1)))
            return index
        }

        /// Abstand zum nächsten getroffenen Dreieck (3D-DDA durch das Gitter), nil = kein Treffer.
        func nearestHit(origin o: SIMD3<Float>, direction d: SIMD3<Float>, skip: Int, tris: [Triangle],
                        stamp: inout [Int32], ray: Int32) -> Float? {
            guard PrintCheck.isFinite(o), PrintCheck.isFinite(d) else { return nil }
            var c = SIMD3<Int>()
            var step = SIMD3<Int>()
            var tMax = SIMD3<Float>(repeating: .infinity)
            var tDelta = SIMD3<Float>(repeating: .infinity)
            for k in 0..<3 {
                c[k] = Grid.clampedCell((o[k] - lo[k]) / cell[k], dims[k])
                if d[k] > 0 {
                    step[k] = 1
                    tMax[k] = (lo[k] + Float(c[k] + 1) * cell[k] - o[k]) / d[k]
                    tDelta[k] = cell[k] / d[k]
                } else if d[k] < 0 {
                    step[k] = -1
                    tMax[k] = (lo[k] + Float(c[k]) * cell[k] - o[k]) / d[k]
                    tDelta[k] = -cell[k] / d[k]
                }
            }
            var best = Float.infinity
            var remaining = dims.x + dims.y + dims.z + 3
            while remaining > 0 {
                remaining -= 1
                let id = (c.z * dims.y + c.y) * dims.x + c.x
                guard id >= 0, id + 1 < starts.count else { break }
                for slot in starts[id]..<starts[id + 1] {
                    let t = Int(items[slot])
                    guard t != skip, t < tris.count, t < stamp.count, stamp[t] != ray else { continue }
                    stamp[t] = ray
                    if let hit = PrintCheck.intersect(o, d, tris[t]), hit > PrintCheck.minHit, hit < best { best = hit }
                }
                // Treffer innerhalb der aktuellen Zelle: kein weiter entfernter Treffer kann näher sein
                if best <= min(tMax.x, tMax.y, tMax.z) { break }
                let axis = tMax.x < tMax.y ? (tMax.x < tMax.z ? 0 : 2) : (tMax.y < tMax.z ? 1 : 2)
                guard step[axis] != 0 else { break }
                c[axis] += step[axis]
                if c[axis] < 0 || c[axis] >= dims[axis] { break }
                tMax[axis] += tDelta[axis]
            }
            return best.isFinite ? best : nil
        }
    }

    /// Strahl-Dreieck-Schnitt (Möller-Trumbore), liefert den Strahlparameter.
    private static func intersect(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ tri: Triangle) -> Float? {
        let e1 = tri.b - tri.a, e2 = tri.c - tri.a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        if abs(det) < 1e-12 { return nil }
        let inv = 1 / det
        let s = o - tri.a
        let u = simd_dot(s, p) * inv
        if u < -1e-6 || u > 1 + 1e-6 { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * inv
        if v < -1e-6 || u + v > 1 + 1e-6 { return nil }
        let t = simd_dot(e2, q) * inv
        return t.isFinite ? t : nil
    }

    /// Wandstärke je Dreieck: Strahl vom Schwerpunkt nach innen (-Normale) bis zum nächsten Dreieck.
    /// NaN = nicht gemessen, unendlich = kein Treffer.
    private static func wallThickness(_ tris: [Triangle]) -> [Float] {
        var result = [Float](repeating: .nan, count: tris.count)
        let candidates = tris.indices.filter { !tris[$0].degenerate }
        guard !candidates.isEmpty, let grid = Grid.build(tris) else { return result }
        // Bei mehr Dreiecken gleichmäßig verteilte Auswahl
        let rays = min(candidates.count, maxRays)
        var stamp = [Int32](repeating: -1, count: tris.count)
        for k in 0..<rays {
            let t = candidates[k * candidates.count / rays]
            let tri = tris[t]
            let origin = (tri.a + tri.b + tri.c) / 3
            let hit = grid.nearestHit(origin: origin, direction: -tri.normal, skip: t, tris: tris,
                                      stamp: &stamp, ray: Int32(k))
            result[t] = hit ?? .infinity
        }
        return result
    }

    // MARK: - Offene Kanten

    /// Kanten, die nach dem Verschweißen gleicher Punkte nur zu einem Dreieck gehören.
    private static func openEdgeCount(_ tris: [Triangle], vertexCount: Int) -> Int {
        guard !tris.isEmpty, vertexCount > 0 else { return 0 }
        var weldIds = [Int](repeating: -1, count: vertexCount)
        var cells: [SIMD3<Int64>: Int] = [:]
        var representatives: [SIMD3<Float>] = []
        let tolerance = Float(weldStep)

        func quantize(_ v: Float) -> Int64 {
            Int64(min(max((Double(v) / weldStep).rounded(), -1e15), 1e15))
        }

        /// Verschweißte Punktnummer (gleiche Rasterzelle oder Nachbarzelle innerhalb der Toleranz)
        func weld(_ index: Int, _ p: SIMD3<Float>) -> Int {
            guard index >= 0, index < weldIds.count else { return -1 }
            if weldIds[index] >= 0 { return weldIds[index] }
            let key = SIMD3<Int64>(quantize(p.x), quantize(p.y), quantize(p.z))
            var id = cells[key]
            if id == nil {
                search: for dx in -1...1 {
                    for dy in -1...1 {
                        for dz in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                            let neighbor = key &+ SIMD3<Int64>(Int64(dx), Int64(dy), Int64(dz))
                            if let other = cells[neighbor], simd_distance(representatives[other], p) <= tolerance {
                                id = other
                                break search
                            }
                        }
                    }
                }
            }
            let result: Int
            if let id {
                result = id
            } else {
                result = representatives.count
                representatives.append(p)
                cells[key] = result
            }
            weldIds[index] = result
            return result
        }

        var edgeUse: [UInt64: Int32] = [:]
        for tri in tris {
            let w0 = weld(tri.i0, tri.a), w1 = weld(tri.i1, tri.b), w2 = weld(tri.i2, tri.c)
            // Entartete Dreiecke (zusammenfallende Punkte) auslassen
            guard w0 >= 0, w1 >= 0, w2 >= 0, w0 != w1, w1 != w2, w0 != w2 else { continue }
            for (p, q) in [(w0, w1), (w1, w2), (w2, w0)] {
                let key = UInt64(min(p, q)) << 32 | UInt64(max(p, q))
                edgeUse[key, default: 0] += 1
            }
        }
        return edgeUse.values.reduce(0) { $0 + ($1 == 1 ? 1 : 0) }
    }

    // MARK: - Volumen

    /// Volumen über den Divergenzsatz (Summe der Tetraeder zum Bezugspunkt), in Double gerechnet.
    private static func volume(_ tris: [Triangle]) -> Float {
        guard let reference = tris.first?.a else { return 0 }
        func wide(_ p: SIMD3<Float>) -> SIMD3<Double> {
            let r = p - reference
            return SIMD3<Double>(Double(r.x), Double(r.y), Double(r.z))
        }
        var sum: Double = 0
        for tri in tris where !tri.degenerate {
            let a = wide(tri.a), b = wide(tri.b), c = wide(tri.c)
            var signed = simd_dot(a, simd_cross(b, c))
            // Umlaufsinn an der ausgerichteten Normale ausrichten
            if simd_dot(simd_cross(tri.b - tri.a, tri.c - tri.a), tri.normal) < 0 { signed = -signed }
            sum += signed
        }
        let result = abs(sum) / 6
        return result.isFinite ? Float(result) : 0
    }
}
