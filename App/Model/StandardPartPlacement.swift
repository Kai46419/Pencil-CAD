import Foundation
import simd

// Build 83 (Kai): Normteile genau setzen.
// - „In Loch zentrieren“: Schraube bzw. Hülse auf die Achse einer Bohrung (Kreiskante oder Bohrungswand antippen),
//   Kopf außen auf der Bohrungskante.
// - „Auf Schraube setzen“: Mutter bzw. Scheibe auf die Achse einer Schraube, aufliegend auf einer angetippten Fläche.
// - „Kopie“: gleiches Normteil noch einmal, z. B. für die nächste Bohrung.

extension ModelStore {
    /// Bohrung unter dem Tipp: Mitte der Kreiskante, Achse nach außen (vom Material weg), Radius.
    func holeCircle(face: FaceRef?, edge: EdgeRef?, near point: SIMD3<Double>?) -> (center: SIMD3<Double>, outward: SIMD3<Double>, radius: Double, body: Int)? {
        func circle(_ body: Int, _ number: Int) -> (center: SIMD3<Double>, axis: SIMD3<Double>, radius: Double)? {
            guard bodies.indices.contains(body),
                  let g = bodies[body].shape.geometry(ofEdge: number)?.map(\.doubleValue), g.count >= 15, g[0] == 1 else { return nil }
            let axis = SIMD3<Double>(g[11], g[12], g[13])
            guard simd_length(axis) > 0.5, g[14] > 0 else { return nil }
            return (SIMD3<Double>(g[8], g[9], g[10]), simd_normalize(axis), g[14])
        }
        var found: (center: SIMD3<Double>, axis: SIMD3<Double>, radius: Double)?
        var body = -1
        if let edge, let c = circle(edge.body, edge.edge) {
            found = c
            body = edge.body
        } else if let face, bodies.indices.contains(face.body),
                  let v = bodies[face.body].shape.cylinder(ofFace: face.face)?.map(\.doubleValue), v.count == 7 {
            // Bohrungswand: die Kreiskante dieser Fläche, die dem Tipp am nächsten liegt
            body = face.body
            var best: Double = .infinity
            for number in bodies[face.body].shape.edgeNumbers(ofFace: face.face) {
                guard let c = circle(face.body, number.intValue), abs(c.radius - v[6]) < 0.05 * v[6] + 0.01 else { continue }
                let d = point.map { simd_distance($0, c.center) } ?? 0
                if d < best {
                    best = d
                    found = c
                }
            }
        }
        guard let found, bodies.indices.contains(body) else { return nil }
        // Außen = die Seite ohne Material neben dem Bohrungsrand
        let helper = abs(found.axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let radial = simd_normalize(simd_cross(found.axis, helper))
        let ring = found.center + radial * (found.radius + 0.6)
        let shape = bodies[body].shape
        let step = 0.4
        var outward = found.axis
        if shape.contains(point: ring + found.axis * step), !shape.contains(point: ring - found.axis * step) {
            outward = -found.axis
        }
        return (found.center, outward, found.radius, body)
    }

    /// Normteil starr so bewegen, dass sein Ursprung auf origin liegt und seine Z-Achse nach up zeigt.
    @discardableResult
    func placePart(_ index: Int, origin desired: SIMD3<Double>, up: SIMD3<Double>, name: String, note: String) -> Bool {
        guard bodies.indices.contains(index), simd_length(up) > 0.5 else { return false }
        dropPreview()
        let target = simd_normalize(up)
        let old = bodies[index]
        let origin = SIMD3(old.placement.columns.3.x, old.placement.columns.3.y, old.placement.columns.3.z)
        let oldAxis = simd_normalize(SIMD3(old.placement.columns.2.x, old.placement.columns.2.y, old.placement.columns.2.z))
        let angle = acos(max(-1.0, min(1.0, simd_dot(oldAxis, target))))
        var axis = simd_cross(oldAxis, target)
        if simd_length(axis) < 1e-9 {
            let reference = abs(oldAxis.x) < 0.8 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            axis = simd_cross(oldAxis, reference)
        }
        axis = simd_normalize(axis)
        var shape = old.shape
        if angle > 1e-9 {
            guard let rotated = shape.rotated(origin: origin, axis: axis, angle: angle) else {
                message = "Teil lässt sich nicht ausrichten."
                return false
            }
            shape = rotated
        }
        let delta = desired - origin
        guard let moved = shape.translated(by: delta) else {
            message = "Teil lässt sich nicht platzieren."
            return false
        }
        let motion = simd_double4x4.translation(delta) * simd_double4x4.rotation(origin: origin, axis: axis, angle: angle)
        var result = bodies
        result[index] = old.with(moved, moving: motion)
        commit(result, name: name)
        selectBodies([index])
        message = note
        return true
    }

    /// Schraube bzw. Hülse mittig in die Bohrung unter dem Tipp.
    func centerPartInHole(_ index: Int, face: FaceRef?, edge: EdgeRef?, point: SIMD3<Double>?) -> Bool {
        guard bodies.indices.contains(index), let spec = bodies[index].effectiveStandardPart, spec.kind.fitsInHole else {
            message = "Erst eine Schraube oder Hülse wählen."
            return false
        }
        guard let hole = holeCircle(face: face, edge: edge, near: point), hole.body != index else {
            message = "Bitte die Kreiskante einer Bohrung oder die Bohrungswand antippen."
            return false
        }
        var note = "\(spec.bodyName) mittig in die Bohrung Ø \(LengthUnit.current.format(2 * hole.radius)) gesetzt."
        if spec.kind.isScrew, spec.metric.d > 2 * hole.radius + 1e-6 {
            note += " Achtung: Schraube ist dicker als die Bohrung."
        }
        return placePart(index, origin: hole.center, up: hole.outward, name: "In Loch zentrieren", note: note)
    }

    /// Mutter bzw. Scheibe auf die Achse der Schraube screw, aufliegend auf der ebenen Fläche face.
    func mountPart(_ index: Int, onScrew screw: Int, face: FaceRef) -> Bool {
        guard bodies.indices.contains(index), bodies.indices.contains(screw), index != screw,
              let spec = bodies[index].effectiveStandardPart, spec.kind.mountsOnScrew,
              bodies[screw].effectiveStandardPart?.kind.isScrew == true else {
            message = "Mutter bzw. Scheibe und eine Schraube wählen."
            return false
        }
        guard let plane = plane(of: face) else {
            message = "Bitte eine ebene Auflagefläche antippen."
            return false
        }
        let p = bodies[screw].placement
        let axisOrigin = SIMD3(p.columns.3.x, p.columns.3.y, p.columns.3.z)
        let axis = simd_normalize(SIMD3(p.columns.2.x, p.columns.2.y, p.columns.2.z))
        let normal = simd_normalize(plane.normal)
        let denominator = simd_dot(axis, normal)
        guard abs(denominator) > 0.2 else {
            message = "Die Fläche steht nicht quer zur Schraube."
            return false
        }
        let t = simd_dot(plane.origin - axisOrigin, normal) / denominator
        let seat = axisOrigin + axis * t
        return placePart(index, origin: seat, up: normal, name: "Auf Schraube setzen",
                         note: "\(spec.bodyName) auf \(bodies[screw].name) gesetzt.")
    }

    /// Gleiches Normteil noch einmal (an derselben Stelle, gewählt) – danach z. B. in die nächste Bohrung setzen.
    func duplicateStandardPart(_ index: Int) {
        guard bodies.indices.contains(index), bodies[index].effectiveStandardPart != nil else { return }
        var copy = bodies[index]
        copy.componentID = nil
        var result = bodies
        result.append(copy)
        commit(result, name: "Normteil kopieren")
        selectBodies([result.count - 1])
        message = "Kopie von \(copy.name) – jetzt z. B. „In Loch zentrieren“."
    }
}
