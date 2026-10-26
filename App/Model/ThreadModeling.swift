import Foundation
import simd

// MARK: - Gewinde modellieren (Werkzeug „Gewinde“, Gewindebohrung)
//
// Außengewinde: Bolzen über die Gewindelänge durch einen Rohling mit dem Außen-Ø ersetzen, dann die
// schraubenförmige Nut abziehen. Innengewinde: Bohrung auffüllen, dann Kernzylinder samt Gang des Gegenstücks
// abziehen. An freien Enden läuft das Gewinde aus und bekommt den Anschnitt (45°-Fase bzw. 90°-Senkung).
// Die Reihenfolge ist mit OpenCASCADE durchprobiert: Schraubenflächen dürfen keine Randkante eines Zylinders kreuzen
// und nicht mit flachen Kegeln verrechnet werden – sonst liefert die Boolesche Operation stillschweigend nichts.
// Kegelige Gewinde (R, NPT): Flanken und Grund folgen dem Kegel 1:16, Spitzen sind zylindrisch abgeflacht
// (außen am kleinsten, innen am größten Ø), damit sie sicher zusammenpassen.

/// Zwei Richtungen senkrecht zu n.
private func threadBasis(_ n: SIMD3<Double>) -> (u: SIMD3<Double>, v: SIMD3<Double>) {
    let reference: SIMD3<Double> = abs(n.z) < 0.9 ? [0, 0, 1] : [1, 0, 0]
    let u = simd_normalize(simd_cross(reference, n))
    let v = simd_cross(n, u)
    return (u, v)
}

extension ModelStore {
    /// Zylinderfläche als Ziel für ein Gewinde: Achse, Länge, Bolzen oder Bohrung, freie Enden. nil bei anderen Flächen.
    func threadTarget(for face: FaceRef) -> ThreadTarget? {
        guard bodies.indices.contains(face.body), let cylinder = cylinder(of: face),
              let span = span(ofCylinderFace: face, origin: cylinder.origin, axis: cylinder.axis) else { return nil }
        let shape = bodies[face.body].shape
        let axis = cylinder.axis
        let low = cylinder.origin + axis * span.low
        let high = cylinder.origin + axis * span.high
        let lowOpen = threadEndIsOpen(shape, end: low, outward: -axis, radius: cylinder.radius,
                                      external: cylinder.convex)
        let highOpen = threadEndIsOpen(shape, end: high, outward: axis, radius: cylinder.radius,
                                       external: cylinder.convex)
        return ThreadTarget(body: face.body, origin: low, axis: axis, radius: cylinder.radius,
                            length: span.high - span.low, external: cylinder.convex, lowOpen: lowOpen,
                            highOpen: highOpen)
    }

    /// Ende frei? Prüfpunkte knapp hinter dem Ende: beim Bolzen etwas außerhalb seines Radius (Kopf, Absatz, Platte),
    /// in der Bohrung etwas innerhalb (Grund einer Sackbohrung, auch mit Bohrspitze).
    private func threadEndIsOpen(_ shape: PCKShape, end: SIMD3<Double>, outward: SIMD3<Double>, radius: Double,
                                 external: Bool) -> Bool {
        let basis = threadBasis(outward)
        let probeRadius = external ? radius + max(0.05, 0.02 * radius) : 0.9 * radius
        let beyond = min(0.5, max(0.05, 0.25 * radius))
        for k in 0..<4 {
            let angle = (Double(k) + 0.5) * .pi / 2
            let radial = basis.u * cos(angle) + basis.v * sin(angle)
            let point = end + outward * beyond + radial * probeRadius
            if shape.contains(point: point) { return false }
        }
        return true
    }

    /// Gewinde als Vorschau an der angetippten Zylinderfläche.
    func previewThread(_ spec: ThreadSpec) {
        guard requireKernel() else { return }
        guard let target = spec.target, bodies.indices.contains(target.body) else {
            dropPreview()
            return
        }
        let outcome = threadedBody(bodies[target.body].shape, spec: spec, target: target)
        guard let shape = outcome.shape else {
            message = outcome.error ?? "Gewinde hier nicht möglich."
            dropPreview()
            return
        }
        var preview = bodies
        preview[target.body] = preview[target.body].with(shape)
        message = threadSummary(spec, target: target)
        showPreview(preview, name: "Gewinde \(spec.designation)")
    }

    /// Kurzinfo: Bezeichnung, Art, Länge, Kern-Ø.
    func threadSummary(_ spec: ThreadSpec, target: ThreadTarget) -> String {
        let geometry = ThreadGeometry(family: spec.family, size: spec.size, pitch: spec.pitch,
                                      clearance: spec.clearance, external: target.external)
        let start = min(max(0, spec.offset), target.length)
        let wanted = spec.fullLength ? target.length : spec.length
        let length = max(0, min(target.length, start + wanted) - start)
        let kind = target.external ? "Außengewinde" : "Innengewinde"
        let lengthText = length.formatted(.number.precision(.fractionLength(0...2)))
        let core = (2 * geometry.minor(at: start)).formatted(.number.precision(.fractionLength(0...2)))
        let outer = (2 * geometry.major(at: start)).formatted(.number.precision(.fractionLength(0...2)))
        return "\(spec.designation) \(kind) · \(lengthText) mm · Ø \(outer) / Kern Ø \(core) mm (mit Spiel)"
    }

    /// Körper mit modelliertem Gewinde; bei Fehler nil und der Grund.
    func threadedBody(_ body: PCKShape, spec: ThreadSpec, target: ThreadTarget) -> (shape: PCKShape?, error: String?) {
        let p = spec.pitch
        guard p >= 0.1, spec.starts >= 1, spec.starts <= 4 else {
            return (nil, "Steigung bzw. Gangzahl ungültig.")
        }
        let external = target.external
        let fromHigh = spec.startsAtHigh(target)
        let inward = fromHigh ? -target.axis : target.axis
        let start = fromHigh ? target.origin + target.axis * target.length : target.origin
        let startOpen = fromHigh ? target.highOpen : target.lowOpen
        let endOpen = fromHigh ? target.lowOpen : target.highOpen

        // Gewindebereich ab dem Anfang
        let zFrom = min(max(0, spec.offset), target.length)
        let wanted = spec.fullLength ? target.length : spec.length
        let zTo = min(target.length, zFrom + wanted)
        guard zTo - zFrom > 0.05 else {
            let faceLength = target.length.formatted(.number.precision(.fractionLength(0...2)))
            return (nil, "Länge bzw. Versatz prüfen – die Fläche ist \(faceLength) mm lang.")
        }
        guard (zTo - zFrom) / spec.lead <= 300 else {
            return (nil, "Höchstens 300 Umdrehungen – kürzer machen oder größere Steigung wählen.")
        }
        // Gewinde läuft an freien Enden aus, die es erreicht
        let openStart = zFrom < 1e-6 && startOpen
        let openEnd = zTo > target.length - 1e-6 && endOpen
        let lead = spec.lead
        let extra = p + 0.5
        let geometry = ThreadGeometry(family: spec.family, size: spec.size, pitch: p, clearance: spec.clearance,
                                      external: external)
        let failed = "Gewinde ließ sich nicht mit dem Körper verrechnen – Länge oder Größe ändern."
        let numbers: (Double) -> [NSNumber]? = { z in
            ThreadProfile.kernelProfile(spec.family.form, pitch: p, major: geometry.major(at: z),
                                        external: external)?.map { NSNumber(value: $0) }
        }
        var shape = body

        if external {
            // Die Nut darf nicht über die Randkante des Bolzens laufen (dort scheitert die Boolesche Operation an
            // der Schraubenfläche): an freien Enden wird der Bolzen vorübergehend verlängert und das Gewinde danach
            // eben abgeschnitten; an Enden mit Material dahinter (Kopf, Absatz) endet die Nut kurz davor.
            let gap = max(0.3 * p, 0.2)
            let grooveFrom = openStart ? zFrom - extra : zFrom + gap
            let grooveTo = openEnd ? zTo + extra : zTo - gap
            guard grooveTo - grooveFrom > p else {
                return (nil, "Gewinde zu kurz – Länge vergrößern.")
            }
            let blankFrom = openStart ? grooveFrom - lead - 0.5 : zFrom
            let blankTo = openEnd ? grooveTo + lead + 0.5 : zTo
            guard geometry.minor(at: blankFrom) > 0.2, geometry.minor(at: blankTo) > 0.2 else {
                return (nil, "Gewinde \(spec.designation) ist für diesen Durchmesser zu fein bzw. zu tief.")
            }
            // Bolzen über die Gewindelänge durch einen Rohling mit dem Außen-Ø des Gewindes ersetzen (kegelig: der
            // kleinste Außen-Ø)
            let blankRadius = min(geometry.major(at: blankFrom), geometry.major(at: blankTo))
            if target.radius > blankRadius + 0.001 {
                guard let old = PCKShape.cylinder(base: start + inward * zFrom, axis: inward,
                                                  radius: target.radius + 0.02, height: zTo - zFrom),
                      let turned = shape.cutting(old) else { return (nil, failed) }
                shape = turned
            }
            guard let blank = PCKShape.cylinder(base: start + inward * blankFrom, axis: inward, radius: blankRadius,
                                                height: blankTo - blankFrom),
                  let filled = shape.fusing(blank) else { return (nil, failed) }
            shape = filled
            // Schraubenförmige Nut abziehen
            guard let profile = numbers(grooveFrom) else { return (nil, "Profil ungültig.") }
            guard let groove = PCKShape.thread(base: start + inward * grooveFrom, axis: inward,
                                               length: grooveTo - grooveFrom, lead: lead, starts: spec.starts,
                                               taper: geometry.taper, leftHanded: spec.leftHanded, profileRZ: profile,
                                               coreRadius: 0) else {
                return (nil, "Gewindegang konnte nicht erzeugt werden (Maße prüfen, Länge kürzen).")
            }
            guard let grooved = shape.cutting(groove) else { return (nil, failed) }
            shape = grooved
            // Verlängerung an den freien Enden abschneiden, dabei die Fase (Anschnitt) anbringen
            var ends: [(point: SIMD3<Double>, into: SIMD3<Double>, z: Double)] = []
            if openStart { ends.append((start, inward, 0)) }
            if openEnd { ends.append((start + inward * target.length, -inward, target.length)) }
            for end in ends {
                guard let trimmed = trimBoltEnd(shape, at: end.point, into: end.into, major: geometry.major(at: end.z),
                                                minor: geometry.minor(at: end.z), faceRadius: target.radius,
                                                beyond: extra + lead + 1.5, chamfer: spec.chamfer) else {
                    return (nil, failed)
                }
                shape = trimmed
            }
        } else {
            // Bohrung auffüllen (ohne Randkante läuft das Werkzeug sauber durch die Fläche), dann Kern samt Gang
            // des Gegenstücks abziehen; an freien Enden über die Fläche hinaus
            let toolFrom = openStart ? zFrom - extra : zFrom
            let toolTo = openEnd ? zTo + extra : zTo
            guard geometry.minor(at: toolFrom) > 0.2, geometry.minor(at: toolTo) > 0.2 else {
                return (nil, "Gewinde \(spec.designation) ist für diesen Durchmesser zu fein bzw. zu tief.")
            }
            guard let fill = PCKShape.cylinder(base: start + inward * zFrom, axis: inward, radius: target.radius + 0.01,
                                               height: zTo - zFrom),
                  let filled = shape.fusing(fill) else { return (nil, failed) }
            shape = filled
            guard let profile = numbers(toolFrom) else { return (nil, "Profil ungültig.") }
            guard let voidTool = PCKShape.thread(base: start + inward * toolFrom, axis: inward, length: toolTo - toolFrom,
                                             lead: lead, starts: spec.starts, taper: geometry.taper,
                                             leftHanded: spec.leftHanded, profileRZ: profile,
                                             coreRadius: geometry.minor(at: toolFrom)) else {
                return (nil, "Gewindegang konnte nicht erzeugt werden (Maße prüfen, Länge kürzen).")
            }
            guard let threaded = shape.cutting(voidTool) else { return (nil, failed) }
            shape = threaded
            // Senkung (Anschnitt) an den freien Enden
            if spec.chamfer {
                if openStart, let sunk = countersink(shape, at: start, into: inward, major: geometry.major(at: 0),
                                                     minor: geometry.minor(at: 0)) {
                    shape = sunk
                }
                if openEnd, let sunk = countersink(shape, at: start + inward * target.length, into: -inward,
                                                   major: geometry.major(at: target.length),
                                                   minor: geometry.minor(at: target.length)) {
                    shape = sunk
                }
            }
        }
        guard let valid = shape.validatedSolid() else {
            return (nil, "Ergebnis ist kein gültiger geschlossener Körper – Länge, Größe oder Spiel ändern.")
        }
        return (valid, nil)
    }

    /// Freies Bolzenende: alles jenseits der Endfläche abschneiden (Länge beyond), mit chamfer zusätzlich eine
    /// 45°-Fase vom Kern-Ø an der Endfläche bis zum Außen-Ø. into zeigt ins Material.
    private func trimBoltEnd(_ shape: PCKShape, at end: SIMD3<Double>, into dir: SIMD3<Double>, major: Double,
                             minor: Double, faceRadius: Double, beyond: Double, chamfer: Bool) -> PCKShape? {
        let outer = max(major, faceRadius) + 1
        let depth = major - minor
        let e = min(0.1, 0.2 * minor)
        guard chamfer, depth > 0, e > 0 else {
            guard let cutter = PCKShape.cylinder(base: end - dir * beyond, axis: dir, radius: outer,
                                                 height: beyond) else { return nil }
            return shape.cutting(cutter)
        }
        guard let big = PCKShape.cylinder(base: end - dir * beyond, axis: dir, radius: outer,
                                          height: beyond + depth + 2 * e),
              let keep = PCKShape.cone(base: end, axis: dir, bottomRadius: minor - e, topRadius: major + e,
                                       height: depth + 2 * e),
              let cutter = big.cutting(keep) else { return nil }
        return shape.cutting(cutter)
    }

    /// 90°-Senkung vom Außen- auf den Kern-Ø am Eingang einer Gewindebohrung; into zeigt ins Material.
    private func countersink(_ shape: PCKShape, at end: SIMD3<Double>, into dir: SIMD3<Double>, major: Double,
                             minor: Double) -> PCKShape? {
        let depth = major - minor
        let e = min(0.1, 0.2 * minor)
        guard depth > 0, e > 0,
              let sink = PCKShape.cone(base: end - dir, axis: dir, bottomRadius: major + e + 1, topRadius: minor - e,
                                       height: depth + 2 * e + 1) else { return nil }
        return shape.cutting(sink)
    }

    /// Länge einer durchgehenden Gewindebohrung: vom Punkt bis hinter das Ende des Körpers in Bohrrichtung.
    func threadReach(body: Int, from point: SIMD3<Double>, direction: SIMD3<Double>) -> Double {
        let indices = mesh.triangleIndices(ofBody: body)
        var far = 0.0
        for index in indices where Int(index) < mesh.vertices.count {
            let vertex = SIMD3<Double>(mesh.vertices[Int(index)].position)
            far = max(far, simd_dot(vertex - point, direction))
        }
        return far + 1
    }
}
