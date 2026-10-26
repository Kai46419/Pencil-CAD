import Foundation
import simd

// MARK: - Dünn extrudieren, Helix, Sweep entlang Kanten, Verjüngung, Normteile

/// Seite der Wand beim dünnen Extrudieren (Fusion 360 „Dünn“).
enum ThinSide: String, CaseIterable, Identifiable {
    case inside = "Innen"
    case center = "Mitte"
    case outside = "Außen"

    var id: Self { self }

    /// Kodierung für PCKShape.thinPrism (0 = mittig, 1 = innen/Seite 1, 2 = außen/Seite 2)
    var kernelValue: Int {
        switch self {
        case .center: 0
        case .inside: 1
        case .outside: 2
        }
    }

    /// Bezeichnung bei offenen Linien (dort gibt es kein Innen und Außen)
    var lineTitle: String {
        switch self {
        case .inside: "Seite 1"
        case .center: "Mitte"
        case .outside: "Seite 2"
        }
    }
}

/// Querschnitt entlang der Schraubenlinie.
enum HelixProfile: String, CaseIterable, Identifiable {
    case spring = "Feder"
    case squareSpring = "Vierkantfeder"
    case thread = "Gewinde"

    var id: Self { self }
}

/// Einstellungen des Helix-Werkzeugs.
struct HelixSpec: Equatable {
    var profile: HelixProfile = .spring
    /// Federn: Ø bis Drahtmitte; Gewinde: Außen-Ø (bzw. Ø der angetippten Zylinderfläche)
    var diameter: Double = 20
    var pitch: Double = 5
    var height: Double = 30
    /// Draht-Ø bzw. Kantenlänge des Vierkantdrahts
    var wire: Double = 2
    var leftHanded = false
    var mode: ExtrudeMode = .newBody
    /// Achse: Fußpunkt und Richtung (Standard: Ursprung, Z)
    var origin: SIMD3<Double> = .zero
    var axis: SIMD3<Double> = [0, 0, 1]
    /// Gewinde in eine angetippte Zylinderfläche schneiden (convex = Bolzen, sonst Bohrung)
    var onCylinder = false
    var convex = true
    var sourceBody: Int?

    var turns: Double { pitch > 0 ? height / pitch : 0 }
}

extension ModelStore {
    // MARK: Dünn extrudieren

    /// Wände entlang der Konturen der Bereiche (Stärke und Seite aus regionThin…), Richtung wie extrudeRegions.
    func thinExtrudeRegions(_ regions: [SketchRegion], plane: SketchPlane, distance: Double, mode: ExtrudeMode) -> PCKShape? {
        guard !regions.isEmpty, distance != 0, regionThinThickness > 0, PCKShape.kernelAvailable else { return nil }
        let sign = plane.extrusionSign(mode: mode)
        let main = sign * distance
        let from: Double
        let length: Double
        switch regionDirection {
        case .oneSide:
            from = mode == .cut ? -sign * 0.01 : 0
            length = main - from
        case .symmetric:
            from = -main
            length = 2 * main
        case .twoSides:
            let second = abs(regionSecondValue) * (main >= 0 ? -1 : 1)
            from = second
            length = main - second
        }
        guard length != 0 else { return nil }
        var shapes: [PCKShape] = []
        for region in regions {
            guard let shape = PCKShape.thinPrism(profileWires: profileWires(region, plane: plane, offset: from),
                                                 planeOrigin: plane.origin + plane.normal * from, planeNormal: plane.normal,
                                                 thickness: regionThinThickness, side: regionThinSide.kernelValue,
                                                 direction: plane.normal * length) else { return nil }
            shapes.append(shape)
        }
        return shapes.count == 1 ? shapes[0] : PCKShape.compound(shapes)
    }

    /// Alle Linienzüge einer Skizze (verkettete Kurven, offen oder geschlossen) als Kernel-Konturen,
    /// um offset entlang der Normale verschoben.
    func lineChains(ofSketch index: Int, offset: Double = 0) -> [[NSNumber]] {
        guard sketches.indices.contains(index) else { return [] }
        let sketch = sketches[index]
        var segments = sketch.entities.indices.filter { !sketch.construction.contains($0) }
            .flatMap { sketch.entities[$0].openSegments }
        let plane = sketch.plane
        let shift = plane.normal * offset
        let world = { (p: Point2) -> [NSNumber] in
            let w = plane.world(p) + shift
            return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
        }
        var chains: [[NSNumber]] = []
        while let seed = segments.popLast() {
            var path = [seed]
            var extended = true
            while extended {
                extended = false
                for (i, s) in segments.enumerated() {
                    guard let last = path.last, let first = path.first else { break }
                    if simd_distance(s.start, last.end) < 1e-6 { path.append(s) }
                    else if simd_distance(s.end, last.end) < 1e-6 { path.append(s.reversed) }
                    else if simd_distance(s.end, first.start) < 1e-6 { path.insert(s, at: 0) }
                    else if simd_distance(s.start, first.start) < 1e-6 { path.insert(s.reversed, at: 0) }
                    else { continue }
                    segments.remove(at: i)
                    extended = true
                    break
                }
            }
            chains.append(path.flatMap { $0.code(world) })
        }
        return chains
    }

    /// Linien einer Skizze dünn extrudieren (auch offene Linienzüge): Wand der Stärke thickness, Höhe height
    /// entlang der Skizzennormale (symmetric: nach beiden Seiten).
    func previewThinLines(sketch index: Int?, thickness: Double, side: ThinSide, height: Double, symmetric: Bool,
                          mode: ExtrudeMode) {
        guard requireKernel(), let index, sketches.indices.contains(index), height != 0, thickness > 0 else {
            dropPreview()
            return
        }
        let sketch = sketches[index]
        let plane = sketch.plane
        let sign = plane.extrusionSign(mode: mode)
        let from = symmetric ? -sign * height : (mode == .cut ? -sign * 0.01 : 0)
        let length = symmetric ? 2 * sign * height : sign * height - from
        let chains = lineChains(ofSketch: index, offset: from)
        guard !chains.isEmpty else {
            message = "Diese Skizze hat keine Linien."
            dropPreview()
            return
        }
        var shapes: [PCKShape] = []
        for chain in chains {
            guard let shape = PCKShape.thinPrism(profileWires: [chain], planeOrigin: plane.origin + plane.normal * from,
                                                 planeNormal: plane.normal, thickness: thickness, side: side.kernelValue,
                                                 direction: plane.normal * length) else {
                message = "Dünne Wand mit \(thickness.formatted()) mm hier nicht möglich."
                dropPreview()
                return
            }
            shapes.append(shape)
        }
        guard let solid = shapes.count == 1 ? shapes.first : PCKShape.compound(shapes),
              let result = extrusionResult(solid, sourceBody: plane.sourceBody, mode: mode, sketch: sketch.id) else {
            dropPreview()
            return
        }
        message = nil
        showPreview(result, name: "Dünn extrudieren")
    }

    // MARK: Sweep entlang Körperkanten

    /// Gewählte Bereiche entlang zusammenhängender Kanten eines Körpers ziehen (SketchUp „Folge mir“).
    func previewSweep(alongEdges edges: [EdgeRef], mode: ExtrudeMode) {
        let chosen = regions(selectedRegions)
        guard requireKernel(), !chosen.isEmpty, let body = edges.first?.body, bodies.indices.contains(body) else {
            dropPreview()
            return
        }
        let numbers = edges.filter { $0.body == body }.map { NSNumber(value: $0.edge) }
        var shapes: [PCKShape] = []
        for entry in chosen {
            guard let shape = bodies[body].shape.sweep(profileWires: profileWires(entry.region, plane: entry.plane),
                                                       alongEdges: numbers) else {
                message = "Sweep entlang der Kanten nicht möglich (Kanten müssen zusammenhängen, Profil am Pfad)."
                dropPreview()
                return
            }
            shapes.append(shape)
        }
        showSolid(shapes, sourceBody: chosen[0].plane.sourceBody ?? body, mode: mode, name: "Sweep entlang Kanten")
    }

    // MARK: Helix

    /// Höhe einer Zylinderfläche entlang ihrer Achse: (unten, oben) als Abstand vom Achsursprung.
    func span(ofCylinderFace face: FaceRef, origin: SIMD3<Double>, axis: SIMD3<Double>) -> (low: Double, high: Double)? {
        let points = mesh.trianglePoints(of: face)
        guard !points.isEmpty else { return nil }
        var low = Double.infinity, high = -Double.infinity
        for point in points {
            let t = simd_dot(SIMD3<Double>(point) - origin, axis)
            low = min(low, t)
            high = max(high, t)
        }
        return high > low ? (low, high) : nil
    }

    /// Feder, Vierkantfeder oder Gewinde als Vorschau (neuer Körper bzw. mit den Körpern verrechnet).
    func previewHelix(_ spec: HelixSpec) {
        guard requireKernel() else { return }
        guard spec.pitch > 0, spec.height > 0, spec.diameter > 0, simd_length(spec.axis) > 1e-9 else {
            message = "Maße ungültig."
            dropPreview()
            return
        }
        guard spec.turns <= 200 else {
            message = "Höchstens 200 Windungen."
            dropPreview()
            return
        }
        let axis = simd_normalize(spec.axis)
        let r = spec.diameter / 2
        let p = spec.pitch
        var shape: PCKShape?
        var name = spec.profile.rawValue
        switch spec.profile {
        case .spring, .squareSpring:
            guard spec.wire > 0, spec.wire < p, spec.wire < spec.diameter, spec.height > spec.wire else {
                message = "Drahtstärke muss kleiner als die Steigung und der Durchmesser sein."
                dropPreview()
                return
            }
            // Feder steht auf dem Fußpunkt: Schraubenlinie um eine halbe Drahtstärke angehoben
            let base = spec.origin + axis * (spec.wire / 2)
            let height = spec.height - spec.wire
            if spec.profile == .spring {
                shape = PCKShape.spring(base: base, axis: axis, radius: r, pitch: p, height: height,
                                        leftHanded: spec.leftHanded, wireDiameter: spec.wire)
            } else {
                let h = spec.wire / 2
                let profile = [r - h, -h, r + h, -h, r + h, h, r - h, h].map { NSNumber(value: $0) }
                shape = PCKShape.helixSweep(base: base, axis: axis, radius: r, pitch: p, height: height,
                                            leftHanded: spec.leftHanded, profileRZ: profile)
            }
        case .thread:
            let w = 0.7 * p
            let depth = w / 2 * sqrt(3)
            if spec.onCylinder {
                // Nut in den Bolzen bzw. in die Bohrung schneiden, an beiden Enden eine Steigung über den Rand
                shape = PartBuilder.threadGroove(base: spec.origin - axis * p, axis: axis, radius: r, pitch: p,
                                                 length: spec.height + 2 * p, external: spec.convex)
                name = "Gewinde M\((spec.diameter).formatted())"
            } else {
                // Gewindestange: Kern plus Gewindegang (60°-Flanken), Gang innerhalb der Höhe
                let core = r - depth
                let eps = min(0.05, 0.1 * p)
                guard core > 0.2, spec.height > w + p else {
                    message = "Für ein Gewinde Durchmesser bzw. Höhe vergrößern oder Steigung verkleinern."
                    dropPreview()
                    return
                }
                let profile = [core - eps, -w / 2, r, 0, core - eps, w / 2].map { NSNumber(value: $0) }
                if let ridge = PCKShape.helixSweep(base: spec.origin + axis * (w / 2), axis: axis, radius: r, pitch: p,
                                                   height: spec.height - w, leftHanded: spec.leftHanded, profileRZ: profile),
                   let rod = PCKShape.cylinder(base: spec.origin, axis: axis, radius: core, height: spec.height) {
                    shape = rod.fusing(ridge)
                }
                name = "Gewindestange"
            }
        }
        guard let shape else {
            message = "Schraubenlinie mit diesen Maßen nicht möglich."
            dropPreview()
            return
        }
        let mode: ExtrudeMode = spec.profile == .thread && spec.onCylinder ? .cut : spec.mode
        if mode == .newBody {
            message = nil
            showPreview(bodies + [newBody(shape, name: name)], name: name)
            return
        }
        guard let result = extrusionResult(shape, sourceBody: spec.sourceBody, mode: mode) else {
            dropPreview()
            return
        }
        message = nil
        showPreview(result, name: name)
    }

    // MARK: Verjüngung

    /// Flächen eines Körpers gegen die Zugrichtung pull neigen; Neutralebene am unteren Ende des Körpers.
    func previewDraft(faces: [FaceRef], pull: SIMD3<Double>, angle: Double) {
        guard requireKernel(), let body = faces.first?.body, bodies.indices.contains(body),
              simd_length(pull) > 1e-9 else {
            dropPreview()
            return
        }
        guard angle != 0 else {
            dropPreview()
            return
        }
        let direction = simd_normalize(pull)
        var low = 0.0
        if let box = mesh.bounds(ofBody: body) {
            low = .infinity
            for k in 0..<8 {
                let corner = SIMD3<Double>(Double(k & 1 == 0 ? box.min.x : box.max.x),
                                           Double(k & 2 == 0 ? box.min.y : box.max.y),
                                           Double(k & 4 == 0 ? box.min.z : box.max.z))
                low = min(low, simd_dot(corner, direction))
            }
        }
        let numbers = faces.filter { $0.body == body }.map { NSNumber(value: $0.face) }
        guard let result = bodies[body].shape.drafting(faces: numbers, pull: direction, neutralOrigin: direction * low,
                                                       angle: angle) else {
            message = "Verjüngung um \(angle.formatted())° hier nicht möglich (Seitenflächen wählen, kleineren Winkel versuchen)."
            dropPreview()
            return
        }
        message = nil
        var preview = bodies
        preview[body] = preview[body].with(result)
        showPreview(preview, name: "Verjüngung")
    }

    // MARK: Normteile und Vorlagen

    /// Neue Körper (z. B. Normteil) als Vorschau einfügen; Übernahme mit „Fertig“, rückgängig machbar.
    func previewGenerated(_ parts: [(shape: PCKShape, name: String)]?, step: String) {
        guard requireKernel() else { return }
        guard let parts, !parts.isEmpty else {
            message = "Mit diesen Maßen nicht möglich."
            dropPreview()
            return
        }
        var preview = bodies
        for part in parts {
            preview.append(SceneBody(shape: part.shape, name: part.name,
                                     color: SceneBody.palette[preview.count % SceneBody.palette.count]))
        }
        message = nil
        showPreview(preview, name: step)
    }
}
