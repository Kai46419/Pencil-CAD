import Foundation
import simd

// Angrenzende Skizzenbereiche vor dem Extrudieren zusammenfassen (Kai: Gewindestange mit vielen Zähnen).
//
// Ein Rechteck mit Zickzack-Linien darauf zerfällt in viele Bereiche (Kern plus je Zahn ein Dreieck). Wurden
// alle angetippt, entstand bisher je Bereich ein Prisma, und separatedSolids vereinigte danach Dutzende sich
// berührender Prismen mit einer booleschen Operation. Genau dort kann OpenCASCADE bei vielen gemeinsamen
// Seitenflächen abstürzen (Speicherzugriff im Kernel, den kein try/catch abfängt) – und es dauert bei jedem
// Ziehen am Pfeil neu. Hier werden gemeinsame Kanten der gewählten Bereiche gestrichen und die übrigen Kanten
// zu neuen Konturen verkettet: aus 81 Bereichen wird ein Profil, das der Kernel in einem Schritt extrudiert.

//
// Kai (später): „Jeder Volumenkörper ist ein eigener Körper, auch wenn es aus einer Skizze entstanden ist.“ Beim
// Modus „Neuer Körper“ wird darum nicht mehr zusammengefasst: jeder angetippte Bereich wird ein eigenes Prisma und
// ein eigener Körper (ModelStore.extrusionResult trennt per separatedParts, ohne zu vereinigen – der absturzgefährdete
// Fuse vieler Prismen entfällt dort ganz). Nur ab separateBodyLimit Bereichen (Zähne einer gezeichneten
// Gewindestange, Muster) werden angrenzende Bereiche wie bisher zu einem Profil zusammengefasst: Dutzende
// Einzelkörper wären dort nicht gemeint und machten Netz und Browser schwer. Beim Vereinigen, Abziehen und
// Schneiden bleibt das Zusammenfassen immer aktiv (das Werkzeug ist dort ohnehin ein einziger Körper).

enum SketchRegionMerge {
    /// Ab so vielen gewählten Bereichen werden auch bei „Neuer Körper“ angrenzende Bereiche zusammengefasst.
    static let separateBodyLimit = 24

    /// Bereiche, wie sie extrudiert werden: bei „Neuer Körper“ (bis separateBodyLimit) jeder einzeln, sonst
    /// angrenzende zusammengefasst. Für Vorschau und Verlauf gleich, damit dieselben Körper entstehen.
    static func forExtrusion(_ regions: [SketchRegion], mode: ExtrudeMode) -> [SketchRegion] {
        if mode == .newBody, regions.count <= separateBodyLimit { return regions }
        return merged(regions)
    }

    /// Hinweis, wenn bei „Neuer Körper“ wegen vieler Bereiche zusammengefasst wurde (sonst nil).
    static func newBodyNote(_ regions: [SketchRegion], mode: ExtrudeMode) -> String? {
        guard mode == .newBody, regions.count > separateBodyLimit else { return nil }
        let count = merged(regions).count
        guard count < regions.count else { return nil }
        return "\(regions.count) Bereiche: angrenzende zu \(count) Körper\(count == 1 ? "" : "n") zusammengefasst – "
            + "für Einzelkörper höchstens \(separateBodyLimit) Bereiche wählen."
    }

    /// Gewählte Bereiche mit gemeinsamen Kanten zu größeren Bereichen vereinigt. Ohne gemeinsame Kanten oder wenn
    /// sich die Konturen nicht sauber schließen, kommen die Bereiche unverändert zurück.
    static func merged(_ regions: [SketchRegion]) -> [SketchRegion] {
        guard regions.count > 1 else { return regions }
        // Nur Ketten aus Kurvenstücken (Bereiche aus der Teilflächen-Berechnung); Kreise, Ellipsen und
        // geschlossene Einzelsplines bleiben, wie sie sind.
        var segments: [SketchSegment] = []
        for region in regions {
            guard let outer = orientedSegments(region.outer, counterClockwise: true) else { return regions }
            segments += outer
            for hole in region.holes {
                guard let inner = orientedSegments(hole, counterClockwise: false) else { return regions }
                segments += inner
            }
        }
        guard segments.count >= 3, segments.count <= 20_000 else { return regions }

        // Gemeinsame Kanten: gleiche Endpunkte in Gegenrichtung (die Teilflächen teilen exakt dieselben Knoten)
        var byEnds: [EndKey: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            byEnds[EndKey(start: segment.start, end: segment.end), default: []].append(index)
        }
        var keep = [Bool](repeating: true, count: segments.count)
        var removed = 0
        for index in segments.indices where keep[index] {
            let segment = segments[index]
            guard let candidates = byEnds[EndKey(start: segment.end, end: segment.start)] else { continue }
            let middle = mean(segment)
            for other in candidates where other != index && keep[other] {
                guard simd_distance(mean(segments[other]), middle) < 1e-6 else { continue }
                keep[index] = false
                keep[other] = false
                removed += 2
                break
            }
        }
        guard removed > 0 else { return regions }
        let rest: [SketchSegment] = segments.indices.filter { keep[$0] }.map { segments[$0] }
        guard !rest.isEmpty, let loops = chains(rest) else { return regions }

        // Positive Umläufe sind Außenkonturen, negative Löcher (im kleinsten umgebenden Außenumriss)
        struct Outline {
            var loop: SketchLoop
            var polygon: [Point2]
            var area: Double
            var holes: [SketchLoop] = []
        }
        var outers: [Outline] = []
        var holes: [(loop: SketchLoop, probe: Point2)] = []
        for loop in loops {
            let polygon = loop.polygon
            let area = signedArea(polygon)
            if area > 1e-9 {
                outers.append(Outline(loop: loop, polygon: polygon, area: area))
            } else if area < -1e-9 {
                guard let probe = edgeMidpoint(polygon) else { return regions }
                holes.append((loop, probe))
            } else {
                // Entartete Restkontur: lieber wie bisher einzeln extrudieren
                return regions
            }
        }
        guard !outers.isEmpty else { return regions }
        for hole in holes {
            let container = outers.indices
                .filter { polygonContains(outers[$0].polygon, hole.probe) }
                .min { outers[$0].area < outers[$1].area }
            guard let container else { return regions }
            outers[container].holes.append(hole.loop)
        }
        return outers
            .map { SketchRegion(outer: $0.loop, holes: $0.holes, polygon: $0.polygon, area: $0.area) }
            .sorted { $0.area > $1.area }
    }

    // MARK: Hilfen

    private struct EndKey: Hashable {
        var start: Point2
        var end: Point2
    }

    /// Kurvenstücke einer Kontur in der gewünschten Umlaufrichtung; nil bei Konturen, die keine Kette sind.
    private static func orientedSegments(_ loop: SketchLoop, counterClockwise: Bool) -> [SketchSegment]? {
        guard case .chain(let pieces) = loop, pieces.count >= 2 else { return nil }
        for piece in pieces {
            let ends: [Point2] = [piece.start, piece.end]
            guard ends.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        }
        let area = signedArea(loop.polygon)
        guard abs(area) > 1e-12 else { return nil }
        if (area > 0) == counterClockwise { return pieces }
        return pieces.reversed().map(\.reversed)
    }

    private static func mean(_ segment: SketchSegment) -> Point2 {
        let samples = segment.samples
        guard !samples.isEmpty else { return (segment.start + segment.end) / 2 }
        return samples.reduce(Point2.zero, +) / Double(samples.count)
    }

    /// Richtung am Anfang bzw. Ende eines Kurvenstücks.
    private static func direction(_ segment: SketchSegment, atEnd: Bool) -> Point2 {
        let samples = segment.samples
        guard samples.count >= 2 else { return segment.end - segment.start }
        if atEnd { return samples[samples.count - 1] - samples[samples.count - 2] }
        return samples[1] - samples[0]
    }

    /// Verkettet gerichtete Kurvenstücke zu geschlossenen Konturen. An Knoten mit mehreren Fortsetzungen
    /// (zwei Bereiche berühren sich nur in einem Punkt) wird die am stärksten links abbiegende genommen, damit
    /// keine Acht entsteht. nil, wenn eine Kontur offen bleibt.
    private static func chains(_ segments: [SketchSegment]) -> [SketchLoop]? {
        let tolerance = 1e-6
        var unused = segments
        var loops: [SketchLoop] = []
        while let first = unused.popLast() {
            var chain = [first]
            var steps = 0
            while simd_distance(chain[chain.count - 1].end, chain[0].start) >= tolerance {
                steps += 1
                guard steps <= segments.count else { return nil }
                let last = chain[chain.count - 1]
                let end = last.end
                let incoming = direction(last, atEnd: true)
                var best: (index: Int, turn: Double)?
                for (index, candidate) in unused.enumerated() where simd_distance(candidate.start, end) < tolerance {
                    let outgoing = direction(candidate, atEnd: false)
                    let cross = incoming.x * outgoing.y - incoming.y * outgoing.x
                    let turn = atan2(cross, simd_dot(incoming, outgoing))
                    if turn > (best?.turn ?? -.infinity) { best = (index, turn) }
                }
                guard let best else { return nil }
                chain.append(unused.remove(at: best.index))
            }
            guard chain.count >= 2 else { return nil }
            loops.append(.chain(chain))
        }
        return loops
    }

    /// Mitte der längsten Polygonkante (Probepunkt eines Lochs).
    private static func edgeMidpoint(_ polygon: [Point2]) -> Point2? {
        guard polygon.count >= 2 else { return nil }
        var best: (index: Int, length: Double)?
        for i in polygon.indices {
            let length = simd_distance(polygon[i], polygon[(i + 1) % polygon.count])
            if length > (best?.length ?? 0) { best = (i, length) }
        }
        guard let best else { return nil }
        return (polygon[best.index] + polygon[(best.index + 1) % polygon.count]) / 2
    }
}
