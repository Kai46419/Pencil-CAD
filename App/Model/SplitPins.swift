import Foundation
import simd

// Build 72: Verbindungszapfen beim Teilen mit einer Ebene (Körper teilen › Ebene › Verbindungszapfen), z. B. um ein
// großes Teil in druckbare Stücke zu zerlegen, die sich wieder genau zusammenstecken lassen. Beide Teile bekommen
// passende Bohrungen (mit Spiel), die Zapfen werden eigene Körper und separat gedruckt. Platz für einen Zapfen ist
// dort, wo rundherum genug Material liegt (Wand), geprüft mit Punkten im Körper.

struct SplitPinSpec {
    var count: Int = 2
    var diameter: Double = 5
    var length: Double = 10
    /// Spiel im Radius (FDM etwa 0,1–0,2 mm)
    var clearance: Double = 0.15
    /// Mindestwand um die Bohrung
    var wall: Double = 1.2
}

extension ModelStore {
    /// Zapfenmitten auf der Teilungsebene, an denen rundherum genug Material ist (höchstens spec.count, weit verteilt).
    func splitPinCenters(in shape: PCKShape, body: Int, origin: SIMD3<Double>, normal: SIMD3<Double>,
                         spec: SplitPinSpec) -> [SIMD3<Double>] {
        guard spec.count > 0, let box = mesh.bounds(ofBody: body) else { return [] }
        let n: SIMD3<Double> = simd_normalize(normal)
        let helper: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let u: SIMD3<Double> = simd_normalize(simd_cross(n, helper))
        let v: SIMD3<Double> = simd_cross(n, u)
        let low = SIMD3<Double>(box.min), high = SIMD3<Double>(box.max)
        var uMin: Double = .infinity, uMax: Double = -.infinity, vMin: Double = .infinity, vMax: Double = -.infinity
        for k in 0..<8 {
            let corner = SIMD3<Double>(k & 1 == 0 ? low.x : high.x, k & 2 == 0 ? low.y : high.y, k & 4 == 0 ? low.z : high.z)
            let d: SIMD3<Double> = corner - origin
            uMin = min(uMin, simd_dot(d, u))
            uMax = max(uMax, simd_dot(d, u))
            vMin = min(vMin, simd_dot(d, v))
            vMax = max(vMax, simd_dot(d, v))
        }
        guard uMax > uMin, vMax > vMin else { return [] }
        let holeRadius: Double = spec.diameter / 2 + spec.clearance
        let ring: Double = holeRadius + spec.wall
        let halfDepth: Double = spec.length / 2 + spec.clearance
        let steps = 10
        var valid: [SIMD3<Double>] = []
        for i in 0..<steps {
            for j in 0..<steps {
                let a: Double = uMin + (Double(i) + 0.5) / Double(steps) * (uMax - uMin)
                let b: Double = vMin + (Double(j) + 0.5) / Double(steps) * (vMax - vMin)
                let center: SIMD3<Double> = origin + u * a + v * b
                // Boden beider Bohrungen mit Wand darunter
                guard shape.contains(point: center + n * (halfDepth + spec.wall)),
                      shape.contains(point: center - n * (halfDepth + spec.wall)),
                      shape.contains(point: center) else { continue }
                var inside = true
                for k in 0..<8 where inside {
                    let angle: Double = Double(k) / 8 * 2 * .pi
                    let side: SIMD3<Double> = (u * cos(angle) + v * sin(angle)) * ring
                    for depth in [-halfDepth, 0, halfDepth] where !shape.contains(point: center + side + n * depth) {
                        inside = false
                        break
                    }
                }
                if inside { valid.append(center) }
            }
        }
        guard !valid.isEmpty else { return [] }
        let spacing: Double = 2 * ring
        if spec.count == 1 {
            var mean = SIMD3<Double>(repeating: 0)
            for p in valid { mean += p }
            mean /= Double(valid.count)
            return [valid.min { simd_distance($0, mean) < simd_distance($1, mean) } ?? valid[0]]
        }
        // Weit verteilt: erst das am weitesten entfernte Paar, dann jeweils der Punkt mit dem größten Abstand
        var chosen: [SIMD3<Double>] = []
        var best: (Int, Int, Double) = (0, 0, -1)
        for i in valid.indices {
            for j in valid.indices where j > i {
                let d: Double = simd_distance(valid[i], valid[j])
                if d > best.2 { best = (i, j, d) }
            }
        }
        chosen.append(valid[best.0])
        if best.2 >= spacing { chosen.append(valid[best.1]) }
        while chosen.count < spec.count {
            var candidate: (point: SIMD3<Double>, distance: Double)?
            for p in valid {
                let d: Double = chosen.map { simd_distance($0, p) }.min() ?? .infinity
                if d >= spacing, d > (candidate?.distance ?? -1) { candidate = (p, d) }
            }
            guard let candidate else { break }
            chosen.append(candidate.point)
        }
        return chosen
    }

    /// Bohrungen (mit Spiel) in beide Teile und Zapfen als eigene Körper. nil, wenn kein Platz für Zapfen ist.
    func splitPins(parts: [PCKShape], source: PCKShape, body: Int, origin: SIMD3<Double>, normal: SIMD3<Double>,
                   spec: SplitPinSpec) -> (parts: [PCKShape], pins: [PCKShape])? {
        let centers = splitPinCenters(in: source, body: body, origin: origin, normal: normal, spec: spec)
        guard !centers.isEmpty else { return nil }
        let n: SIMD3<Double> = simd_normalize(normal)
        let holeRadius: Double = spec.diameter / 2 + spec.clearance
        let halfDepth: Double = spec.length / 2 + spec.clearance
        let holes: [PCKShape] = centers.compactMap { center in
            PCKShape.cylinder(base: center - n * halfDepth, axis: n, radius: holeRadius, height: 2 * halfDepth)
        }
        guard holes.count == centers.count else { return nil }
        let tool: PCKShape? = holes.count == 1 ? holes[0] : PCKShape.compound(holes)
        guard let tool else { return nil }
        var drilled: [PCKShape] = []
        for part in parts {
            guard let cut = part.cutting(tool, fuzzy: 0) else { return nil }
            drilled.append(cut)
        }
        // Zapfen etwas kürzer als die Bohrungen tief sind (Spiel auch an den Enden)
        let pins: [PCKShape] = centers.compactMap { center in
            PCKShape.cylinder(base: center - n * (spec.length / 2), axis: n, radius: spec.diameter / 2,
                              height: spec.length)
        }
        return (drilled, pins)
    }
}
