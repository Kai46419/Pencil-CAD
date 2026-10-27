import Foundation
import simd

// Bogen und Kreis ändern, ohne die übrige Form zu verziehen (Kai): „Ich habe versucht, den Kreis unten ein
// bisschen größer zu machen. Dabei hat es mir die ganze Form verzogen.“
//
// Ursache: Beim Ziehen an der Wölbung blieben die Bogenenden stehen und der Bogen war fest. Ist eine Nachbarlinie
// tangential, geht das nur, wenn die Linie kippt – solveKeepingLines gab dann die ganze Skizze frei, beide
// parallelen Linien kippten und die Oberkante wanderte mit.
//
// Jetzt wie in Fusion 360 bei einer Abrundung: Der Bogen ist frei (geht durch den Finger bzw. hält den neuen
// Radius), seine Enden gleiten auf den angrenzenden Linien (Richtung und anderes Ende bleiben) bzw. auf dem
// Kreis angrenzender Bögen; der Rest steht. Erst wenn das nicht geht, greifen die Stufen von
// ConstraintSolver.solveLocally weiter aus – und ohne örtliche Lösung bleibt es beim bisherigen Weg.

extension SketchController {
    /// Vorläufige Bedingung für den neuen Radius (Bogen) bzw. Durchmesser (Kreis) eines Elements.
    static func resizeConstraint(of index: Int, value: Double, diameter: Bool) -> SketchConstraint {
        SketchConstraint(variant: .radius(SketchCurveRef(entity: index, index: 0), value: value, diameter: diameter))
    }

    /// Wölbung eines Bogens gezogen: trial enthält den Bogen durch den Finger (Enden noch an alter Stelle).
    /// Der Bogen bleibt frei und geht durch den Fingerpunkt; die Nachbarn gleiten. nil = örtlich nicht lösbar.
    func arcBulgeSolution(_ trial: [SketchEntity], arc index: Int) -> [SketchEntity]? {
        guard trial.indices.contains(index), case .arc(_, let through, _) = trial[index] else { return nil }
        // Hilfspunkt am Finger (fest), der Bogenkreis geht durch ihn
        var extended = trial
        extended.append(.point(through))
        let helper = trial.count
        let onArc = SketchConstraint(variant: .pointOnCurve(SketchPointRef(entity: helper, index: 0),
                                                            SketchCurveRef(entity: index, index: 0)))
        return localCurveSolution(extended, keeping: trial.count, focus: index, locked: [helper], extra: [onArc],
                                  original: trial)
    }

    /// Bogenende gezogen: Der Bogen hat genau die gezogene Form (fest); nur seine Nachbarn passen sich an,
    /// zuerst gleitend, dann die direkten Nachbarn frei. nil = kein Bogen bzw. örtlich nicht lösbar.
    func arcEndSolution(_ trial: [SketchEntity], arc index: Int) -> [SketchEntity]? {
        guard trial.indices.contains(index), case .arc = trial[index] else { return nil }
        return localCurveSolution(trial, keeping: trial.count, focus: index, locked: [index], extra: [],
                                  original: trial)
    }

    /// Kreisrand gezogen: Der Kreis hält den gezogenen Radius, darf aber selbst ausweichen (Mittelpunkt),
    /// bevor Nachbarn sich bewegen. nil = kein Kreis bzw. örtlich nicht lösbar.
    func circleRadiusSolution(_ trial: [SketchEntity], circle index: Int) -> [SketchEntity]? {
        guard trial.indices.contains(index), case .circle(_, let radius) = trial[index] else { return nil }
        let size = Self.resizeConstraint(of: index, value: 2 * radius, diameter: true)
        return localCurveSolution(trial, keeping: trial.count, focus: index, locked: [], extra: [size],
                                  original: trial)
    }

    /// Örtlich lösen (ohne Ausweg über die ganze Skizze); Lösungen, die die Form zusammenklappen, gelten nicht.
    /// keeping: Anzahl der echten Elemente (dahinter liegen Hilfselemente).
    private func localCurveSolution(_ entities: [SketchEntity], keeping count: Int, focus: Int, locked: Set<Int>,
                                    extra: [SketchConstraint], original: [SketchEntity]) -> [SketchEntity]? {
        guard !constraints.isEmpty else { return nil }
        let all: [SketchConstraint] = constraints + extra
        let accept: ([SketchEntity]) -> Bool = { candidate in
            let real = Array(candidate.prefix(count))
            return !ConstraintSolver.folds(from: original, to: real)
        }
        guard let found = ConstraintSolver.solveLocally(entities, constraints: all, focus: [focus], locked: locked,
                                                        allowGlobal: false, accept: accept),
              !found.isGlobal else { return nil }
        return Array(found.entities.prefix(count))
    }
}
