import Foundation
import simd

// Spline-Werkzeug, weitere Varianten (Fusion 360 / Shapr3D): Freihand (Stiftstrich wird zu einer geglätteten
// Spline mit wenigen Fit-Punkten) und Punkt einfügen (vorhandene Spline antippen → neuer Punkt an der Stelle).

/// Wie das Spline-Werkzeug Eingaben versteht (Varianten der Kachel „Spline“).
enum SplineInput: String, CaseIterable, Identifiable {
    /// Jeder Strich bzw. jedes Antippen setzt einen Punkt (wie bisher)
    case points = "Punkte"
    /// Ein Strich wird zu einer glatten Spline
    case freehand = "Freihand"
    /// Vorhandene Spline antippen: Punkt einfügen
    case insert = "Punkt einfügen"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .points: "scribble.variable"
        case .freehand: "pencil.and.scribble"
        case .insert: "plus.circle"
        }
    }
}

extension SketchController {
    // MARK: Freihand-Spline

    /// Stiftstrich → Spline: glätten, mit Douglas-Peucker ausdünnen und so lange Punkte ergänzen, bis die
    /// Spline dem Strich bis auf einen kleinen Rest folgt. Anfang und Ende rasten wie beim Zeichnen ein,
    /// ein Strich zurück zum Anfang ergibt eine geschlossene Spline.
    func endFreehandSpline(_ samples: [Point2], start: Point2, end: Point2, raw: Point2, tolerance: Double) {
        var points = SplineFit.cleaned(samples)
        guard points.count >= 2, StrokeGesture.length(points) > tolerance * 0.5 else {
            notice = "Für eine Freihand-Spline eine Kurve ziehen."
            return
        }
        // Eingerastete Enden übernehmen (verbindet mit vorhandenen Elementen)
        points[0] = start
        if simd_distance(end, raw) <= tolerance { points[points.count - 1] = end }
        let closed = points.count >= 4 && simd_distance(points[0], points[points.count - 1]) <= tolerance * 0.6
            && StrokeGesture.length(points) > tolerance * 4
        if closed { points.removeLast() }
        // Abweichung: etwa 3 Bildschirmpunkte (tolerance entspricht etwa 20 Punkten)
        let fit = SplineFit.fit(points, closed: closed, epsilon: tolerance * 0.15)
        guard fit.count >= (closed ? 3 : 2) else {
            notice = "Strich zu kurz für eine Spline."
            return
        }
        appendEntity(.spline(points: fit, kind: .fit, closed: closed))
        notice = "Freihand-Spline mit \(fit.count) Punkten – Punkte mit „Auswählen“ ziehen."
    }

    // MARK: Punkt einfügen

    /// Spline antippen: an der Stelle einen Punkt einfügen. Fit-Splines laufen weiter durch alle bisherigen
    /// Punkte; der neue liegt genau auf der Kurve. Bei Kontrollpunkt-Splines kommt der Punkt auf das
    /// Kontrollpolygon (die Form ändert sich dort leicht).
    func insertSplinePoint(at p: Point2, tolerance: Double) {
        var best: (distance: Double, entity: Int, hit: SplineFit.Hit)?
        for (index, entity) in entities.enumerated() {
            guard case .spline(let points, let kind, let closed) = entity,
                  let hit = SplineFit.nearest(to: p, points: points, kind: kind, closed: closed) else { continue }
            let distance = simd_distance(hit.point, p)
            if distance <= tolerance * 1.6, distance < (best?.distance ?? .infinity) { best = (distance, index, hit) }
        }
        guard let best, case .spline(var points, let kind, let closed) = entities[best.entity] else {
            notice = "Keine Spline getroffen – direkt auf eine Spline tippen."
            return
        }
        let inserted = best.hit.insertIndex
        let point = best.hit.newPoint
        if points.contains(where: { simd_distance($0, point) < tolerance * 0.3 }) {
            notice = "Dort liegt schon ein Punkt."
            return
        }
        points.insert(point, at: inserted)
        let entityIndex = best.entity
        // Punktverweise hinter dem neuen Punkt rücken eins weiter
        let shifted = constraints.map { constraint in
            constraint.remappingPoints { ref in
                ref.entity == entityIndex && ref.index >= inserted ? SketchPointRef(entity: ref.entity, index: ref.index + 1) : ref
            }
        }
        replaceElement(at: entityIndex, with: .spline(points: points, kind: kind, closed: closed), constraints: shifted)
        notice = kind == .fit ? "Punkt eingefügt (\(points.count) Punkte)."
            : "Kontrollpunkt eingefügt – die Kurve passt sich dort leicht an."
    }
}

// MARK: Rechnen

/// Ausdünnen und Anpassen von Stiftstrichen, Abstand zu Splines.
enum SplineFit {
    /// Nächste Stelle auf einer Spline: Punkt auf der Kurve, wo der neue Punkt eingefügt wird, und welcher.
    struct Hit {
        var point: Point2
        var newPoint: Point2
        var insertIndex: Int
    }

    /// Strich vorbereiten: doppelte Punkte weg, leicht geglättet (Zittern des Stifts), Enden bleiben.
    static func cleaned(_ samples: [Point2]) -> [Point2] {
        var unique: [Point2] = []
        for p in samples where unique.last.map({ simd_distance($0, p) > 1e-9 }) ?? true { unique.append(p) }
        guard unique.count > 4 else { return unique }
        // Sehr lange Striche ausdünnen (das Anpassen prüft jeden Punkt), Enden bleiben
        if unique.count > 800 {
            let step = unique.count / 600 + 1
            let last = unique[unique.count - 1]
            unique = stride(from: 0, to: unique.count, by: step).map { unique[$0] }
            if let tail = unique.last, simd_distance(tail, last) > 1e-9 { unique.append(last) }
        }
        var smoothed = unique
        for _ in 0..<2 {
            let previous = smoothed
            for i in 1..<(previous.count - 1) {
                smoothed[i] = previous[i - 1] * 0.25 + previous[i] * 0.5 + previous[i + 1] * 0.25
            }
        }
        return smoothed
    }

    /// Douglas-Peucker: Indizes der Punkte, die den Linienzug bis auf epsilon wiedergeben.
    static func simplifiedIndices(_ points: [Point2], epsilon: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = Set([0, points.count - 1])
        var stack = [(0, points.count - 1)]
        while let range = stack.popLast() {
            let (a, b) = range
            guard b > a + 1 else { continue }
            var farthest = (distance: 0.0, index: a)
            for i in (a + 1)..<b {
                let d = segmentDistance(points[i], points[a], points[b])
                if d > farthest.distance { farthest = (d, i) }
            }
            if farthest.distance > epsilon {
                keep.insert(farthest.index)
                stack.append((a, farthest.index))
                stack.append((farthest.index, b))
            }
        }
        return keep.sorted()
    }

    /// Fit-Punkte für den Strich: möglichst wenige, mit höchstens etwa epsilon Abweichung. Die Fit-Spline der App
    /// (Catmull-Rom) mag gleichmäßig verteilte Punkte, Douglas-Peucker trifft Ecken und Wendestellen – darum
    /// werden mehrere Vorschläge geprüft und der mit den wenigsten Punkten genommen.
    static func fit(_ points: [Point2], closed: Bool, epsilon: Double) -> [Point2] {
        guard points.count > 2 else { return points }
        var best: [Int]?
        func consider(_ chosen: [Int]) {
            guard chosen.count >= (closed ? 3 : 2), chosen.count < (best?.count ?? .max),
                  deviation(points, chosen, closed: closed) <= epsilon else { return }
            best = chosen
        }
        for factor in [12.0, 8, 6, 4, 3, 2, 1.5, 1] {
            consider(simplifiedIndices(points, epsilon: epsilon * factor))
        }
        consider(evenIndices(points, closed: closed, epsilon: epsilon, limit: best?.count ?? 80))
        let chosen = best ?? greedyIndices(points, closed: closed, epsilon: epsilon)
        return chosen.map { points[$0] }
    }

    /// Größte Abweichung der Strichpunkte von der Fit-Spline durch die gewählten Punkte.
    static func deviation(_ points: [Point2], _ chosen: [Int], closed: Bool) -> Double {
        let poles = fitBezierPoles(chosen.map { points[$0] }, closed: closed)
        let spans = closed ? chosen.count : chosen.count - 1
        var worst = 0.0
        for span in 0..<spans {
            let from = chosen[span]
            let to = span + 1 < chosen.count ? chosen[span + 1] : points.count
            guard to > from + 1 else { continue }
            let curve = (0...16).map { bezier(poles, span: span, t: Double($0) / 16) }
            for i in (from + 1)..<to where i < points.count {
                worst = max(worst, polylineDistance(points[i], curve))
            }
        }
        return worst
    }

    /// Gleichmäßig nach Bogenlänge verteilte Punkte: so wenige wie möglich (höchstens limit).
    static func evenIndices(_ points: [Point2], closed: Bool, epsilon: Double, limit: Int) -> [Int] {
        var lengths = [0.0]
        for i in 1..<points.count { lengths.append(lengths[i - 1] + simd_distance(points[i - 1], points[i])) }
        let total = lengths[lengths.count - 1] + (closed ? simd_distance(points[points.count - 1], points[0]) : 0)
        guard total > 1e-9 else { return [] }
        var chosen: [Int] = []
        for count in (closed ? 3 : 2)..<max(limit, closed ? 4 : 3) {
            chosen = []
            var j = 0
            for k in 0..<count {
                let target = total * Double(k) / Double(closed ? count : count - 1)
                while j + 1 < points.count, abs(lengths[j + 1] - target) <= abs(lengths[j] - target) { j += 1 }
                if chosen.last.map({ j > $0 }) ?? true { chosen.append(j) }
            }
            if deviation(points, chosen, closed: closed) <= epsilon { return chosen }
        }
        return chosen
    }

    /// Rückfall: Douglas-Peucker, dann den am weitesten entfernten Strichpunkt ergänzen, bis es passt.
    static func greedyIndices(_ points: [Point2], closed: Bool, epsilon: Double) -> [Int] {
        var chosen = simplifiedIndices(points, epsilon: epsilon * 2)
        if closed, chosen.count < 3 {
            chosen = [0, points.count / 3, 2 * points.count / 3]
        }
        for _ in 0..<40 {
            let poles = fitBezierPoles(chosen.map { points[$0] }, closed: closed)
            var worst: (distance: Double, index: Int)?
            let spans = closed ? chosen.count : chosen.count - 1
            for span in 0..<spans {
                let from = chosen[span]
                let to = span + 1 < chosen.count ? chosen[span + 1] : points.count
                guard to > from + 1 else { continue }
                let curve = (0...16).map { bezier(poles, span: span, t: Double($0) / 16) }
                for i in (from + 1)..<to where i < points.count {
                    let d = polylineDistance(points[i], curve)
                    if d > epsilon, d > (worst?.distance ?? 0) { worst = (d, i) }
                }
            }
            guard let worst, chosen.count < 200 else { break }
            chosen.append(worst.index)
            chosen.sort()
        }
        return chosen
    }

    /// Nächste Stelle der Spline zum Punkt p.
    static func nearest(to p: Point2, points: [Point2], kind: SplineKind, closed: Bool) -> Hit? {
        guard points.count >= 2 else { return nil }
        switch kind {
        case .fit:
            let poles = fitBezierPoles(points, closed: closed)
            let spans = (poles.count - 1) / 3
            var best: (distance: Double, span: Int, t: Double)?
            for span in 0..<spans {
                // Grob abtasten, dann um den besten Wert verfeinern
                var local: (distance: Double, t: Double)?
                for k in 0...32 {
                    let t = Double(k) / 32
                    let d = simd_distance(bezier(poles, span: span, t: t), p)
                    if d < (local?.distance ?? .infinity) { local = (d, t) }
                }
                guard var refined = local else { continue }
                var step = 1.0 / 64
                for _ in 0..<12 {
                    for t in [refined.t - step, refined.t + step] where t >= 0 && t <= 1 {
                        let d = simd_distance(bezier(poles, span: span, t: t), p)
                        if d < refined.distance { refined = (d, t) }
                    }
                    step /= 2
                }
                if refined.distance < (best?.distance ?? .infinity) { best = (refined.distance, span, refined.t) }
            }
            guard let best else { return nil }
            let onCurve = bezier(poles, span: best.span, t: best.t)
            return Hit(point: onCurve, newPoint: onCurve, insertIndex: best.span + 1)
        case .control:
            // Abstand zur Kurve über ihre Darstellung, eingefügt wird auf dem nächsten Stück des Kontrollpolygons
            let drawing = SketchEntity.spline(points: points, kind: kind, closed: closed).drawing.flatMap { $0 }
            guard let onCurve = drawing.min(by: { simd_distance($0, p) < simd_distance($1, p) }) else { return nil }
            let count = closed ? points.count : points.count - 1
            var best: (distance: Double, index: Int, point: Point2)?
            for i in 0..<count {
                let a = points[i], b = points[(i + 1) % points.count]
                let q = closestPoint(onCurve, a, b)
                let d = simd_distance(q, onCurve)
                if d < (best?.distance ?? .infinity) { best = (d, i, q) }
            }
            guard let best else { return nil }
            return Hit(point: onCurve, newPoint: best.point, insertIndex: best.index + 1)
        }
    }

    /// Punkt t (0…1) im Bézierstück span der Polliste.
    static func bezier(_ poles: [Point2], span: Int, t: Double) -> Point2 {
        let i = span * 3
        guard i + 3 < poles.count else { return poles.last ?? .zero }
        let u = 1 - t
        // In Teilen, sonst braucht der Typprüfer zu lange
        let b0: Double = u * u * u, b1: Double = 3 * u * u * t, b2: Double = 3 * u * t * t, b3: Double = t * t * t
        let head: Point2 = b0 * poles[i] + b1 * poles[i + 1]
        let tail: Point2 = b2 * poles[i + 2] + b3 * poles[i + 3]
        return head + tail
    }

    static func closestPoint(_ p: Point2, _ a: Point2, _ b: Point2) -> Point2 {
        let ab = b - a
        let length2 = simd_length_squared(ab)
        guard length2 > 1e-18 else { return a }
        let t = min(max(simd_dot(p - a, ab) / length2, 0), 1)
        return a + ab * t
    }

    static func segmentDistance(_ p: Point2, _ a: Point2, _ b: Point2) -> Double {
        simd_distance(p, closestPoint(p, a, b))
    }

    static func polylineDistance(_ p: Point2, _ line: [Point2]) -> Double {
        guard line.count >= 2 else { return line.first.map { simd_distance($0, p) } ?? .infinity }
        var best = Double.infinity
        for i in 0..<(line.count - 1) { best = min(best, segmentDistance(p, line[i], line[i + 1])) }
        return best
    }
}

// MARK: Einschränkungen mit verschobenen Punktnummern

extension SketchConstraint {
    /// Dieselbe Einschränkung mit umgerechneten Punktverweisen (z. B. nach dem Einfügen eines Spline-Punkts).
    func remappingPoints(_ f: (SketchPointRef) -> SketchPointRef) -> SketchConstraint {
        var result = self
        switch variant {
        case .coincident(let a, let b): result.variant = .coincident(f(a), f(b))
        case .pointOnCurve(let a, let c): result.variant = .pointOnCurve(f(a), c)
        case .midpoint(let a, let c): result.variant = .midpoint(f(a), c)
        case .horizontalPoints(let a, let b): result.variant = .horizontalPoints(f(a), f(b))
        case .verticalPoints(let a, let b): result.variant = .verticalPoints(f(a), f(b))
        case .symmetric(let a, let b, let axis): result.variant = .symmetric(f(a), f(b), axis: axis)
        case .lock(let a, let at): result.variant = .lock(f(a), at: at)
        case .distance(let a, let b, let value): result.variant = .distance(f(a), f(b), value: value)
        case .pointLineDistance(let a, let c, let value): result.variant = .pointLineDistance(f(a), c, value: value)
        case .parallel, .perpendicular, .tangent, .concentric, .horizontal, .vertical, .equalLength, .equalRadius,
             .angle, .radius:
            break
        }
        return result
    }
}
