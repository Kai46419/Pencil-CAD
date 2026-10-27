import Foundation
import simd

// Fertige Formen der SolidCraft-Klickfolge übernehmen (SolidCraft MIT OR Apache-2.0, crates/ui-egui/src/tools.rs
// `commit_*`, inference.rs `constraints_for`): Jeder Fang beim Absetzen wird zu einer Bedingung, getippte Werte zu
// treibenden Maßen – alles in einem Rückgängig-Schritt. Ohne „Automatisch einschränken“ bleiben nur das Verbinden
// gleicher Punkte und die getippten Maße.

typealias SketchVariant = SketchConstraint.Variant

extension SketchController {
    // MARK: Bedingungen aus dem Fang

    /// Mittelpunkt einer Kurve als Punktreferenz (Kreis, Ellipse, Polygon: 0; Bogen: 2).
    func centerRef(of curve: SketchCurveRef) -> SketchPointRef? {
        guard entities.indices.contains(curve.entity) else { return nil }
        switch entities[curve.entity] {
        case .circle, .ellipse, .regularPolygon: return SketchPointRef(entity: curve.entity, index: 0)
        case .arc: return SketchPointRef(entity: curve.entity, index: 2)
        default: return nil
        }
    }

    /// Punktreferenz des neuen Elements an p (Griffpunkt), nil = p ist kein Griffpunkt.
    private func handleRef(_ p: Point2, in index: Int) -> SketchPointRef? {
        guard entities.indices.contains(index) else { return nil }
        let handles = entities[index].handlePoints
        guard let k = handles.firstIndex(where: { simd_distance($0, p) < 1e-6 }) else { return nil }
        return SketchPointRef(entity: index, index: k)
    }

    /// Bedingungen eines Punkt-Fangs (Schnitt, Mitte, auf Kurve, Verlängerung). Punktfang: verbindet connect().
    private func pointConstraints(_ ref: SketchPointRef, target: SnapTarget?) -> [SketchVariant] {
        guard let target else { return [] }
        switch target {
        case .crossing(let c1, let c2): return [.pointOnCurve(ref, c1), .pointOnCurve(ref, c2)]
        case .midpoint(let c): return [.midpoint(ref, c)]
        case .onCurve(let c), .lineExtension(let c): return [.pointOnCurve(ref, c)]
        default: return []
        }
    }

    /// Punkt der neuen Kurve, der kein Griffpunkt ist (Randpunkt eines Kreises, Punkt auf dem Bogen):
    /// ein gefangener Skizzenpunkt kommt auf die Kurve.
    private func throughConstraints(_ target: SnapTarget?, curve: SketchCurveRef) -> [SketchVariant] {
        guard case .point(let ref?)? = target else { return [] }
        return [.pointOnCurve(ref, curve)]
    }

    /// Bedingungen der Klickpunkte für das neue Element index: Griffpunkte bekommen ihren Fang, andere Punkte
    /// auf der Kurve (curve) einen gefangenen Skizzenpunkt.
    private func placedConstraints(_ placed: [SketchClickPoint], index: Int, curve: SketchCurveRef?) -> [SketchVariant] {
        var result: [SketchVariant] = []
        for point in placed {
            if let ref = handleRef(point.point, in: index) {
                result += pointConstraints(ref, target: point.target)
            } else if let curve {
                result += throughConstraints(point.target, curve: curve)
            }
        }
        return result
    }

    /// Formel eines gesperrten Werts, wenn sie Projektvariablen verwendet (das Maß bleibt verknüpft).
    private func lockedExpression(_ key: String) -> String? {
        guard let text = options.locked[key]?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              Formula.names(in: text).contains(where: { variableValues[$0] != nil }) else { return nil }
        return text
    }

    /// Bedingungen setzen und die Form abschließen.
    private func apply(_ variants: [SketchVariant], dimensions: [(SketchVariant, String?)], base: Int, editable: Int?) {
        if autoConstrain {
            for variant in variants { addCommitConstraint(variant, lockBelow: base) }
        }
        for (variant, expression) in dimensions { addCommitConstraint(variant, expression: expression, lockBelow: base) }
        notice = nil
        finishCommit(editable: editable)
    }

    // MARK: Linie

    /// Linienstück der Klickfolge übernehmen (SolidCraft `commit_line` mit `constraints_for` und `infer_at_start`).
    /// Liefert den Index der neuen Linie.
    func commitLine(from start: SketchClickPoint, to end: SketchClickPoint) -> Int? {
        let a = start.point, b = end.point
        guard simd_distance(a, b) > 1e-9 else { return nil }
        let base = entities.count
        beginCommit()
        let index = appendCommitted(.line(a, b))
        let line = SketchCurveRef(entity: index, index: 0)
        let p0 = SketchPointRef(entity: index, index: 0), p1 = SketchPointRef(entity: index, index: 1)
        var variants = pointConstraints(p0, target: start.target)
        variants += lineEndConstraints(end.target, end: p1, line: line)
        // Genau waagerecht bzw. senkrecht (Achsfang): H/V, außer ein getippter Winkel legt die Richtung fest
        if lockedValue("Winkel") == nil {
            if abs(b.y - a.y) < 1e-9 {
                variants.append(.horizontal(line))
            } else if abs(b.x - a.x) < 1e-9 {
                variants.append(.vertical(line))
            }
        }
        variants += inferredAtStart(start, line: line, direction: b - a)
        var dimensions: [(SketchVariant, String?)] = []
        if let length = lockedValue("Länge"), length > 0 {
            dimensions.append((.distance(p0, p1, value: length), lockedExpression("Länge")))
        }
        apply(variants, dimensions: dimensions, base: base, editable: index)
        return index
    }

    /// Fang am Linienende (SolidCraft `constraints_for`).
    private func lineEndConstraints(_ target: SnapTarget?, end: SketchPointRef, line: SketchCurveRef) -> [SketchVariant] {
        guard let target else { return [] }
        switch target {
        case .tangent(let c):
            return [.tangent(c, line, outside: true)]
        case .throughCenter(let c, let rim, let atCenter):
            guard !atCenter, let center = centerRef(of: c) else { return [] }
            return rim ? [.pointOnCurve(end, c), .pointOnCurve(center, line)] : [.pointOnCurve(center, line)]
        case .horizontal:
            return [.horizontal(line)]
        case .vertical:
            return [.vertical(line)]
        case .parallel(let c):
            return [.parallel(c, line)]
        case .perpendicular(let c):
            return [.perpendicular(c, line)]
        case .angle, .aligned:
            // Winkelschritt bzw. Ausrichtung: nur die Lage, keine Bedingung (0/90° ergeben H/V aus der genauen
            // Lage, 90° zum vorigen Stück „senkrecht“ über inferredAtStart)
            return []
        default:
            return pointConstraints(end, target: target)
        }
    }

    /// SolidCraft `infer_at_start`: Beginnt die Linie an einem Bogenende senkrecht zum Radius, ist sie tangential;
    /// an einem Linienende rechtwinklig dazu senkrecht (außer beide liegen achsparallel – das sagen H/V schon).
    private func inferredAtStart(_ start: SketchClickPoint, line: SketchCurveRef, direction: Point2) -> [SketchVariant] {
        guard case .point(let ref?)? = start.target, entities.indices.contains(ref.entity), ref.index <= 1,
              simd_length(direction) > 1e-9 else { return [] }
        let u = simd_normalize(direction)
        let other = SketchCurveRef(entity: ref.entity, index: 0)
        switch entities[ref.entity] {
        case .arc(let a, let m, let b):
            guard let circle = circleThrough(a, m, b) else { return [] }
            let radial = start.point - circle.center
            guard simd_length(radial) > 1e-9, abs(simd_dot(simd_normalize(radial), u)) < 1e-6 else { return [] }
            return [.tangent(other, line, outside: true)]
        case .line(let a, let b):
            guard simd_distance(a, b) > 1e-9 else { return [] }
            let w = simd_normalize(b - a)
            guard abs(simd_dot(w, u)) < 1e-6 else { return [] }
            let otherAxis = abs(w.x) < 1e-9 || abs(w.y) < 1e-9
            let ownAxis = abs(u.x) < 1e-9 || abs(u.y) < 1e-9
            return otherAxis && ownAxis ? [] : [.perpendicular(other, line)]
        default:
            return []
        }
    }

    // MARK: Formen

    /// Fertige Form der Klickfolge übernehmen.
    func commitClickShape(_ kind: SketchClickKind, _ placed: [SketchClickPoint], sweep: Double,
                          circleInference: CircleInference?) {
        guard let first = placed.first else { return }
        switch kind {
        case .point:
            commitSingle(.point(first.point), placed: placed)
        case .rectangle:
            guard placed.count >= 2 else { return }
            commitRectangle(placed)
        case .rectangleThreePoint:
            guard placed.count >= 3 else { return }
            commitThreePointRectangle(placed)
        case .circle:
            guard placed.count >= 2 else { return }
            commitCircle(placed, inference: circleInference)
        case .circleThreePoint:
            guard placed.count >= 3,
                  let circle = SketchShapes.circle(through: placed[0].point, placed[1].point, placed[2].point) else {
                notice = "Die drei Punkte liegen auf einer Geraden."
                return
            }
            commitSingle(circle, placed: placed)
        case .arcThreePoint:
            guard placed.count >= 3 else { return }
            // Start A, Ende B, Punkt C auf dem Bogen
            let a = placed[0].point, b = placed[1].point, c = placed[2].point
            guard circleThrough(a, c, b) != nil else {
                notice = "Kein Bogen: der dritte Punkt liegt auf der Sehne."
                return
            }
            commitSingle(ConstraintSolver.balancedArc(.arc(start: a, mid: c, end: b)), placed: placed)
        case .arcCenter:
            guard placed.count >= 2,
                  let arc = SketchShapes.arc(center: placed[0].point, start: placed[1].point, sweep: sweep) else {
                notice = "Kein Bogen: Bogenwinkel zu klein."
                return
            }
            var dimensions: [(SketchVariant, String?)] = []
            if let radius = lockedValue("Radius"), radius > 0 {
                dimensions.append((.radius(SketchCurveRef(entity: entities.count, index: 0), value: radius,
                                           diameter: false), lockedExpression("Radius")))
            }
            // Das Ende folgt dem Bogenwinkel: nur ein genau dort gefangener Punkt zählt
            var points = Array(placed.prefix(2))
            if placed.count >= 3, case .arc(_, _, let end) = arc, simd_distance(placed[2].point, end) < 1e-6 {
                points.append(placed[2])
            }
            commitSingle(arc, placed: points, dimensions: dimensions)
        case .arcTangent:
            guard placed.count >= 2 else { return }
            commitTangentArc(placed)
        case .polygon:
            guard placed.count >= 2,
                  let polygon = SketchShapes.polygon(center: placed[0].point, through: placed[1].point,
                                                     sides: polygonSideCount, mode: polygonMode) else { return }
            commitSingle(polygon, placed: placed)
        case .slot:
            guard placed.count >= 3 else { return }
            commitSlot(placed)
        case .ellipse:
            guard placed.count >= 2 else { return }
            let radii = simd_abs(placed[1].point - placed[0].point)
            guard radii.x > 1e-9, radii.y > 1e-9 else { return }
            commitSingle(.ellipse(center: placed[0].point, radii: radii), placed: placed)
        case .line, .tangentCircle:
            break
        }
    }

    /// Ein Element mit den Bedingungen seiner Klickpunkte.
    private func commitSingle(_ entity: SketchEntity, placed: [SketchClickPoint],
                              dimensions: [(SketchVariant, String?)] = [], extra: [SketchVariant] = []) {
        let base = entities.count
        beginCommit()
        let index = appendCommitted(entity)
        let curve: SketchCurveRef? = entity.curveCount == 1 ? SketchCurveRef(entity: index, index: 0) : nil
        apply(placedConstraints(placed, index: index, curve: curve) + extra, dimensions: dimensions, base: base,
              editable: index)
    }

    private func commitCircle(_ placed: [SketchClickPoint], inference: CircleInference?) {
        let a = placed[0].point, b = placed[1].point
        let circle: SketchEntity?
        if circleMode == .twoPoint {
            circle = SketchShapes.circle(diameterFrom: a, to: b)
        } else {
            let r = simd_distance(a, b)
            circle = r > 1e-9 ? .circle(center: a, radius: r) : nil
        }
        guard let circle else { return }
        let curve = SketchCurveRef(entity: entities.count, index: 0)
        var extra: [SketchVariant] = []
        // PencilCAD: beim Aufziehen erkannt (tangential, gleicher Radius)
        if let variant = inference?.variant { extra.append(variant(curve)) }
        var dimensions: [(SketchVariant, String?)] = []
        if let diameter = lockedValue("Durchmesser"), diameter > 0 {
            dimensions.append((.radius(curve, value: diameter, diameter: true), lockedExpression("Durchmesser")))
        }
        commitSingle(circle, placed: placed, dimensions: dimensions, extra: extra)
    }

    /// Rechteck (Diagonale bzw. von der Mitte); abgerundet aus 4 Linien und 4 Bögen.
    private func commitRectangle(_ placed: [SketchClickPoint]) {
        let shapes = rectangleShapes(placed[0].point, placed[1].point)
        guard !shapes.isEmpty else { return }
        let width = lockedValue("Breite"), height = lockedValue("Höhe")
        guard shapes.count == 8 else {
            let index = entities.count
            func corner(_ k: Int) -> SketchPointRef { SketchPointRef(entity: index, index: k) }
            var dimensions: [(SketchVariant, String?)] = []
            if let width, width > 0 { dimensions.append((.distance(corner(0), corner(1), value: width), lockedExpression("Breite"))) }
            if let height, height > 0 { dimensions.append((.distance(corner(1), corner(2), value: height), lockedExpression("Höhe"))) }
            commitSingle(shapes[0], placed: placed, dimensions: dimensions)
            return
        }
        let base = entities.count
        beginCommit()
        let indices = shapes.map { appendCommitted($0) }
        func curve(_ k: Int) -> SketchCurveRef { SketchCurveRef(entity: indices[k], index: 0) }
        // Unten, rechts, oben, links (gerade Indizes) mit den Eckbögen dazwischen (ungerade)
        var variants: [SketchVariant] = [.horizontal(curve(0)), .vertical(curve(2)), .horizontal(curve(4)),
                                         .vertical(curve(6))]
        for k in stride(from: 1, to: 8, by: 2) {
            variants.append(.tangent(curve(k - 1), curve(k), outside: true))
            variants.append(.tangent(curve(k), curve((k + 1) % 8), outside: true))
        }
        for k in [3, 5, 7] { variants.append(.equalRadius(curve(1), curve(k))) }
        // Klickpunkte (Ecken bzw. Mitte) sind keine Griffpunkte der Stücke: nur Punktfang auf den Seiten bleibt
        var dimensions: [(SketchVariant, String?)] = []
        if let width, width > 0 {
            dimensions.append((.pointLineDistance(SketchPointRef(entity: indices[2], index: 0), curve(6), value: width),
                               lockedExpression("Breite")))
        }
        if let height, height > 0 {
            dimensions.append((.pointLineDistance(SketchPointRef(entity: indices[0], index: 0), curve(4), value: height),
                               lockedExpression("Höhe")))
        }
        if let radius = lockedValue("Radius"), radius > 0 {
            dimensions.append((.radius(curve(1), value: radius, diameter: false), lockedExpression("Radius")))
        }
        apply(variants, dimensions: dimensions, base: base, editable: nil)
    }

    /// Gedrehtes Rechteck aus Kante und Breite: geschlossener Linienzug mit rechten Winkeln.
    private func commitThreePointRectangle(_ placed: [SketchClickPoint]) {
        let corners = Self.threePointCorners(placed[0].point, placed[1].point, placed[2].point)
        let edge = corners[1] - corners[0], side = corners[3] - corners[0]
        guard simd_length(edge) > 1e-9, simd_length(side) > 1e-9 else { return }
        let index = entities.count
        func edgeRef(_ k: Int) -> SketchCurveRef { SketchCurveRef(entity: index, index: k) }
        var extra: [SketchVariant] = [.perpendicular(edgeRef(0), edgeRef(1)), .perpendicular(edgeRef(1), edgeRef(2)),
                                      .perpendicular(edgeRef(2), edgeRef(3))]
        if abs(edge.y) < 1e-9 {
            extra.append(.horizontal(edgeRef(0)))
        } else if abs(edge.x) < 1e-9 {
            extra.append(.vertical(edgeRef(0)))
        }
        commitSingle(.polyline(corners, closed: true), placed: Array(placed.prefix(2)), extra: extra)
    }

    /// Tangentialbogen am Ende einer Linie bzw. eines Bogens.
    private func commitTangentArc(_ placed: [SketchClickPoint]) {
        let start = placed[0].point, end = placed[1].point
        guard let tangent = outwardTangent(at: start, tolerance: 1e-6),
              let arc = Self.tangentArcShape(start: start, direction: tangent.direction, end: end) else {
            notice = "Kein Bogen: das Ende liegt auf der Verlängerung."
            return
        }
        let curve = SketchCurveRef(entity: entities.count, index: 0)
        let previous = SketchCurveRef(entity: tangent.entity, index: 0)
        commitSingle(arc, placed: placed, extra: [.tangent(previous, curve, outside: true)])
    }

    /// Langloch: zwei Linien, zwei Halbkreise, tangential, gleicher Radius.
    private func commitSlot(_ placed: [SketchClickPoint]) {
        guard let shapes = slotEntities(base: (placed[0].point, placed[1].point), through: placed[2].point),
              shapes.count == 4 else {
            notice = "Langloch: Breite zu klein."
            return
        }
        let base = entities.count
        beginCommit()
        let indices = shapes.map { appendCommitted($0) }
        func curve(_ k: Int) -> SketchCurveRef { SketchCurveRef(entity: indices[k], index: 0) }
        var variants: [SketchVariant] = [
            .tangent(curve(0), curve(1), outside: true), .tangent(curve(1), curve(2), outside: true),
            .tangent(curve(2), curve(3), outside: true), .tangent(curve(3), curve(0), outside: true),
            .equalRadius(curve(1), curve(3)),
        ]
        // Klickpunkte auf den Bogenmitten (Mitte zu Mitte): ihr Fang gilt für die Mittelpunkte
        for point in placed.prefix(2) {
            for k in [1, 3] {
                if let ref = handleRef(point.point, in: indices[k]) { variants += pointConstraints(ref, target: point.target) }
            }
        }
        var dimensions: [(SketchVariant, String?)] = []
        let centers = (SketchPointRef(entity: indices[3], index: 2), SketchPointRef(entity: indices[1], index: 2))
        if slotMode != .overall, let length = lockedValue("Länge"), length > 0 {
            dimensions.append((.distance(centers.0, centers.1, value: length), lockedExpression("Länge")))
        }
        if let width = lockedValue("Breite"), width > 0 {
            dimensions.append((.radius(curve(1), value: width / 2, diameter: false), lockedExpression("Breite")))
        }
        apply(variants, dimensions: dimensions, base: base, editable: nil)
    }

    // MARK: Tangentenkreise

    /// Hübscher Radius: 1, 2 oder 5 mal einer Zehnerpotenz (SolidCraft `nice_round`).
    static func roundNice(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let power = pow(10, floor(log10(value)))
        let f = value / power
        let nice: Double = f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10
        return nice * power
    }

    /// Versatz einer Kurve um d (beide Seiten): Geraden bzw. Kreise.
    private enum OffsetPath {
        case line(Point2, Point2)
        case circle(Point2, Double)
    }

    private static func offsets(of shape: SketchInference.Shape, by d: Double) -> [OffsetPath] {
        switch shape {
        case .line(let a, let b):
            guard simd_distance(a, b) > 1e-12 else { return [] }
            let n = rightNormal(b - a)
            return [.line(a + n * d, b + n * d), .line(a - n * d, b - n * d)]
        case .circle, .arc:
            guard let round = shape.round else { return [] }
            var result: [OffsetPath] = [.circle(round.center, round.radius + d)]
            if round.radius - d > 1e-9 { result.append(.circle(round.center, round.radius - d)) }
            if d - round.radius > 1e-9 { result.append(.circle(round.center, d - round.radius)) }
            return result
        case .polyline:
            return []
        }
    }

    /// Schnittpunkte zweier Versatzwege (Geraden unbegrenzt, Vollkreise).
    private static func intersections(_ p: OffsetPath, _ q: OffsetPath) -> [Point2] {
        switch (p, q) {
        case (.line(let a, let b), .line(let c, let d)):
            let r = b - a, s = d - c
            let denominator = r.x * s.y - r.y * s.x
            guard abs(denominator) > 1e-12 else { return [] }
            let t = ((c.x - a.x) * s.y - (c.y - a.y) * s.x) / denominator
            return [a + r * t]
        case (.line(let a, let b), .circle(let c, let radius)), (.circle(let c, let radius), .line(let a, let b)):
            let d = b - a
            let l2 = simd_length_squared(d)
            guard l2 > 1e-18 else { return [] }
            let t0 = simd_dot(c - a, d) / l2
            let foot = a + d * t0
            let h2 = radius * radius - simd_length_squared(c - foot)
            guard h2 >= -1e-12 else { return [] }
            let h = max(h2, 0).squareRoot() / l2.squareRoot()
            return h < 1e-12 ? [foot] : [foot + d * h, foot - d * h]
        case (.circle(let c1, let r1), .circle(let c2, let r2)):
            let d = simd_distance(c1, c2)
            guard d > 1e-12, d <= r1 + r2 + 1e-12, d >= abs(r1 - r2) - 1e-12 else { return [] }
            let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
            let h = max(r1 * r1 - a * a, 0).squareRoot()
            let u = (c2 - c1) / d
            let mid = c1 + u * a
            let n = Point2(-u.y, u.x)
            return h < 1e-12 ? [mid] : [mid + n * h, mid - n * h]
        }
    }

    /// Außen- bzw. Innenberührung des neuen Kreises (Mitte, Radius) an der Kurve.
    private static func touchesOutside(_ shape: SketchInference.Shape, center: Point2, radius: Double) -> Bool {
        guard let round = shape.round else { return true }
        return simd_distance(round.center, center) > max(round.radius, radius)
    }

    /// Kreis tangential an zwei angetippte Kurven (SolidCraft `commit_tt_circle`): Radius ein Zehntel der kürzeren
    /// Kurve (gerundet), Mitte am Schnitt der Versatzwege nächst der Mitte zwischen den Tippstellen.
    func commitTwoTangentCircle(_ picks: [(ref: SketchCurveRef, at: Point2)]) {
        guard picks.count >= 2, let c1 = inference.curve(picks[0].ref), let c2 = inference.curve(picks[1].ref) else { return }
        let shortest = min(c1.shape.length, c2.shape.length)
        let r = Self.roundNice(0.1 * max(shortest, 1e-6))
        let middle = (picks[0].at + picks[1].at) / 2
        var best: (distance: Double, center: Point2)?
        for p in Self.offsets(of: c1.shape, by: r) {
            for q in Self.offsets(of: c2.shape, by: r) {
                for center in Self.intersections(p, q) {
                    let distance = simd_distance(center, middle)
                    if distance < (best?.distance ?? .infinity) { best = (distance, center) }
                }
            }
        }
        guard let center = best?.center else {
            notice = "Kein Tangentenkreis an dieser Stelle."
            return
        }
        let base = entities.count
        beginCommit()
        let index = appendCommitted(.circle(center: center, radius: r))
        let curve = SketchCurveRef(entity: index, index: 0)
        let variants: [SketchVariant] = [
            .tangent(picks[0].ref, curve, outside: Self.touchesOutside(c1.shape, center: center, radius: r)),
            .tangent(picks[1].ref, curve, outside: Self.touchesOutside(c2.shape, center: center, radius: r)),
        ]
        // Tangenten immer (sie sind der Sinn des Werkzeugs), dazu der Durchmesser als Maß
        for variant in variants { addCommitConstraint(variant, lockBelow: base) }
        addCommitConstraint(.radius(curve, value: 2 * r, diameter: true), lockBelow: base)
        notice = nil
        finishCommit(editable: index)
    }

    /// Kreis tangential an drei angetippte Kurven (SolidCraft `commit_ttt_circle`): Start in der Mitte der
    /// Tippstellen, der Löser bewegt nur den neuen Kreis.
    func commitThreeTangentCircle(_ picks: [(ref: SketchCurveRef, at: Point2)]) {
        let curves = picks.compactMap { inference.curve($0.ref) }
        guard picks.count >= 3, curves.count == picks.count else { return }
        let centroid = picks.map { $0.at }.reduce(Point2.zero, +) / Double(picks.count)
        let r0 = curves.map { $0.shape.distance(to: centroid) }.reduce(0, +) / Double(curves.count)
        guard r0 > 1e-9 else {
            notice = "Kein Tangentenkreis an dieser Stelle."
            return
        }
        let base = entities.count
        beginCommit()
        let index = appendCommitted(.circle(center: centroid, radius: r0))
        let curve = SketchCurveRef(entity: index, index: 0)
        var tangents: [SketchConstraint] = []
        for k in picks.indices {
            let outside = Self.touchesOutside(curves[k].shape, center: centroid, radius: r0)
            tangents.append(SketchConstraint(variant: .tangent(picks[k].ref, curve, outside: outside)))
        }
        let old = Set(entities.indices.filter { $0 < base })
        guard let solved = ConstraintSolver.solve(entities, constraints: constraints + tangents, locked: old),
              solved.indices.contains(index), case .circle(_, let radius) = solved[index], radius > 1e-6 else {
            revertCommit()
            notice = "Kein Tangentenkreis an dieser Stelle."
            return
        }
        replaceCommitted(solved)
        for tangent in tangents { addCommitConstraint(tangent.variant, lockBelow: base) }
        notice = nil
        finishCommit(editable: index)
    }

    // MARK: Freiheitsgrade, Werte, Hinweise (für das rechte Panel)

    /// Freiheitsgrade der Skizze (SolidCraft „DOF“): übrig, gesamt, und ob alle Bedingungen erfüllt sind.
    var degreesOfFreedom: (remaining: Int, total: Int, ok: Bool) {
        if let cached = dofCache, cached.revision == geometryRevision, cached.constraints == constraints.count {
            return cached.value
        }
        let total = entities.reduce(0) { (sum: Int, entity: SketchEntity) -> Int in
            var count = entity.parameters.count
            if case .arc = entity { count -= 1 }
            return sum + count
        }
        let value: (remaining: Int, total: Int, ok: Bool)
        if let rank = ConstraintSolver.constraintRank(entities, constraints: constraints) {
            value = (max(total - rank.rank, 0), total, rank.satisfied)
        } else {
            value = (total, total, true)
        }
        dofCache = (geometryRevision, constraints.count, value)
        return value
    }

    /// Werte der Wertfelder der aktuellen Stufe (mm bzw. Grad, „Seiten“ als Zahl); leer ohne laufende Form.
    var liveValues: [(key: String, value: Double)] { clickLiveValues }

    /// Hinweis zum aktuellen Werkzeug und seiner Stufe.
    var currentHint: String {
        if let hint = clickHint { return hint }
        switch tool {
        case .select: return "Auswählen: Element antippen, ziehen verschiebt – Rahmen mit dem Finger"
        case .spline: return "Spline: Punkte antippen, „Fertig“ beendet"
        case .text: return "Text: Stelle antippen"
        case .polyline: return "Linie: Punkte antippen bzw. ziehen"
        case .rectangle: return "Rechteck: aufziehen"
        case .circle: return "Kreis: vom Mittelpunkt aufziehen"
        case .arc: return "Bogen: von Start nach Ende ziehen, dann aufziehen"
        case .offset: return "Versatz: Kurve antippen, Pfeil ziehen"
        case .trim: return "Beschneiden: über die Stücke wischen, die wegfallen"
        case .fillet: return "Abrunden: Ecke antippen"
        case .chamfer: return "Fase: Ecke antippen"
        case .extend: return "Verlängern: Linie nahe dem Ende antippen"
        case .breakCurve: return "Unterbrechen: Kurve antippen"
        case .splitAtPoint: return "Teilen an Punkt: Stelle auf der Kurve antippen"
        case .mirror, .circPattern, .rectPattern: return transformStatus
        case .measure: return "Messen: zwei Elemente antippen"
        default: return tool.rawValue
        }
    }
}
