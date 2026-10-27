import Foundation
import simd

/// Stiftgesten der Skizze: Strich-Erkennung für das Linienwerkzeug (rund gezogen wird Kreis bzw. Bogen)
/// und Kritzeln zum Löschen, wie bei Shapr3D. Alles in lokalen Skizzenkoordinaten (mm).
enum StrokeGesture {
    enum Shape {
        case circle(center: Point2, radius: Double)
        /// Bogen vom Anfang zum Ende des Strichs durch mid
        case arc(mid: Point2)
    }

    static func length(_ points: [Point2]) -> Double {
        guard points.count > 1 else { return 0 }
        return (1..<points.count).reduce(0) { $0 + simd_distance(points[$1 - 1], points[$1]) }
    }

    /// Gleichmäßig nach Bogenlänge abgetastet (Abstand step).
    static func resample(_ points: [Point2], step: Double) -> [Point2] {
        guard let first = points.first, step > 0 else { return points }
        var result = [first]
        var previous = first
        var left = step
        for point in points.dropFirst() {
            var a = previous
            var segment = simd_distance(a, point)
            while segment >= left {
                let p = a + (point - a) * (left / segment)
                result.append(p)
                segment -= left
                a = p
                left = step
                if result.count > 2000 { return result }
            }
            left -= segment
            previous = point
        }
        if let last = points.last, simd_distance(result[result.count - 1], last) > step * 0.25 {
            result.append(last)
        }
        return result
    }

    /// Kreis nach kleinsten Quadraten (Kåsa-Verfahren); error = mittlere Abweichung relativ zum Radius.
    static func fitCircle(_ points: [Point2]) -> (center: Point2, radius: Double, error: Double)? {
        guard points.count >= 3 else { return nil }
        let mean = points.reduce(Point2.zero, +) / Double(points.count)
        var suu = 0.0, suv = 0.0, svv = 0.0, su = 0.0, sv = 0.0
        var bu = 0.0, bv = 0.0, b1 = 0.0
        for p in points {
            let u = p.x - mean.x, v = p.y - mean.y
            let b = -(u * u + v * v)
            suu += u * u
            suv += u * v
            svv += v * v
            su += u
            sv += v
            bu += u * b
            bv += v * b
            b1 += b
        }
        let n = Double(points.count)
        // (AᵀA) p = Aᵀb mit A-Zeilen [u, v, 1], Lösung nach Cramer
        let m = simd_double3x3(rows: [SIMD3(suu, suv, su), SIMD3(suv, svv, sv), SIMD3(su, sv, n)])
        let det = m.determinant
        guard abs(det) > 1e-12 else { return nil }
        let solution = m.inverse * SIMD3(bu, bv, b1)
        let d = solution.x, e = solution.y, f = solution.z
        let squared = (d * d + e * e) / 4 - f
        guard squared > 0 else { return nil }
        let radius = squared.squareRoot()
        let center = mean + Point2(-d / 2, -e / 2)
        let deviation = points.reduce(0) { $0 + abs(simd_distance($1, center) - radius) } / n
        return (center, radius, deviation / radius)
    }

    /// Überstrichener Winkel um center (Summe der Winkelschritte) und Summe der Beträge.
    private static func sweep(_ points: [Point2], around center: Point2) -> (signed: Double, absolute: Double) {
        var signed = 0.0, absolute = 0.0
        for i in 1..<points.count {
            let a = points[i - 1] - center, b = points[i] - center
            let step = atan2(a.x * b.y - a.y * b.x, simd_dot(a, b))
            signed += step
            absolute += abs(step)
        }
        return (signed, absolute)
    }

    /// Linienwerkzeug: Ist der Strich deutlich rund, wird er zum Kreis (geschlossen) bzw. Bogen.
    /// tolerance = Fangradius in mm (etwa 20 Bildschirmpunkte).
    static func recognize(_ raw: [Point2], tolerance: Double) -> Shape? {
        let total = length(raw)
        guard raw.count >= 6, total > tolerance * 3, let first = raw.first, let last = raw.last else { return nil }
        let chord = simd_distance(first, last)
        // Fast gerade: bleibt eine Linie
        guard total > chord * 1.15 else { return nil }
        let points = resample(raw, step: total / 64)
        guard points.count >= 8, let fit = fitCircle(points), fit.error < 0.12,
              fit.radius > tolerance * 0.5, fit.radius < total * 2 else { return nil }
        let turn = sweep(points, around: fit.center)
        // Hin und her um die Mitte (z. B. Zickzack) ist kein Bogen
        guard turn.absolute < abs(turn.signed) * 1.3 + 0.2 else { return nil }
        let angle = abs(turn.signed)
        if angle >= 1.6 * .pi, chord < fit.radius * 1.2 {
            return .circle(center: fit.center, radius: fit.radius)
        }
        guard angle >= 0.2 * .pi, angle < 1.9 * .pi else { return nil }
        let middle = points[points.count / 2] - fit.center
        guard simd_length(middle) > 1e-9 else { return nil }
        return .arc(mid: fit.center + simd_normalize(middle) * fit.radius)
    }

    /// Kritzeln: mehrfach hin und her (mindestens vier Umkehrungen), nicht rund.
    static func isScribble(_ raw: [Point2], tolerance: Double) -> Bool {
        let total = length(raw)
        guard raw.count >= 10, total > tolerance * 4 else { return false }
        let points = resample(raw, step: tolerance * 0.25)
        guard points.count >= 12 else { return false }
        // Hauptrichtung des Strichs (Hauptachse der Punktwolke)
        let mean = points.reduce(Point2.zero, +) / Double(points.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in points {
            let d = p - mean
            sxx += d.x * d.x
            sxy += d.x * d.y
            syy += d.y * d.y
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let axis = Point2(cos(theta), sin(theta))
        // Umkehrungen entlang der Hauptachse mit Hysterese
        let hysteresis = tolerance * 0.5
        var reversals = 0
        var direction = 0
        var extreme = simd_dot(points[0] - mean, axis)
        for p in points.dropFirst() {
            let t = simd_dot(p - mean, axis)
            if direction >= 0 {
                if t > extreme {
                    extreme = t
                    if direction == 0, t - simd_dot(points[0] - mean, axis) > hysteresis { direction = 1 }
                } else if extreme - t > hysteresis {
                    if direction == 1 { reversals += 1 }
                    direction = -1
                    extreme = t
                }
            } else {
                if t < extreme {
                    extreme = t
                } else if t - extreme > hysteresis {
                    reversals += 1
                    direction = 1
                    extreme = t
                }
            }
        }
        guard reversals >= 4 else { return false }
        if let fit = fitCircle(points), fit.error < 0.2 { return false }
        return true
    }

    /// Elemente, über die gekritzelt wurde (Abstand höchstens reach).
    static func scribbledEntities(_ raw: [Point2], entities: [SketchEntity], reach: Double) -> Set<Int> {
        let points = resample(raw, step: reach * 0.5)
        var hit = Set<Int>()
        for (index, entity) in entities.enumerated() {
            let touched = entity.drawing.contains { polyline in
                points.contains { polylineDistance(from: $0, to: polyline, closed: false).distance <= reach }
            }
            if touched { hit.insert(index) }
        }
        return hit
    }
}
