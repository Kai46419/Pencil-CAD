import Foundation
import simd

// Build 71: Formerkennung für Netze (STL/3MF). Eine Bohrung in einer STL ist kein Zylinder, sondern ein Ring aus
// schmalen ebenen Dreiecken – Abrunden, Fasen und Antippen der Bohrung gingen daran nicht. Hier werden ganz
// umlaufende zylindrische Bereiche erkannt (Bohrungen und Zapfen) und im Kernel durch echte Zylinder ersetzt:
// - Bohrung: Zylinder mit dem Umkreisradius der Netzpunkte abziehen (entfernt die schmalen Restkeile zwischen
//   den Dreiecken und dem Kreis; offene Enden etwas verlängert, damit keine deckungsgleichen Flächen entstehen),
// - Zapfen: Zylinder mit dem Umkreisradius vereinigen (füllt die Keile auf).
// Danach ist die Wand EINE Zylinderfläche. Jede Änderung wird über das Volumen geprüft: weicht es mehr ab als die
// Keile ausmachen können, bleibt der Körper an dieser Stelle wie er war.

/// Ein im Netz erkannter, ganz umlaufender Zylinder.
struct MeshCylinder {
    /// Punkt auf der Achse (bei Achskoordinate 0)
    var origin: SIMD3<Double>
    /// Achsrichtung (Einheitsvektor)
    var axis: SIMD3<Double>
    /// Größter Abstand der Netzpunkte von der Achse (Umkreis der Dreiecke)
    var radius: Double
    /// Ausdehnung entlang der Achse (Achskoordinaten)
    var start: Double
    var end: Double
    /// Material außen (Bohrung) bzw. innen (Zapfen)
    var isHole: Bool
    /// Bohrung ohne Boden an diesem Ende (darf verlängert werden)
    var openStart = false
    var openEnd = false

    var height: Double { end - start }
}

enum MeshFeatures {
    /// Knickwinkel, ab dem zwei Nachbardreiecke zu verschiedenen Flächen gehören
    static let featureAngle: Double = 50 * .pi / 180
    /// Kleinster und größter erkannter Radius (mm)
    static let minimumRadius: Double = 0.2
    static let maximumRadius: Double = 500
    /// Höchstzahl ersetzter Zylinder je Körper
    static let maximumCylinders = 200

    // MARK: Erkennen

    static func cylinders(in mesh: IndexedMesh) -> [MeshCylinder] {
        let positions: [SIMD3<Double>] = mesh.positions
        let triangles: [SIMD3<UInt32>] = mesh.triangles
        let count: Int = triangles.count
        guard count >= 8, positions.count >= 6 else { return [] }

        var normals = [SIMD3<Double>](repeating: SIMD3<Double>(repeating: 0), count: count)
        var areas = [Double](repeating: 0, count: count)
        var centroids = [SIMD3<Double>](repeating: SIMD3<Double>(repeating: 0), count: count)
        var signedVolume: Double = 0
        for i in 0..<count {
            let t = triangles[i]
            guard Int(t.x) < positions.count, Int(t.y) < positions.count, Int(t.z) < positions.count else { continue }
            let a: SIMD3<Double> = positions[Int(t.x)]
            let b: SIMD3<Double> = positions[Int(t.y)]
            let c: SIMD3<Double> = positions[Int(t.z)]
            let cross: SIMD3<Double> = simd_cross(b - a, c - a)
            let length: Double = simd_length(cross)
            areas[i] = length / 2
            if length > 1e-15 { normals[i] = cross / length }
            centroids[i] = (a + b + c) / 3
            signedVolume += simd_dot(a, simd_cross(b, c)) / 6
        }
        // Normalen nach außen (das reparierte Netz ist einheitlich, aber evtl. insgesamt innen-außen vertauscht)
        let outward: Double = signedVolume >= 0 ? 1 : -1

        // Nachbarn über gemeinsame Kanten
        var edgeTriangles: [SIMD2<UInt32>: [Int32]] = [:]
        edgeTriangles.reserveCapacity(count * 3 / 2 + 1)
        for i in 0..<count {
            let t = triangles[i]
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                edgeTriangles[SIMD2<UInt32>(min(a, b), max(a, b)), default: []].append(Int32(i))
            }
        }

        // Glatte Bereiche (ohne Knick über featureAngle)
        let cosLimit: Double = cos(featureAngle)
        var patchOf = [Int32](repeating: -1, count: count)
        var patches: [[Int]] = []
        for seed in 0..<count where patchOf[seed] < 0 && areas[seed] > 0 {
            let id = Int32(patches.count)
            var members: [Int] = [seed]
            var stack: [Int] = [seed]
            patchOf[seed] = id
            while let current = stack.popLast() {
                let t = triangles[current]
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    guard let list = edgeTriangles[SIMD2<UInt32>(min(a, b), max(a, b))] else { continue }
                    for other32 in list {
                        let other = Int(other32)
                        guard other != current, patchOf[other] < 0, areas[other] > 0,
                              simd_dot(normals[current], normals[other]) >= cosLimit else { continue }
                        patchOf[other] = id
                        members.append(other)
                        stack.append(other)
                    }
                }
            }
            patches.append(members)
        }

        var found: [MeshCylinder] = []
        for members in patches where members.count >= 8 {
            guard var cylinder = fitCylinder(members, positions: positions, triangles: triangles, normals: normals,
                                             areas: areas, centroids: centroids, outward: outward) else { continue }
            if cylinder.isHole {
                let floors = floorsAtEnds(of: cylinder, patch: Set(members), normals: normals, areas: areas,
                                          centroids: centroids)
                cylinder.openStart = !floors.start
                cylinder.openEnd = !floors.end
            }
            found.append(cylinder)
            if found.count >= maximumCylinders { break }
        }
        return found
    }

    /// Zylinder an einen glatten Bereich anpassen; nil, wenn es kein ganz umlaufender Zylinder ist.
    private static func fitCylinder(_ members: [Int], positions: [SIMD3<Double>], triangles: [SIMD3<UInt32>],
                                    normals: [SIMD3<Double>], areas: [Double], centroids: [SIMD3<Double>],
                                    outward: Double) -> MeshCylinder? {
        // Streuung der Normalen: beim Zylinder liegen alle in einer Ebene senkrecht zur Achse
        var m = simd_double3x3(0)
        var total: Double = 0
        for i in members {
            let n: SIMD3<Double> = normals[i]
            let w: Double = areas[i]
            m += simd_double3x3(columns: (n * (n.x * w), n * (n.y * w), n * (n.z * w)))
            total += w
        }
        guard total > 1e-12 else { return nil }
        let eigen = symmetricEigen(m)
        let trace: Double = eigen.values.x + eigen.values.y + eigen.values.z
        guard trace > 1e-12, eigen.values.x < 0.03 * trace, eigen.values.y > 0.2 * trace else { return nil }
        let axis: SIMD3<Double> = simd_normalize(eigen.vectors.0)
        // Alle Dreiecke (fast) parallel zur Achse
        var offAxis: Double = 0
        for i in members where abs(simd_dot(normals[i], axis)) > 0.2 { offAxis += areas[i] }
        guard offAxis <= 0.02 * total else { return nil }

        // Ebene senkrecht zur Achse
        let helper: SIMD3<Double> = abs(axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u: SIMD3<Double> = simd_normalize(simd_cross(axis, helper))
        let v: SIMD3<Double> = simd_cross(axis, u)
        var vertexSet = Set<UInt32>()
        for i in members {
            let t = triangles[i]
            vertexSet.insert(t.x)
            vertexSet.insert(t.y)
            vertexSet.insert(t.z)
        }
        let vertices: [SIMD3<Double>] = vertexSet.compactMap { Int($0) < positions.count ? positions[Int($0)] : nil }
        guard vertices.count >= 6 else { return nil }
        var planar: [SIMD2<Double>] = []
        planar.reserveCapacity(vertices.count)
        var low: Double = .infinity, high: Double = -.infinity
        for p in vertices {
            planar.append(SIMD2<Double>(simd_dot(p, u), simd_dot(p, v)))
            let t: Double = simd_dot(p, axis)
            low = min(low, t)
            high = max(high, t)
        }
        guard let circle = fitCircle(planar) else { return nil }
        let r: Double = circle.radius
        guard r >= minimumRadius, r <= maximumRadius, high - low > 0.05 else { return nil }
        // Alle Punkte auf dem Kreis
        var largest: Double = 0
        var angles: [Double] = []
        angles.reserveCapacity(planar.count)
        for q in planar {
            let d: SIMD2<Double> = q - circle.center
            let distance: Double = simd_length(d)
            guard abs(distance - r) <= max(0.03 * r, 0.05) else { return nil }
            largest = max(largest, distance)
            angles.append(atan2(d.y, d.x))
        }
        // Ganz umlaufend: keine Lücke über 70°
        angles.sort()
        var gap: Double = (angles.first ?? 0) + 2 * .pi - (angles.last ?? 0)
        for k in 1..<angles.count { gap = max(gap, angles[k] - angles[k - 1]) }
        guard gap <= 70 * .pi / 180 else { return nil }

        let origin: SIMD3<Double> = u * circle.center.x + v * circle.center.y
        // Bohrung, wenn die Außennormalen zur Achse zeigen
        var facing: Double = 0
        for i in members {
            let c: SIMD3<Double> = centroids[i]
            let alongAxis: SIMD3<Double> = origin + axis * simd_dot(c - origin, axis)
            let radial: SIMD3<Double> = c - alongAxis
            let length: Double = simd_length(radial)
            guard length > 1e-12 else { continue }
            facing += areas[i] * simd_dot(normals[i] * outward, radial / length)
        }
        guard abs(facing) > 0.5 * total else { return nil }
        return MeshCylinder(origin: origin, axis: axis, radius: largest, start: low, end: high, isHole: facing < 0)
    }

    /// Liegt an den Enden einer Bohrung ein Boden (Dreiecke senkrecht zur Achse innerhalb des Kreises)?
    private static func floorsAtEnds(of cylinder: MeshCylinder, patch: Set<Int>, normals: [SIMD3<Double>],
                                     areas: [Double], centroids: [SIMD3<Double>]) -> (start: Bool, end: Bool) {
        let reach: Double = 0.02 + 0.01 * cylinder.height
        var atStart = false, atEnd = false
        for i in centroids.indices where !patch.contains(i) && areas[i] > 0 {
            guard abs(simd_dot(normals[i], cylinder.axis)) > 0.95 else { continue }
            let c: SIMD3<Double> = centroids[i]
            let t: Double = simd_dot(c - cylinder.origin, cylinder.axis)
            let radial: Double = simd_length(c - cylinder.origin - cylinder.axis * t)
            guard radial < 0.9 * cylinder.radius else { continue }
            if abs(t - cylinder.start) <= reach { atStart = true }
            if abs(t - cylinder.end) <= reach { atEnd = true }
            if atStart && atEnd { break }
        }
        return (atStart, atEnd)
    }

    // MARK: Ersetzen

    /// Erkannte Bohrungen und Zapfen im Körper durch echte Zylinder ersetzen (langsam: im KernelThread aufrufen).
    static func trueCylinders(_ shape: PCKShape, mesh: IndexedMesh) -> (shape: PCKShape, holes: Int, bosses: Int) {
        guard shape.isClosedSolid else { return (shape, 0, 0) }
        let found = cylinders(in: mesh)
        guard !found.isEmpty else { return (shape, 0, 0) }
        var current = shape
        let holes = found.filter { $0.isHole }, bosses = found.filter { !$0.isHole }
        var holeCount = 0, bossCount = 0
        if !holes.isEmpty {
            let applied = apply(holes, to: current, cut: true)
            current = applied.shape
            holeCount = applied.count
        }
        if !bosses.isEmpty {
            let applied = apply(bosses, to: current, cut: false)
            current = applied.shape
            bossCount = applied.count
        }
        return (current, holeCount, bossCount)
    }

    /// Erst alle in einem Schritt; ist das Ergebnis unplausibel, einzeln (jeweils mit Volumenprüfung).
    private static func apply(_ list: [MeshCylinder], to shape: PCKShape, cut: Bool) -> (shape: PCKShape, count: Int) {
        var tools: [(tool: PCKShape, bound: Double)] = []
        for cylinder in list {
            if let made = tool(for: cylinder) { tools.append((tool: made, bound: bound(for: cylinder))) }
        }
        guard !tools.isEmpty else { return (shape, 0) }
        if tools.count > 1, let compound = PCKShape.compound(tools.map { $0.tool }),
           let result = combine(shape, compound, cut: cut),
           plausible(before: shape, after: result, bound: tools.reduce(0) { $0 + $1.bound }, cut: cut) {
            return (result, tools.count)
        }
        var current = shape
        var applied = 0
        for item in tools.prefix(60) {
            guard let result = combine(current, item.tool, cut: cut),
                  plausible(before: current, after: result, bound: item.bound, cut: cut) else { continue }
            current = result
            applied += 1
        }
        return (current, applied)
    }

    private static func combine(_ shape: PCKShape, _ tool: PCKShape, cut: Bool) -> PCKShape? {
        cut ? shape.cutting(tool, fuzzy: 0) : shape.fusing(tool)
    }

    /// Werkzeugzylinder: Umkreis + 5 µm; offene Bohrungsenden 0,5 mm verlängert.
    private static func tool(for cylinder: MeshCylinder) -> PCKShape? {
        let extensionLength: Double = 0.5
        let before: Double = cylinder.isHole && cylinder.openStart ? extensionLength : 0
        let after: Double = cylinder.isHole && cylinder.openEnd ? extensionLength : 0
        let base: SIMD3<Double> = cylinder.origin + cylinder.axis * (cylinder.start - before)
        return PCKShape.cylinder(base: base, axis: cylinder.axis, radius: cylinder.radius + 0.005,
                                 height: cylinder.height + before + after)
    }

    /// Höchste plausible Volumenänderung: die Keile zwischen Dreiecken und Kreis (großzügig 15 % der Kreisfläche).
    private static func bound(for cylinder: MeshCylinder) -> Double {
        let r: Double = cylinder.radius + 0.005
        return 0.15 * .pi * r * r * cylinder.height + 1e-3
    }

    private static func plausible(before: PCKShape, after: PCKShape, bound: Double, cut: Bool) -> Bool {
        guard after.isClosedSolid else { return false }
        let v0: Double = before.volume, v1: Double = after.volume
        guard v0.isFinite, v1.isFinite, v0 > 0, v1 > 0 else { return false }
        let change: Double = cut ? v0 - v1 : v1 - v0
        return change >= -1e-6 * v0 - 1e-6 && change <= bound
    }

    // MARK: Mathematik

    /// Kreis durch Punkte (Kasa-Ausgleich, Punkte vorher um ihren Schwerpunkt verschoben).
    static func fitCircle(_ points: [SIMD2<Double>]) -> (center: SIMD2<Double>, radius: Double)? {
        guard points.count >= 3 else { return nil }
        var mean = SIMD2<Double>(0, 0)
        for p in points { mean += p }
        mean /= Double(points.count)
        var sxx: Double = 0, sxy: Double = 0, syy: Double = 0, sx: Double = 0, sy: Double = 0
        var sxz: Double = 0, syz: Double = 0, sz: Double = 0
        for p in points {
            let q: SIMD2<Double> = p - mean
            let z: Double = q.x * q.x + q.y * q.y
            sxx += q.x * q.x
            sxy += q.x * q.y
            syy += q.y * q.y
            sx += q.x
            sy += q.y
            sxz += q.x * z
            syz += q.y * z
            sz += z
        }
        let n = Double(points.count)
        let a = simd_double3x3(rows: [SIMD3<Double>(sxx, sxy, sx), SIMD3<Double>(sxy, syy, sy), SIMD3<Double>(sx, sy, n)])
        guard abs(a.determinant) > 1e-18 else { return nil }
        let solution: SIMD3<Double> = a.inverse * SIMD3<Double>(-sxz, -syz, -sz)
        let center = SIMD2<Double>(-solution.x / 2, -solution.y / 2)
        let r2: Double = center.x * center.x + center.y * center.y - solution.z
        guard r2 > 0, r2.isFinite else { return nil }
        return (center + mean, sqrt(r2))
    }

    /// Eigenwerte (aufsteigend) und Eigenvektoren einer symmetrischen 3×3-Matrix (Jacobi-Verfahren).
    static func symmetricEigen(_ matrix: simd_double3x3)
        -> (values: SIMD3<Double>, vectors: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)) {
        var a: [[Double]] = (0..<3).map { r in (0..<3).map { c in matrix[c][r] } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var p = 0, q = 1
            var largest: Double = abs(a[0][1])
            if abs(a[0][2]) > largest { p = 0; q = 2; largest = abs(a[0][2]) }
            if abs(a[1][2]) > largest { p = 1; q = 2; largest = abs(a[1][2]) }
            if largest < 1e-14 { break }
            let theta: Double = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t: Double = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
            let c: Double = 1 / sqrt(t * t + 1)
            let s: Double = t * c
            for k in 0..<3 {
                let akp: Double = a[k][p], akq: Double = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk: Double = a[p][k], aqk: Double = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp: Double = v[k][p], vkq: Double = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        var order: [Int] = [0, 1, 2]
        order.sort { a[$0][$0] < a[$1][$1] }
        func column(_ k: Int) -> SIMD3<Double> { SIMD3<Double>(v[0][k], v[1][k], v[2][k]) }
        return (SIMD3<Double>(a[order[0]][order[0]], a[order[1]][order[1]], a[order[2]][order[2]]),
                (column(order[0]), column(order[1]), column(order[2])))
    }
}
