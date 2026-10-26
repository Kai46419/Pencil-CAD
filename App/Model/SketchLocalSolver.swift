import Foundation
import simd

// Örtliches Lösen beim Ändern eines Maßes (Kai): „Du musst erkennen, welche Form ich gerade auswähle, und nur
// diese Form ändern, nicht die ganzen anderen Striche und Bögen.“
//
// Vorbild Fusion 360 beim Radius einer Abrundung: Der Bogen ändert sich, seine Enden gleiten auf den
// angrenzenden Linien (die sich dabei nur verkürzen bzw. verlängern – Richtung und anderes Ende bleiben),
// der Mittelpunkt wandert auf der Winkelhalbierenden. Der Rest der Kontur bleibt stehen.
//
// Vorgehen in Stufen, die erste brauchbare Lösung gilt:
//  0. nur die geänderten Elemente frei, direkte Nachbarn „gleiten“ (Linie: Richtung und freies Ende fest,
//     Bogen: Kreis und freies Ende fest), alles andere steht
//  1. Elemente und direkte Nachbarn frei, alles andere steht
//  2. wie 1, die Nachbarn der Nachbarn gleiten
//  3. bis zum zweiten Ring frei … (usw. bis Ring 3)
//  zuletzt: alles frei, aber gewichtet – je weiter ein Element entfernt ist, desto teurer ist es zu bewegen.

extension ConstraintSolver {
    /// Ergebnis des örtlichen Lösens.
    struct LocalSolution {
        var entities: [SketchEntity]
        /// Stufe der Lösung (0 = nur die Form und gleitende Nachbarn; größer = weiter ausgreifend)
        var stage: Int
        /// Lösung erst mit der ganzen Skizze gefunden (gewichtet)
        var isGlobal: Bool
    }

    /// Einschränkungen lösen und dabei möglichst nur die Elemente in focus und ihre direkten Nachbarn bewegen.
    /// locked: Elemente, die fest stehen (z. B. eine bereits auf das neue Maß gebrachte Form).
    /// accept: prüft eine Lösung (z. B. kein Zusammenklappen); abgelehnte Lösungen führen zur nächsten Stufe.
    static func solveLocally(_ entities: [SketchEntity], constraints all: [SketchConstraint], focus: Set<Int>,
                             locked: Set<Int> = [],
                             accept: ([SketchEntity]) -> Bool = { _ in true }) -> LocalSolution? {
        let constraints = all.filter { !$0.isSuspended }
        guard !constraints.isEmpty else {
            return accept(entities) ? LocalSolution(entities: entities, stage: 0, isGlobal: false) : nil
        }
        let ring = rings(from: focus, constraints, count: entities.count)
        var plans: [(inner: Set<Int>, sliding: Set<Int>)] = []
        for k in 0..<3 {
            let inner = Set(ring.filter { $0.value <= k }.keys)
            let boundary = Set(ring.filter { $0.value == k + 1 }.keys)
            if boundary.isEmpty {
                plans.append((inner: inner, sliding: []))
                break
            }
            plans.append((inner: inner, sliding: boundary))
            plans.append((inner: inner.union(boundary), sliding: []))
        }
        for (stage, plan) in plans.enumerated() {
            guard let solved = attempt(entities, constraints, inner: plan.inner, sliding: plan.sliding,
                                       locked: locked) else { continue }
            if accept(solved) { return LocalSolution(entities: solved, stage: stage, isGlobal: false) }
        }
        // Letzter Ausweg: ganze Skizze, entfernte Elemente teuer
        var weights: [Int: Double] = [:]
        for index in entities.indices {
            if let level = ring[index] {
                weights[index] = pow(10, Double(min(level, 4)))
            } else {
                weights[index] = 1e5
            }
        }
        if let solved = solve(entities, constraints: constraints, locked: locked, weights: weights), accept(solved) {
            return LocalSolution(entities: solved, stage: plans.count, isGlobal: true)
        }
        return nil
    }

    /// Abstand jedes Elements (in Einschränkungen) von focus: 0 = focus, 1 = direkte Nachbarn, …
    /// Elemente ohne Verbindung fehlen.
    static func rings(from focus: Set<Int>, _ constraints: [SketchConstraint], count: Int) -> [Int: Int] {
        var neighbors: [Int: Set<Int>] = [:]
        for constraint in constraints {
            let linked = Set(constraint.entities.filter { $0 >= 0 && $0 < count })
            guard linked.count > 1 else { continue }
            for index in linked { neighbors[index, default: []].formUnion(linked) }
        }
        var ring: [Int: Int] = [:]
        var frontier = focus.filter { $0 >= 0 && $0 < count }
        for index in frontier { ring[index] = 0 }
        var level = 0
        while !frontier.isEmpty {
            level += 1
            var next = Set<Int>()
            for index in frontier {
                for other in neighbors[index] ?? [] where ring[other] == nil {
                    ring[other] = level
                    next.insert(other)
                }
            }
            frontier = next
        }
        return ring
    }

    /// Punkte, die in einer Einschränkung vorkommen (für „hängt dieser Punkt am inneren Bereich?“).
    static func pointRefs(of constraint: SketchConstraint) -> [SketchPointRef] {
        switch constraint.variant {
        case .coincident(let a, let b), .horizontalPoints(let a, let b), .verticalPoints(let a, let b):
            return [a, b]
        case .distance(let a, let b, _), .symmetric(let a, let b, _):
            return [a, b]
        case .pointOnCurve(let p, _), .midpoint(let p, _), .lock(let p, _), .pointLineDistance(let p, _, _):
            return [p]
        default:
            return []
        }
    }

    /// Griffpunkte von Element index, die mit dem inneren Bereich verbunden sind: über eine Einschränkung
    /// (Zusammenfallend usw.) oder weil sie auf einem Griffpunkt eines inneren Elements liegen.
    private static func touchingPoints(of index: Int, inner: Set<Int>, _ entities: [SketchEntity],
                                       _ constraints: [SketchConstraint]) -> Set<Int> {
        var result = Set<Int>()
        for constraint in constraints {
            let linked = constraint.entities
            guard linked.contains(index), !inner.isDisjoint(with: linked) else { continue }
            for ref in pointRefs(of: constraint) where ref.entity == index { result.insert(ref.index) }
        }
        let own = entities[index].handlePoints
        for other in inner where entities.indices.contains(other) {
            for q in entities[other].handlePoints {
                for (k, p) in own.enumerated() where simd_distance(p, q) < 1e-6 { result.insert(k) }
            }
        }
        return result
    }

    /// Ein Lösungsversuch: inner frei (außer locked), sliding gleitet, alles andere steht.
    private static func attempt(_ entities: [SketchEntity], _ constraints: [SketchConstraint], inner: Set<Int>,
                                sliding: Set<Int>, locked: Set<Int>) -> [SketchEntity]? {
        let count = entities.count
        var extended = entities
        var extra: [SketchConstraint] = []
        var movable = inner.subtracting(locked)
        for index in sliding.sorted() where !locked.contains(index) && entities.indices.contains(index) {
            let touching = touchingPoints(of: index, inner: inner, entities, constraints)
            switch entities[index] {
            case .line(let a, let b):
                // Linie bleibt auf ihrer Geraden; das freie Ende steht
                guard simd_distance(a, b) > 1e-9 else { continue }
                let helper = extended.count
                extended.append(.line(a, b))
                let guide = SketchCurveRef(entity: helper, index: 0)
                let ends: [Point2] = [a, b]
                for k in 0..<2 {
                    let ref = SketchPointRef(entity: index, index: k)
                    let variant: SketchConstraint.Variant = touching.contains(k)
                        ? .pointOnCurve(ref, guide) : .lock(ref, at: ends[k])
                    extra.append(SketchConstraint(variant: variant))
                }
                movable.insert(index)
            case .arc(let a, let m, let b):
                // Bogen bleibt auf seinem Kreis (Mittelpunkt und Radius fest); das freie Ende steht
                guard let circle = circleThrough(a, m, b) else { continue }
                let helper = extended.count
                extended.append(.circle(center: circle.center, radius: circle.radius))
                let guide = SketchCurveRef(entity: helper, index: 0)
                let ends: [Point2] = [a, b]
                for k in 0..<2 {
                    let ref = SketchPointRef(entity: index, index: k)
                    let variant: SketchConstraint.Variant = touching.contains(k)
                        ? .pointOnCurve(ref, guide) : .lock(ref, at: ends[k])
                    extra.append(SketchConstraint(variant: variant))
                }
                extra.append(SketchConstraint(variant: .lock(SketchPointRef(entity: index, index: 2), at: circle.center)))
                movable.insert(index)
            default:
                // Kreise, Rechtecke, Polygone, Splines … stehen
                continue
            }
        }
        let fixed = Set(extended.indices).subtracting(movable)
        // Nur Einschränkungen, die bewegliche oder innere Elemente betreffen (der Rest ändert sich nicht)
        let touched = movable.union(inner)
        let relevant = constraints.filter { !touched.isDisjoint(with: $0.entities) }
        guard let solved = solve(extended, constraints: relevant + extra, locked: fixed) else { return nil }
        return Array(solved.prefix(count))
    }
}
