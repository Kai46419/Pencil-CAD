import Foundation
import simd

// Fang („Rastfunktion“) nach SolidCraft (MIT OR Apache-2.0, crates/ui-egui/src/sketch_tools.rs `refine_snap`,
// inference.rs, sketch_dims.rs `snap_axis`/`on_curve_axis`, viewport.rs `sketch_point_at`): je Stiftposition genau
// ein Fangkandidat in fester Reihenfolge – vorhandener Punkt, Körperecke, Schnittpunkt, Linienmitte, Tangente und
// „durch das Zentrum“ (nur Linie), auf Kurve, waagerecht/senkrecht zum vorigen Punkt, parallel/senkrecht/
// Verlängerung (nur Linie), sonst Feinraster. Jeder Fang wird beim Absetzen zu einer Bedingung (SketchCommit.swift).

/// Eingabeart für die Fangradien (SolidCraft rechnet mit Mauspunkten; Stift ×1,5, Finger ×3).
enum SnapInput {
    case pencil, finger, hover
}

/// Fangradien in Skizzenmaß (mm) für die aktuelle Zoomstufe und Eingabeart (Spezifikation C.4).
struct SnapMetrics {
    /// Millimeter je Bildschirmpunkt
    var mmPerPoint: Double
    var input: SnapInput = .pencil
    /// Halbe sichtbare Höhe in mm (für das 1-2-5-Raster)
    var viewHalfHeight: Double = 0

    private var factor: Double { input == .finger ? 3 : 1.5 }
    /// Schnittpunkt, Mitte, Tangente, Zentrum, H/V, //, ⊥ (SolidCraft 7 pt)
    var refine: Double { 7 * factor * mmPerPoint }
    /// Auf Kurve, Verlängerung (0,8 · tol)
    var onCurve: Double { refine * 0.8 }
    /// „Nur Mitte“: 1,5 · tol
    var preferredMidpoint: Double { refine * 1.5 }
    /// Vorhandener Skizzenpunkt: 8 pt + 2 pt Bonus der aktiven Skizze
    var pointPick: Double { 10 * factor * mmPerPoint }
    /// Kurve unter dem Stift: 6 pt + 2 pt Bonus
    var curvePick: Double { 8 * factor * mmPerPoint }
    /// Geweckte Kreis- bzw. Bogenmitte (SolidCraft 16 pt)
    var wokenCenter: Double { (input == .finger ? 40 : 24) * mmPerPoint }
    /// Spline schließen (8 pt)
    var splineClose: Double { 8 * factor * mmPerPoint }
    /// Achsfang der Linie (2,5°, Finger 3°)
    var axisSnap: Double { (input == .finger ? 3.0 : 2.5) * .pi / 180 }
    /// Kürzer als das: Tippen statt Ziehen
    var tapSlop: Double { (input == .finger ? 10 : 6) * mmPerPoint }

    /// SolidCraft `grid_step`: raw = h/10, Stufe 1-2-5 · 10ⁿ, Hauptlinie jede 5.
    static func gridStep(halfHeight: Double) -> (minor: Double, major: Double) {
        let raw = max(halfHeight / 10, 1e-3)
        let power: Double = pow(10.0, floor(log10(raw)))
        let ratio = raw / power
        let minor: Double = ratio < 2 ? power : (ratio < 5 ? 2 * power : 5 * power)
        return (minor, 5 * minor)
    }

    /// Feinraster des Fangs: ein Zehntel der Rasterstufe.
    var fineGridStep: Double {
        let half = viewHalfHeight > 0 ? viewHalfHeight : mmPerPoint * 400
        return Self.gridStep(halfHeight: half).minor / 10
    }
}

/// Was ein Fang beim Absetzen bedeutet (SolidCraft-Punktargument bzw. Inferenz).
enum SnapTarget: Equatable {
    /// Vorhandener Skizzenpunkt (nil: Ursprung oder Punkt der laufenden Eingabe)
    case point(SketchPointRef?)
    /// Körperecke (projiziert)
    case modelVertex(Point2)
    /// Schnittpunkt zweier Kurven
    case crossing(SketchCurveRef, SketchCurveRef)
    /// Linienmitte
    case midpoint(SketchCurveRef)
    /// Punkt auf einer Kurve
    case onCurve(SketchCurveRef)
    /// Tangentenpunkt an Kreis/Bogen vom vorigen Punkt aus
    case tangent(SketchCurveRef)
    /// Linie durch das Zentrum eines Kreises/Bogens; rim = Ende auf dem Rand, atCenter = Ende im Zentrum
    case throughCenter(SketchCurveRef, rim: Bool, atCenter: Bool)
    case horizontal
    case vertical
    case parallel(SketchCurveRef)
    case perpendicular(SketchCurveRef)
    /// Auf der Verlängerung einer Linie
    case lineExtension(SketchCurveRef)
    case grid

    /// Fang mit Punktargument: großer Ring (6 pt) statt kleinem (3 pt).
    var isPointArgument: Bool {
        switch self {
        case .point, .modelVertex, .crossing, .midpoint, .onCurve, .throughCenter: true
        default: false
        }
    }

    /// Punktfänge klicken immer (Haptik); Leitlinien und Kurven nur mit „Haptik beim Zeichnen“.
    var isPointSnap: Bool {
        switch self {
        case .point, .modelVertex, .crossing, .midpoint, .throughCenter: true
        default: false
        }
    }
}

/// Ein Fangkandidat: Punkt, Bedeutung, gestrichelte Leitlinie und Schild („X“, „Mid“, „On“, „H“ …).
struct SnapCandidate {
    var point: Point2
    var target: SnapTarget?
    var guide: (Point2, Point2)?
    var label: String = ""

    static func free(_ p: Point2) -> SnapCandidate { SnapCandidate(point: p, target: nil, guide: nil, label: "") }

    var hasArgument: Bool { target?.isPointArgument ?? false }
}

/// Kurven und Punkte der Skizze mit ihren Referenzen, einmal je Änderung aufgebaut.
struct SketchInference {
    enum Shape {
        case line(Point2, Point2)
        case circle(center: Point2, radius: Double)
        case arc(ArcGeometry)
        /// Ellipse, Spline: als Linienzug angenähert
        case polyline([Point2])
    }

    struct Curve {
        var ref: SketchCurveRef
        var shape: Shape
        var construction: Bool
    }

    struct Node {
        var point: Point2
        var ref: SketchPointRef?
        var isCenter: Bool
        /// Ursprung: bei Gleichstand gewinnt ein beweglicher Punkt
        var movable: Bool
    }

    private(set) var curves: [Curve] = []
    private(set) var nodes: [Node] = []
    private(set) var modelPoints: [Point2] = []

    init() {}

    init(entities: [SketchEntity], construction: Set<Int>, modelPoints: [Point2] = []) {
        self.modelPoints = modelPoints
        for (index, entity) in entities.enumerated() {
            if case .text = entity { continue }
            let handles = entity.handlePoints
            for (k, p) in handles.enumerated() {
                var isCenter = false
                switch entity {
                // SolidCraft kennt keine Rechteckmitte als Punkt
                case .rectangle where k == 4: continue
                case .circle, .ellipse, .regularPolygon: isCenter = k == 0
                case .arc: isCenter = k == 2
                default: break
                }
                nodes.append(Node(point: p, ref: SketchPointRef(entity: index, index: k), isCenter: isCenter,
                                  movable: true))
            }
            let isConstruction = construction.contains(index)
            let first = SketchCurveRef(entity: index, index: 0)
            switch entity {
            case .point:
                break
            case .arc(let a, let m, let b):
                if let arc = ArcGeometry(a, m, b) {
                    curves.append(Curve(ref: first, shape: .arc(arc), construction: isConstruction))
                } else {
                    curves.append(Curve(ref: first, shape: .line(a, b), construction: isConstruction))
                }
            case .line, .rectangle, .regularPolygon, .polyline, .circle:
                for k in 0..<entity.curveCount {
                    let ref = SketchCurveRef(entity: index, index: k)
                    switch entity.constraintCurve(k) {
                    case .line(let a, let b):
                        curves.append(Curve(ref: ref, shape: .line(a, b), construction: isConstruction))
                    case .circle(let c, let r):
                        curves.append(Curve(ref: ref, shape: .circle(center: c, radius: r), construction: isConstruction))
                    case .other:
                        break
                    }
                }
            default:
                for line in entity.drawing where line.count >= 2 {
                    curves.append(Curve(ref: first, shape: .polyline(line), construction: isConstruction))
                }
            }
        }
        // Ursprung der Skizze (fest)
        nodes.append(Node(point: .zero, ref: nil, isCenter: false, movable: false))
    }

    // MARK: Stufe 0: vorhandener Punkt

    /// Nächster Skizzenpunkt unter dem Stift (Bildschirmabstand < 8 pt + Bonus), bei Gleichstand der bewegliche.
    func pointHit(_ lp: Point2, metrics: SnapMetrics, kinds: Set<SnapKind>, extra: [Point2]) -> Node? {
        var best: (distance: Double, node: Node)?
        let all = nodes + extra.map { Node(point: $0, ref: nil, isCenter: false, movable: true) }
        for node in all {
            if node.isCenter ? !kinds.contains(.center) : !kinds.contains(.endpoint) { continue }
            let d = simd_distance(node.point, lp)
            guard d < metrics.pointPick else { continue }
            if let current = best {
                let tie = abs(d - current.distance) < 1e-9
                if tie ? !(node.movable && !current.node.movable) : d >= current.distance { continue }
            }
            best = (d, node)
        }
        return best?.node
    }

    /// Kurve unter dem Stift (zum Wecken der Kreismitte und für die Auswahl der Tangentenkreise).
    func curveHit(_ lp: Point2, radius: Double) -> Curve? {
        var best: (distance: Double, curve: Curve)?
        for curve in curves {
            let d = curve.shape.distance(to: lp)
            if d < radius, d < (best?.distance ?? .infinity) { best = (d, curve) }
        }
        return best?.curve
    }

    func curve(_ ref: SketchCurveRef) -> Curve? {
        curves.first { $0.ref == ref }
    }

    // MARK: refine_snap

    /// Fang an lp in der Reihenfolge von SolidCraft. prev = zuletzt gesetzter Punkt des Werkzeugs, lineTool =
    /// Inferenzen nur für die Linie (Tangente, Zentrum, parallel/senkrecht/Verlängerung), midOnly = nur Mitten,
    /// fineStep = Feinraster (für H/V und das Raster), gridOn = Raster aktiv.
    func refine(_ lp: Point2, prev: Point2?, lineTool: Bool, metrics: SnapMetrics, midOnly: Bool, kinds: Set<SnapKind>,
                extra: [Point2], woken: Point2?, fineStep: Double, gridOn: Bool) -> SnapCandidate {
        // 0: vorhandener Punkt bzw. geweckte Mitte
        if let node = pointHit(lp, metrics: metrics, kinds: kinds, extra: extra) {
            return SnapCandidate(point: node.point, target: .point(node.ref), guide: nil, label: "")
        }
        if let woken, simd_distance(woken, lp) < metrics.wokenCenter,
           let node = nodes.first(where: { $0.isCenter && simd_distance($0.point, woken) < 1e-9 }) {
            return SnapCandidate(point: node.point, target: .point(node.ref), guide: nil, label: "")
        }
        let tol = metrics.refine
        // 1: Körperecke
        if kinds.contains(.modelPoint) {
            var best: (distance: Double, point: Point2)?
            for q in modelPoints {
                let d = simd_distance(q, lp)
                if d < metrics.pointPick, d < (best?.distance ?? .infinity) { best = (d, q) }
            }
            if let best { return SnapCandidate(point: best.point, target: .modelVertex(best.point), guide: nil, label: "Pt") }
        }
        // 2: Schnittpunkt zweier Kurven
        if !midOnly, kinds.contains(.intersection), let crossing = nearestCrossing(lp, tolerance: tol, extra: extra) {
            return SnapCandidate(point: crossing.point, target: .crossing(crossing.a, crossing.b), guide: nil, label: "X")
        }
        // 3: Linienmitte (Bögen nicht)
        if kinds.contains(.midpoint) {
            let reach = midOnly ? metrics.preferredMidpoint : tol
            var best: (distance: Double, point: Point2, ref: SketchCurveRef)?
            for curve in curves {
                guard case .line(let a, let b) = curve.shape else { continue }
                let m = (a + b) / 2
                let d = simd_distance(m, lp)
                if d < reach, d < (best?.distance ?? .infinity) { best = (d, m, curve.ref) }
            }
            if let best { return SnapCandidate(point: best.point, target: .midpoint(best.ref), guide: nil, label: "Mid") }
        }
        if midOnly { return gridded(lp, fineStep: fineStep, gridOn: gridOn) }
        // 4, 5: Tangente und durch das Zentrum (nur Linie)
        if lineTool, let prev {
            if let found = tangent(prev: prev, lp: lp, tolerance: tol) { return found }
            if let found = throughCenter(prev: prev, lp: lp, tolerance: tol) { return found }
        }
        // 6: auf Kurve
        if kinds.contains(.onCurve) {
            var best: (distance: Double, point: Point2, ref: SketchCurveRef)?
            for curve in curves {
                let q = curve.shape.project(lp)
                let d = simd_distance(q, lp)
                if d < metrics.onCurve, d < (best?.distance ?? .infinity) { best = (d, q, curve.ref) }
            }
            if let best { return SnapCandidate(point: best.point, target: .onCurve(best.ref), guide: nil, label: "On") }
        }
        // 7: waagerecht/senkrecht zum vorigen Punkt; die freie Koordinate folgt dem Feinraster
        if let prev {
            let dx = abs(lp.x - prev.x), dy = abs(lp.y - prev.y)
            func g(_ v: Double) -> Double { fineStep > 0 ? (v / fineStep).rounded() * fineStep : v }
            if dy < tol, dx > tol {
                return SnapCandidate(point: Point2(g(lp.x), prev.y), target: .horizontal, guide: nil, label: "H")
            }
            if dx < tol, dy > tol {
                return SnapCandidate(point: Point2(prev.x, g(lp.y)), target: .vertical, guide: nil, label: "V")
            }
        }
        // 8: parallel, senkrecht, Verlängerung (nur Linie)
        if lineTool, let prev, let found = lineInference(prev: prev, lp: lp, tolerance: tol) { return found }
        // 9: Raster
        return gridded(lp, fineStep: fineStep, gridOn: gridOn)
    }

    private func gridded(_ lp: Point2, fineStep: Double, gridOn: Bool) -> SnapCandidate {
        guard gridOn, fineStep > 0 else { return .free(lp) }
        let p = Point2((lp.x / fineStep).rounded() * fineStep, (lp.y / fineStep).rounded() * fineStep)
        return SnapCandidate(point: p, target: .grid, guide: nil, label: "")
    }

    /// Nächster Schnittpunkt zweier Kurven nahe lp (höchstens 256 Kurven); ohne Schnittpunkte, auf denen schon
    /// ein Punkt liegt (dort greift Stufe 0).
    private func nearestCrossing(_ lp: Point2, tolerance tol: Double, extra: [Point2])
        -> (point: Point2, a: SketchCurveRef, b: SketchCurveRef)? {
        var candidates: [Curve] = []
        for curve in curves where curve.shape.distance(to: lp) <= tol {
            candidates.append(curve)
            if candidates.count >= 256 { break }
        }
        guard candidates.count >= 2 else { return nil }
        var best: (distance: Double, point: Point2, a: SketchCurveRef, b: SketchCurveRef)?
        for i in candidates.indices {
            for j in candidates.indices where j > i {
                // Kanten desselben Elements treffen sich an Ecken: das sind Punkte
                let first = candidates[i], second = candidates[j]
                for p in first.shape.primitives {
                    for q in second.shape.primitives {
                        for x in SketchTrim.intersections(p, q) {
                            let d = simd_distance(x, lp)
                            guard d <= tol, d < (best?.distance ?? .infinity) else { continue }
                            if nodes.contains(where: { simd_distance($0.point, x) <= 1e-4 })
                                || extra.contains(where: { simd_distance($0, x) <= 1e-4 }) { continue }
                            best = (d, x, first.ref, second.ref)
                        }
                    }
                }
            }
        }
        return best.map { ($0.point, $0.a, $0.b) }
    }

    // MARK: Inferenzen der Linie (inference.rs)

    /// Tangente vom vorigen Punkt an einen Kreis bzw. Bogen (nicht an Konstruktionskreise).
    func tangent(prev: Point2, lp: Point2, tolerance tol: Double) -> SnapCandidate? {
        var best: (distance: Double, candidate: SnapCandidate)?
        for curve in curves where !curve.construction {
            guard let round = curve.shape.round else { continue }
            let d = simd_distance(prev, round.center)
            guard d > round.radius + 1e-9 else { continue }
            let base = atan2(prev.y - round.center.y, prev.x - round.center.x)
            let half = acos(round.radius / d)
            for s in [-1.0, 1.0] {
                let angle = base + s * half
                let t = round.center + Point2(cos(angle), sin(angle)) * round.radius
                guard curve.shape.distance(to: t) < 1e-6 else { continue }
                let e = simd_distance(t, lp)
                if e < tol, e < (best?.distance ?? .infinity) {
                    best = (e, SnapCandidate(point: t, target: .tangent(curve.ref), guide: (prev, t), label: "T"))
                }
            }
        }
        return best?.candidate
    }

    /// Die Linie vom vorigen Punkt läuft durch das Zentrum eines Kreises bzw. Bogens: auf dem Rand ein
    /// Durchmesser bzw. Radius, auf dem Zentrum das Zentrum, sonst ein freier Punkt auf der Radiallinie.
    func throughCenter(prev: Point2, lp: Point2, tolerance tol: Double) -> SnapCandidate? {
        var best: (distance: Double, candidate: SnapCandidate)?
        for curve in curves {
            guard let round = curve.shape.round, round.radius > 1e-9 else { continue }
            let o = round.center, r = round.radius
            let toCenter = o - prev
            let d = simd_length(toCenter)
            guard d > 1e-9 else { continue }
            let dir = toCenter / d
            let v = lp - prev
            let off = abs(v.x * dir.y - v.y * dir.x)
            guard off <= tol else { continue }
            let along = simd_dot(v, dir)
            guard along >= tol else { continue }
            let past = along + tol >= d
            let far = prev + dir * (d + r)
            let onArc = curve.shape.distance(to: far) < 1e-6
            let nearCurve = curve.shape.distance(to: lp) < tol * 0.8
            let rim = nearCurve && onArc && past && simd_distance(far, lp) <= tol
            let atCentre = simd_distance(lp, o) <= tol
            var at: Point2
            var target: SnapTarget
            if rim, !atCentre || simd_distance(far, lp) <= simd_distance(lp, o) {
                at = far
                target = .throughCenter(curve.ref, rim: true, atCenter: false)
            } else if atCentre {
                at = o
                target = .throughCenter(curve.ref, rim: false, atCenter: true)
            } else if past {
                at = prev + dir * along
                if simd_distance(at, o) <= tol {
                    at = o
                    target = .throughCenter(curve.ref, rim: false, atCenter: true)
                } else {
                    target = .throughCenter(curve.ref, rim: false, atCenter: false)
                }
            } else {
                continue
            }
            guard simd_distance(at, prev) >= 1e-6 else { continue }
            let distance = simd_distance(at, lp)
            if distance <= tol, distance < (best?.distance ?? .infinity) {
                best = (distance, SnapCandidate(point: at, target: target, guide: (prev, at), label: "Ctr"))
            }
        }
        return best?.candidate
    }

    /// Parallel bzw. senkrecht zu einer schrägen Linie (vom vorigen Punkt aus) oder auf der Verlängerung einer Linie.
    func lineInference(prev: Point2, lp: Point2, tolerance tol: Double) -> SnapCandidate? {
        let v = lp - prev
        guard simd_length(v) >= tol * 2 else { return nil }
        var best: (distance: Double, candidate: SnapCandidate)?
        func offer(_ distance: Double, _ candidate: SnapCandidate) {
            if distance < (best?.distance ?? .infinity) { best = (distance, candidate) }
        }
        for curve in curves where !curve.construction {
            guard case .line(let a, let b) = curve.shape else { continue }
            let length = simd_distance(a, b)
            guard length > 1e-9 else { continue }
            let dir = (b - a) / length
            // Achsparallele Richtungen übernimmt H/V
            let axis = abs(dir.x) < 1e-9 || abs(dir.y) < 1e-9
            let touches = simd_distance(a, prev) < 1e-9 || simd_distance(b, prev) < 1e-9
            if !axis {
                let perpendicular = Point2(-dir.y, dir.x)
                for (isParallel, d) in [(true, dir), (false, perpendicular)] {
                    if isParallel, touches { continue }
                    let t = simd_dot(v, d)
                    let at = prev + d * t
                    let e = simd_distance(at, lp)
                    guard e < tol else { continue }
                    let sign: Double = t < 0 ? -1 : 1
                    let guide = (prev - d * (sign * tol * 6), at + d * (sign * tol * 6))
                    let target: SnapTarget = isParallel ? .parallel(curve.ref) : .perpendicular(curve.ref)
                    offer(e, SnapCandidate(point: at, target: target, guide: guide, label: isParallel ? "//" : "⊥"))
                }
            }
            // Verlängerung über die Enden hinaus
            let s = simd_dot(lp - a, dir)
            if s < -tol || s > length + tol {
                let at = a + dir * s
                let e = simd_distance(at, lp)
                if e < tol * 0.8, !touches {
                    let from = s < 0 ? a : b
                    offer(e * 0.9, SnapCandidate(point: at, target: .lineExtension(curve.ref), guide: (from, at), label: "Ext"))
                }
            }
        }
        return best?.candidate
    }

    // MARK: Achsfang (sketch_dims.rs)

    /// Winkel bis limit neben 0/90/180/270° rasten genau dort ein.
    static func snapAxis(_ angle: Double, limit: Double) -> Double {
        let quarter = Double.pi / 2
        let k = (angle / quarter).rounded()
        return abs(angle - k * quarter) < limit ? k * quarter : angle
    }

    /// Linienende auf einer Kurve im Achsfang: wo die Waagerechte bzw. Senkrechte vom Start die Kurve nahe dem
    /// Stift schneidet (vom Kreiszentrum aus der Quadrantenpunkt), auf der Kurve und genau achsparallel.
    func onCurveAxis(start a: Point2, candidate: SnapCandidate, limit: Double) -> SnapCandidate? {
        guard case .onCurve(let ref)? = candidate.target, let curve = self.curve(ref) else { return nil }
        let v = candidate.point - a
        let length = simd_length(v)
        guard length > 1e-9 else { return nil }
        let angle = atan2(v.y, v.x)
        let snapped = Self.snapAxis(angle, limit: limit)
        guard snapped != angle else { return nil }
        let dir = Point2(cos(snapped), sin(snapped))
        let horizontal = abs(dir.y) < abs(dir.x)
        // Achse als lange Strecke ab dem Start
        let reach = length * 4 + 1
        let axis = TrimPrimitive.segment(a, a + dir * reach)
        let tol = 1e-9 * (1 + length)
        var best: (distance: Double, point: Point2)?
        for primitive in curve.shape.primitives {
            for hit in SketchTrim.intersections(axis, primitive) {
                let q = horizontal ? Point2(hit.x, a.y) : Point2(a.x, hit.y)
                guard simd_dot(q - a, dir) > tol, curve.shape.distance(to: q) <= max(tol, 1e-7),
                      simd_distance(q, candidate.point) <= length * 0.1 else { continue }
                let d = simd_distance(q, candidate.point)
                if d < (best?.distance ?? .infinity) { best = (d, q) }
            }
        }
        guard let best else { return nil }
        var result = candidate
        result.point = best.point
        return result
    }
}

extension SketchInference.Shape {
    /// Kreis bzw. Bogen: Mittelpunkt und Radius
    var round: (center: Point2, radius: Double)? {
        switch self {
        case .circle(let c, let r): return (c, r)
        case .arc(let arc): return (arc.center, arc.radius)
        default: return nil
        }
    }

    var isStraight: Bool {
        if case .line = self { return true }
        return false
    }

    /// Nächster Punkt der Kurve.
    func project(_ p: Point2) -> Point2 {
        switch self {
        case .line(let a, let b):
            let ab = b - a
            let l2 = simd_length_squared(ab)
            guard l2 > 1e-18 else { return a }
            let t = min(max(simd_dot(p - a, ab) / l2, 0), 1)
            return a + ab * t
        case .circle(let c, let r):
            let d = p - c
            let l = simd_length(d)
            return l > 1e-12 ? c + d / l * r : c + Point2(r, 0)
        case .arc(let arc):
            let d = p - arc.center
            let l = simd_length(d)
            let onCircle = l > 1e-12 ? arc.center + d / l * arc.radius : arc.point(0)
            if arc.parameter(onCircle) != nil { return onCircle }
            let s = arc.point(0), e = arc.point(1)
            return simd_distance(s, p) <= simd_distance(e, p) ? s : e
        case .polyline(let points):
            return polylineDistance(from: p, to: points, closed: false).point
        }
    }

    func distance(to p: Point2) -> Double {
        simd_distance(project(p), p)
    }

    /// Grundformen für Schnittpunkte
    var primitives: [TrimPrimitive] {
        switch self {
        case .line(let a, let b): return [.segment(a, b)]
        case .circle(let c, let r): return [.circle(center: c, radius: r)]
        case .arc(let arc): return [.arc(arc)]
        case .polyline(let points):
            guard points.count >= 2 else { return [] }
            return (0..<(points.count - 1)).map { TrimPrimitive.segment(points[$0], points[$0 + 1]) }
        }
    }

    /// Länge der Kurve (für den Radiusvorschlag des 2-Tangenten-Kreises)
    var length: Double {
        switch self {
        case .line(let a, let b): return simd_distance(a, b)
        case .circle(_, let r): return 2 * .pi * r
        case .arc(let arc): return abs(arc.sweep) * arc.radius
        case .polyline(let points):
            guard points.count >= 2 else { return 0 }
            var total = 0.0
            for k in 1..<points.count { total += simd_distance(points[k - 1], points[k]) }
            return total
        }
    }
}
