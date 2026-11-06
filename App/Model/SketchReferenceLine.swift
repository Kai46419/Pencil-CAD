import Foundation
import simd

// MARK: - Build 45: Bezugslinie beim Zeichnen (Kai)

// „Ich lasse den Stift über eine Linie schweben, du rastest mir die Linie ein und setzt davon ein paar Abhängigkeiten
// für die Linie, die ich zeichne.“ Stift 0,5 s über einer geraden Linie schweben lassen (nicht an ihren Enden – dort
// merkt das Schweben wie bisher den Punkt) bzw. sie mit dem Finger antippen: Sie wird blau zur Bezugslinie. Die nächste
// Linie rastet an ihr dreimal so weit und bevorzugt ein – parallel, gespiegelter Winkel, rechtwinklig und gleich lang.
// Beim Absetzen entstehen die Bedingungen wie bei jedem Fang (Parallel, Gleicher Winkel, Senkrecht, Gleiche Länge).
// Der Bezug gilt für eine Linie; noch einmal schweben bzw. antippen nimmt ihn weg.
extension SketchController {
    /// Bezugslinie, solange sie noch eine gerade, nicht konstruktive Linie der Skizze ist.
    var validReferenceLine: SketchCurveRef? {
        guard let ref = referenceLine, ref.index == 0, entities.indices.contains(ref.entity),
              !construction.contains(ref.entity), case .line = entities[ref.entity] else { return nil }
        return ref
    }

    /// Bezugslinie zum Hervorheben (blau), nur im Linienwerkzeug.
    var referenceLinePolyline: [Point2]? {
        guard clickKind == .line, let ref = validReferenceLine, case .line(let a, let b) = entities[ref.entity] else {
            return nil
        }
        return [a, b]
    }

    /// Gerade Linie unter p (Abstand ≤ tolerance, nicht an einem ihrer Enden) als Bezug setzen bzw. wieder wegnehmen.
    /// false = keine passende Linie (oder nicht das Linienwerkzeug).
    @discardableResult
    func toggleReferenceLine(at p: Point2, tolerance: Double) -> Bool {
        // Nur vor einer Linie: bei gesetztem Startpunkt soll Verweilen über einer Linie den Endpunkt dort lassen
        guard clickKind == .line, click.points.isEmpty, tolerance > 0, tolerance.isFinite else { return false }
        var best: (distance: Double, index: Int)?
        for index in entities.indices where !construction.contains(index) {
            guard case .line(let a, let b) = entities[index] else { continue }
            let segment = b - a
            let lengthSquared = simd_length_squared(segment)
            guard lengthSquared > 1e-18 else { continue }
            // An den Enden bleibt das Schweben beim Punktmerken
            if simd_distance(p, a) <= tolerance || simd_distance(p, b) <= tolerance { continue }
            let t = min(max(simd_dot(p - a, segment) / lengthSquared, 0), 1)
            let distance = simd_distance(p, a + segment * t)
            guard distance <= tolerance else { continue }
            if best == nil || distance < best!.distance { best = (distance, index) }
        }
        guard let found = best else { return false }
        let ref = SketchCurveRef(entity: found.index, index: 0)
        if validReferenceLine == ref {
            referenceLine = nil
            notice = nil
        } else {
            referenceLine = ref
            notice = "Bezug gesetzt: die nächste Linie rastet parallel, gespiegelt, rechtwinklig und gleich lang ein"
        }
        changed()
        return true
    }
}
