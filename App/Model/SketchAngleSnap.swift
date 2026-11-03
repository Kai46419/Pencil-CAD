import Foundation
import simd

// Fang „Gleicher Winkel“ beim Zeichnen von Linien (Kai): Linie unten links nach oben rechts, oben ein Halbkreis,
// rechts eine Linie von oben links nach unten rechts. Hat die neue Linie denselben Winkel wie eine vorhandene –
// oder den gespiegelten (70° und 110° zur Waagerechten, symmetrisch zur Senkrechten) –, rastet sie leicht ein,
// färbt sich grün, die Bezugslinie leuchtet ebenfalls grün, und nach dem Abheben hält eine Einschränkung
// „Gleicher Winkel“ (∠=) die Beziehung.
//
// Spiegeln an der Senkrechten (α → 180° − α) und an der Waagerechten (α → −α) ergibt für Linien ohne
// Richtungssinn dieselbe Gerade; es gibt also nur „gleich“ (= parallel) und „gespiegelt“.
// Vorrang behalten Punktfang und Waagerecht/Senkrecht (siehe withParallel in Sketch.swift).

extension InferredRelation {
    var isMirrored: Bool {
        if case .mirrored = self { return true }
        return false
    }
}

extension SketchController {
    /// Winkeltoleranz für gleichen bzw. gespiegelten Winkel (etwa 3°)
    static let equalAngleTolerance: Double = 3 * .pi / 180

    /// Richtungen, an denen eine neue Linie an der vorhandenen Linie (Richtung v) einrastet: parallel,
    /// gespiegelt (nur bei schrägen Linien – bei waagerechten/senkrechten fällt es mit parallel zusammen) und
    /// senkrecht. Bei 45° fällt „gespiegelt“ mit „senkrecht“ zusammen: dann nur „senkrecht“, damit z. B. eine
    /// Raute beim späteren Ändern des Winkels rechtwinklig bleibt.
    static func inferenceDirections(_ v: Point2, ref: SketchCurveRef) -> [(direction: Point2, relation: InferredRelation)] {
        let length = simd_length(v)
        guard length > 1e-12 else { return [] }
        let d = v / length
        var result: [(direction: Point2, relation: InferredRelation)] = [(direction: d, relation: .parallel(ref))]
        let slant = min(abs(d.x), abs(d.y))
        let mirror = Point2(d.x, -d.y)
        let perpendicular = Point2(-d.y, d.x)
        let matchesPerpendicular: Bool = abs(simd_dot(mirror, perpendicular)) > cos(equalAngleTolerance)
        if slant > sin(equalAngleTolerance), !matchesPerpendicular {
            result.append((direction: mirror, relation: .mirrored(ref)))
        }
        result.append((direction: perpendicular, relation: .perpendicular(ref)))
        return result
    }

    /// Größter Abstand des Stifts von der eingerasteten Richtung. Gleicher bzw. gespiegelter Winkel rastet
    /// innerhalb von etwa 3° ein (bei langen Linien großzügiger als der Fangradius), senkrecht wie bisher.
    static func inferenceLimit(_ relation: InferredRelation, reach: Double, tolerance: Double) -> Double {
        if relation.isPerpendicular { return tolerance }
        let angular: Double = reach * sin(equalAngleTolerance)
        return max(tolerance, angular)
    }

    /// Richtung genau waagerecht oder senkrecht (15°-Schritt auf 0° bzw. 90°)
    static func isAxisAligned(_ v: Point2) -> Bool {
        let length = simd_length(v)
        guard length > 1e-12 else { return false }
        return abs(v.x) <= length * 1e-9 || abs(v.y) <= length * 1e-9
    }

    /// Die gerade gezeichnete Linie hat (eingerastet) denselben bzw. den gespiegelten Winkel wie eine
    /// vorhandene: Vorschau grün.
    var showsAngleMatch: Bool {
        guard tool == .polyline || tool == .rectangle && rectangleMode == .threePoint else { return false }
        guard let snap = currentSnap, snap.kind == .angle, !angleCandidate, !parallelLines.isEmpty else { return false }
        guard strokeShape == nil, !arcActive else { return false }
        return inferredRelation?.isPerpendicular != true
    }

    /// Einschränkung „Gleicher Winkel“ für zwei Linien: gespiegelt, wenn die Linien jetzt näher am
    /// gespiegelten als am gleichen Winkel liegen.
    func equalAngleVariant(_ a: SketchCurveRef, _ b: SketchCurveRef) -> SketchConstraint.Variant {
        guard case .line(let p1, let p2) = ConstraintSolver.curve(a, entities),
              case .line(let q1, let q2) = ConstraintSolver.curve(b, entities),
              simd_distance(p1, p2) > 1e-12, simd_distance(q1, q2) > 1e-12 else {
            return .equalAngle(a, b, mirrored: false)
        }
        let d1 = simd_normalize(p2 - p1)
        let d2 = simd_normalize(q2 - q1)
        let same: Double = abs(d1.x * d2.y - d1.y * d2.x)
        let mirrored: Double = abs(d1.x * d2.y + d1.y * d2.x)
        return .equalAngle(a, b, mirrored: mirrored < same)
    }
}
