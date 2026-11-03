import Foundation
import simd

// Loft mit Führungskurven und Tangentenbedingung (Fusion 360 „Rails“ bzw. „Direction“).
// Die erste Führung ist die Leitkurve, an der die Querschnitte entlanggeführt werden, eine zweite steuert die
// Verdrehung. Ohne Führung kann der Loft am ersten bzw. letzten Querschnitt senkrecht zur Skizzenebene auslaufen.

/// Führungskurve für den Loft: offene Kurven einer Skizze (alle oder einzelne Elemente).
struct LoftGuide: Hashable, Identifiable {
    var sketch: Int
    /// Elementnummern in der Skizze; leer = alle offenen Kurven der Skizze
    var entities: [Int] = []

    var id: String {
        let list: [String] = entities.map { String($0) }
        return "\(sketch):" + list.joined(separator: ",")
    }
}

/// Wählbare Führung im Menü „Führung hinzufügen“: ein offenes Kurvenelement einer Skizze.
struct LoftGuideCandidate: Identifiable {
    var entity: Int
    var title: String

    var id: Int { entity }
}

/// Einstellungen des Loft-Werkzeugs (Workspace.loft).
struct LoftSettings {
    var guides: [LoftGuide] = []
    /// Am ersten Querschnitt senkrecht zur Skizzenebene auslaufen
    var tangentStart = false
    /// Am letzten Querschnitt senkrecht zur Skizzenebene einlaufen
    var tangentEnd = false
    /// Einfluss der Tangentenbedingung: Anteil des Abstands zum Nachbarquerschnitt
    var tangentWeight: Double = 0.3

    /// Mehr Führungen verarbeitet der Kernel nicht (Leitkurve + Hilfsleitkurve)
    static let maxGuides = 2
}

extension ModelStore {
    // MARK: Führungen wählen

    /// Offene Kurven einer Skizze, die als Führung taugen (ohne Konstruktionsgeometrie).
    func loftGuideCandidates(inSketch index: Int) -> [LoftGuideCandidate] {
        guard sketches.indices.contains(index) else { return [] }
        let sketch = sketches[index]
        var result: [LoftGuideCandidate] = []
        for entity in sketch.entities.indices where !sketch.construction.contains(entity) {
            guard !sketch.entities[entity].openSegments.isEmpty else { continue }
            let title: String = Self.loftCurveName(sketch.entities[entity]) + " \(entity + 1)"
            result.append(LoftGuideCandidate(entity: entity, title: title))
        }
        return result
    }

    private static func loftCurveName(_ entity: SketchEntity) -> String {
        switch entity {
        case .line: "Linie"
        case .arc: "Bogen"
        case .spline: "Spline"
        case .polyline: "Linienzug"
        default: "Kurve"
        }
    }

    /// Anzeige einer Führung, z. B. „Skizze 3: Spline 2“.
    func loftGuideTitle(_ guide: LoftGuide) -> String {
        guard sketches.indices.contains(guide.sketch) else { return "Führung" }
        let sketch = sketches[guide.sketch]
        guard !guide.entities.isEmpty else { return sketch.name }
        let names: [String] = guide.entities.filter { sketch.entities.indices.contains($0) }.map { entity in
            Self.loftCurveName(sketch.entities[entity]) + " \(entity + 1)"
        }
        return sketch.name + ": " + names.joined(separator: ", ")
    }

    // MARK: Pfad der Führung

    /// Kurvenstücke der Führung (lokal), zu einer Kette verbunden. nil, wenn leer oder nicht zusammenhängend.
    func loftGuideSegments(_ guide: LoftGuide) -> [SketchSegment]? {
        guard sketches.indices.contains(guide.sketch) else { return nil }
        let sketch = sketches[guide.sketch]
        let chosen: [Int] = guide.entities.isEmpty
            ? sketch.entities.indices.filter { !sketch.construction.contains($0) }
            : guide.entities.filter { sketch.entities.indices.contains($0) }
        var segments: [SketchSegment] = chosen.flatMap { sketch.entities[$0].openSegments }
        guard let first = segments.popLast() else { return nil }
        var path: [SketchSegment] = [first]
        var extended = true
        while extended {
            extended = false
            for (i, s) in segments.enumerated() {
                let head = path[0].start
                let tail = path[path.count - 1].end
                if simd_distance(s.start, tail) < 1e-6 {
                    path.append(s)
                } else if simd_distance(s.end, tail) < 1e-6 {
                    path.append(s.reversed)
                } else if simd_distance(s.end, head) < 1e-6 {
                    path.insert(s, at: 0)
                } else if simd_distance(s.start, head) < 1e-6 {
                    path.insert(s.reversed, at: 0)
                } else {
                    continue
                }
                segments.remove(at: i)
                extended = true
                break
            }
        }
        // Übrige Stücke hängen nicht an: keine eindeutige Führung
        return segments.isEmpty ? path : nil
    }

    /// Führung als Kernel-Pfad, so gerichtet, dass sie beim ersten Querschnitt (first) beginnt.
    func loftGuidePath(_ guide: LoftGuide, first: SIMD3<Double>, last: SIMD3<Double>) -> [NSNumber]? {
        guard var path = loftGuideSegments(guide), let lastSegment = path.last else { return nil }
        let plane = sketches[guide.sketch].plane
        let start: SIMD3<Double> = plane.world(path[0].start)
        let end: SIMD3<Double> = plane.world(lastSegment.end)
        let forward: Double = simd_distance(start, first) + simd_distance(end, last)
        let backward: Double = simd_distance(end, first) + simd_distance(start, last)
        if backward < forward {
            path = path.reversed().map { $0.reversed }
        }
        let world = { (p: Point2) -> [NSNumber] in
            let w = plane.world(p)
            return [NSNumber(value: w.x), NSNumber(value: w.y), NSNumber(value: w.z)]
        }
        return path.flatMap { $0.code(world) }
    }

    // MARK: Loft

    /// Mitte eines Querschnitts in Weltkoordinaten (Mittel der Umrisspunkte).
    private static func loftCenter(_ region: SketchRegion, plane: SketchPlane) -> SIMD3<Double> {
        guard !region.polygon.isEmpty else { return plane.origin }
        var sum = Point2(0, 0)
        for p in region.polygon { sum += p }
        let mean: Point2 = sum / Double(region.polygon.count)
        return plane.world(mean)
    }

    /// Verschiebung der Hilfsquerschnitte für „tangential“: senkrecht zur Skizzenebene, zum Nachbarn hin.
    private static func tangentOffset(plane: SketchPlane, from center: SIMD3<Double>, toward neighbour: SIMD3<Double>,
                                      weight: Double) -> SIMD3<Double> {
        let delta: SIMD3<Double> = neighbour - center
        let along: Double = simd_dot(delta, plane.normal)
        // Liegt der Nachbar in der Skizzenebene, gibt es keine sinnvolle Richtung
        guard abs(along) > 1e-6, abs(along) > simd_length(delta) * 0.05 else { return .zero }
        let length: Double = abs(along) * max(0.05, min(weight, 0.45))
        let sign: Double = along > 0 ? 1 : -1
        return plane.normal * (sign * length)
    }

    /// Loft durch die gewählten Bereiche mit Führungen und Tangentenbedingung. Gelingt der Loft entlang der
    /// Führung nicht, wird er ohne Führung berechnet und eine Meldung gezeigt.
    func previewLoft(mode: ExtrudeMode, settings: LoftSettings) {
        let chosen = regions(selectedRegions)
        guard requireKernel(), chosen.count >= 2 else {
            dropPreview()
            return
        }
        let sections: [[NSNumber]] = chosen.compactMap { profileWires($0.region, plane: $0.plane).first }
        let centers: [SIMD3<Double>] = chosen.map { Self.loftCenter($0.region, plane: $0.plane) }
        guard sections.count == chosen.count, let firstCenter = centers.first, let lastCenter = centers.last else {
            message = "Loft nicht möglich."
            dropPreview()
            return
        }
        var note: String?
        func addNote(_ text: String) {
            if let previous = note {
                note = previous + " " + text
            } else {
                note = text
            }
        }
        var shape: PCKShape?
        let guides = Array(settings.guides.prefix(LoftSettings.maxGuides))
        if !guides.isEmpty {
            var paths: [[NSNumber]] = []
            for guide in guides {
                guard let path = loftGuidePath(guide, first: firstCenter, last: lastCenter) else {
                    note = "Führung „\(loftGuideTitle(guide))“ ist keine zusammenhängende Kurve – Loft ohne Führung."
                    paths = []
                    break
                }
                paths.append(path)
            }
            if !paths.isEmpty {
                shape = PCKShape.loft(sections: sections, guides: paths)
                if shape == nil {
                    note = "Loft entlang der Führung nicht möglich (sie muss am ersten Querschnitt beginnen und durch "
                        + "alle Querschnitte laufen) – ohne Führung berechnet."
                } else if settings.tangentStart || settings.tangentEnd {
                    note = "Mit Führung folgt der Loft der Führungskurve; „Tangential“ gilt nur ohne Führung."
                }
            }
        }
        if shape == nil {
            var startOffset = SIMD3<Double>(0, 0, 0)
            var endOffset = SIMD3<Double>(0, 0, 0)
            let count = chosen.count
            if settings.tangentStart {
                startOffset = Self.tangentOffset(plane: chosen[0].plane, from: centers[0], toward: centers[1],
                                                 weight: settings.tangentWeight)
            }
            if settings.tangentEnd {
                endOffset = Self.tangentOffset(plane: chosen[count - 1].plane, from: centers[count - 1],
                                               toward: centers[count - 2], weight: settings.tangentWeight)
            }
            let wantsTangent = settings.tangentStart || settings.tangentEnd
            if wantsTangent, startOffset == .zero, endOffset == .zero {
                addNote("Tangential: Querschnitte liegen nicht hintereinander – ohne Bedingung.")
            }
            if startOffset != .zero || endOffset != .zero {
                shape = PCKShape.loft(sections: sections, startOffset: startOffset, endOffset: endOffset)
                if shape == nil {
                    addNote("Tangential nicht möglich – ohne Bedingung berechnet.")
                }
            }
            if shape == nil {
                shape = PCKShape.loft(sections: sections)
            }
        }
        guard let solid = shape else {
            message = "Loft nicht möglich."
            dropPreview()
            return
        }
        showSolid([solid], sourceBody: chosen[0].plane.sourceBody, mode: mode, name: "Loft")
        if let note { message = note }
    }
}
