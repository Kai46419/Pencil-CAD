import Foundation
import QuartzCore
import simd

// Radiusgriff an Bögen und Kreisen (Kai: „Wenn ich den Bogen gezogen habe, fehlt mir im Auswahlwerkzeug ein Punkt,
// um den Kreis oder Bogen ein bisschen größer zu machen.“). Ein gewählter Bogen zeigt am Scheitel (Mitte des
// Bogens), ein gewählter Kreis rechts oben auf dem Rand einen Ring mit Doppelpfeil. Ziehen vom Mittelpunkt weg macht
// den Radius größer, zum Mittelpunkt hin kleiner – stufenlos mit Rasterung je nach Zoom, das Maßfeld zeigt mit.
// Geändert wird über dasselbe Maß am Element wie beim Eintippen (dragEntityDimension → changeEntityDimension):
// Bogenenden gleiten auf den Nachbarlinien, der Rest der Skizze steht. Ein Ziehvorgang = ein Rückgängig-Schritt.

/// Radiusgriff eines Bogens bzw. Kreises.
struct SketchRadiusHandle {
    var entity: Int
    /// Lage des Griffs (Scheitel des Bogens bzw. Punkt auf dem Kreis)
    var point: Point2
    /// Richtung vom Mittelpunkt zum Griff (Länge 1): so zieht man größer
    var outward: Point2
    var center: Point2
    var radius: Double
    /// Maß am Element: Radius (Bogen) bzw. Durchmesser (Kreis)
    var kind: SketchDimension.Kind
}

extension SketchController {
    /// Laufendes Ziehen eines Radiusgriffs (gespeichert in radiusHandleDrag).
    struct RadiusHandleDrag {
        var entity: Int
        var kind: SketchDimension.Kind
        var start: Point2
        var outward: Point2
        /// Radius beim Aufsetzen
        var radius: Double
        /// Bildschirmmaß beim Aufsetzen (Fangweite, etwa 20 Punkte in mm)
        var tolerance: Double
        var hasMoved = false
        /// Der Schritt zum Rückgängigmachen ist angelegt (beim ersten gelungenen Ändern)
        var remembered = false
        /// Zuletzt angewandter bzw. noch anzuwendender Maßwert (Radius bzw. Durchmesser)
        var applied: Double?
        var pending: Double?
        var lastApply: CFTimeInterval = 0
    }

    /// Mindestabstand zweier Lösungen beim Ziehen (der Löser läuft je Bild, der Stift liefert bis zu 240 Punkte/s)
    private static let radiusDragInterval: CFTimeInterval = 1.0 / 40

    /// Griff eines Bogens bzw. Kreises; nil für andere Elemente.
    static func radiusHandle(of entity: SketchEntity, index: Int) -> SketchRadiusHandle? {
        switch entity {
        case .arc(let a, let m, let b):
            guard let circle = circleThrough(a, m, b), circle.radius > 1e-9 else { return nil }
            let chord: Point2 = b - a
            let chordLength: Double = simd_length(chord)
            var normal: Point2
            if chordLength > 1e-12 {
                normal = Point2(-chord.y, chord.x) / chordLength
                // Scheitel auf der Seite der Sehne, auf der der Bogen liegt (Seite des Durchgangspunkts)
                let side: Double = simd_dot(m - a, normal)
                if side < 0 { normal = -normal }
            } else {
                let toMid: Point2 = m - circle.center
                guard simd_length(toMid) > 1e-12 else { return nil }
                normal = simd_normalize(toMid)
            }
            let apex: Point2 = circle.center + normal * circle.radius
            return SketchRadiusHandle(entity: index, point: apex, outward: normal, center: circle.center,
                                      radius: circle.radius, kind: .radius)
        case .circle(let center, let radius):
            guard radius > 1e-9 else { return nil }
            let direction = Point2(0.7071067811865476, 0.7071067811865476)
            return SketchRadiusHandle(entity: index, point: center + direction * radius, outward: direction,
                                      center: center, radius: radius, kind: .diameter)
        default:
            return nil
        }
    }

    /// Griffe der gewählten Bögen und Kreise (nur im Pfeil-Werkzeug).
    var radiusHandles: [SketchRadiusHandle] {
        guard tool == .select, pendingAction == nil else { return [] }
        var seen = Set<Int>()
        var result: [SketchRadiusHandle] = []
        for ref in selection where entities.indices.contains(ref.entity) && !seen.contains(ref.entity) {
            seen.insert(ref.entity)
            if let handle = Self.radiusHandle(of: entities[ref.entity], index: ref.entity) { result.append(handle) }
        }
        return result
    }

    /// Ring und Doppelpfeil der Griffe für den Viewport. unit = Weltmaß eines Bildschirmpunkts.
    func radiusHandleGeometry(unit: Double) -> (lines: [[Point2]], knobs: [Point2]) {
        var lines: [[Point2]] = []
        var knobs: [Point2] = []
        let ringRadius: Double = 8 * unit
        for handle in radiusHandles {
            let p: Point2 = handle.point
            let n: Point2 = handle.outward
            let t = Point2(-n.y, n.x)
            var ring: [Point2] = []
            for k in 0...24 {
                let angle: Double = Double(k) / 24 * 2 * .pi
                let offset = Point2(cos(angle), sin(angle))
                ring.append(p + offset * ringRadius)
            }
            lines.append(ring)
            // Doppelpfeil entlang des Radius: größer nach außen, kleiner nach innen
            for sign in [1.0, -1.0] {
                let axis: Point2 = n * sign
                let base: Point2 = p + axis * (11 * unit)
                let tip: Point2 = p + axis * (21 * unit)
                let back: Point2 = tip - axis * (5 * unit)
                let side: Point2 = t * (4 * unit)
                lines.append([base, tip])
                lines.append([back + side, tip, back - side])
            }
            knobs.append(p)
        }
        return (lines, knobs)
    }

    /// true, wenn p einen Radiusgriff trifft (der Viewport beginnt dort keine Rahmenauswahl und nimmt
    /// auch den Finger als Ziehen an).
    func hitsRadiusHandle(at p: Point2, tolerance: Double) -> Bool {
        radiusHandleHit(at: p, tolerance: tolerance) != nil
    }

    /// Nächster Griff unter p. Liegt ein Griffpunkt des Elements (Ende, Mittelpunkt) näher, gewinnt dieser.
    private func radiusHandleHit(at p: Point2, tolerance: Double) -> SketchRadiusHandle? {
        var best: (distance: Double, handle: SketchRadiusHandle)?
        for handle in radiusHandles {
            let distance: Double = simd_distance(handle.point, p)
            guard distance <= tolerance * 0.9 else { continue }
            let points: [Point2] = entities[handle.entity].handlePoints
            let closerPoint = points.contains { simd_distance($0, p) < distance }
            if closerPoint { continue }
            if distance < (best?.distance ?? .infinity) { best = (distance, handle) }
        }
        return best?.handle
    }

    // MARK: Ziehen (Haken in began/moved/ended)

    /// Stift bzw. Finger setzt im Pfeil-Werkzeug auf: Radiusgriff getroffen? Dann übernimmt er das Ziehen.
    func beginRadiusHandleDrag(at p: Point2, tolerance: Double) -> Bool {
        radiusHandleDrag = nil
        guard let handle = radiusHandleHit(at: p, tolerance: tolerance) else { return false }
        radiusHandleDrag = RadiusHandleDrag(entity: handle.entity, kind: handle.kind, start: p,
                                            outward: handle.outward, radius: handle.radius, tolerance: tolerance)
        return true
    }

    /// Stift bewegt sich: neuer Radius = Radius beim Aufsetzen plus Weg entlang des Pfeils, gerastert.
    func moveRadiusHandleDrag(to p: Point2, tolerance: Double) -> Bool {
        guard var drag = radiusHandleDrag else { return false }
        if !drag.hasMoved {
            // Kleines Zittern beim Tippen ist noch kein Ziehen
            guard simd_distance(p, drag.start) > tolerance * 0.15 else { return true }
            drag.hasMoved = true
        }
        drag.pending = Self.radiusDragValue(drag, at: p)
        let now: CFTimeInterval = CACurrentMediaTime()
        if now - drag.lastApply >= Self.radiusDragInterval {
            drag.lastApply = now
            applyRadiusDrag(&drag)
        }
        radiusHandleDrag = drag
        return true
    }

    /// Stift hebt ab: letzten Wert anwenden.
    func endRadiusHandleDrag(at p: Point2, tolerance: Double) -> Bool {
        guard var drag = radiusHandleDrag else { return false }
        if drag.hasMoved {
            drag.pending = Self.radiusDragValue(drag, at: p)
            applyRadiusDrag(&drag)
            if drag.remembered, drag.applied != nil, notice == nil {
                notice = drag.kind == .diameter ? "Durchmesser geändert." : "Radius geändert."
            }
        } else {
            notice = "Griff ziehen: vom Mittelpunkt weg größer, zum Mittelpunkt hin kleiner."
        }
        radiusHandleDrag = nil
        return true
    }

    /// Maßwert (Radius bzw. Durchmesser) für den Stiftpunkt p, auf eine zum Zoom passende Stufe gerundet.
    private static func radiusDragValue(_ drag: RadiusHandleDrag, at p: Point2) -> Double {
        let along: Double = simd_dot(p - drag.start, drag.outward)
        let radius: Double = max(drag.radius + along, 1e-3)
        let factor: Double = drag.kind == .diameter ? 2 : 1
        let shown: Double = radius * factor
        let step: Double = radiusDragStep(unit: drag.tolerance / 20)
        let rounded: Double = (shown / step).rounded() * step
        return max(rounded, step)
    }

    /// Rasterstufe nach 1-2-5 (etwa drei Bildschirmpunkte je Stufe).
    private static func radiusDragStep(unit: Double) -> Double {
        let raw: Double = max(unit * 3, 1e-4)
        let decade: Double = pow(10, floor(log10(raw)))
        for factor in [1.0, 2.0, 5.0, 10.0] where decade * factor >= raw - 1e-12 {
            return decade * factor
        }
        return decade * 10
    }

    /// Wert anwenden, wenn er sich geändert hat. Der Schritt zum Rückgängigmachen entsteht nur einmal je Ziehen.
    private func applyRadiusDrag(_ drag: inout RadiusHandleDrag) {
        guard let value = drag.pending, entities.indices.contains(drag.entity) else { return }
        if let applied = drag.applied, abs(applied - value) < 1e-9 { return }
        if isFormulaDriven(drag.entity) {
            notice = "Das Maß hängt an einer Formel – dort ändern."
            return
        }
        notice = nil
        let begin = !drag.remembered
        if dragEntityDimension(drag.kind, of: drag.entity, to: value, begin: begin) {
            drag.remembered = true
            drag.applied = value
        }
    }

    /// Festes Radius- bzw. Durchmessermaß des Elements mit Formel: Ziehen würde die Formel überschreiben.
    private func isFormulaDriven(_ index: Int) -> Bool {
        constraints.contains { constraint in
            guard !constraint.isSuspended, constraint.expression != nil,
                  case .radius(let curve, _, _) = constraint.variant else { return false }
            return curve.entity == index
        }
    }
}
