import Foundation
import simd

// Fläche versetzen robuster (Kai, Punkt 12): Gelingt der gemeinsame Versatz aller gewählten Flächen im Kernel nicht
// (z. B. Rundung plus ebene Oberseite), werden sie nacheinander versetzt. Die übrigen Flächen findet man nach jedem
// Schritt über ihre unveränderte Trägerfläche (Ebene bzw. Zylinder) wieder. Scheitert es ganz, nennt die Meldung
// den Grund und den größten Wert, der noch geht.

/// Trägerfläche einer Körperfläche, zum Wiederfinden nach einer Änderung.
private enum FaceSurface {
    case plane(point: SIMD3<Double>, normal: SIMD3<Double>, area: Double)
    case cylinder(origin: SIMD3<Double>, axis: SIMD3<Double>, radius: Double, area: Double)

    init?(_ shape: PCKShape, face: Int) {
        let area = shape.area(ofFace: face)
        if let v = shape.plane(ofFace: face)?.map(\.doubleValue), v.count == 6 {
            self = .plane(point: SIMD3(v[0], v[1], v[2]), normal: simd_normalize(SIMD3(v[3], v[4], v[5])), area: area)
        } else if let v = shape.cylinder(ofFace: face)?.map(\.doubleValue), v.count == 7 {
            self = .cylinder(origin: SIMD3(v[0], v[1], v[2]), axis: simd_normalize(SIMD3(v[3], v[4], v[5])),
                             radius: v[6], area: area)
        } else {
            return nil
        }
    }

    private var area: Double {
        switch self {
        case .plane(_, _, let area), .cylinder(_, _, _, let area): area
        }
    }

    /// Gleiche Trägerfläche (Lage und Ausrichtung), die Begrenzung darf sich geändert haben.
    private func matches(_ other: FaceSurface) -> Bool {
        let tolerance = 1e-5
        switch (self, other) {
        case let (.plane(p1, n1, _), .plane(p2, n2, _)):
            return simd_dot(n1, n2) > 1 - 1e-6 && abs(simd_dot(p2 - p1, n1)) < tolerance
        case let (.cylinder(o1, a1, r1, _), .cylinder(o2, a2, r2, _)):
            guard abs(r1 - r2) < tolerance, abs(simd_dot(a1, a2)) > 1 - 1e-6 else { return false }
            var offset: SIMD3<Double> = o2 - o1
            offset -= simd_dot(offset, a1) * a1
            return simd_length(offset) < tolerance
        default:
            return false
        }
    }

    /// Nummer der passenden Fläche in shape; bei mehreren die mit der ähnlichsten Größe.
    func find(in shape: PCKShape) -> Int? {
        let count = shape.faceCount
        guard count > 0 else { return nil }
        var best: (face: Int, difference: Double)?
        for face in 1...count {
            guard let candidate = FaceSurface(shape, face: face), matches(candidate) else { continue }
            let difference = abs(candidate.area - area)
            if best == nil || difference < best!.difference { best = (face, difference) }
        }
        return best?.face
    }
}

extension ModelStore {
    /// Flächen eines Körpers um distance versetzen: alle zugleich, sonst nacheinander.
    func offsetShape(_ shape: PCKShape, faces: [Int], distance: Double) -> PCKShape? {
        let numbers = faces.map { NSNumber(value: $0) }
        if let together = shape.offsetting(faces: numbers, distance: distance) { return together }
        guard faces.count > 1 else { return nil }
        let surfaces = faces.compactMap { FaceSurface(shape, face: $0) }
        guard surfaces.count == faces.count else { return nil }
        var current = shape
        for (index, surface) in surfaces.enumerated() {
            let face: Int
            if index == 0 {
                face = faces[0]
            } else {
                guard let found = surface.find(in: current) else { return nil }
                face = found
            }
            guard let next = current.offsetting(faces: [NSNumber(value: face)], distance: distance) else { return nil }
            current = next
        }
        return current
    }

    /// Größter Versatz in Richtung von distance, der noch gelingt (Halbierungssuche, wenige Kernel-Aufrufe).
    func largestOffset(_ shape: PCKShape, faces: [Int], toward distance: Double) -> Double? {
        var good = 0.0, bad = distance
        for _ in 0..<6 {
            let middle = (good + bad) / 2
            if offsetShape(shape, faces: faces, distance: middle) != nil { good = middle } else { bad = middle }
        }
        return abs(good) >= 0.01 ? good : nil
    }

    /// Meldung, warum das Versetzen nicht ging, mit dem größten möglichen Wert bzw. einem Tipp.
    func offsetFailureMessage(_ shape: PCKShape, faces: [Int], distance: Double) -> String {
        let unit = LengthUnit.current
        let wanted = unit.format(abs(distance))
        if let largest = largestOffset(shape, faces: faces, toward: distance) {
            return "Versetzen um \(wanted) nicht möglich – höchstens etwa \(unit.format(abs(largest))) "
                + "(sonst würden Nachbarflächen verschwinden)."
        }
        let curved = faces.contains { shape.plane(ofFace: $0) == nil }
        if curved {
            return "Die runde Fläche lässt sich nicht versetzen – meist geht sie ohne Kante (tangential) in eine "
                + "Nachbarfläche über. Tipp: diese Nachbarflächen mit antippen oder den Radius in der Skizze ändern."
        }
        return "Versetzen um \(wanted) nicht möglich – die Nachbarflächen lassen sich nicht bis dorthin verlängern."
    }
}
