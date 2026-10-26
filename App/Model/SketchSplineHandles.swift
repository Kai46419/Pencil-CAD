import Foundation
import simd

// Tangentengriffe an Fit-Splines (wie Fusion 360): Ist eine Fit-Spline im Pfeil-Werkzeug gewählt, zeigt jeder
// Fit-Punkt einen Griff aus zwei Armen. Ziehen am Armende ändert Richtung und Stärke der Tangente, Antippen eines
// geänderten Griffs stellt die automatische Tangente wieder her. Gespeichert wird die Tangente in der Spline
// (SketchEntity.spline(…, tangents:)); Anzeige und Kernel rechnen beide über fitBezierPoles.

extension SketchEntity {
    /// Tangenten nach einer Abbildung f der Punkte (Drehen, Spiegeln, Skalieren): f(p + t) − f(p), so drehen,
    /// spiegeln und skalieren sie mit.
    static func mappedTangents(_ tangents: [Point2?]?, points: [Point2], _ f: (Point2) -> Point2) -> [Point2?]? {
        guard let tangents else { return nil }
        var result: [Point2?] = []
        for (i, tangent) in tangents.enumerated() {
            guard let tangent, points.indices.contains(i) else {
                result.append(nil)
                continue
            }
            let base: Point2 = f(points[i])
            let tip: Point2 = f(points[i] + tangent)
            result.append(tip - base)
        }
        return result
    }
}

/// Ein Tangentengriff am Fit-Punkt index der Spline entity.
struct SplineTangentHandle {
    var entity: Int
    var index: Int
    var point: Point2
    /// Armende vorwärts (Richtung der Kurve) und rückwärts
    var forward: Point2
    var backward: Point2
    /// Tangente in Hermite-Form (mm); die Pole der Bézierkette liegen bei point ± tangent / 3
    var tangent: Point2
    /// true = eigene Tangente, false = automatisch
    var isCustom: Bool
}

extension SketchController {
    /// Laufendes Ziehen eines Tangentengriffs (gespeichert in splineHandleDrag).
    struct SplineHandleDrag {
        var entity: Int
        var index: Int
        /// Am rückwärtigen Arm gegriffen (Ziehen wirkt gespiegelt)
        var backward: Bool
        var start: Point2
        var tangent: Point2
        var hasMoved = false
    }

    /// Gewählte Fit-Splines, an denen Griffe erscheinen (nur im Pfeil-Werkzeug).
    var tangentHandleSplines: [Int] {
        guard tool == .select else { return [] }
        var result: [Int] = []
        for ref in selection where entities.indices.contains(ref.entity) && !result.contains(ref.entity) {
            if case .spline(let points, .fit, _, _) = entities[ref.entity], points.count >= 2 {
                result.append(ref.entity)
            }
        }
        return result
    }

    /// Griffe der gewählten Fit-Splines. unit = Weltmaß eines Bildschirmpunkts: kurze Arme werden auf eine
    /// greifbare Länge verlängert (die Richtung bleibt).
    func splineTangentHandles(unit: Double) -> [SplineTangentHandle] {
        let minimum: Double = 12 * unit
        var result: [SplineTangentHandle] = []
        for entity in tangentHandleSplines {
            guard case .spline(let points, _, let closed, let tangents) = entities[entity] else { continue }
            for index in points.indices {
                let tangent: Point2 = fitSplineTangent(points, closed: closed, index: index, tangents: tangents)
                let length: Double = simd_length(tangent) / 3
                guard length > 1e-9 else { continue }
                let direction: Point2 = tangent / simd_length(tangent)
                let arm: Point2 = direction * max(length, minimum)
                var custom = false
                if let tangents, tangents.indices.contains(index), tangents[index] != nil { custom = true }
                result.append(SplineTangentHandle(entity: entity, index: index, point: points[index],
                                                  forward: points[index] + arm, backward: points[index] - arm,
                                                  tangent: tangent, isCustom: custom))
            }
        }
        return result
    }

    /// Linien und Knöpfe der Griffe für den Viewport, getrennt nach automatisch und eigen.
    func splineTangentHandleGeometry(unit: Double)
        -> (automatic: [[Point2]], automaticKnobs: [Point2], custom: [[Point2]], customKnobs: [Point2]) {
        var automatic: [[Point2]] = [], custom: [[Point2]] = []
        var automaticKnobs: [Point2] = [], customKnobs: [Point2] = []
        for handle in splineTangentHandles(unit: unit) {
            let line: [Point2] = [handle.backward, handle.forward]
            if handle.isCustom {
                custom.append(line)
                customKnobs += [handle.backward, handle.forward]
            } else {
                automatic.append(line)
                automaticKnobs += [handle.backward, handle.forward]
            }
        }
        return (automatic, automaticKnobs, custom, customKnobs)
    }

    // MARK: Ziehen (Haken in began/moved/ended)

    /// true, wenn p ein Armende eines Tangentengriffs trifft (der Viewport beginnt dort keine Rahmenauswahl).
    func hitsSplineHandle(at p: Point2, tolerance: Double) -> Bool {
        handleHit(at: p, tolerance: tolerance) != nil
    }

    /// Stift setzt im Pfeil-Werkzeug auf: Armende eines Griffs getroffen? Dann übernimmt der Griff das Ziehen.
    func beginSplineHandleDrag(at p: Point2, tolerance: Double) -> Bool {
        splineHandleDrag = nil
        guard let hit = handleHit(at: p, tolerance: tolerance) else { return false }
        splineHandleDrag = SplineHandleDrag(entity: hit.handle.entity, index: hit.handle.index,
                                            backward: hit.backward, start: p, tangent: hit.handle.tangent)
        return true
    }

    /// Nächstes Armende unter p (tolerance = Fangweite, etwa 20 Bildschirmpunkte).
    private func handleHit(at p: Point2, tolerance: Double) -> (handle: SplineTangentHandle, backward: Bool)? {
        let handles = splineTangentHandles(unit: tolerance / 20)
        guard !handles.isEmpty else { return nil }
        var best: (distance: Double, handle: SplineTangentHandle, backward: Bool)?
        for handle in handles {
            for backward in [false, true] {
                let knob: Point2 = backward ? handle.backward : handle.forward
                let distance: Double = simd_distance(knob, p)
                // Liegt der Fit-Punkt selbst näher, wird er gezogen (wie bisher)
                guard distance <= tolerance * 0.7, distance < simd_distance(handle.point, p) else { continue }
                if distance < (best?.distance ?? .infinity) { best = (distance, handle, backward) }
            }
        }
        guard let found = best else { return nil }
        return (found.handle, found.backward)
    }

    /// Stift bewegt sich: Tangente aus dem Zustand beim Aufsetzen plus Versatz (Arm = Tangente / 3).
    func moveSplineHandleDrag(to p: Point2, tolerance: Double) -> Bool {
        guard var drag = splineHandleDrag else { return false }
        if !drag.hasMoved {
            // Kleines Zittern beim Tippen ist noch kein Ziehen
            guard simd_distance(p, drag.start) > tolerance * 0.15 else { return true }
        }
        let delta: Point2 = (p - drag.start) * 3
        let tangent: Point2 = drag.backward ? drag.tangent - delta : drag.tangent + delta
        guard simd_length(tangent) > 1e-6, let entity = withTangent(tangent, entity: drag.entity, index: drag.index) else {
            return true
        }
        let first = !drag.hasMoved
        drag.hasMoved = true
        splineHandleDrag = drag
        setDraggedElement(entity, at: drag.entity, begin: first, final: false)
        return true
    }

    /// Stift hebt ab: Ziehen abschließen bzw. Antippen eines eigenen Griffs setzt ihn auf automatisch zurück.
    func endSplineHandleDrag(at p: Point2, tolerance: Double) -> Bool {
        guard let drag = splineHandleDrag else { return false }
        if drag.hasMoved {
            _ = moveSplineHandleDrag(to: p, tolerance: tolerance)
            if entities.indices.contains(drag.entity) {
                setDraggedElement(entities[drag.entity], at: drag.entity, begin: false, final: true)
            }
            notice = "Tangente geändert – Griff antippen stellt die automatische wieder her."
        } else if let entity = withTangent(nil, entity: drag.entity, index: drag.index), isCustomTangent(drag) {
            setDraggedElement(entity, at: drag.entity, begin: true, final: true)
            notice = "Tangente wieder automatisch."
        }
        splineHandleDrag = nil
        return true
    }

    private func isCustomTangent(_ drag: SplineHandleDrag) -> Bool {
        guard entities.indices.contains(drag.entity),
              case .spline(_, _, _, let stored) = entities[drag.entity],
              let tangents = stored, tangents.indices.contains(drag.index) else { return false }
        return tangents[drag.index] != nil
    }

    /// Spline mit geänderter Tangente am Fit-Punkt index (nil = automatisch). nil, wenn keine Fit-Spline.
    private func withTangent(_ tangent: Point2?, entity: Int, index: Int) -> SketchEntity? {
        guard entities.indices.contains(entity),
              case .spline(let points, .fit, let closed, let tangents) = entities[entity],
              points.indices.contains(index) else { return nil }
        var list: [Point2?] = tangents ?? []
        if list.count < points.count {
            list += Array(repeating: nil, count: points.count - list.count)
        } else if list.count > points.count {
            list = Array(list.prefix(points.count))
        }
        list[index] = tangent
        let stored: [Point2?]? = list.contains(where: { $0 != nil }) ? list : nil
        return .spline(points: points, kind: .fit, closed: closed, tangents: stored)
    }
}
