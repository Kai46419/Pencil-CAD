import Foundation
import simd

// Build 73 (Kai): Rundung bzw. Bohrung einer STL antippen und als EINE saubere Fläche nachbauen – mit wählbarem
// Radius (z. B. die Rundung „dicker“ machen). Erkannt wird der zusammenhängende Streifen schmaler ebener Flächen um
// die angetippte Stelle, der auf einem Kreis liegt:
// - Rundung (Teilkreis zwischen zwei Flächen): erst scharf machen (Keil abziehen bzw. auffüllen), dann die neue
//   scharfe Kante im Kernel mit dem gewünschten Radius abrunden → echte Rundungsfläche, später wie jede Rundung
//   änderbar.
// - Bohrung (ganz umlaufend, Material außen): auffüllen und mit dem gewünschten Durchmesser neu bohren.
// - Zapfen (ganz umlaufend, Material innen): auf den Umkreis bzw. den größeren Wunschdurchmesser vereinigen.

struct MeshRound {
    enum Kind {
        /// Innenrundung (Material zwischen Ecke und Bogen, Kreismitte in der Luft)
        case concaveFillet
        /// Außenrundung (abgerundete Kante)
        case convexFillet
        case hole
        case boss
    }

    var kind: Kind
    var body: Int
    /// Kreismitte bei Achskoordinate 0, Achse (Einheitsvektor), Radius (Umkreis der Netzpunkte)
    var origin: SIMD3<Double>
    var axis: SIMD3<Double>
    var radius: Double
    var start: Double
    var end: Double
    /// Rundung: Richtungen von der Kreismitte zu den Bogenenden (Einheitsvektoren senkrecht zur Achse)
    var endA = SIMD3<Double>(repeating: 0)
    var endB = SIMD3<Double>(repeating: 0)
    /// Öffnungswinkel des Bogens (Bogenmaß)
    var sweep: Double = 2 * .pi
    /// Bohrung: Ende ohne Boden (darf verlängert werden)
    var openStart = true
    var openEnd = true
    /// Umriss der erkannten Fläche zum Anzeigen (Strecken)
    var outline: [[SIMD3<Double>]] = []

    var isFillet: Bool { kind == .concaveFillet || kind == .convexFillet }
    var length: Double { end - start }

    var title: String {
        let unit = LengthUnit.current
        switch kind {
        case .concaveFillet, .convexFillet:
            let degrees = Int((sweep * 180 / .pi).rounded())
            return "\(kind == .concaveFillet ? "Innenrundung" : "Außenrundung") R \(unit.format(radius)), \(degrees)°"
        case .hole: return "Bohrung Ø \(unit.format(2 * radius))"
        case .boss: return "Zapfen Ø \(unit.format(2 * radius))"
        }
    }
}

enum MeshRounds {
    /// Zwei Dreiecke gelten als eine ebene Fläche bis 0,5° Knick
    private static let planarCos: Double = cos(0.5 * .pi / 180)
    /// Nachbarstreifen der Rundung knicken höchstens so stark ab
    private static let stepCos: Double = cos(50 * .pi / 180)

    // MARK: Erkennen

    /// Rundung bzw. Bohrung an der Stelle point (Weltpunkt auf dem Netz). nil, wenn dort keine ist.
    /// Build 74: mit second (zweiter Tipp) gilt der Bereich von der ersten bis zur letzten angetippten Seite der
    /// Rundung – auch bei unsauberen Netzen, wo die automatische Suche nicht weiß, wo die Rundung aufhört.
    static func detect(in mesh: IndexedMesh, body: Int, at point: SIMD3<Double>,
                       to second: SIMD3<Double>? = nil) -> MeshRound? {
        let positions = mesh.positions, triangles = mesh.triangles
        let count = triangles.count
        guard count >= 4 else { return nil }
        var normals = [SIMD3<Double>](repeating: SIMD3<Double>(repeating: 0), count: count)
        var areas = [Double](repeating: 0, count: count)
        var signedVolume: Double = 0
        for i in 0..<count {
            let t = triangles[i]
            guard Int(max(t.x, t.y, t.z)) < positions.count else { continue }
            let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
            let cross: SIMD3<Double> = simd_cross(b - a, c - a)
            let length: Double = simd_length(cross)
            areas[i] = length / 2
            if length > 1e-15 { normals[i] = cross / length }
            signedVolume += simd_dot(a, simd_cross(b, c)) / 6
        }
        let outward: Double = signedVolume >= 0 ? 1 : -1

        // Angetipptes Dreieck: Punkt liegt in seiner Ebene, nächster Schwerpunkt
        func triangle(at p: SIMD3<Double>) -> Int {
            var found = -1
            var best: Double = .infinity
            for i in 0..<count where areas[i] > 0 {
                let t = triangles[i]
                let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
                guard abs(simd_dot(p - a, normals[i])) < 0.05 else { continue }
                let d: Double = simd_distance(p, (a + b + c) / 3)
                if d < best {
                    best = d
                    found = i
                }
            }
            return found
        }
        let seed = triangle(at: point)
        guard seed >= 0 else { return nil }
        let lastSeed: Int = second.map { triangle(at: $0) } ?? -1
        if second != nil, lastSeed < 0 { return nil }

        // Kanten → Dreiecke
        var edgeTriangles: [SIMD2<UInt32>: [Int32]] = [:]
        edgeTriangles.reserveCapacity(count * 3 / 2 + 1)
        for i in 0..<count {
            let t = triangles[i]
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                edgeTriangles[SIMD2<UInt32>(min(a, b), max(a, b)), default: []].append(Int32(i))
            }
        }
        func neighbors(of i: Int) -> [Int] {
            let t = triangles[i]
            var list: [Int] = []
            for (a, b) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] {
                for other in edgeTriangles[SIMD2<UInt32>(min(a, b), max(a, b))] ?? [] where Int(other) != i {
                    list.append(Int(other))
                }
            }
            return list
        }

        // Ebene Gruppen (Streifen) – nur bei Bedarf, ausgehend von der angetippten Stelle
        var groupOf = [Int32](repeating: -1, count: count)
        var groups: [[Int]] = []
        func group(containing start: Int) -> Int {
            if groupOf[start] >= 0 { return Int(groupOf[start]) }
            let id = Int32(groups.count)
            var members = [start]
            var stack = [start]
            groupOf[start] = id
            while let current = stack.popLast() {
                for other in neighbors(of: current) where groupOf[other] < 0 && areas[other] > 0 {
                    guard simd_dot(normals[current], normals[other]) >= planarCos else { continue }
                    groupOf[other] = id
                    members.append(other)
                    stack.append(other)
                }
            }
            groups.append(members)
            return Int(id)
        }
        func groupNormal(_ g: Int) -> SIMD3<Double> {
            var sum = SIMD3<Double>(repeating: 0)
            for i in groups[g] { sum += normals[i] * areas[i] }
            return simd_length(sum) > 1e-15 ? simd_normalize(sum) : sum
        }
        func groupWidth(_ g: Int) -> Double {
            var area: Double = 0
            var low = SIMD3<Double>(repeating: .infinity), high = SIMD3<Double>(repeating: -.infinity)
            for i in groups[g] {
                area += areas[i]
                let t = triangles[i]
                for k in [t.x, t.y, t.z] {
                    low = simd_min(low, positions[Int(k)])
                    high = simd_max(high, positions[Int(k)])
                }
            }
            let diagonal: Double = simd_length(high - low)
            return diagonal > 1e-12 ? area / diagonal : 0
        }

        let first = group(containing: seed)
        // Bereich zwischen zwei Tipps: Achse aus beiden Normalen, nur Streifen mit Normale dazwischen
        let last: Int? = lastSeed >= 0 ? group(containing: lastSeed) : nil
        var rangeAxis: SIMD3<Double>?
        var rangeAngle: Double = 0
        var firstNormal = SIMD3<Double>(repeating: 0), lastNormal = SIMD3<Double>(repeating: 0)
        if let last {
            firstNormal = groupNormal(first)
            lastNormal = groupNormal(last)
            let cross: SIMD3<Double> = simd_cross(firstNormal, lastNormal)
            guard last != first, simd_length(cross) > 0.08 else { return nil }
            rangeAxis = simd_normalize(cross)
            rangeAngle = acos(max(-1, min(1, simd_dot(firstNormal, lastNormal))))
        }
        func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { acos(max(-1, min(1, simd_dot(a, b)))) }
        var accepted: [Int] = [first]
        var acceptedSet: Set<Int> = [first]
        var rejected: Set<Int> = []
        var widths: [Double] = [groupWidth(first)]
        var normalOf: [Int: SIMD3<Double>] = [first: groupNormal(first)]
        var queue: [Int] = [first]
        while let current = queue.popLast(), accepted.count < 2000 {
            var touching: Set<Int> = []
            for i in groups[current] {
                for other in neighbors(of: i) { touching.insert(group(containing: other)) }
            }
            for g in touching where !acceptedSet.contains(g) && !rejected.contains(g) {
                let n = normalOf[g] ?? groupNormal(g)
                normalOf[g] = n
                let bend: Double = simd_dot(n, normalOf[current] ?? n)
                let typical: Double = widths.sorted()[widths.count / 2]
                let width: Double = groupWidth(g)
                if let rangeAxis {
                    // Zwischen erster und letzter Seite: Normale senkrecht zur Achse und im Winkel dazwischen
                    let slack: Double = 2 * .pi / 180
                    guard bend >= stepCos, abs(simd_dot(n, rangeAxis)) < 0.15,
                          angle(n, firstNormal) <= rangeAngle + slack, angle(n, lastNormal) <= rangeAngle + slack else {
                        rejected.insert(g)
                        continue
                    }
                } else {
                    // Nachbarstreifen: leicht abgeknickt und ähnlich schmal (große Nachbarflächen gehören nicht dazu)
                    guard bend >= stepCos, bend < planarCos, width <= 2.5 * typical + 1e-6 else {
                        rejected.insert(g)
                        continue
                    }
                }
                accepted.append(g)
                acceptedSet.insert(g)
                widths.append(width)
                queue.append(g)
            }
        }
        guard accepted.count >= (last == nil ? 3 : 2) else { return nil }
        if let last, !acceptedSet.contains(last) { return nil }

        // Achse: Kreuzprodukt der am weitesten auseinander liegenden Normalen
        let list: [SIMD3<Double>] = accepted.compactMap { normalOf[$0] }
        var pair: (SIMD3<Double>, SIMD3<Double>, Double) = (list[0], list[0], 1)
        for i in list.indices {
            for j in list.indices where j > i {
                let d: Double = simd_dot(list[i], list[j])
                if d < pair.2 { pair = (list[i], list[j], d) }
            }
        }
        let crossAxis: SIMD3<Double> = simd_cross(pair.0, pair.1)
        guard rangeAxis != nil || simd_length(crossAxis) > 0.15 || pair.2 < -0.5 else { return nil }
        var axis: SIMD3<Double>
        if let rangeAxis {
            axis = rangeAxis
        } else if simd_length(crossAxis) > 0.15 {
            axis = simd_normalize(crossAxis)
        } else {
            // Fast gegenüberliegende Normalen (Halbkreis und mehr): Achse aus der Streuung
            var m = simd_double3x3(0)
            for n in list { m += simd_double3x3(columns: (n * n.x, n * n.y, n * n.z)) }
            axis = simd_normalize(MeshFeatures.symmetricEigen(m).vectors.0)
        }
        for n in list where abs(simd_dot(n, axis)) > (rangeAxis == nil ? 0.1 : 0.15) { return nil }

        // Querschnitt: Kreis durch alle Punkte
        let helper: SIMD3<Double> = abs(axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u: SIMD3<Double> = simd_normalize(simd_cross(axis, helper))
        let v: SIMD3<Double> = simd_cross(axis, u)
        var vertexSet = Set<UInt32>()
        var memberTriangles: [Int] = []
        for g in accepted {
            for i in groups[g] {
                memberTriangles.append(i)
                let t = triangles[i]
                vertexSet.insert(t.x)
                vertexSet.insert(t.y)
                vertexSet.insert(t.z)
            }
        }
        let vertices: [SIMD3<Double>] = vertexSet.map { positions[Int($0)] }
        let planar: [SIMD2<Double>] = vertices.map { SIMD2<Double>(simd_dot($0, u), simd_dot($0, v)) }
        guard let circle = MeshFeatures.fitCircle(planar) else { return nil }
        let r: Double = circle.radius
        guard r >= 0.1, r <= 1000 else { return nil }
        var largest: Double = 0
        var angles: [Double] = []
        var low: Double = .infinity, high: Double = -.infinity
        for (k, q) in planar.enumerated() {
            let d: SIMD2<Double> = q - circle.center
            let distance: Double = simd_length(d)
            // Mit zwei Tipps großzügiger (unsaubere Netze, z. B. Scans oder stark reduzierte Dateien)
            let tolerance: Double = rangeAxis == nil ? max(0.04 * r, 0.05) : max(0.12 * r, 0.3)
            guard abs(distance - r) <= tolerance else { return nil }
            largest = max(largest, distance)
            angles.append(atan2(d.y, d.x))
            let t: Double = simd_dot(vertices[k], axis)
            low = min(low, t)
            high = max(high, t)
        }
        guard high - low > 0.05 else { return nil }
        angles.sort()
        var gap: Double = angles[0] + 2 * .pi - angles[angles.count - 1]
        var gapEnd: Double = angles[0]  // Winkel nach der größten Lücke (Bogenanfang)
        var gapStart: Double = angles[angles.count - 1]
        for k in 1..<angles.count where angles[k] - angles[k - 1] > gap {
            gap = angles[k] - angles[k - 1]
            gapEnd = angles[k]
            gapStart = angles[k - 1]
        }
        let origin: SIMD3<Double> = u * circle.center.x + v * circle.center.y
        // Material innen oder außen?
        var facing: Double = 0, total: Double = 0
        for i in memberTriangles {
            let t = triangles[i]
            let c: SIMD3<Double> = (positions[Int(t.x)] + positions[Int(t.y)] + positions[Int(t.z)]) / 3
            let radial: SIMD3<Double> = c - origin - axis * simd_dot(c - origin, axis)
            let length: Double = simd_length(radial)
            guard length > 1e-12 else { continue }
            facing += areas[i] * simd_dot(normals[i] * outward, radial / length)
            total += areas[i]
        }
        guard total > 0, abs(facing) > 0.5 * total else { return nil }
        let inward: Bool = facing < 0

        var round = MeshRound(kind: inward ? .hole : .boss, body: body, origin: origin, axis: axis, radius: largest,
                              start: low, end: high)
        if gap > 70 * .pi / 180 {
            // Teilkreis: Rundung
            let sweep: Double = 2 * .pi - gap
            guard sweep >= 15 * .pi / 180, sweep <= 150 * .pi / 180 else { return nil }
            round.kind = inward ? .concaveFillet : .convexFillet
            round.sweep = sweep
            round.endA = u * cos(gapEnd) + v * sin(gapEnd)
            round.endB = u * cos(gapStart) + v * sin(gapStart)
        } else if inward {
            let floors = MeshRounds.floors(of: round, triangles: triangles, positions: positions, normals: normals,
                                          areas: areas, excluding: Set(memberTriangles))
            round.openStart = !floors.start
            round.openEnd = !floors.end
        }
        round.outline = outline(of: round)
        return round
    }

    private static func floors(of round: MeshRound, triangles: [SIMD3<UInt32>], positions: [SIMD3<Double>],
                               normals: [SIMD3<Double>], areas: [Double], excluding: Set<Int>) -> (start: Bool, end: Bool) {
        let reach: Double = 0.02 + 0.01 * round.length
        var atStart = false, atEnd = false
        for i in triangles.indices where areas[i] > 0 && !excluding.contains(i) {
            guard abs(simd_dot(normals[i], round.axis)) > 0.95 else { continue }
            let t = triangles[i]
            let c: SIMD3<Double> = (positions[Int(t.x)] + positions[Int(t.y)] + positions[Int(t.z)]) / 3
            let along: Double = simd_dot(c - round.origin, round.axis)
            let radial: Double = simd_length(c - round.origin - round.axis * along)
            guard radial < 0.9 * round.radius else { continue }
            if abs(along - round.start) <= reach { atStart = true }
            if abs(along - round.end) <= reach { atEnd = true }
        }
        return (atStart, atEnd)
    }

    /// Bögen an beiden Enden und Verbindungslinien (Anzeige im Viewport).
    static func outline(of round: MeshRound) -> [[SIMD3<Double>]] {
        let axis = round.axis
        let helper: SIMD3<Double> = abs(axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u0: SIMD3<Double> = round.isFillet ? round.endA : simd_normalize(simd_cross(axis, helper))
        let w: SIMD3<Double> = simd_cross(axis, u0)
        let sweep: Double = round.isFillet ? round.sweep : 2 * .pi
        // Richtung so, dass der Bogen von endA nach endB läuft
        let sign: Double = round.isFillet && simd_dot(simd_cross(round.endA, round.endB), axis) < 0 ? -1 : 1
        var lines: [[SIMD3<Double>]] = []
        for t in [round.start, round.end] {
            var arc: [SIMD3<Double>] = []
            for k in 0...32 {
                let a: Double = sign * sweep * Double(k) / 32
                arc.append(round.origin + axis * t + (u0 * cos(a) + w * sin(a)) * round.radius)
            }
            lines.append(arc)
        }
        if round.isFillet {
            for direction in [round.endA, round.endB] {
                let p: SIMD3<Double> = round.origin + direction * round.radius
                lines.append([p + axis * round.start, p + axis * round.end])
            }
        }
        return lines
    }

    // MARK: Ersetzen

    /// Erkannte Form im Körper durch eine echte Fläche ersetzen (langsam: im KernelThread aufrufen).
    /// target = gewünschter Radius. Ergebnis nil mit Grund bei Fehler.
    static func apply(_ round: MeshRound, to shape: PCKShape, radius target: Double) -> (shape: PCKShape?, note: String) {
        guard target > 0.01, target.isFinite else { return (nil, "Ungültiger Radius.") }
        switch round.kind {
        case .hole:
            return replaceHole(round, in: shape, radius: target)
        case .boss:
            guard target >= round.radius - 1e-6 else {
                return (nil, "Ein Zapfen lässt sich hier nur gleich groß oder größer machen.")
            }
            guard let tool = PCKShape.cylinder(base: round.origin + round.axis * round.start, axis: round.axis,
                                               radius: max(target, round.radius + 0.005), height: round.length),
                  let result = shape.fusing(tool), result.isClosedSolid else {
                return (nil, "Zapfen ließ sich nicht nachbauen.")
            }
            return (result, "Zapfen ist jetzt ein echter Zylinder")
        case .concaveFillet, .convexFillet:
            return replaceFillet(round, in: shape, radius: target)
        }
    }

    private static func replaceHole(_ round: MeshRound, in shape: PCKShape, radius target: Double) -> (shape: PCKShape?, note: String) {
        // Auffüllen (etwas größer als der Umkreis, genau über die Bohrungslänge), dann neu bohren
        guard let fill = PCKShape.cylinder(base: round.origin + round.axis * round.start, axis: round.axis,
                                           radius: round.radius + 0.01, height: round.length),
              let filled = shape.fusing(fill) else { return (nil, "Bohrung ließ sich nicht auffüllen.") }
        let before: Double = round.openStart ? 0.5 : 0
        let after: Double = round.openEnd ? 0.5 : 0
        guard let drill = PCKShape.cylinder(base: round.origin + round.axis * (round.start - before), axis: round.axis,
                                            radius: target, height: round.length + before + after),
              let result = filled.cutting(drill, fuzzy: 0), result.isClosedSolid else {
            return (nil, "Bohrung ließ sich nicht neu bohren.")
        }
        return (result, "Bohrung ist jetzt ein echter Zylinder (Ø \(LengthUnit.current.format(2 * target)))")
    }

    private static func replaceFillet(_ round: MeshRound, in shape: PCKShape, radius target: Double) -> (shape: PCKShape?, note: String) {
        // Ecke C: Schnitt der Tangenten an beiden Bogenenden (im Querschnitt)
        let bisector: SIMD3<Double> = round.endA + round.endB
        guard simd_length(bisector) > 1e-6 else { return (nil, "Rundung ist zu weit geöffnet.") }
        let half: Double = round.sweep / 2
        let cornerDistance: Double = round.radius / cos(half)
        let corner: SIMD3<Double> = round.origin + simd_normalize(bisector) * cornerDistance
        let a: SIMD3<Double> = round.origin + round.endA * round.radius
        let b: SIMD3<Double> = round.origin + round.endB * round.radius
        // Viereck Ecke – Bogenende – Kreismitte – Bogenende: enthält genau den Keil zwischen Bogen und Ecke
        // (dazu Material bzw. Luft, das ohnehin da ist)
        let cut: Bool = round.kind == .concaveFillet
        let margin: Double = cut ? 0.01 : 0
        let base: SIMD3<Double> = round.axis * (round.start - margin)
        var xyz: [NSNumber] = []
        for p in [corner, a, round.origin, b] {
            let q: SIMD3<Double> = p + base
            xyz += [NSNumber(value: q.x), NSNumber(value: q.y), NSNumber(value: q.z)]
        }
        guard let wedge = PCKShape.prism(pointsXYZ: xyz, direction: round.axis * (round.length + 2 * margin)) else {
            return (nil, "Keil ließ sich nicht bilden.")
        }
        let sharp: PCKShape? = cut ? shape.cutting(wedge, fuzzy: 1e-4) : shape.fusing(wedge)
        guard let sharp, sharp.isClosedSolid else { return (nil, "Ecke ließ sich nicht scharf machen.") }
        // Neue scharfe Kante: Strecke(n) auf der Geraden durch C parallel zur Achse
        var edges: [NSNumber] = []
        var seen = Set<Int>()
        for face in 1...max(1, sharp.faceCount) {
            for number in sharp.edgeNumbers(ofFace: face) {
                let edge = number.intValue
                guard !seen.contains(edge) else { continue }
                seen.insert(edge)
                guard let g = sharp.geometry(ofEdge: edge)?.map(\.doubleValue), g.count >= 8, g[0] == 0 else { continue }
                let s = SIMD3<Double>(g[2], g[3], g[4]), e = SIMD3<Double>(g[5], g[6], g[7])
                func offLine(_ p: SIMD3<Double>) -> Double {
                    let d: SIMD3<Double> = p - corner
                    return simd_length(d - round.axis * simd_dot(d, round.axis))
                }
                guard offLine(s) < 0.02, offLine(e) < 0.02, simd_distance(s, e) > 0.01 else { continue }
                edges.append(NSNumber(value: edge))
            }
        }
        guard !edges.isEmpty else { return (sharp, "Ecke ist scharf, die Kante zum Abrunden wurde aber nicht gefunden – bitte mit „Abrunden“ selbst runden.") }
        guard let rounded = sharp.filleting(edges: edges, radius: target), rounded.isClosedSolid else {
            return (sharp, "Ecke ist scharf, Abrunden mit R \(LengthUnit.current.format(target)) ging hier nicht – kleineren Radius versuchen oder mit „Abrunden“ selbst runden.")
        }
        return (rounded, "Rundung ist jetzt eine echte Fläche (R \(LengthUnit.current.format(target)))")
    }
}
