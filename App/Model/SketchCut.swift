import Foundation
import simd

// Schneiden in der Skizze (Kai: „Beim Skizzieren fehlt mir ein Schneidewerkzeug, um Linien durchzuschneiden.“).
// Die Kachel „Schneiden“ links bündelt Beschneiden, Teilen an Punkt, Unterbrechen und Verlängern.
// - Beschneiden per Wischen wie „Power Trim“ in Fusion 360: mit Stift oder Finger quer über mehrere Kurven
//   streichen, jedes überstrichene Stück wird bis zu seinen Schnittpunkten entfernt (ein Rückgängig-Schritt).
//   Antippen beschneidet wie bisher ein Stück. Beim Wischen zeigt der Viewport die Spur dünn rot (cutTrace).
// - Teilen an Punkt: Linie, Bogen, Kreis oder Fit-Spline antippen, sie wird genau dort (auf die Kurve projiziert)
//   in zwei Teile getrennt. Die Teile bleiben über „Zusammenfallend“ verbunden (wie beim Unterbrechen).
//   Ein Kreis wird an der Stelle und gegenüber geteilt (ein Bogen kann nicht ganz herum gehen),
//   eine geschlossene Spline an der Stelle geöffnet.

enum SketchCut {
    /// Stellen, an denen der Strich Kurven kreuzt, in Strichrichtung (Text und Punkte zählen nicht).
    /// step = Abtastweite des Strichs (mm).
    static func crossings(of stroke: [Point2], with entities: [SketchEntity], step: Double) -> [Point2] {
        let path = StrokeGesture.resample(stroke, step: max(step, 1e-6))
        guard path.count >= 2 else { return [] }
        var lo = path[0], hi = path[0]
        for p in path {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        var found: [(position: Double, point: Point2)] = []
        for entity in entities {
            switch entity {
            case .text, .point: continue
            default: break
            }
            for line in entity.drawing where line.count >= 2 {
                for k in 0..<(line.count - 1) {
                    let c = line[k], d = line[k + 1]
                    // Stück liegt neben dem Strich: nichts zu prüfen
                    if max(c.x, d.x) < lo.x || min(c.x, d.x) > hi.x { continue }
                    if max(c.y, d.y) < lo.y || min(c.y, d.y) > hi.y { continue }
                    for j in 0..<(path.count - 1) {
                        guard let x = SketchTrim.segmentSegment(path[j], path[j + 1], c, d) else { continue }
                        let length: Double = max(simd_distance(path[j], path[j + 1]), 1e-12)
                        let along: Double = Double(j) + simd_distance(path[j], x) / length
                        // Ein Hauch entlang der Kurve versetzt: Läuft der Strich genau durch einen Schnittpunkt
                        // zweier Kurven, trifft jeder Treffer weiter seine eigene Kurve statt einer zufälligen
                        let segment: Point2 = d - c
                        let segmentLength: Double = simd_length(segment)
                        let shift: Point2 = segmentLength > 1e-12 ? segment * (step * 0.25 / segmentLength) : .zero
                        found.append((position: along, point: x + shift))
                    }
                }
            }
        }
        found.sort { $0.position < $1.position }
        // Doppelte Treffer (Eckpunkt der Darstellung, zwei Stücke derselben Stelle) nur einmal
        let same = max(step * 0.1, 1e-6)
        var result: [Point2] = []
        for hit in found where !result.contains(where: { simd_distance($0, hit.point) < same }) {
            result.append(hit.point)
        }
        return result
    }
}

// MARK: Teilen an Punkt (Rechnen)

extension SketchTrim {
    /// Teilen an Punkt: entity an der Stelle von p (auf die Kurve projiziert) trennen. Linie und Bogen ergeben
    /// zwei Teile, ein Kreis zwei Halbkreise (an der Stelle und gegenüber), eine offene Fit-Spline zwei Splines,
    /// eine geschlossene wird dort geöffnet. nil, wenn die Stelle ein Ende ist oder sich das Element nicht teilen
    /// lässt (Ellipse, Kontrollpunkt-Spline, Text, Punkt; Rechtecke und Linienzüge vorher in Linien zerlegen).
    static func splitAtPoint(_ entity: SketchEntity, _ p: Point2) -> [SketchEntity]? {
        switch entity {
        case .line(let a, let b):
            let ab: Point2 = b - a
            let length2: Double = simd_length_squared(ab)
            guard length2 > 1e-18 else { return nil }
            let t: Double = min(max(simd_dot(p - a, ab) / length2, 0), 1)
            let length: Double = length2.squareRoot()
            // Mindestens ein tausendstel Millimeter auf jeder Seite
            guard t * length > 1e-3, (1 - t) * length > 1e-3 else { return nil }
            let q: Point2 = a + ab * t
            return [.line(a, q), .line(q, b)]
        case .arc(let a, let m, let b):
            guard let arc = ArcGeometry(a, m, b), let s = arc.parameter(p) else { return nil }
            let length: Double = abs(arc.sweep) * arc.radius
            guard s * length > 1e-3, (1 - s) * length > 1e-3 else { return nil }
            // Enden genau übernehmen, damit verbundene Nachbarn verbunden bleiben
            let q: Point2 = arc.point(s)
            let first = SketchEntity.arc(start: a, mid: arc.point(s / 2), end: q)
            let second = SketchEntity.arc(start: q, mid: arc.point((1 + s) / 2), end: b)
            return [first, second]
        case .circle(let c, let r):
            guard r > 1e-9 else { return nil }
            let tap: Double = atan2(p.y - c.y, p.x - c.x)
            func point(_ angle: Double) -> Point2 { c + r * Point2(cos(angle), sin(angle)) }
            let q = point(tap), opposite = point(tap + .pi)
            let first = SketchEntity.arc(start: q, mid: point(tap + .pi / 2), end: opposite)
            let second = SketchEntity.arc(start: opposite, mid: point(tap + 1.5 * .pi), end: q)
            return [first, second]
        case .spline(let points, let kind, let closed, let tangents):
            guard kind == .fit else { return nil }
            return splitFitSpline(points: points, closed: closed, tangents: tangents, at: p)
        default:
            return nil
        }
    }

    /// Ableitung des Bézierstücks span nach seinem Parameter (entspricht der Hermite-Tangente der Fit-Spline).
    private static func bezierDerivative(_ poles: [Point2], span: Int, t: Double) -> Point2 {
        let i = span * 3
        guard i + 3 < poles.count else { return .zero }
        let u: Double = 1 - t
        let d0: Point2 = poles[i + 1] - poles[i]
        let d1: Point2 = poles[i + 2] - poles[i + 1]
        let d2: Point2 = poles[i + 3] - poles[i + 2]
        let w0: Double = 3 * u * u
        let w1: Double = 6 * u * t
        let w2: Double = 3 * t * t
        let head: Point2 = w0 * d0 + w1 * d1
        let tail: Point2 = w2 * d2
        return head + tail
    }

    /// Fit-Spline an der nächsten Stelle zu p trennen. Damit sich die Form kaum ändert, bekommen die neuen Enden
    /// die Tangente der Kurve an der Schnittstelle und die Nachbarpunkte ihre bisherige Tangente als eigene.
    private static func splitFitSpline(points: [Point2], closed: Bool, tangents: [Point2?]?,
                                       at p: Point2) -> [SketchEntity]? {
        let n = points.count
        guard n >= 2, !(closed && n < 3) else { return nil }
        let poles: [Point2] = fitBezierPoles(points, closed: closed, tangents: tangents)
        let spans = (poles.count - 1) / 3
        guard spans >= 1 else { return nil }
        // Nächste Stelle: grob abtasten, dann um den besten Wert verfeinern
        var best: (distance: Double, span: Int, t: Double)?
        for span in 0..<spans {
            for k in 0...32 {
                let t = Double(k) / 32
                let d = simd_distance(SplineFit.bezier(poles, span: span, t: t), p)
                if d < (best?.distance ?? .infinity) { best = (d, span, t) }
            }
        }
        guard var hit = best else { return nil }
        var step = 1.0 / 64
        for _ in 0..<14 {
            for t in [hit.t - step, hit.t + step] where t >= 0 && t <= 1 {
                let d = simd_distance(SplineFit.bezier(poles, span: hit.span, t: t), p)
                if d < hit.distance { hit = (d, hit.span, t) }
            }
            step /= 2
        }
        let span = hit.span, t = hit.t
        let q: Point2 = SplineFit.bezier(poles, span: span, t: t)
        let effective: [Point2] = (0..<n).map { fitSplineTangent(points, closed: closed, index: $0, tangents: tangents) }
        func custom(_ i: Int) -> Point2? {
            guard let list = tangents, list.indices.contains(i) else { return nil }
            return list[i]
        }
        func usable(_ v: Point2) -> Point2? { simd_length(v) > 1e-12 ? v : nil }

        // Schnitt genau auf einem vorhandenen Fit-Punkt
        let next = (span + 1) % n
        var onPoint: Int?
        if simd_distance(q, points[span]) < 1e-5 {
            onPoint = span
        } else if simd_distance(q, points[next]) < 1e-5 {
            onPoint = next
        }
        if let k = onPoint {
            if closed {
                // Geschlossen: ab dem Punkt einmal herum und wieder zurück zu ihm
                let order: [Int] = (0...n).map { (k + $0) % n }
                let opened: [Point2] = order.map { points[$0] }
                var list: [Point2?] = order.map { custom($0) }
                list[0] = usable(effective[k])
                list[n] = usable(effective[k])
                return [.spline(points: opened, kind: .fit, closed: false, tangents: list)]
            }
            guard k > 0, k < n - 1 else { return nil }
            let leftPoints = Array(points[0...k])
            var leftTangents: [Point2?] = (0...k).map { custom($0) }
            leftTangents[k] = usable(effective[k])
            let rightPoints = Array(points[k...])
            var rightTangents: [Point2?] = (k..<n).map { custom($0) }
            rightTangents[0] = usable(effective[k])
            return [.spline(points: leftPoints, kind: .fit, closed: false, tangents: leftTangents),
                    .spline(points: rightPoints, kind: .fit, closed: false, tangents: rightTangents)]
        }

        // Schnitt mitten im Stück span: neuer Punkt q
        let derivative: Point2 = bezierDerivative(poles, span: span, t: t)
        let intoCut: Point2? = usable(derivative * t)
        let outOfCut: Point2? = usable(derivative * (1 - t))
        if closed {
            // q, P(span+1), …, P(span), q
            let order: [Int] = (1...n).map { (span + $0) % n }
            var opened: [Point2] = [q]
            opened += order.map { points[$0] }
            opened.append(q)
            var list: [Point2?] = [outOfCut]
            list += order.map { custom($0) }
            list.append(intoCut)
            list[1] = usable(effective[order[0]])
            list[n] = usable(effective[span])
            return [.spline(points: opened, kind: .fit, closed: false, tangents: list)]
        }
        var leftPoints: [Point2] = Array(points[0...span])
        leftPoints.append(q)
        var leftTangents: [Point2?] = (0...span).map { custom($0) }
        leftTangents[span] = usable(effective[span])
        leftTangents.append(intoCut)
        var rightPoints: [Point2] = [q]
        rightPoints += points[(span + 1)...]
        var rightTangents: [Point2?] = [outOfCut]
        rightTangents += ((span + 1)..<n).map { custom($0) }
        rightTangents[1] = usable(effective[span + 1])
        return [.spline(points: leftPoints, kind: .fit, closed: false, tangents: leftTangents),
                .spline(points: rightPoints, kind: .fit, closed: false, tangents: rightTangents)]
    }
}

// MARK: Werkzeuge

extension SketchController {
    /// Beschneiden per Wischen (Fusion 360 „Power Trim“): jedes überstrichene Kurvenstück wird bis zu seinen
    /// Schnittpunkten entfernt – ein Rückgängig-Schritt für den ganzen Wisch. false = kein Wisch, sondern ein
    /// Antippen (dann beschneidet der Aufrufer wie bisher).
    func trimSwiped(_ samples: [Point2], tolerance: Double) -> Bool {
        let length = StrokeGesture.length(samples)
        guard samples.count >= 2, length > tolerance * 0.5 else { return false }
        let crossings = SketchCut.crossings(of: samples, with: entities, step: tolerance * 0.2)
        guard !crossings.isEmpty else {
            // Kurz verrutscht, ohne etwas zu kreuzen: gilt als Antippen
            if length < tolerance * 2 { return false }
            notice = "Keine Kurve überstrichen – quer über die Stücke wischen, die weg sollen."
            return true
        }
        rememberForCut()
        var trimmed = 0
        var refused = 0
        for point in crossings {
            // Stück schon mit einem früheren Treffer entfernt: nil
            guard let done = trimPiece(at: point, reach: tolerance * 0.1) else { continue }
            if done { trimmed += 1 } else { refused += 1 }
        }
        guard trimmed > 0 else {
            revertCut()
            notice = refused > 0
                ? "Ellipsen und Splines mit Schnittpunkten lassen sich nicht beschneiden – nur ganz löschen."
                : "Keine Kurve überstrichen – quer über die Stücke wischen, die weg sollen."
            return true
        }
        notice = refused > 0
            ? "\(trimmed) beschnitten – Ellipsen und Splines mit Schnittpunkten bleiben (nur ganz löschbar)."
            : nil
        finishCut()
        return true
    }

    /// Ein Stück an p beschneiden, ohne eigenen Rückgängig-Schritt. nil = dort liegt keine Kurve (mehr),
    /// false = das Element lässt sich nicht beschneiden.
    private func trimPiece(at p: Point2, reach: Double) -> Bool? {
        guard let index = cutTarget(near: p, tolerance: reach) else { return nil }
        switch entities[index] {
        case .text:
            return false
        case .ellipse, .spline:
            // Erst prüfen, dann ändern (Ellipsen und Splines mit Schnittpunkten gehen nicht)
            let cutters = entities.indices.filter { $0 != index }.flatMap { entities[$0].trimPrimitives }
            guard let pieces = SketchTrim.trim(entities[index], at: p, cutters: cutters) else { return false }
            replaceForCut(index, with: pieces)
            return true
        default:
            break
        }
        var target = index
        if let lines = entities[index].exploded {
            let first = replaceForCut(index, with: lines)
            target = cutTarget(near: p, tolerance: .infinity, among: Array(first..<entities.count)) ?? first
        }
        let cutters = entities.indices.filter { $0 != target }.flatMap { entities[$0].trimPrimitives }
        guard let pieces = SketchTrim.trim(entities[target], at: p, cutters: cutters) else { return false }
        replaceForCut(target, with: pieces)
        return true
    }

    /// Teilen an Punkt: angetippte Kurve an der Stelle trennen. snapped = gefangener Punkt; liegt er auf der Kurve
    /// (Mitte, Schnittpunkt), wird genau dort geteilt, sonst an der angetippten Stelle.
    func splitCurve(at raw: Point2, snapped: Point2, tolerance: Double) {
        guard let index = cutTarget(near: raw, tolerance: tolerance) else {
            notice = "Linie, Bogen, Kreis oder Spline antippen – sie wird an der Stelle geteilt."
            return
        }
        switch entities[index] {
        case .text, .point:
            notice = "Text und Punkte lassen sich nicht teilen."
            return
        case .ellipse:
            notice = "Ellipsen lassen sich nicht teilen."
            return
        case .spline(_, let kind, _, _) where kind == .control:
            notice = "Kontrollpunkt-Splines lassen sich nicht teilen – nur Splines durch Fit-Punkte."
            return
        default:
            break
        }
        rememberForCut()
        var target = index
        if let lines = entities[index].exploded {
            let first = replaceForCut(index, with: lines)
            target = cutTarget(near: raw, tolerance: .infinity, among: Array(first..<entities.count)) ?? first
        }
        let entity = entities[target]
        var found: [SketchEntity]?
        if simd_distance(snapped, raw) > 1e-9 {
            let distance: Double = entity.drawing
                .map { polylineDistance(from: snapped, to: $0, closed: false).distance }
                .min() ?? .infinity
            if distance <= tolerance * 0.05 { found = SketchTrim.splitAtPoint(entity, snapped) }
        }
        if found == nil { found = SketchTrim.splitAtPoint(entity, raw) }
        guard let pieces = found, !pieces.isEmpty else {
            revertCut()
            notice = "Am Ende einer Kurve lässt sich nicht teilen – etwas weiter innen antippen."
            return
        }
        replaceForCut(target, with: pieces)
        switch entity {
        case .circle:
            notice = "Kreis an der Stelle und gegenüber geteilt – zwei Halbkreise, verbunden."
        case .spline(_, _, let closed, _) where closed:
            notice = "Spline an der Stelle geöffnet."
        default:
            notice = "In \(pieces.count) Teile geteilt – die Enden bleiben verbunden."
        }
        finishCut()
    }
}
