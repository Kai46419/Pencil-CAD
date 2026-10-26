import Foundation
import simd

// Netze aus STL/3MF reparieren und vereinfachen: Punkte verschweißen, entartete und doppelte Dreiecke entfernen,
// Normalen einheitlich ausrichten, kleine Löcher schließen, Dreiecke reduzieren (Quadrik-Fehlermaß) bzw.
// verfeinern (für den Pinsel „Netz bearbeiten“). Danach wird das Netz im Kernel ein Volumenkörper (MeshSolid).

/// Dreiecksnetz mit gemeinsamen Punkten (Einheit mm). Dreiecke von außen gesehen gegen den Uhrzeigersinn.
struct IndexedMesh {
    var positions: [SIMD3<Double>] = []
    var triangles: [SIMD3<UInt32>] = []

    var triangleCount: Int { triangles.count }

    /// Achsenparalleler Hüllquader (min, max).
    var bounds: (min: SIMD3<Double>, max: SIMD3<Double>)? {
        guard var low = positions.first else { return nil }
        var high = low
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        return (low, high)
    }

    /// Diagonale des Hüllquaders (0 bei leerem Netz).
    var size: Double {
        guard let box = bounds else { return 0 }
        return simd_distance(box.min, box.max)
    }
}

/// Was beim Reparieren passiert ist (für die Meldung nach dem Import).
struct MeshRepairReport {
    var mergedPoints = 0
    var removedTriangles = 0
    var flippedTriangles = 0
    var closedHoles = 0
    /// Randschleifen, die zu groß zum Schließen waren
    var openHoles = 0
    var reducedFrom: Int?
    var reducedTo: Int?

    mutating func add(_ other: MeshRepairReport) {
        mergedPoints += other.mergedPoints
        removedTriangles += other.removedTriangles
        flippedTriangles += other.flippedTriangles
        closedHoles += other.closedHoles
        openHoles += other.openHoles
        if let from = other.reducedFrom { reducedFrom = (reducedFrom ?? 0) + from }
        if let to = other.reducedTo { reducedTo = (reducedTo ?? 0) + to }
    }

    /// Kurzer Text, z. B. „2 Löcher geschlossen, 14 Dreiecke entfernt“ (leer, wenn nichts zu reparieren war).
    var summary: String {
        var parts: [String] = []
        if closedHoles > 0 { parts.append(closedHoles == 1 ? "1 Loch geschlossen" : "\(closedHoles) Löcher geschlossen") }
        if removedTriangles > 0 {
            parts.append(removedTriangles == 1 ? "1 Dreieck entfernt" : "\(removedTriangles) Dreiecke entfernt")
        }
        if flippedTriangles > 0 { parts.append("\(flippedTriangles) Dreiecke umgedreht") }
        if openHoles > 0 { parts.append(openHoles == 1 ? "1 großes Loch offen" : "\(openHoles) große Löcher offen") }
        if let from = reducedFrom, let to = reducedTo {
            parts.append("von \(from) auf \(to) Dreiecke reduziert")
        }
        return parts.joined(separator: ", ")
    }
}

enum MeshRepair {
    /// Punkte, die näher als tolerance beieinander liegen, gelten als derselbe Punkt.
    static let weldTolerance = 1e-4

    // MARK: Verschweißen

    /// Dreieckssuppe (je drei Punkte ein Dreieck) zu einem Netz mit gemeinsamen Punkten.
    static func weld(_ soup: [SIMD3<Double>], tolerance: Double = weldTolerance) -> (mesh: IndexedMesh, merged: Int) {
        var mesh = IndexedMesh()
        var lookup: [SIMD3<Int64>: UInt32] = [:]
        lookup.reserveCapacity(soup.count / 2)
        mesh.positions.reserveCapacity(soup.count / 2)
        mesh.triangles.reserveCapacity(soup.count / 3)
        let scale: Double = 1 / max(tolerance, 1e-9)
        func index(_ p: SIMD3<Double>) -> UInt32 {
            let scaled: SIMD3<Double> = (p * scale).rounded(.toNearestOrAwayFromZero)
            let key = SIMD3<Int64>(Int64(scaled.x), Int64(scaled.y), Int64(scaled.z))
            if let existing = lookup[key] { return existing }
            let new = UInt32(mesh.positions.count)
            mesh.positions.append(p)
            lookup[key] = new
            return new
        }
        var t = 0
        while t + 2 < soup.count {
            let a = soup[t], b = soup[t + 1], c = soup[t + 2]
            t += 3
            // Kaputte Zahlen (NaN, riesige Werte) überspringen, sonst läuft die Rundung über
            guard usable(a), usable(b), usable(c) else { continue }
            mesh.triangles.append(SIMD3(index(a), index(b), index(c)))
        }
        let merged = soup.count - mesh.positions.count
        return (mesh, max(0, merged))
    }

    private static func usable(_ p: SIMD3<Double>) -> Bool {
        p.x.isFinite && p.y.isFinite && p.z.isFinite && abs(p.x) < 1e9 && abs(p.y) < 1e9 && abs(p.z) < 1e9
    }

    // MARK: Entartete und doppelte Dreiecke

    @inline(__always) static func key(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 32 | UInt64(b)
    }

    @inline(__always) static func undirected(_ a: UInt32, _ b: UInt32) -> UInt64 {
        a < b ? key(a, b) : key(b, a)
    }

    /// Entfernt Dreiecke ohne Fläche und doppelte Dreiecke. „Kappen“ (ein Punkt liegt auf der gegenüberliegenden
    /// Kante) werden aufgelöst, indem das Nachbardreieck an diesem Punkt geteilt wird – so bleibt das Netz dicht.
    /// Liefert die Zahl der entfernten Dreiecke.
    static func removeDegenerate(_ mesh: inout IndexedMesh, tolerance: Double = weldTolerance) -> Int {
        let before = mesh.triangles.count
        // Gleiche Punkte
        mesh.triangles.removeAll { $0.x == $0.y || $0.y == $0.z || $0.x == $0.z }
        for _ in 0..<3 {
            if !splitCaps(&mesh, tolerance: tolerance) { break }
        }
        removeDuplicates(&mesh)
        return before - mesh.triangles.count
    }

    /// Kappen auflösen; true, wenn etwas geändert wurde.
    private static func splitCaps(_ mesh: inout IndexedMesh, tolerance: Double) -> Bool {
        var owner: [UInt64: Int] = [:]
        owner.reserveCapacity(mesh.triangles.count * 3)
        for (index, t) in mesh.triangles.enumerated() {
            owner[key(t.x, t.y)] = index
            owner[key(t.y, t.z)] = index
            owner[key(t.z, t.x)] = index
        }
        var touched = Set<Int>()
        var removed = Set<Int>()
        var appended: [SIMD3<UInt32>] = []
        var changed = false
        for index in mesh.triangles.indices where !touched.contains(index) {
            let t = mesh.triangles[index]
            let corners: [UInt32] = [t.x, t.y, t.z]
            let p: [SIMD3<Double>] = corners.map { mesh.positions[Int($0)] }
            // Längste Kante und Höhe darauf
            var longest = 0
            var longestLength: Double = 0
            for j in 0..<3 {
                let length = simd_distance(p[j], p[(j + 1) % 3])
                if length > longestLength {
                    longestLength = length
                    longest = j
                }
            }
            guard longestLength > 0 else { continue }
            let doubleArea: Double = simd_length(simd_cross(p[1] - p[0], p[2] - p[0]))
            let height: Double = doubleArea / longestLength
            guard height < tolerance else { continue }
            // a → b ist die längste Kante, c liegt (fast) darauf
            let a = corners[longest], b = corners[(longest + 1) % 3], c = corners[(longest + 2) % 3]
            touched.insert(index)
            removed.insert(index)
            changed = true
            guard let neighbor = owner[key(b, a)], neighbor != index, !touched.contains(neighbor) else { continue }
            let n = mesh.triangles[neighbor]
            let ring: [UInt32] = [n.x, n.y, n.z]
            guard let start = ring.firstIndex(of: b), ring[(start + 1) % 3] == a else { continue }
            let d = ring[(start + 2) % 3]
            guard d != c else { continue }
            touched.insert(neighbor)
            removed.insert(neighbor)
            appended.append(SIMD3(b, c, d))
            appended.append(SIMD3(c, a, d))
        }
        guard changed else { return false }
        var kept: [SIMD3<UInt32>] = []
        kept.reserveCapacity(mesh.triangles.count)
        for (index, t) in mesh.triangles.enumerated() where !removed.contains(index) {
            kept.append(t)
        }
        mesh.triangles = kept + appended
        return true
    }

    /// Doppelte Dreiecke: gleich ausgerichtete Kopien fallen weg, entgegengesetzte Paare (Doppelwand) beide.
    private static func removeDuplicates(_ mesh: inout IndexedMesh) {
        var seen: [SIMD3<UInt32>: Int] = [:]
        var drop = Set<Int>()
        for (index, t) in mesh.triangles.enumerated() {
            let sorted = sortedCorners(t)
            if let other = seen[sorted] {
                drop.insert(index)
                if !sameOrientation(mesh.triangles[other], t) { drop.insert(other) }
            } else {
                seen[sorted] = index
            }
        }
        guard !drop.isEmpty else { return }
        var kept: [SIMD3<UInt32>] = []
        for (index, t) in mesh.triangles.enumerated() where !drop.contains(index) {
            kept.append(t)
        }
        mesh.triangles = kept
    }

    private static func sortedCorners(_ t: SIMD3<UInt32>) -> SIMD3<UInt32> {
        let low = min(t.x, min(t.y, t.z)), high = max(t.x, max(t.y, t.z))
        let middle = t.x &+ t.y &+ t.z &- low &- high
        return SIMD3(low, middle, high)
    }

    private static func sameOrientation(_ first: SIMD3<UInt32>, _ second: SIMD3<UInt32>) -> Bool {
        let rotations: [SIMD3<UInt32>] = [second, SIMD3(second.y, second.z, second.x), SIMD3(second.z, second.x, second.y)]
        return rotations.contains(first)
    }

    // MARK: Ausrichten

    /// Nachbardreiecke gleich ausrichten (eine gemeinsame Kante läuft in beiden in Gegenrichtung), danach jedes
    /// zusammenhängende Teil so drehen, dass die Normalen nach außen zeigen (positives Volumen).
    /// Liefert die Zahl der umgedrehten Dreiecke.
    static func orient(_ mesh: inout IndexedMesh) -> Int {
        let count = mesh.triangles.count
        guard count > 0 else { return 0 }
        // Je ungerichteter Kante bis zu zwei Dreiecke; -2 = mehr als zwei (nicht mannigfaltig)
        var adjacency: [UInt64: SIMD2<Int32>] = [:]
        adjacency.reserveCapacity(count * 2)
        for (index, t) in mesh.triangles.enumerated() {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                let k = undirected(a, b)
                if var entry = adjacency[k] {
                    if entry.y == -1 { entry.y = Int32(index) } else { entry = SIMD2(-2, -2) }
                    adjacency[k] = entry
                } else {
                    adjacency[k] = SIMD2(Int32(index), -1)
                }
            }
        }
        var flip = [Bool](repeating: false, count: count)
        var visited = [Bool](repeating: false, count: count)
        var flippedTotal = 0
        for seed in 0..<count where !visited[seed] {
            var component: [Int] = [seed]
            visited[seed] = true
            var cursor = 0
            while cursor < component.count {
                let current = component[cursor]
                cursor += 1
                let t = oriented(mesh.triangles[current], flip[current])
                for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                    guard let entry = adjacency[undirected(a, b)], entry.x >= 0, entry.y >= 0 else { continue }
                    let other = Int(entry.x) == current ? Int(entry.y) : Int(entry.x)
                    guard !visited[other] else { continue }
                    // Der Nachbar muss die Kante b → a enthalten
                    flip[other] = contains(mesh.triangles[other], a, b)
                    visited[other] = true
                    component.append(other)
                }
            }
            // Vorzeichen des Volumens des Teils
            var volume: Double = 0
            for index in component {
                let t = oriented(mesh.triangles[index], flip[index])
                let p0 = mesh.positions[Int(t.x)], p1 = mesh.positions[Int(t.y)], p2 = mesh.positions[Int(t.z)]
                volume += simd_dot(p0, simd_cross(p1, p2))
            }
            if volume < 0 {
                for index in component { flip[index].toggle() }
            }
            for index in component where flip[index] {
                mesh.triangles[index] = oriented(mesh.triangles[index], true)
                flippedTotal += 1
            }
        }
        return flippedTotal
    }

    @inline(__always) private static func oriented(_ t: SIMD3<UInt32>, _ flipped: Bool) -> SIMD3<UInt32> {
        flipped ? SIMD3(t.x, t.z, t.y) : t
    }

    /// Enthält das Dreieck die gerichtete Kante a → b?
    @inline(__always) private static func contains(_ t: SIMD3<UInt32>, _ a: UInt32, _ b: UInt32) -> Bool {
        (t.x == a && t.y == b) || (t.y == a && t.z == b) || (t.z == a && t.x == b)
    }

    // MARK: Löcher schließen

    /// Gerichtete Randkanten (zu ihnen gibt es keine Gegenkante).
    static func boundaryEdges(_ mesh: IndexedMesh) -> [(UInt32, UInt32)] {
        var directed = Set<UInt64>()
        directed.reserveCapacity(mesh.triangles.count * 3)
        for t in mesh.triangles {
            directed.insert(key(t.x, t.y))
            directed.insert(key(t.y, t.z))
            directed.insert(key(t.z, t.x))
        }
        var result: [(UInt32, UInt32)] = []
        for t in mesh.triangles {
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] where !directed.contains(key(b, a)) {
                result.append((a, b))
            }
        }
        return result
    }

    /// Zahl der offenen Kanten (0 = dicht).
    static func openEdgeCount(_ mesh: IndexedMesh) -> Int {
        boundaryEdges(mesh).count
    }

    /// Randschleifen mit höchstens maxEdges Kanten schließen (Ohrenschneiden in der Ausgleichsebene, sonst Fächer
    /// um die Mitte). Liefert geschlossene und offen gebliebene Löcher.
    static func fillHoles(_ mesh: inout IndexedMesh, maxEdges: Int = 500) -> (closed: Int, open: Int) {
        let boundary = boundaryEdges(mesh)
        guard !boundary.isEmpty else { return (0, 0) }
        var outgoing: [UInt32: [UInt32]] = [:]
        for (a, b) in boundary { outgoing[a, default: []].append(b) }
        var closed = 0, open = 0
        for (start, firstNext) in boundary {
            // Kante schon in einer anderen Schleife verbraucht?
            guard var list = outgoing[start], let slot = list.firstIndex(of: firstNext) else { continue }
            list.remove(at: slot)
            outgoing[start] = list
            var loop: [UInt32] = [start]
            var current = firstNext
            var ok = true
            while current != start {
                loop.append(current)
                guard loop.count <= maxEdges * 4, var next = outgoing[current], !next.isEmpty else {
                    ok = false
                    break
                }
                let target = next.removeLast()
                outgoing[current] = next
                current = target
            }
            guard ok, loop.count >= 3 else {
                open += 1
                continue
            }
            guard loop.count <= maxEdges else {
                open += 1
                continue
            }
            // Füllfläche läuft gegen die Randrichtung
            let polygon: [UInt32] = loop.reversed()
            let fill: [SIMD3<UInt32>] = triangulate(polygon, mesh: &mesh)
            mesh.triangles += fill
            closed += 1
        }
        return (closed, open)
    }

    /// Geschlossenes Vieleck (Punktnummern) triangulieren: Ohrenschneiden in der Ebene seiner Newell-Normale;
    /// klappt das nicht, Fächer um einen neuen Mittelpunkt.
    private static func triangulate(_ polygon: [UInt32], mesh: inout IndexedMesh) -> [SIMD3<UInt32>] {
        if polygon.count == 3 { return [SIMD3(polygon[0], polygon[1], polygon[2])] }
        let points: [SIMD3<Double>] = polygon.map { mesh.positions[Int($0)] }
        var normal = SIMD3<Double>(repeating: 0)
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            normal += SIMD3<Double>((p.y - q.y) * (p.z + q.z), (p.z - q.z) * (p.x + q.x), (p.x - q.x) * (p.y + q.y))
        }
        if simd_length(normal) > 1e-12 {
            let n = simd_normalize(normal)
            let helper: SIMD3<Double> = abs(n.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
            let u = simd_normalize(simd_cross(n, helper))
            let v = simd_cross(n, u)
            let flat: [SIMD2<Double>] = points.map { SIMD2(simd_dot($0, u), simd_dot($0, v)) }
            if let ears = earClip(flat) {
                return ears.map { SIMD3(polygon[Int($0.x)], polygon[Int($0.y)], polygon[Int($0.z)]) }
            }
        }
        // Fächer um die Mitte
        var center = SIMD3<Double>(repeating: 0)
        for p in points { center += p }
        center /= Double(points.count)
        let c = UInt32(mesh.positions.count)
        mesh.positions.append(center)
        var result: [SIMD3<UInt32>] = []
        for i in polygon.indices {
            result.append(SIMD3(c, polygon[i], polygon[(i + 1) % polygon.count]))
        }
        return result
    }

    /// Ohrenschneiden eines einfachen Vielecks (gegen den Uhrzeigersinn). nil, wenn es nicht aufgeht.
    private static func earClip(_ points: [SIMD2<Double>]) -> [SIMD3<Int32>]? {
        var remaining: [Int] = Array(points.indices)
        var result: [SIMD3<Int32>] = []
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            let ab = b - a, ac = c - a
            return ab.x * ac.y - ab.y * ac.x
        }
        var guardCount = 0
        while remaining.count > 3 {
            guardCount += 1
            if guardCount > points.count * points.count + 10 { return nil }
            var found = false
            for k in remaining.indices {
                let count = remaining.count
                let i0 = remaining[(k + count - 1) % count], i1 = remaining[k], i2 = remaining[(k + 1) % count]
                let a = points[i0], b = points[i1], c = points[i2]
                guard cross(a, b, c) > 1e-14 else { continue }
                var inside = false
                for other in remaining where other != i0 && other != i1 && other != i2 {
                    let p = points[other]
                    if cross(a, b, p) >= 0, cross(b, c, p) >= 0, cross(c, a, p) >= 0 {
                        inside = true
                        break
                    }
                }
                guard !inside else { continue }
                result.append(SIMD3(Int32(i0), Int32(i1), Int32(i2)))
                remaining.remove(at: k)
                found = true
                break
            }
            if !found { return nil }
        }
        if remaining.count == 3 {
            result.append(SIMD3(Int32(remaining[0]), Int32(remaining[1]), Int32(remaining[2])))
        }
        return result
    }

    // MARK: Teile

    /// Zusammenhängende Teile (über gemeinsame Punkte) als eigene Netze.
    static func components(_ mesh: IndexedMesh) -> [IndexedMesh] {
        var parent: [Int] = Array(mesh.positions.indices)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var node = x
            while parent[node] != root {
                let next = parent[node]
                parent[node] = root
                node = next
            }
            return root
        }
        for t in mesh.triangles {
            let a = find(Int(t.x)), b = find(Int(t.y)), c = find(Int(t.z))
            if a != b { parent[b] = a }
            let a2 = find(a)
            if a2 != c { parent[c] = a2 }
        }
        var groups: [Int: Int] = [:]
        var parts: [IndexedMesh] = []
        var remap: [[Int: UInt32]] = []
        for t in mesh.triangles {
            let root = find(Int(t.x))
            let group: Int
            if let existing = groups[root] {
                group = existing
            } else {
                group = parts.count
                groups[root] = group
                parts.append(IndexedMesh())
                remap.append([:])
            }
            var corners = SIMD3<UInt32>(0, 0, 0)
            for k in 0..<3 {
                let old = Int(t[k])
                if let new = remap[group][old] {
                    corners[k] = new
                } else {
                    let new = UInt32(parts[group].positions.count)
                    parts[group].positions.append(mesh.positions[old])
                    remap[group][old] = new
                    corners[k] = new
                }
            }
            parts[group].triangles.append(corners)
        }
        return parts
    }

    /// Ganze Reparatur nach dem Einlesen: verschweißen, aufräumen, ausrichten, Löcher schließen.
    static func repair(soup: [SIMD3<Double>]) -> (mesh: IndexedMesh, report: MeshRepairReport) {
        var report = MeshRepairReport()
        let welded = weld(soup)
        var mesh = welded.mesh
        report.mergedPoints = welded.merged
        report.removedTriangles = removeDegenerate(&mesh)
        report.flippedTriangles = orient(&mesh)
        let holes = fillHoles(&mesh)
        report.closedHoles = holes.closed
        report.openHoles = holes.open
        if holes.closed > 0 {
            // Füllflächen können neue Kappen bilden; Ausrichtung danach noch einmal prüfen
            report.removedTriangles += removeDegenerate(&mesh)
            _ = orient(&mesh)
        }
        return (mesh, report)
    }

    // MARK: Reduzieren (Quadrik-Fehlermaß)

    /// Netz auf etwa target Dreiecke reduzieren (Kantenkollaps mit Quadrik-Fehlermaß, Ränder bleiben).
    static func simplify(_ mesh: IndexedMesh, target: Int) -> IndexedMesh {
        guard target > 3, mesh.triangles.count > target else { return mesh }
        var simplifier = QuadricSimplifier(mesh)
        simplifier.run(target: target)
        return simplifier.result()
    }

    // MARK: Verfeinern

    /// Kanten länger als maxEdge halbieren (mehrere Durchgänge), höchstens bis limit Dreiecke.
    /// only: nur Dreiecke, die diesen Bereich (Mitte, Radius) berühren; nil = überall.
    static func refine(_ mesh: IndexedMesh, maxEdge: Double, limit: Int,
                       only region: (center: SIMD3<Double>, radius: Double)? = nil) -> IndexedMesh {
        guard maxEdge > 0 else { return mesh }
        var current = mesh
        for _ in 0..<8 {
            guard let next = refineOnce(current, maxEdge: maxEdge, limit: limit, region: region) else { break }
            current = next
        }
        return current
    }

    private static func refineOnce(_ mesh: IndexedMesh, maxEdge: Double, limit: Int,
                                   region: (center: SIMD3<Double>, radius: Double)?) -> IndexedMesh? {
        let limitSquared = maxEdge * maxEdge
        var splits = Set<UInt64>()
        for t in mesh.triangles {
            let corners: [UInt32] = [t.x, t.y, t.z]
            if let region {
                let reach = region.radius + maxEdge * 2
                let near = corners.contains { simd_distance(mesh.positions[Int($0)], region.center) < reach }
                if !near { continue }
            }
            for j in 0..<3 {
                let a = corners[j], b = corners[(j + 1) % 3]
                if simd_distance_squared(mesh.positions[Int(a)], mesh.positions[Int(b)]) > limitSquared {
                    splits.insert(undirected(a, b))
                }
            }
        }
        guard !splits.isEmpty else { return nil }
        // Grobe Abschätzung: jede geteilte Kante erzeugt zwei Dreiecke mehr
        guard mesh.triangles.count + splits.count * 2 <= limit else { return nil }
        var result = mesh
        var middle: [UInt64: UInt32] = [:]
        for k in splits {
            let a = Int(k >> 32), b = Int(k & 0xFFFF_FFFF)
            middle[k] = UInt32(result.positions.count)
            result.positions.append((mesh.positions[a] + mesh.positions[b]) / 2)
        }
        var triangles: [SIMD3<UInt32>] = []
        triangles.reserveCapacity(mesh.triangles.count + splits.count * 2)
        for t in mesh.triangles {
            let v: [UInt32] = [t.x, t.y, t.z]
            let m: [UInt32?] = (0..<3).map { j in middle[undirected(v[j], v[(j + 1) % 3])] }
            let splitCount = m.compactMap { $0 }.count
            switch splitCount {
            case 0:
                triangles.append(t)
            case 1:
                let j = m.firstIndex(where: { $0 != nil }) ?? 0
                let a = v[j], b = v[(j + 1) % 3], c = v[(j + 2) % 3]
                let ab = m[j] ?? a
                triangles.append(SIMD3(a, ab, c))
                triangles.append(SIMD3(ab, b, c))
            case 2:
                // Kante j ist nicht geteilt: a → b bleibt, b → c und c → a sind geteilt
                let j = m.firstIndex(where: { $0 == nil }) ?? 0
                let a = v[j], b = v[(j + 1) % 3], c = v[(j + 2) % 3]
                let bc = m[(j + 1) % 3] ?? b, ca = m[(j + 2) % 3] ?? c
                triangles.append(SIMD3(bc, c, ca))
                triangles.append(SIMD3(a, b, bc))
                triangles.append(SIMD3(a, bc, ca))
            default:
                let ab = m[0] ?? v[0], bc = m[1] ?? v[1], ca = m[2] ?? v[2]
                triangles.append(SIMD3(v[0], ab, ca))
                triangles.append(SIMD3(ab, v[1], bc))
                triangles.append(SIMD3(ca, bc, v[2]))
                triangles.append(SIMD3(ab, bc, ca))
            }
        }
        result.triangles = triangles
        return result
    }
}

/// Kantenkollaps nach Garland/Heckbert in der schnellen Variante ohne Prioritätswarteschlange: in jedem Durchgang
/// werden Kanten unter einer wachsenden Fehlerschwelle zusammengezogen (nach „Fast Quadric Mesh Simplification“).
private struct QuadricSimplifier {
    /// Symmetrische 4×4-Matrix, Einträge 0…9 benutzt
    typealias Quadric = SIMD16<Double>

    struct Triangle {
        var v: SIMD3<Int>
        var error: SIMD4<Double> = .zero
        var deleted = false
        var dirty = false
        var normal = SIMD3<Double>(repeating: 0)
    }

    struct Vertex {
        var p: SIMD3<Double>
        var q = Quadric(repeating: 0)
        var tstart = 0
        var tcount = 0
        var border = false
    }

    struct Ref {
        var tid: Int
        var tvertex: Int
    }

    var triangles: [Triangle]
    var vertices: [Vertex]
    var refs: [Ref] = []

    init(_ mesh: IndexedMesh) {
        triangles = mesh.triangles.map { Triangle(v: SIMD3<Int>(Int($0.x), Int($0.y), Int($0.z))) }
        vertices = mesh.positions.map { Vertex(p: $0) }
    }

    static func plane(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Quadric {
        var q = Quadric(repeating: 0)
        q[0] = a * a
        q[1] = a * b
        q[2] = a * c
        q[3] = a * d
        q[4] = b * b
        q[5] = b * c
        q[6] = b * d
        q[7] = c * c
        q[8] = c * d
        q[9] = d * d
        return q
    }

    static func det(_ q: Quadric, _ a11: Int, _ a12: Int, _ a13: Int, _ a21: Int, _ a22: Int, _ a23: Int,
                    _ a31: Int, _ a32: Int, _ a33: Int) -> Double {
        let t1: Double = q[a11] * q[a22] * q[a33]
        let t2: Double = q[a13] * q[a21] * q[a32]
        let t3: Double = q[a12] * q[a23] * q[a31]
        let t4: Double = q[a13] * q[a22] * q[a31]
        let t5: Double = q[a11] * q[a23] * q[a32]
        let t6: Double = q[a12] * q[a21] * q[a33]
        return t1 + t2 + t3 - t4 - t5 - t6
    }

    static func vertexError(_ q: Quadric, _ p: SIMD3<Double>) -> Double {
        let x: Double = p.x, y: Double = p.y, z: Double = p.z
        let xx: Double = q[0] * x * x
        let xy: Double = q[1] * x * y
        let xz: Double = q[2] * x * z
        let xw: Double = q[3] * x
        let yy: Double = q[4] * y * y
        let yz: Double = q[5] * y * z
        let yw: Double = q[6] * y
        let zz: Double = q[7] * z * z
        let zw: Double = q[8] * z
        let squares: Double = xx + yy + zz + q[9]
        let mixed: Double = xy + xz + xw + yz + yw + zw
        return squares + 2 * mixed
    }

    /// Fehler beim Zusammenziehen von i0 und i1 und der beste Zielpunkt.
    func collapseError(_ i0: Int, _ i1: Int) -> (error: Double, point: SIMD3<Double>) {
        let q: Quadric = vertices[i0].q + vertices[i1].q
        let border = vertices[i0].border && vertices[i1].border
        let d = Self.det(q, 0, 1, 2, 1, 4, 5, 2, 5, 7)
        if d != 0, !border {
            let x: Double = -1 / d * Self.det(q, 1, 2, 3, 4, 5, 6, 5, 7, 8)
            let y: Double = 1 / d * Self.det(q, 0, 2, 3, 1, 5, 6, 2, 7, 8)
            let z: Double = -1 / d * Self.det(q, 0, 1, 3, 1, 4, 6, 2, 5, 8)
            let p = SIMD3<Double>(x, y, z)
            if p.x.isFinite, p.y.isFinite, p.z.isFinite {
                return (Self.vertexError(q, p), p)
            }
        }
        let p1 = vertices[i0].p, p2 = vertices[i1].p
        let p3: SIMD3<Double> = (p1 + p2) / 2
        let e1 = Self.vertexError(q, p1), e2 = Self.vertexError(q, p2), e3 = Self.vertexError(q, p3)
        let best = min(e1, min(e2, e3))
        if best == e1 { return (e1, p1) }
        if best == e2 { return (e2, p2) }
        return (e3, p3)
    }

    mutating func updateErrors(_ index: Int) {
        var t = triangles[index]
        for j in 0..<3 {
            t.error[j] = collapseError(t.v[j], t.v[(j + 1) % 3]).error
        }
        t.error[3] = min(t.error[0], min(t.error[1], t.error[2]))
        triangles[index] = t
    }

    /// Würde ein Dreieck um i0 beim Verschieben nach p umklappen? Dreiecke, die auch i1 enthalten, werden
    /// als gelöscht markiert.
    func flipped(_ p: SIMD3<Double>, _ i0: Int, _ i1: Int, _ deleted: inout [Bool]) -> Bool {
        let v0 = vertices[i0]
        for k in 0..<v0.tcount {
            let r = refs[v0.tstart + k]
            let t = triangles[r.tid]
            if t.deleted { continue }
            let s = r.tvertex
            let id1 = t.v[(s + 1) % 3], id2 = t.v[(s + 2) % 3]
            if id1 == i1 || id2 == i1 {
                deleted[k] = true
                continue
            }
            let e1: SIMD3<Double> = vertices[id1].p - p, e2: SIMD3<Double> = vertices[id2].p - p
            let l1 = simd_length(e1), l2 = simd_length(e2)
            if l1 < 1e-12 || l2 < 1e-12 { return true }
            let d1 = e1 / l1, d2 = e2 / l2
            if abs(simd_dot(d1, d2)) > 0.999 { return true }
            let n = simd_normalize(simd_cross(d1, d2))
            deleted[k] = false
            if simd_dot(n, t.normal) < 0.2 { return true }
        }
        return false
    }

    mutating func updateTriangles(_ i0: Int, _ v: Vertex, _ deleted: [Bool], _ deletedCount: inout Int) {
        for k in 0..<v.tcount {
            let r = refs[v.tstart + k]
            if triangles[r.tid].deleted { continue }
            if deleted[k] {
                triangles[r.tid].deleted = true
                deletedCount += 1
                continue
            }
            triangles[r.tid].v[r.tvertex] = i0
            triangles[r.tid].dirty = true
            updateErrors(r.tid)
            refs.append(r)
        }
    }

    mutating func updateMesh(iteration: Int) {
        if iteration > 0 {
            triangles.removeAll { $0.deleted }
        }
        if iteration == 0 {
            for i in vertices.indices { vertices[i].q = Quadric(repeating: 0) }
            for i in triangles.indices {
                let t = triangles[i]
                let p0 = vertices[t.v.x].p, p1 = vertices[t.v.y].p, p2 = vertices[t.v.z].p
                let c = simd_cross(p1 - p0, p2 - p0)
                let length = simd_length(c)
                let n: SIMD3<Double> = length > 0 ? c / length : SIMD3(0, 0, 1)
                triangles[i].normal = n
                let q = Self.plane(n.x, n.y, n.z, -simd_dot(n, p0))
                vertices[t.v.x].q += q
                vertices[t.v.y].q += q
                vertices[t.v.z].q += q
            }
            for i in triangles.indices { updateErrors(i) }
        }
        // Verweise Punkt → Dreiecke neu aufbauen
        for i in vertices.indices {
            vertices[i].tstart = 0
            vertices[i].tcount = 0
        }
        for t in triangles {
            vertices[t.v.x].tcount += 1
            vertices[t.v.y].tcount += 1
            vertices[t.v.z].tcount += 1
        }
        var start = 0
        for i in vertices.indices {
            vertices[i].tstart = start
            start += vertices[i].tcount
            vertices[i].tcount = 0
        }
        refs = [Ref](repeating: Ref(tid: 0, tvertex: 0), count: triangles.count * 3)
        for (index, t) in triangles.enumerated() {
            for j in 0..<3 {
                let vertex = t.v[j]
                refs[vertices[vertex].tstart + vertices[vertex].tcount] = Ref(tid: index, tvertex: j)
                vertices[vertex].tcount += 1
            }
        }
        // Randpunkte: Nachbarpunkte, die nur in einem Dreieck vorkommen, liegen auf einer offenen Kante
        if iteration == 0 {
            for i in vertices.indices {
                var counts: [Int: Int] = [:]
                let v = vertices[i]
                for k in 0..<v.tcount {
                    let t = triangles[refs[v.tstart + k].tid]
                    for j in 0..<3 { counts[t.v[j], default: 0] += 1 }
                }
                for (other, count) in counts where count == 1 {
                    vertices[other].border = true
                }
            }
        }
    }

    mutating func run(target: Int) {
        let startCount = triangles.count
        var deletedCount = 0
        for iteration in 0..<100 {
            if startCount - deletedCount <= target { break }
            if iteration % 5 == 0 { updateMesh(iteration: iteration) }
            for i in triangles.indices { triangles[i].dirty = false }
            let threshold: Double = 1e-9 * pow(Double(iteration + 3), 7)
            for i in triangles.indices {
                let t = triangles[i]
                if t.error[3] > threshold || t.deleted || t.dirty { continue }
                for j in 0..<3 where t.error[j] < threshold {
                    let i0 = t.v[j], i1 = t.v[(j + 1) % 3]
                    if vertices[i0].border != vertices[i1].border { continue }
                    let collapse = collapseError(i0, i1)
                    let p = collapse.point
                    var deleted0 = [Bool](repeating: false, count: vertices[i0].tcount)
                    var deleted1 = [Bool](repeating: false, count: vertices[i1].tcount)
                    if flipped(p, i0, i1, &deleted0) { continue }
                    if flipped(p, i1, i0, &deleted1) { continue }
                    vertices[i0].p = p
                    vertices[i0].q = vertices[i1].q + vertices[i0].q
                    let tstart = refs.count
                    let v0 = vertices[i0], v1 = vertices[i1]
                    updateTriangles(i0, v0, deleted0, &deletedCount)
                    updateTriangles(i0, v1, deleted1, &deletedCount)
                    let tcount = refs.count - tstart
                    if tcount <= vertices[i0].tcount {
                        for k in 0..<tcount { refs[vertices[i0].tstart + k] = refs[tstart + k] }
                    } else {
                        vertices[i0].tstart = tstart
                    }
                    vertices[i0].tcount = tcount
                    break
                }
                if startCount - deletedCount <= target { break }
            }
        }
    }

    func result() -> IndexedMesh {
        var mesh = IndexedMesh()
        var remap = [Int](repeating: -1, count: vertices.count)
        for t in triangles where !t.deleted {
            var corners = SIMD3<UInt32>(0, 0, 0)
            for j in 0..<3 {
                let old = t.v[j]
                if remap[old] < 0 {
                    remap[old] = mesh.positions.count
                    mesh.positions.append(vertices[old].p)
                }
                corners[j] = UInt32(remap[old])
            }
            guard corners.x != corners.y, corners.y != corners.z, corners.x != corners.z else { continue }
            mesh.triangles.append(corners)
        }
        return mesh
    }
}

// MARK: - Netz → Körper

/// Wandelt ein repariertes Netz im Kernel in einen Körper um.
enum MeshSolid {
    /// Mehr Dreiecke werden vor dem Umwandeln reduziert (das Umwandeln und die Anzeige werden sonst zu langsam).
    static let maxTriangles = 60_000

    static func shape(from mesh: IndexedMesh) -> PCKShape? {
        guard mesh.triangles.count >= 4 else { return nil }
        var coordinates: [Double] = []
        coordinates.reserveCapacity(mesh.positions.count * 3)
        for p in mesh.positions {
            coordinates.append(p.x)
            coordinates.append(p.y)
            coordinates.append(p.z)
        }
        var corners: [UInt32] = []
        corners.reserveCapacity(mesh.triangles.count * 3)
        for t in mesh.triangles {
            corners.append(t.x)
            corners.append(t.y)
            corners.append(t.z)
        }
        let pointData: Data = coordinates.withUnsafeBufferPointer { Data(buffer: $0) }
        let triangleData: Data = corners.withUnsafeBufferPointer { Data(buffer: $0) }
        return PCKShape.solid(meshPoints: pointData, triangles: triangleData, tolerance: 1e-3)
    }
}
