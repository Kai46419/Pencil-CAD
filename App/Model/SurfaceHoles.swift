import Foundation
import simd

// MARK: - Bohrungen und Gewindebohrungen auf beliebigen Flächen
//
// Bohrungswerkzeug und Gewinde-Werkzeug setzen Bohrungen auf ebene und gewölbte Flächen (Oberseite, Unterseite,
// Seiten, Rundungen): Achse = Flächennormale am Tippunkt, gebohrt wird ins Material. An nach innen gewölbten
// Flächen (Hohlkehle, Innenseite eines Rohrs) beginnt das Werkzeug höher, damit es sauber aus der Fläche austritt.

/// Stelle auf einer Fläche: Punkt, Normale aus dem Körper heraus und ob die Fläche eben ist.
struct SurfaceSpot {
    var point: SIMD3<Double>
    var normal: SIMD3<Double>
    var planar: Bool
}

/// Zwei Richtungen senkrecht zu n.
private func spotBasis(_ n: SIMD3<Double>) -> (u: SIMD3<Double>, v: SIMD3<Double>) {
    let reference: SIMD3<Double> = abs(n.z) < 0.9 ? [0, 0, 1] : [1, 0, 0]
    let u: SIMD3<Double> = simd_normalize(simd_cross(reference, n))
    let v: SIMD3<Double> = simd_cross(n, u)
    return (u, v)
}

extension ModelStore {
    /// Punkt einer Fläche (eben oder gewölbt), der point am nächsten liegt, mit der Normale dort (aus dem Körper).
    func surfacePoint(of face: FaceRef, near point: SIMD3<Double>) -> SurfaceSpot? {
        guard bodies.indices.contains(face.body) else { return nil }
        if let plane = plane(of: face) {
            let n: SIMD3<Double> = simd_normalize(plane.normal)
            let projected: SIMD3<Double> = point - n * simd_dot(point - plane.anchor, n)
            return SurfaceSpot(point: projected, normal: n, planar: true)
        }
        guard let values = bodies[face.body].shape.surfacePoint(ofFace: face.face, near: point)?.map(\.doubleValue),
              values.count == 6 else { return nil }
        let n = SIMD3<Double>(values[3], values[4], values[5])
        guard simd_length(n) > 1e-12 else { return nil }
        let spot = SIMD3<Double>(values[0], values[1], values[2])
        return SurfaceSpot(point: spot, normal: simd_normalize(n), planar: false)
    }

    /// Bohrstelle beim Antippen: auf ebenen Flächen rastet der Punkt an Ecken, Kantenmitten und Kreismitten (wie
    /// bisher), auf gewölbten Flächen nur, wenn der Fangpunkt auf der Fläche liegt.
    func holeSpot(on face: FaceRef, near point: SIMD3<Double>, tolerance: Double) -> SurfaceSpot? {
        let snapped: SIMD3<Double> = snappedModelPoint(point, tolerance: tolerance)
        if let onFace = surfacePoint(of: face, near: snapped) {
            if onFace.planar || simd_distance(onFace.point, snapped) < 1e-3 { return onFace }
        }
        return surfacePoint(of: face, near: point)
    }

    /// Abstand über der Tangentialebene, ab dem das Bohrwerkzeug beginnt: eben bzw. nach außen gewölbt 0,05 mm; an
    /// nach innen gewölbten Flächen so hoch, dass Prüfpunkte am Werkzeugrand nicht mehr im Material liegen.
    func holeLift(_ shape: PCKShape, at point: SIMD3<Double>, outward n: SIMD3<Double>, radius: Double,
                  planar: Bool) -> Double {
        let base: Double = 0.05
        guard !planar, radius > 0 else { return base }
        let basis = spotBasis(n)
        let candidates: [Double] = [base, 0.25 * radius, 0.5 * radius, radius, 1.5 * radius, 2 * radius]
        for lift in candidates {
            var free = true
            for k in 0..<8 {
                let angle: Double = Double(k) * .pi / 4
                let radial: SIMD3<Double> = basis.u * cos(angle) + basis.v * sin(angle)
                let probe: SIMD3<Double> = point + n * lift + radial * radius
                if shape.contains(point: probe) {
                    free = false
                    break
                }
            }
            if free { return lift }
        }
        return 2 * radius + base
    }

    /// Läuft die Zylinderfläche ganz herum (zusammen mit gleichachsigen Flächen gleichen Radius, z. B. zwei
    /// Hälften)? Bolzen und Bohrungen ja; Rundungen wie ein gerundetes Ende oder eine Hohlkehle nicht.
    func isFullRound(_ face: FaceRef, target: ThreadTarget) -> Bool {
        guard bodies.indices.contains(face.body) else { return false }
        let shape = bodies[face.body].shape
        let axis: SIMD3<Double> = simd_normalize(target.axis)
        let tolerance: Double = max(1e-3, 1e-4 * target.radius)
        // Flächen desselben Körpers auf demselben Zylinder
        var faces: Set<FaceRef> = [face]
        var checked: Set<FaceRef> = [face]
        for ref in mesh.triangleFaces where ref.body == face.body && !checked.contains(ref) {
            checked.insert(ref)
            guard let v = shape.cylinder(ofFace: ref.face)?.map(\.doubleValue), v.count == 7 else { continue }
            let otherAxis: SIMD3<Double> = simd_normalize(SIMD3(v[3], v[4], v[5]))
            guard abs(v[6] - target.radius) < tolerance, abs(simd_dot(otherAxis, axis)) > 0.9999 else { continue }
            var offset: SIMD3<Double> = SIMD3(v[0], v[1], v[2]) - target.origin
            offset -= axis * simd_dot(offset, axis)
            if simd_length(offset) < tolerance { faces.insert(ref) }
        }
        // Winkel aller Netzpunkte dieser Flächen um die Achse; größte Lücke klein = ganz herum
        let basis = spotBasis(axis)
        var angles: [Double] = []
        for (t, ref) in mesh.triangleFaces.enumerated() where faces.contains(ref) {
            for k in 0..<3 {
                let index = Int(mesh.indices[t * 3 + k])
                guard index < mesh.vertices.count else { continue }
                let p = SIMD3<Double>(mesh.vertices[index].position)
                let relative: SIMD3<Double> = p - target.origin
                angles.append(atan2(simd_dot(relative, basis.v), simd_dot(relative, basis.u)))
            }
        }
        guard angles.count >= 3 else { return true }
        angles.sort()
        var gap: Double = angles[0] + 2 * .pi - angles[angles.count - 1]
        for i in 1..<angles.count {
            gap = max(gap, angles[i] - angles[i - 1])
        }
        return gap < 1.2
    }
}

extension HoleSpec {
    /// Größter Radius des Bohrwerkzeugs an der Fläche (Bohrung, Senkung bzw. Gewinde-Außen-Ø).
    var toolRadius: Double {
        var radius: Double = (diameter + clearance) / 2
        if kind != .simple {
            radius = max(radius, (counterDiameter + clearance) / 2)
        }
        if let thread {
            radius = max(radius, (thread.size.diameter + clearance) / 2 + 0.1)
        }
        return radius
    }
}

// MARK: - Gewindebohrung im Gewinde-Werkzeug

/// Gewindebohrungen am Tippunkt (Gewinde-Werkzeug auf Flächen, die kein Bolzen und keine Bohrung sind).
struct ThreadHoleSettings {
    var points: [HolePoint] = []
    var depth: Double = 10
    var through = false
    var drillPoint = false
    /// Sackloch: Ende des Gewindes (bis Grund, DIN 76, eigenes Maß)
    var runout: ThreadRunout = .bottom
    var runoutLength: Double = 8
    /// Zuletzt angetippte Stelle auf einem Bolzen bzw. in einer Bohrung (für „Gewindebohrung hier“)
    var lastTap: HolePoint?
}

extension ThreadSpec {
    /// Bohrung mit Gewinde aus den Einstellungen des Gewinde-Werkzeugs (gleiche Logik wie im Bohrungswerkzeug).
    func holeSpec(_ settings: ThreadHoleSettings) -> HoleSpec {
        var thread = HoleThread()
        thread.family = family
        thread.sizeIndex = sizeIndex
        thread.pitch = pitch
        thread.leftHanded = leftHanded
        thread.cosmetic = cosmetic
        thread.runout = settings.runout
        thread.runoutLength = settings.runoutLength
        var spec = HoleSpec()
        spec.kind = .simple
        spec.diameter = (thread.tapDrill * 100).rounded() / 100
        spec.depth = settings.depth
        spec.through = settings.through
        spec.drillPoint = settings.drillPoint
        spec.clearance = clearance
        spec.thread = thread
        return spec
    }
}
