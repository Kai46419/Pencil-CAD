import Foundation
import QuartzCore
import simd

// Build 68 (Kai): Auswahl im Skizzenmodus als Ganzes verschieben, drehen und skalieren – z. B. ein gezeichnetes
// Rechteck antippen und dann bewegen. Rahmen um die Auswahl wie bei Texten (SketchTextTransform.swift):
// - Kreuz in der Mitte bzw. Ziehen in der Fläche (nicht auf einer Kurve) verschiebt,
// - Pfeil rechts oben skaliert gleichmäßig (Ecke links unten bleibt stehen),
// - Griff oberhalb dreht um die Rahmenmitte (15°-Schritte rasten ein).
// Kanten und Ecken ziehen weiter wie bisher (Größe ändern). Elemente, die über Bedingungen an der Auswahl
// hängen, gehen mit; Maße werden beim Skalieren mitskaliert. Ein gedrehtes Rechteck wird ein geschlossener
// Linienzug mit rechten Winkeln (Senkrecht-Bedingungen), damit es ein Rechteck bleibt.

/// Achsparalleler Rahmen um Skizzenelemente.
struct SketchSelectionFrame {
    var low: Point2
    var high: Point2

    var center: Point2 { (low + high) / 2 }
    /// links unten, rechts unten, rechts oben, links oben
    var corners: [Point2] { [low, Point2(high.x, low.y), high, Point2(low.x, high.y)] }
    var size: Point2 { high - low }

    func contains(_ p: Point2) -> Bool {
        p.x >= low.x && p.x <= high.x && p.y >= low.y && p.y <= high.y
    }

    func padded(_ d: Double) -> SketchSelectionFrame {
        SketchSelectionFrame(low: low - Point2(d, d), high: high + Point2(d, d))
    }
}

extension SketchController {
    /// Laufendes Ziehen am Auswahlrahmen (gespeichert in selectionTransformDrag, Sketch.swift).
    struct SelectionTransformDrag {
        enum Kind {
            case move
            case scale
            case rotate
            /// Build 101: Ecke oben links – waagrecht neigen (scheren)
            case shear
            /// Build 101: Schloss unten rechts – verankern/lösen (nur Tippen)
            case lock
        }

        var kind: Kind
        var start: Point2
        var lastPoint: Point2
        /// Fangweite des Viewports (20 pt in mm)
        var tolerance: Double
        /// Bewegte Elemente: Auswahl und alles, was über Bedingungen daran hängt
        var moving: [Int]
        var original: [SketchEntity]
        var originalConstraints: [SketchConstraint]
        /// Rahmen beim Aufsetzen, ohne Rand
        var frame: SketchSelectionFrame
        /// Fang ohne die bewegten Elemente
        var snapIndex: SnapIndex
        var extra: [Point2]
        /// Auf einem Griff aufgesetzt (Antippen zeigt dann einen Hinweis statt abzuwählen)
        var onKnob: Bool
        /// Verankertes Element in der Gruppe: nichts bewegen
        var blocked = false
        var hasMoved = false
        var remembered = false
        var lastAngle: Double = 0
        var sweep: Double = 0
        var snap: SnapResult?
        var lastApply: CFTimeInterval = 0
        /// Zuletzt angewandte Lage (für den Hinweis nach dem Abheben)
        var delta = Point2.zero
        var factor: Double = 1
        var angle: Double = 0
    }

    private static let selectionHandleHitPoints: Double = 24
    private static let selectionDragInterval: CFTimeInterval = 1.0 / 60

    /// Elemente, deren Rahmen gezeigt wird: Auswahl im Pfeil-Werkzeug. Ein einzelner Text hat eigene Griffe.
    var transformSelectionIndices: [Int]? {
        guard tool == .select, pendingAction == nil, textDeformMode == nil else { return nil }
        let chosen: [Int] = selectedEntities.filter { entities.indices.contains($0) }.sorted()
        guard !chosen.isEmpty else { return nil }
        if chosen.count == 1, case .text = entities[chosen[0]] { return nil }
        return chosen
    }

    /// Achsparalleler Rahmen um die Elemente (aus ihrer Darstellung).
    func selectionFrame(_ indices: [Int]) -> SketchSelectionFrame? {
        var low = Point2(Double.infinity, Double.infinity)
        var high = Point2(-Double.infinity, -Double.infinity)
        for index in indices where entities.indices.contains(index) {
            for line in entities[index].drawing {
                for p in line where p.x.isFinite && p.y.isFinite {
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
        }
        guard low.x.isFinite, low.y.isFinite, high.x.isFinite, high.y.isFinite else { return nil }
        return SketchSelectionFrame(low: low, high: high)
    }

    /// Lage der Griffe. unit = Skizzenmaß eines Bildschirmpunkts.
    private func selectionHandlePoints(unit: Double)
        -> (frame: SketchSelectionFrame, move: Point2, scale: Point2, rotate: Point2, rotateBase: Point2,
            shear: Point2, lock: Point2)? {
        guard let indices = transformSelectionIndices, let raw = selectionFrame(indices) else { return nil }
        let frame = raw.padded(8 * unit)
        let top = Point2(frame.center.x, frame.high.y)
        return (frame, frame.center, frame.high, top + Point2(0, 30 * unit), top,
                Point2(frame.low.x, frame.high.y), Point2(frame.high.x + 16 * unit, frame.low.y - 16 * unit))
    }

    /// Rahmen, Pfeile und Knöpfe für den Viewport (Viewport.addSelectionTransformHandles).
    func selectionTransformHandleGeometry(unit: Double) -> (frame: [Point2], lines: [[Point2]], knobs: [Point2])? {
        guard let h = selectionHandlePoints(unit: unit) else { return nil }
        var lines: [[Point2]] = []
        func arrow(from base: Point2, to tip: Point2) {
            let length: Double = simd_distance(base, tip)
            guard length > 1e-12 else { return }
            let axis: Point2 = (tip - base) / length
            let side = Point2(-axis.y, axis.x) * (3.5 * unit)
            let back: Point2 = tip - axis * (4.5 * unit)
            lines.append([base, tip])
            lines.append([back + side, tip, back - side])
        }
        // Verschiebe-Kreuz
        for direction in [Point2(1, 0), Point2(-1, 0), Point2(0, 1), Point2(0, -1)] {
            arrow(from: h.move + direction * (4 * unit), to: h.move + direction * (15 * unit))
        }
        // Skalieren: Doppelpfeil entlang der Diagonale
        let diagonal: Point2 = h.frame.high - h.frame.low
        let d: Point2 = simd_length(diagonal) > 1e-12 ? simd_normalize(diagonal) : simd_normalize(Point2(1, 1))
        arrow(from: h.scale + d * (12 * unit), to: h.scale + d * (22 * unit))
        arrow(from: h.scale + d * (12 * unit), to: h.scale + d * (5 * unit))
        // Drehen: Stiel, Ring, gebogener Pfeil
        lines.append([h.rotateBase, h.rotate - Point2(0, 7 * unit)])
        var ring: [Point2] = []
        for k in 0...24 {
            let a: Double = Double(k) / 24 * 2 * .pi
            ring.append(h.rotate + Point2(cos(a), sin(a)) * (7 * unit))
        }
        lines.append(ring)
        var bow: [Point2] = []
        for k in 0...10 {
            let a: Double = .pi / 2 + 0.35 + Double(k) / 10 * 1.6
            bow.append(h.rotate + Point2(cos(a), sin(a)) * (12 * unit))
        }
        if bow.count >= 2, let tip = bow.last {
            lines.append(bow)
            let axis: Point2 = simd_normalize(tip - bow[bow.count - 2])
            let side = Point2(-axis.y, axis.x) * (3 * unit)
            let back: Point2 = tip - axis * (4 * unit)
            lines.append([back + side, tip, back - side])
        }
        // Neigen: Doppelpfeil waagrecht an der Ecke oben links
        arrow(from: h.shear + Point2(-6 * unit, 8 * unit), to: h.shear + Point2(-20 * unit, 8 * unit))
        arrow(from: h.shear + Point2(-14 * unit, 8 * unit), to: h.shear + Point2(0, 8 * unit))
        lines.append([h.shear, h.shear + Point2(-6 * unit, 14 * unit)])
        // Schloss: Bügel offen bzw. geschlossen, Körper als Rechteck
        let body = [Point2(-5, -6), Point2(5, -6), Point2(5, 1), Point2(-5, 1), Point2(-5, -6)]
        lines.append(body.map { h.lock + $0 * unit })
        var shackle: [Point2] = []
        let open = !selectionIsAnchored
        for k in 0...12 {
            let a: Double = Double(k) / 12 * .pi
            shackle.append(h.lock + Point2(cos(a) * 3.5 + (open ? 3 : 0), 1 + 3 + sin(a) * 3.5) * unit)
        }
        lines.append([h.lock + Point2(-3.5 + (open ? 3 : 0), 1) * unit] + shackle.reversed()
                     + [h.lock + Point2(3.5 + (open ? 3 : 0), open ? 3 : 1) * unit])
        let corners = h.frame.corners
        return (corners + [corners[0]], lines, [h.move, h.scale, h.rotate, h.shear, h.lock])
    }

    /// Fang beim Ziehen am Rahmen (Anzeige über currentSnap).
    var selectionTransformSnap: SnapResult? {
        selectionTransformDrag?.snap
    }

    /// Welcher Griff liegt unter p? onKnob = auf einem der drei Knöpfe (sonst in der Rahmenfläche).
    private func selectionTransformHit(at p: Point2, tolerance: Double)
        -> (kind: SelectionTransformDrag.Kind, onKnob: Bool)? {
        let unit: Double = tolerance / 20
        let reach: Double = Self.selectionHandleHitPoints * unit
        guard let h = selectionHandlePoints(unit: unit) else { return nil }
        if simd_distance(p, h.lock) <= reach { return (.lock, true) }
        if simd_distance(p, h.shear) <= reach { return (.shear, true) }
        if simd_distance(p, h.rotate) <= reach { return (.rotate, true) }
        if simd_distance(p, h.scale) <= reach { return (.scale, true) }
        if simd_distance(p, h.move) <= reach { return (.move, true) }
        // In der Fläche: verschieben – außer eine Kurve bzw. ein Punkt liegt dort (Kante ziehen geht vor)
        if h.frame.contains(p), pick(at: p, tolerance: tolerance, includeText: true) == nil { return (.move, false) }
        return nil
    }

    /// true, wenn p einen Griff bzw. die Fläche des Auswahlrahmens trifft (der Viewport beginnt dort keine
    /// Rahmenauswahl und nimmt auch den Finger als Ziehen an).
    func hitsSelectionTransformHandle(at p: Point2, tolerance: Double) -> Bool {
        selectionTransformHit(at: p, tolerance: tolerance) != nil
    }

    /// Nur die drei Knöpfe (Finger: in der Fläche verschiebt der Finger weiter die Ansicht).
    func hitsSelectionTransformKnob(at p: Point2, tolerance: Double) -> Bool {
        selectionTransformHit(at: p, tolerance: tolerance)?.onKnob == true
    }

    /// Auswahl und alle Elemente, die über Bedingungen (auch mehrstufig) daran hängen.
    func constraintGroup(of indices: [Int]) -> [Int] {
        var group = Set(indices)
        var grew = true
        while grew {
            grew = false
            for constraint in constraints {
                let ids: [Int] = constraint.entities.filter { entities.indices.contains($0) }
                guard ids.contains(where: { group.contains($0) }) else { continue }
                for id in ids where !group.contains(id) {
                    group.insert(id)
                    grew = true
                }
            }
        }
        return group.sorted()
    }

    // MARK: Ziehen (Haken in began/moved/ended, Sketch.swift)

    func beginSelectionTransformDrag(at p: Point2, tolerance: Double) -> Bool {
        selectionTransformDrag = nil
        guard let hit = selectionTransformHit(at: p, tolerance: tolerance), let indices = transformSelectionIndices,
              let frame = selectionFrame(indices) else { return false }
        let moving: [Int] = constraintGroup(of: indices)
        let movingSet = Set(moving)
        let others: [SketchEntity] = entities.indices.filter { !movingSet.contains($0) }.map { entities[$0] }
        var drag = SelectionTransformDrag(kind: hit.kind, start: p, lastPoint: p, tolerance: tolerance, moving: moving,
                                          original: entities, originalConstraints: constraints, frame: frame,
                                          snapIndex: SnapIndex(entities: others, guides: modelGuides),
                                          extra: marks + [Point2.zero], onKnob: hit.onKnob)
        drag.lastAngle = atan2(p.y - frame.center.y, p.x - frame.center.x)
        drag.blocked = hit.kind != .lock && constraints.contains { constraint in
            if case .lock = constraint.variant {
                return constraint.entities.contains { movingSet.contains($0) }
            }
            return false
        }
        selectionTransformDrag = drag
        return true
    }

    func moveSelectionTransformDrag(to p: Point2, tolerance: Double) -> Bool {
        guard var drag = selectionTransformDrag else { return false }
        drag.lastPoint = p
        if !drag.hasMoved {
            guard simd_distance(p, drag.start) > tolerance * 0.15 else {
                selectionTransformDrag = drag
                return true
            }
            drag.hasMoved = true
            if drag.blocked {
                notice = "Ein Element der Auswahl ist verankert – erst „Verankern“ lösen, dann verschieben."
                selectionTransformDrag = drag
                changed()
                return true
            }
        }
        guard !drag.blocked, drag.kind != .lock else {
            selectionTransformDrag = drag
            return true
        }
        let now: CFTimeInterval = CACurrentMediaTime()
        if now - drag.lastApply >= Self.selectionDragInterval {
            drag.lastApply = now
            applySelectionTransform(&drag, at: p, final: false)
        }
        selectionTransformDrag = drag
        return true
    }

    func endSelectionTransformDrag(at p: Point2, tolerance: Double) -> Bool {
        guard var drag = selectionTransformDrag else { return false }
        selectionTransformDrag = nil
        if drag.kind == .lock {
            toggleSelectionLock()
            return true
        }
        if drag.blocked {
            changed()
            return true
        }
        if drag.hasMoved {
            // Beim Abheben zittert der Stift: kaum bewegt, gilt die zuletzt gezeigte Lage
            let lifted: Point2 = simd_distance(p, drag.lastPoint) > tolerance * 0.25 ? p : drag.lastPoint
            applySelectionTransform(&drag, at: lifted, final: true)
            switch drag.kind {
            case .move:
                notice = "Verschoben um \(LengthUnit.current.format(drag.delta.x)) / \(LengthUnit.current.format(drag.delta.y))"
            case .scale:
                notice = "Skaliert auf \(Int((drag.factor * 100).rounded())) %"
            case .rotate:
                notice = "Gedreht um \(Int((drag.angle * 180 / .pi).rounded()))°"
            case .shear:
                notice = "Geneigt um \(Int((atan(drag.factor) * 180 / .pi).rounded()))°"
            case .lock:
                break
            }
            changed()
            return true
        }
        if drag.onKnob {
            switch drag.kind {
            case .move: notice = "Kreuz oder Fläche ziehen verschiebt die Auswahl."
            case .scale: notice = "Pfeil ziehen skaliert die Auswahl, die Ecke links unten bleibt stehen."
            case .rotate: notice = "Griff ziehen dreht die Auswahl um ihre Mitte (15°-Schritte rasten ein)."
            case .shear: notice = "Ecke oben links waagrecht ziehen neigt die Auswahl, die Unterkante bleibt stehen."
            case .lock: break
            }
            changed()
        } else {
            // Tippen in die Fläche: wählen bzw. abwählen wie das Pfeil-Werkzeug
            select(at: drag.start, tolerance: tolerance)
            editableIndex = selection.count == 1 ? selection[0].entity : nil
            changed()
        }
        return true
    }

    /// Berührung abgebrochen: bis dahin Gezogenes bleibt (ein Rückgängig-Schritt).
    func cancelSelectionTransformDrag() {
        guard let drag = selectionTransformDrag else { return }
        selectionTransformDrag = nil
        if drag.remembered {
            setTransformedSelection(entities, constraints: constraints, begin: false, final: true)
        }
    }

    private func applySelectionTransform(_ drag: inout SelectionTransformDrag, at p: Point2, final: Bool) {
        guard let result = selectionTransformResult(&drag, at: p) else { return }
        setTransformedSelection(result.entities, constraints: result.constraints, begin: !drag.remembered, final: final)
        drag.remembered = true
    }

    /// Neue Lage aus dem Stand beim Aufsetzen (damit sich nichts aufschaukelt).
    private func selectionTransformResult(_ drag: inout SelectionTransformDrag, at p: Point2)
        -> (entities: [SketchEntity], constraints: [SketchConstraint])? {
        let frame = drag.frame
        drag.snap = nil
        switch drag.kind {
        case .move:
            var delta: Point2 = p - drag.start
            var snapped = false
            if snapEnabled {
                let pointKinds: Set<SnapKind> = [.endpoint, .midpoint, .center, .intersection, .modelPoint]
                let kinds: Set<SnapKind> = snapKinds.intersection(pointKinds)
                if !kinds.isEmpty {
                    var refs: [Point2] = frame.corners + [frame.center]
                    for index in drag.moving where drag.original.indices.contains(index) {
                        refs += drag.original[index].snapPoints
                        if refs.count > 80 { break }
                    }
                    let reach: Double = drag.tolerance * 0.5
                    var best: (point: Point2, ref: Point2, kind: SnapKind, distance: Double)?
                    for ref in refs {
                        let moved: Point2 = ref + delta
                        let result = drag.snapIndex.snap(moved, tolerance: reach, kinds: kinds, extra: drag.extra,
                                                         gridStep: 0)
                        guard let kind = result.kind, pointKinds.contains(kind) else { continue }
                        let distance: Double = simd_distance(result.point, moved)
                        if distance < (best?.distance ?? .infinity) { best = (result.point, ref, kind, distance) }
                    }
                    if let best {
                        delta = best.point - best.ref
                        drag.snap = SnapResult(point: best.point, kind: best.kind)
                        snapped = true
                    }
                }
                // Ohne Punktfang: Versatz im Raster
                if !snapped, snapKinds.contains(.grid), gridStep > 0 {
                    delta = (delta / gridStep).rounded(.toNearestOrAwayFromZero) * gridStep
                }
            }
            drag.delta = delta
            let moved = drag.original.enumerated().map { pair -> SketchEntity in
                drag.moving.contains(pair.offset) ? Self.movedEntity(pair.element, by: delta) : pair.element
            }
            return (moved, drag.originalConstraints)
        case .scale:
            let fixed: Point2 = frame.low
            let diagonal: Point2 = frame.high - frame.low
            let length2: Double = simd_dot(diagonal, diagonal)
            guard length2 > 1e-12 else { return nil }
            let corner: Point2 = frame.high + (p - drag.start)
            var factor: Double = simd_dot(corner - fixed, diagonal) / length2
            // Glatte Prozentwerte (1 %) und nicht durch die feste Ecke hindurch
            if snapEnabled { factor = (factor * 100).rounded() / 100 }
            factor = max(factor, 0.02)
            drag.factor = factor
            let scaled = drag.original.enumerated().map { pair -> SketchEntity in
                drag.moving.contains(pair.offset) ? pair.element.scaled(about: fixed, by: factor) : pair.element
            }
            let adjusted = scaledSelectionConstraints(drag.originalConstraints, moving: Set(drag.moving), by: factor)
            return (scaled, adjusted)
        case .rotate:
            let center: Point2 = frame.center
            let a: Double = atan2(p.y - center.y, p.x - center.x)
            drag.sweep += remainder(a - drag.lastAngle, 2 * .pi)
            drag.lastAngle = a
            var turn: Double = drag.sweep
            if snapEnabled, snapKinds.contains(.angle) {
                let step: Double = .pi / 12
                let rounded: Double = (turn / step).rounded() * step
                if abs(turn - rounded) <= 2 * .pi / 180 { turn = rounded }
            }
            drag.angle = turn
            return rotatedSelection(drag.original, constraints: drag.originalConstraints, moving: drag.moving,
                                    about: center, by: turn)
        case .shear:
            let height: Double = frame.high.y - frame.low.y
            guard height > 1e-9 else { return nil }
            var factor: Double = (p.x - drag.start.x) / height
            // 5°-Schritte rasten ein
            if snapEnabled, snapKinds.contains(.angle) {
                let degrees = atan(factor) * 180 / .pi
                let rounded = (degrees / 5).rounded() * 5
                if abs(degrees - rounded) <= 1.5 { factor = tan(rounded * .pi / 180) }
            }
            factor = max(min(factor, 5), -5)
            drag.factor = factor
            return shearedSelection(drag.original, constraints: drag.originalConstraints, moving: drag.moving,
                                    baseline: frame.low.y, by: factor)
        case .lock:
            return nil
        }
    }

    /// Element verschoben (Text über seine Griff-Lage, damit Verformung und Pfad erhalten bleiben).
    static func movedEntity(_ entity: SketchEntity, by delta: Point2) -> SketchEntity {
        if case .text(let text) = entity {
            let current: SketchTextTransform = text.transform ?? .identity
            return .text(text.with(transform: current.moved(by: delta)))
        }
        return entity.translated(by: delta)
    }

    /// Element um center gedreht (Text über seine Griff-Lage).
    static func rotatedEntity(_ entity: SketchEntity, about center: Point2, by angle: Double) -> SketchEntity {
        if case .text(let text) = entity {
            let current: SketchTextTransform = text.transform ?? .identity
            return .text(text.with(transform: current.followed(byScale: 1, rotation: angle, about: center,
                                                               pivot: text.transformPivot)))
        }
        return entity.rotated(about: center, by: angle) ?? entity
    }

    // MARK: Werte aus der Leiste (SketchSelectionTransformPanel.swift), je ein Rückgängig-Schritt

    /// Rahmenmitte der Auswahl an x bzw. y setzen.
    func setSelectionCenter(x: Double? = nil, y: Double? = nil) {
        guard let indices = transformSelectionIndices, let frame = selectionFrame(indices) else { return }
        let target = Point2(x ?? frame.center.x, y ?? frame.center.y)
        let delta: Point2 = target - frame.center
        guard simd_length(delta) > 1e-12, !selectionIsLocked(indices) else { return }
        let moving = constraintGroup(of: indices)
        let moved = entities.enumerated().map { pair -> SketchEntity in
            moving.contains(pair.offset) ? Self.movedEntity(pair.element, by: delta) : pair.element
        }
        setTransformedSelection(moved, constraints: constraints, begin: true, final: true)
    }

    /// Auswahl um factor skalieren (um die Rahmenmitte).
    func scaleSelection(by factor: Double) {
        guard factor > 1e-4, factor.isFinite, abs(factor - 1) > 1e-9, let indices = transformSelectionIndices,
              let frame = selectionFrame(indices), !selectionIsLocked(indices) else { return }
        let moving = constraintGroup(of: indices)
        let scaled = entities.enumerated().map { pair -> SketchEntity in
            moving.contains(pair.offset) ? pair.element.scaled(about: frame.center, by: factor) : pair.element
        }
        let adjusted = scaledSelectionConstraints(constraints, moving: Set(moving), by: factor)
        setTransformedSelection(scaled, constraints: adjusted, begin: true, final: true)
    }

    /// Auswahl um angle (Bogenmaß) um die Rahmenmitte drehen.
    func rotateSelection(by angle: Double) {
        guard angle.isFinite, abs(angle) > 1e-12, let indices = transformSelectionIndices,
              let frame = selectionFrame(indices), !selectionIsLocked(indices) else { return }
        let moving = constraintGroup(of: indices)
        let result = rotatedSelection(entities, constraints: constraints, moving: moving, about: frame.center, by: angle)
        setTransformedSelection(result.entities, constraints: result.constraints, begin: true, final: true)
    }

    private func selectionIsLocked(_ indices: [Int]) -> Bool {
        let moving = Set(constraintGroup(of: indices))
        let locked = constraints.contains { constraint in
            if case .lock = constraint.variant { return constraint.entities.contains { moving.contains($0) } }
            return false
        }
        if locked {
            notice = "Ein Element der Auswahl ist verankert – erst „Verankern“ lösen."
            changed()
        }
        return locked
    }
}
