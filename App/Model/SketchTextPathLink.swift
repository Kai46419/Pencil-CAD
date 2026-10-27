import Foundation
import simd

// Text am Pfad: Bezug zur Kurve und Treffer auf der Schrift. Kai: „Die Verknüpfung bricht nach ein, zwei Mal …
// verschiebt man die Pfadlinie, folgt der Text nicht“ und „nach weiterem Zeichnen ist der Text schlecht wählbar“.
//
// Der Pfad merkt sich die Kurve über ihren Index (SketchTextPath.source). Damit der Bezug hält, wenn Elemente
// gelöscht, beschnitten, verlängert oder ersetzt werden, schreibt SketchController.removeEntities den Index jedes
// Texts mit um (remapped); eine durch genau ein neues Element ersetzte Kurve (Verlängern) bleibt verknüpft. Der
// Text folgt jeder Änderung der Kurve, auch während des Ziehens (followTextPaths in Sketch.swift).
// Treffer: Text am Pfad zählt über die tatsächlich gelegten Buchstabenumrisse, nicht über das umgebende Rechteck
// (das bei einem Bogen die ganze Fläche darunter abdeckt), und direkt auf einem Buchstaben geht er der Kurve vor,
// auf der er sitzt.

enum SketchTextPathLink {
    /// Indizes der Pfad-Quellen nach Entfernen bzw. Umsortieren von Elementen anpassen. map: alter Index → neuer
    /// (nil = Kurve entfernt: der Text bleibt, wo er ist, und folgt keiner Kurve mehr). Die Umrisse bleiben gleich.
    static func remapped(_ entities: [SketchEntity], map: (Int) -> Int?) -> [SketchEntity] {
        var result = entities
        for index in result.indices {
            guard case .text(var text) = result[index], var deform = text.deform, var path = deform.path,
                  let source = path.source else { continue }
            let target: Int? = map(source)
            if let target, target != index {
                path.source = target
                path.sourceCount = result.count
            } else {
                path.source = nil
                path.sourceCount = nil
            }
            deform.path = path
            text.deform = deform
            result[index] = .text(text)
        }
        return result
    }

    /// Kopien (Spiegeln, Muster) mit Text am Pfad: der kopierte Text folgt der Kopie seiner Kurve aus derselben
    /// Gruppe (gleicher Linienzug wie sein Pfad); ohne mitkopierte Kurve bleibt er als feste Form stehen, statt
    /// auf die Originalkurve zurückzuspringen. sources: Index des Originals je Kopie, first: Index der ersten Kopie.
    static func relinkedCopies(_ shapes: [SketchEntity], sources: [Int], first: Int) -> [SketchEntity] {
        var result = shapes
        for k in result.indices {
            guard case .text(var text) = result[k], var deform = text.deform, var path = deform.path,
                  let source = path.source else { continue }
            let match: Int? = result.indices.first { j in
                guard j != k, sources.indices.contains(j), sources[j] == source,
                      let curve = SketchTextPath.curve(of: result[j]) else { return false }
                return curve.closed == path.closed && samePoints(curve.points, path.points, tolerance: 1e-6)
            }
            path.source = match.map { first + $0 }
            path.sourceCount = nil
            deform.path = path
            text.deform = deform
            result[k] = .text(text)
        }
        return result
    }

    private static func samePoints(_ a: [Point2], _ b: [Point2], tolerance: Double) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where simd_distance(a[i], b[i]) > tolerance { return false }
        return true
    }
}

extension SketchText {
    /// Liegt p in einem Buchstaben (gefüllte Fläche eines Umrisses)?
    func glyphHit(_ p: Point2) -> Bool {
        for loop in loops {
            let polygon: [Point2] = loop.polygon
            if polygon.count >= 3, polygonContains(polygon, p) { return true }
        }
        return false
    }

    /// Treffer für Text am Pfad: in einem Buchstaben oder nahe an seinem Umriss (auch in den Lücken zwischen den
    /// Buchstaben), gemessen an den gelegten Umrissen.
    func pathOutlineContains(_ p: Point2, tolerance: Double) -> Bool {
        let scale: Double = max(transform?.scale ?? 1, 1e-6)
        let margin: Double = max(tolerance * 0.5, height * scale * 0.3)
        for loop in loops {
            let polygon: [Point2] = loop.polygon
            guard polygon.count >= 2 else { continue }
            if polygon.count >= 3, polygonContains(polygon, p) { return true }
            if polylineDistance(from: p, to: polygon, closed: true).distance <= margin { return true }
        }
        return false
    }
}

extension SketchController {
    /// Text am Pfad, auf dessen Buchstaben p liegt (zuletzt gezeichneter zuerst) – geht beim Antippen der Kurve
    /// vor, auf der die Schrift sitzt.
    func pathTextIndex(onGlyphAt p: Point2) -> Int? {
        for index in entities.indices.reversed() {
            guard case .text(let text) = entities[index], text.deform?.path != nil else { continue }
            if text.glyphHit(p) { return index }
        }
        return nil
    }
}
